
-module(hayata_openai).

-behaviour(hayata_llm_adapter).

-export([
    capabilities/1,
    generate/2,
    generate_stream/3
]).

-ifdef(TEST).
-export([
    parse_sse_chunk/2,
    normalize_sse_event/2
]).
-endif.

-define(DEFAULT_BASE_URL, <<"https://api.openai.com/v1">>).
-define(DEFAULT_TIMEOUT, 30000).

-doc("Returns the capabilities currently implemented by the OpenAI adapter.").
-spec capabilities(map()) ->
    {ok, hayata_llm_adapter:capabilities()} |
    {error, hayata_llm_adapter:normalized_error()}.
capabilities(_Config) ->
    {ok, #{
        features => #{
            tool_calling => true,
            structured_output => false,
            streaming => true,
            embeddings => false
        },
        modalities => #{
            input => [text],
            output => [text]
        }
    }}.

-doc("Generates a normalized text response using the OpenAI Responses API.").
-spec generate(map(), map()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
generate(Request, Config) ->
    case validate_provider_config(Config) of
        ok ->
            case maps:find(api_key, Config) of
                {ok, ApiKey}
                        when is_binary(ApiKey),
                             byte_size(ApiKey) > 0 ->
                    case prepare_payload(Request) of
                        {ok, Payload} ->
                            send_request(Payload, ApiKey, Config);
                        {error, _Reason} ->
                            {error, #{code => invalid_request}}
                    end;
                _ ->
                    {error, #{code => authentication}}
            end;
        {error, _Reason} ->
            {error, #{code => invalid_request}}
    end.

-doc("Generates a normalized response and emits streaming events.").
-spec generate_stream(map(), map(), hayata_llm_adapter:consumer()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
generate_stream(Request, Config, Consumer)
        when is_function(Consumer, 1) ->
    case validate_provider_config(Config) of
        ok ->
            case maps:find(api_key, Config) of
                {ok, ApiKey}
                        when is_binary(ApiKey),
                             byte_size(ApiKey) > 0 ->
                    case prepare_payload(Request) of
                        {ok, Payload} ->
                            StreamPayload = Payload#{<<"stream">> => true},
                            send_stream_request(
                                StreamPayload,
                                ApiKey,
                                Config,
                                Consumer
                            );
                        {error, _Reason} ->
                            {error, #{code => invalid_request}}
                    end;
                _ ->
                    {error, #{code => authentication}}
            end;
        {error, _Reason} ->
            {error, #{code => invalid_request}}
    end;
generate_stream(_Request, _Config, _Consumer) ->
    {error, #{code => invalid_request}}.

-spec validate_provider_config(map()) -> ok | {error, term()}.
validate_provider_config(Config) when is_map(Config) ->
    case {
        maps:get(base_url, Config, ?DEFAULT_BASE_URL),
        maps:get(timeout, Config, ?DEFAULT_TIMEOUT)
    } of
        {BaseUrl, Timeout}
                when is_binary(BaseUrl),
                     byte_size(BaseUrl) > 0,
                     is_integer(Timeout),
                     Timeout > 0 ->
            ok;
        _ ->
            {error, invalid_provider_config}
    end;
validate_provider_config(_Config) ->
    {error, invalid_provider_config}.

-spec prepare_payload(map()) ->
    {ok, map()} | {error, term()}.
prepare_payload(#{model := Model, messages := Messages} = Request)
        when is_binary(Model), is_list(Messages) ->
    case convert_messages(Messages, []) of
        {ok, Input} ->
            Payload = #{
                <<"model">> => Model,
                <<"input">> => Input
            },
            case convert_tools(maps:get(tools, Request, [])) of
                {ok, []} ->
                    {ok, Payload};
                {ok, Tools} ->
                    {ok, Payload#{<<"tools">> => Tools}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end;
prepare_payload(_Request) ->
    {error, invalid_request}.

-spec convert_tools(term()) -> {ok, [map()]} | {error, term()}.
convert_tools(Tools) when is_list(Tools) ->
    convert_tools(Tools, []);
convert_tools(_Tools) ->
    {error, invalid_tools}.

-spec convert_tools([map()], [map()]) ->
    {ok, [map()]} | {error, term()}.
convert_tools([], Acc) ->
    {ok, lists:reverse(Acc)};
convert_tools([Tool | Rest], Acc) when is_map(Tool) ->
    case convert_tool(Tool) of
        {ok, Converted} ->
            convert_tools(Rest, [Converted | Acc]);
        {error, Reason} ->
            {error, Reason}
    end;
convert_tools(_Tools, _Acc) ->
    {error, invalid_tool_definition}.

-spec convert_tool(map()) -> {ok, map()} | {error, term()}.
convert_tool(#{
    name := Name,
    description := Description,
    parameters := Parameters
})
        when is_binary(Name),
             byte_size(Name) > 0,
             is_binary(Description),
             byte_size(Description) > 0,
             is_map(Parameters) ->
    case convert_parameter_schema(Parameters) of
        {ok, ConvertedParameters} ->
            {ok, #{
                <<"type">> => <<"function">>,
                <<"name">> => Name,
                <<"description">> => Description,
                <<"parameters">> => ConvertedParameters
            }};
        {error, Reason} ->
            {error, Reason}
    end;
convert_tool(_Tool) ->
    {error, invalid_tool_definition}.

-spec convert_parameter_schema(map()) ->
    {ok, map()} | {error, term()}.
convert_parameter_schema(Schema) when is_map(Schema) ->
    convert_schema_value(maps:to_list(Schema), #{});
convert_parameter_schema(_Schema) ->
    {error, invalid_tool_schema}.

-spec convert_schema_value([{term(), term()}], map()) ->
    {ok, map()} | {error, term()}.
convert_schema_value([{type, Type} | Rest], Acc) ->
    case schema_type(Type) of
        {ok, JsonType} ->
            convert_schema_value(
                Rest,
                maps:put(<<"type">>, JsonType, Acc)
            );
        error ->
            {error, invalid_tool_schema}
    end;
convert_schema_value([{properties, Properties} | Rest], Acc)
        when is_map(Properties) ->
    case convert_schema_properties(maps:to_list(Properties), #{}) of
        {ok, ConvertedProperties} ->
            convert_schema_value(
                Rest,
                maps:put(<<"properties">>, ConvertedProperties, Acc)
            );
        {error, Reason} ->
            {error, Reason}
    end;
convert_schema_value([{required, Required} | Rest], Acc)
        when is_list(Required) ->
    case convert_required(Required, []) of
        {ok, ConvertedRequired} ->
            convert_schema_value(
                Rest,
                maps:put(<<"required">>, ConvertedRequired, Acc)
            );
        {error, Reason} ->
            {error, Reason}
    end;
convert_schema_value([{Key, Value} | Rest], Acc)
        when Key =:= additionalProperties;
             Key =:= enum;
             Key =:= description ->
    convert_schema_value(
        Rest,
        maps:put(atom_to_binary(Key, utf8), Value, Acc)
    );
convert_schema_value([], Acc) ->
    {ok, Acc};
convert_schema_value(_Other, _Acc) ->
    {error, invalid_tool_schema}.

-spec schema_type(term()) -> {ok, binary()} | error.
schema_type(object) -> {ok, <<"object">>};
schema_type(string) -> {ok, <<"string">>};
schema_type(number) -> {ok, <<"number">>};
schema_type(integer) -> {ok, <<"integer">>};
schema_type(boolean) -> {ok, <<"boolean">>};
schema_type(_Type) -> error.

-spec convert_schema_properties([{term(), term()}], map()) ->
    {ok, map()} | {error, term()}.
convert_schema_properties([{Name, Schema} | Rest], Acc)
        when is_atom(Name); is_binary(Name) ->
    case convert_parameter_schema(Schema) of
        {ok, ConvertedSchema} ->
            convert_schema_properties(
                Rest,
                maps:put(normalize_tool_name(Name), ConvertedSchema, Acc)
            );
        {error, Reason} ->
            {error, Reason}
    end;
convert_schema_properties([], Acc) ->
    {ok, Acc};
convert_schema_properties(_Properties, _Acc) ->
    {error, invalid_tool_schema}.

-spec convert_required([term()], [binary()]) ->
    {ok, [binary()]} | {error, term()}.
convert_required([Name | Rest], Acc)
        when is_atom(Name); is_binary(Name) ->
    convert_required(
        Rest,
        [normalize_tool_name(Name) | Acc]
    );
convert_required([], Acc) ->
    {ok, lists:reverse(Acc)};
convert_required(_Required, _Acc) ->
    {error, invalid_tool_schema}.

-spec normalize_tool_name(atom() | binary()) -> binary().
normalize_tool_name(Name) when is_atom(Name) ->
    atom_to_binary(Name, utf8);
normalize_tool_name(Name) when is_binary(Name) ->
    Name.

-spec convert_messages(list(), list()) ->
    {ok, list()} | {error, term()}.
convert_messages([], Acc) ->
    {ok, lists:reverse(Acc)};
convert_messages([Message | Rest], Acc) ->
    case convert_message(Message) of
        {ok, Converted} ->
            convert_messages(Rest, lists:reverse(Converted) ++ Acc);
        {error, Reason} ->
            {error, Reason}
    end.

-spec convert_message(map()) ->
    {ok, [map()]} | {error, term()}.
convert_message(#{
    role := assistant,
    content := Content,
    tool_calls := ToolCalls
}) when is_list(Content), is_list(ToolCalls) ->
    case convert_content(Content, []) of
        {ok, TextBlocks} ->
            convert_assistant_tool_message(
                lists:reverse(TextBlocks),
                ToolCalls
            );
        {error, Reason} ->
            {error, Reason}
    end;
convert_message(#{
    role := tool,
    tool_call_id := CallId,
    content := Content
}) when is_binary(CallId), is_list(Content) ->
    case convert_tool_output(Content, []) of
        {ok, Output} ->
            {ok, [
                #{
                    <<"type">> => <<"function_call_output">>,
                    <<"call_id">> => CallId,
                    <<"output">> => Output
                }
            ]};
        {error, Reason} ->
            {error, Reason}
    end;
convert_message(#{role := Role, content := Content})
        when is_atom(Role), is_list(Content) ->
    case lists:member(Role, [system, developer, user, assistant]) of
        true ->
            case convert_content(Content, []) of
                {ok, TextBlocks} ->
                    {ok, [
                        #{
                            <<"role">> => atom_to_binary(Role, utf8),
                            <<"content">> => lists:reverse(TextBlocks)
                        }
                    ]};
                {error, Reason} ->
                    {error, Reason}
            end;
        false ->
            {error, unsupported_message_role}
    end;
convert_message(_Message) ->
    {error, invalid_message}.

-spec convert_assistant_tool_message([map()], [map()]) ->
    {ok, [map()]} | {error, term()}.
convert_assistant_tool_message(TextBlocks, ToolCalls) ->
    case convert_tool_calls(ToolCalls, []) of
        {ok, ConvertedCalls} ->
            MessageItems = case TextBlocks of
                [] ->
                    [];
                _ ->
                    [#{
                        <<"role">> => <<"assistant">>,
                        <<"content">> => TextBlocks
                    }]
            end,
            {ok, MessageItems ++ ConvertedCalls};
        {error, Reason} ->
            {error, Reason}
    end.

-spec convert_tool_calls([map()], [map()]) ->
    {ok, [map()]} | {error, term()}.
convert_tool_calls([], Acc) ->
    {ok, lists:reverse(Acc)};
convert_tool_calls([
    #{
        id := CallId,
        name := Name,
        arguments := Arguments
    } | Rest
], Acc)
        when is_binary(CallId), byte_size(CallId) > 0,
             is_binary(Name), byte_size(Name) > 0,
             is_map(Arguments) ->
    case encode_tool_arguments(Arguments) of
        {ok, EncodedArguments} ->
            Call = #{
                <<"type">> => <<"function_call">>,
                <<"call_id">> => CallId,
                <<"name">> => Name,
                <<"arguments">> => EncodedArguments
            },
            convert_tool_calls(Rest, [Call | Acc]);
        {error, Reason} ->
            {error, Reason}
    end;
convert_tool_calls(_ToolCalls, _Acc) ->
    {error, invalid_tool_call}.

-spec encode_tool_arguments(map()) -> {ok, binary()} | {error, term()}.
encode_tool_arguments(Arguments) ->
    try json:encode(normalize_json_keys(Arguments)) of
        Encoded when is_binary(Encoded) ->
            {ok, Encoded};
        Encoded ->
            {ok, iolist_to_binary(Encoded)}
    catch
        _:_ ->
            {error, invalid_tool_arguments}
    end.

-spec normalize_json_keys(map()) -> map().
normalize_json_keys(Map) when is_map(Map) ->
    maps:from_list([
        {normalize_json_key(Key), normalize_json_value(Value)}
        || {Key, Value} <- maps:to_list(Map)
    ]).

-spec normalize_json_key(atom() | binary()) -> binary().
normalize_json_key(Key) when is_atom(Key) ->
    atom_to_binary(Key, utf8);
normalize_json_key(Key) when is_binary(Key) ->
    Key.

-spec normalize_json_value(term()) -> term().
normalize_json_value(Value) when is_map(Value) ->
    normalize_json_keys(Value);
normalize_json_value(Value) when is_list(Value) ->
    [normalize_json_value(Item) || Item <- Value];
normalize_json_value(Value) ->
    Value.

-spec convert_tool_output(list(), list()) ->
    {ok, binary()} | {error, term()}.
convert_tool_output([], Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc))};
convert_tool_output([
    #{type := text, text := Text} | Rest
], Acc) when is_binary(Text) ->
    convert_tool_output(Rest, [Text | Acc]);
convert_tool_output(_Content, _Acc) ->
    {error, unsupported_content}.

-spec convert_content(list(), list()) ->
    {ok, list()} | {error, term()}.
convert_content([], Acc) ->
    {ok, Acc};
convert_content([#{type := text, text := Text} | Rest], Acc)
        when is_binary(Text) ->
    Block = #{
        <<"type">> => <<"input_text">>,
        <<"text">> => Text
    },
    convert_content(Rest, [Block | Acc]);
convert_content(_Content, _Acc) ->
    {error, unsupported_content}.

-spec send_request(map(), binary(), map()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
send_request(Payload, ApiKey, Config) ->
    BaseUrl = maps:get(base_url, Config, ?DEFAULT_BASE_URL),
    Timeout = maps:get(timeout, Config, ?DEFAULT_TIMEOUT),
    Url = binary_to_list(<<BaseUrl/binary, "/responses">>),
    Headers = [
        {"authorization", "Bearer " ++ binary_to_list(ApiKey)},
        {"accept", "application/json"}
    ],
    Body = iolist_to_binary(json:encode(Payload)),
    HttpOptions = [
        {timeout, Timeout},
        {connect_timeout, Timeout},
        {ssl, [
            {verify, verify_peer},
            {cacerts, public_key:cacerts_get()}
        ]}
    ],
    Request = {
        Url,
        Headers,
        "application/json",
        Body
    },
    case httpc:request(
        post,
        Request,
        HttpOptions,
        [{body_format, binary}]
    ) of
        {ok, {{_Version, 200, _ReasonPhrase}, _ResponseHeaders, ResponseBody}} ->
            decode_response(ResponseBody);
        {ok, {{_Version, Status, _ReasonPhrase}, _Headers, ResponseBody}} ->
            normalize_http_error(Status, ResponseBody);
        {error, timeout} ->
            {error, #{code => timeout}};
        {error, _Reason} ->
            {error, #{code => provider_error}}
    end.

-spec send_stream_request(map(), binary(), map(), hayata_llm_adapter:consumer()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
send_stream_request(Payload, ApiKey, Config, Consumer) ->
    BaseUrl = maps:get(base_url, Config, ?DEFAULT_BASE_URL),
    Timeout = maps:get(timeout, Config, ?DEFAULT_TIMEOUT),
    Url = binary_to_list(<<BaseUrl/binary, "/responses">>),
    Headers = [
        {"authorization", "Bearer " ++ binary_to_list(ApiKey)},
        {"accept", "text/event-stream"}
    ],
    StreamPayload = Payload#{<<"stream">> => true},
    Body = iolist_to_binary(json:encode(StreamPayload)),
    HttpOptions = [
        {timeout, Timeout},
        {connect_timeout, Timeout},
        {ssl, [
            {verify, verify_peer},
            {cacerts, public_key:cacerts_get()}
        ]}
    ],
    Request = {Url, Headers, "application/json", Body},
    RequestOptions = [
        {sync, false},
        {stream, {self, once}},
        {body_format, binary}
    ],
    case httpc:request(
        post,
        Request,
        HttpOptions,
        RequestOptions
    ) of
        {ok, RequestId} ->
            receive_stream_response(
                RequestId,
                Timeout,
                Consumer,
                #{buffer => <<>>, event => undefined, data => []},
                #{}
            );
        {error, timeout} ->
            {error, #{code => timeout}};
        {error, _Reason} ->
            {error, #{code => provider_error}}
    end.

-spec receive_stream_response(
    term(),
    pos_integer(),
    hayata_llm_adapter:consumer(),
    map(),
    map()
) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
receive_stream_response(RequestId, Timeout, Consumer, ParserState, EventState) ->
    receive
        {http, {RequestId, stream_start, Headers, HandlerPid}} ->
            case stream_response_status(Headers) of
                ok ->
                    httpc:stream_next(HandlerPid),
                    receive_stream_chunk(
                        RequestId,
                        HandlerPid,
                        Timeout,
                        Consumer,
                        ParserState,
                        EventState
                    );
                {error, Error} ->
                    httpc:cancel_request(RequestId),
                    {error, Error}
            end;
        {http, {RequestId, {{_Version, Status, _Reason}, _Headers, Body}}} ->
            normalize_http_error(Status, Body);
        {http, {RequestId, {error, timeout}}} ->
            {error, #{code => timeout}};
        {http, {RequestId, {error, _Reason}}} ->
            {error, #{code => provider_error}}
    after Timeout ->
        httpc:cancel_request(RequestId),
        {error, #{code => timeout}}
    end.

-spec receive_stream_chunk(
    term(),
    pid(),
    pos_integer(),
    hayata_llm_adapter:consumer(),
    map(),
    map()
) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
receive_stream_chunk(
    RequestId,
    HandlerPid,
    Timeout,
    Consumer,
    ParserState,
    EventState
) ->
    receive
        {http, {RequestId, stream, Chunk}} ->
            case process_stream_chunk(
                Chunk,
                Consumer,
                ParserState,
                EventState
            ) of
                {ok, NextParserState, NextEventState} ->
                    case maps:find(response, NextEventState) of
                        {ok, Response} ->
                            {ok, Response};
                        error ->
                            httpc:stream_next(HandlerPid),
                            receive_stream_chunk(
                                RequestId,
                                HandlerPid,
                                Timeout,
                                Consumer,
                                NextParserState,
                                NextEventState
                            )
                    end;
                {error, Error} ->
                    httpc:cancel_request(RequestId),
                    {error, Error}
            end;
        {http, {RequestId, stream_end, _Headers}} ->
            case maps:find(response, EventState) of
                {ok, Response} ->
                    {ok, Response};
                error ->
                    {error, #{code => invalid_response}}
            end;
        {http, {RequestId, {error, timeout}}} ->
            {error, #{code => timeout}};
        {http, {RequestId, {error, _Reason}}} ->
            {error, #{code => provider_error}}
    after Timeout ->
        httpc:cancel_request(RequestId),
        {error, #{code => timeout}}
    end.


-spec process_stream_chunk(binary(), hayata_llm_adapter:consumer(), map(), map()) ->
    {ok, map(), map()} |
    {error, hayata_llm_adapter:normalized_error()}.
process_stream_chunk(Chunk, Consumer, ParserState, EventState) ->
    {Events, NextParserState} =
        parse_sse_chunk(Chunk, ParserState),

    case process_stream_events(Events, Consumer, EventState) of
        {ok, NextEventState} ->
            case maps:find(error, NextEventState) of
                {ok, Error} ->
                    {error, Error};
                error ->
                    {ok, NextParserState, NextEventState}
            end;
        {error, Error} ->
            {error, Error}
    end.

-spec process_stream_events([map()], hayata_llm_adapter:consumer(), map()) ->
    {ok, map()} |
    {error, hayata_llm_adapter:normalized_error()}.
process_stream_events([], _Consumer, EventState) ->
    {ok, EventState};
process_stream_events([Event | Rest], Consumer, EventState) ->
    case normalize_sse_event(Event, EventState) of
        {ok, NormalizedEvents, NextEventState} ->
            case deliver_stream_events(NormalizedEvents, Consumer) of
                ok ->
                    process_stream_events(
                        Rest,
                        Consumer,
                        NextEventState
                    );
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error, _NextEventState} ->
            {error, Error}
    end.

-spec deliver_stream_events([map()], hayata_llm_adapter:consumer()) ->
    ok | {error, hayata_llm_adapter:normalized_error()}.
deliver_stream_events([], _Consumer) ->
    ok;
deliver_stream_events([Event | Rest], Consumer) ->
    try Consumer(Event) of
        ok ->
            deliver_stream_events(Rest, Consumer);
        {error, Reason} ->
            {error, #{code => cancelled, reason => Reason}};
        _Other ->
            {error, #{code => invalid_response}}
    catch
        _:_ ->
            {error, #{code => cancelled, reason => consumer_failed}}
    end.

-spec stream_response_status(list()) ->
    ok | {error, hayata_llm_adapter:normalized_error()}.
stream_response_status(Headers) ->
    case lists:keyfind("content-type", 1, Headers) of
        {_, ContentType} ->
            case string:find(
                string:lowercase(ContentType),
                "text/event-stream"
            ) of
                nomatch ->
                    {error, #{code => invalid_response}};
                _ ->
                    ok
            end;
        false ->
            {error, #{code => invalid_response}}
    end.

-spec decode_response(binary()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
decode_response(Body) ->
    try json:decode(Body) of
        Response when is_map(Response) ->
            normalize_response(Response);
        _Other ->
            {error, #{code => invalid_response}}
    catch
        _:_ ->
            {error, #{code => invalid_response}}
    end.

-spec normalize_response(map()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
normalize_response(
    #{<<"status">> := <<"completed">>,
      <<"output">> := Output} = Response
) when is_list(Output) ->
    case {
        extract_text(Output, []),
        extract_tool_calls(Output, [])
    } of
        {{ok, Text}, {ok, []}} when byte_size(Text) > 0 ->
            {ok, #{
                message => #{
                    role => assistant,
                    content => [#{type => text, text => Text}]
                },
                finish_reason => stop,
                id => maps:get(<<"id">>, Response, undefined)
            }};
        {{ok, Text}, {ok, ToolCalls}} when ToolCalls =/= [] ->
            Content = case Text of
                <<>> -> [];
                _ -> [#{type => text, text => Text}]
            end,
            {ok, #{
                message => #{
                    role => assistant,
                    content => Content,
                    tool_calls => ToolCalls
                },
                finish_reason => tool_calls,
                id => maps:get(<<"id">>, Response, undefined)
            }};
        _ ->
            {error, #{code => invalid_response}}
    end;
normalize_response(
    #{<<"status">> := <<"incomplete">>,
      <<"incomplete_details">> := Details}
) ->
    normalize_incomplete(Details);
normalize_response(_Response) ->
    {error, #{code => invalid_response}}.

-spec extract_text(list(), list()) ->
    {ok, binary()} | {error, term()}.
extract_text([], Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc))};
extract_text([
    #{<<"type">> := <<"message">>,
      <<"content">> := Content} | Rest
], Acc) ->
    case extract_content_text(Content, Acc) of
        {ok, NextAcc} ->
            extract_text(Rest, NextAcc);
        {error, Reason} ->
            {error, Reason}
    end;
extract_text([_Other | Rest], Acc) ->
    extract_text(Rest, Acc).

-spec extract_content_text(list(), list()) ->
    {ok, list()} | {error, term()}.
extract_content_text([], Acc) ->
    {ok, Acc};
extract_content_text([
    #{<<"type">> := <<"output_text">>,
      <<"text">> := Text} | Rest
], Acc) when is_binary(Text) ->
    extract_content_text(Rest, [Text | Acc]);
extract_content_text([_Other | Rest], Acc) ->
    extract_content_text(Rest, Acc).

-spec extract_tool_calls(list(), list()) ->
    {ok, [hayata_llm_adapter:tool_call()]} | {error, term()}.
extract_tool_calls([], Acc) ->
    {ok, lists:reverse(Acc)};
extract_tool_calls([
    #{<<"type">> := <<"function_call">>,
      <<"call_id">> := Id,
      <<"name">> := Name,
      <<"arguments">> := Arguments} | Rest
], Acc)
        when is_binary(Id), byte_size(Id) > 0,
             is_binary(Name), byte_size(Name) > 0,
             is_binary(Arguments) ->
    case decode_tool_arguments(Arguments) of
        {ok, ParsedArguments} ->
            ToolCall = #{
                id => Id,
                name => Name,
                arguments => ParsedArguments
            },
            extract_tool_calls(Rest, [ToolCall | Acc]);
        {error, Reason} ->
            {error, Reason}
    end;
extract_tool_calls([
    #{<<"type">> := <<"function_call">>} | _Rest
], _Acc) ->
    {error, invalid_tool_call};
extract_tool_calls([_Other | Rest], Acc) ->
    extract_tool_calls(Rest, Acc).

-spec decode_tool_arguments(binary()) -> {ok, map()} | {error, term()}.
decode_tool_arguments(Arguments) ->
    try json:decode(Arguments) of
        ParsedArguments when is_map(ParsedArguments) ->
            {ok, ParsedArguments};
        _Other ->
            {error, invalid_tool_arguments}
    catch
        _:_ ->
            {error, invalid_tool_arguments}
    end.

-spec normalize_incomplete(map()) ->
    {error, hayata_llm_adapter:normalized_error()}.
normalize_incomplete(#{<<"reason">> := <<"max_output_tokens">>}) ->
    {error, #{
        code => provider_error,
        reason => max_output_tokens
    }};
normalize_incomplete(#{<<"reason">> := <<"content_filter">>}) ->
    {error, #{
        code => provider_error,
        reason => content_filter
    }};
normalize_incomplete(_Details) ->
    {error, #{code => invalid_response}}.

-spec normalize_http_error(non_neg_integer(), binary()) ->
    {error, hayata_llm_adapter:normalized_error()}.
normalize_http_error(401, _Body) ->
    {error, #{code => authentication}};
normalize_http_error(403, _Body) ->
    {error, #{code => authentication}};
normalize_http_error(408, _Body) ->
    {error, #{code => timeout}};
normalize_http_error(429, _Body) ->
    {error, #{code => rate_limited}};
normalize_http_error(400, _Body) ->
    {error, #{code => invalid_request}};
normalize_http_error(504, _Body) ->
    {error, #{code => timeout}};
normalize_http_error(Status, _Body) when Status >= 500 ->
    {error, #{code => provider_error}};
normalize_http_error(_Status, _Body) ->
    {error, #{code => provider_error}}.

-spec parse_sse_chunk(binary(), map()) ->
    {[map()], map()}.
parse_sse_chunk(Chunk, State) when is_binary(Chunk), is_map(State) ->
    Buffer = maps:get(buffer, State, <<>>),
    Data = <<Buffer/binary, Chunk/binary>>,
    split_sse_lines(Data, State#{buffer => <<>>}, []).

-spec split_sse_lines(binary(), map(), [map()]) ->
    {[map()], map()}.
split_sse_lines(Buffer, State, Acc) ->
    case binary:match(Buffer, <<"\n">>) of
        {Position, 1} ->
            Line0 = binary:part(Buffer, 0, Position),
            RestStart = Position + 1,
            Rest = binary:part(
                Buffer,
                RestStart,
                byte_size(Buffer) - RestStart
            ),
            Line = strip_sse_carriage_return(Line0),
            {Events, NextState} = process_sse_line(Line, State),
            split_sse_lines(
                Rest,
                NextState,
                lists:reverse(Events) ++ Acc
            );
        nomatch ->
            {lists:reverse(Acc), State#{buffer => Buffer}}
    end.

-spec strip_sse_carriage_return(binary()) -> binary().
strip_sse_carriage_return(Line) ->
    case byte_size(Line) of
        0 ->
            Line;
        Size ->
            case binary:at(Line, Size - 1) of
                $\r -> binary:part(Line, 0, Size - 1);
                _ -> Line
            end
    end.

-spec process_sse_line(binary(), map()) ->
    {[map()], map()}.
process_sse_line(<<>>, State) ->
    dispatch_sse_event(State);
process_sse_line(<<":", _Comment/binary>>, State) ->
    {[], State};
process_sse_line(Line, State) ->
    {Field, Value} = split_sse_field(Line),
    update_sse_field(Field, Value, State).

-spec split_sse_field(binary()) -> {binary(), binary()}.
split_sse_field(Line) ->
    case binary:match(Line, <<":">>) of
        {Position, 1} ->
            Field = binary:part(Line, 0, Position),
            ValueStart = Position + 1,
            Value0 = binary:part(
                Line,
                ValueStart,
                byte_size(Line) - ValueStart
            ),
            Value = remove_sse_leading_space(Value0),
            {Field, Value};
        nomatch ->
            {Line, <<>>}
    end.

-spec remove_sse_leading_space(binary()) -> binary().
remove_sse_leading_space(<<" ", Rest/binary>>) ->
    Rest;
remove_sse_leading_space(Value) ->
    Value.

-spec update_sse_field(binary(), binary(), map()) ->
    {[map()], map()}.
update_sse_field(<<"event">>, Value, State) ->
    {[], State#{event => Value}};
update_sse_field(<<"data">>, Value, State) ->
    Data = maps:get(data, State, []),
    {[], State#{data => [Value | Data]}};
update_sse_field(_Field, _Value, State) ->
    {[], State}.

-spec dispatch_sse_event(map()) -> {[map()], map()}.
dispatch_sse_event(State) ->
    Data = maps:get(data, State, []),
    Event = maps:get(event, State, undefined),
    NextState = State#{event => undefined, data => []},
    case Data of
        [] ->
            {[], NextState};
        _ ->
            Name = case Event of
                undefined -> <<"message">>;
                _ -> Event
            end,
            Payload = iolist_to_binary(
                lists:join(<<"\n">>, lists:reverse(Data))
            ),
            {[#{event => Name, data => Payload}], NextState}
    end.

-spec normalize_sse_event(map(), map()) ->
    {ok, [hayata_llm_adapter:stream_event()], map()} |
    {error, hayata_llm_adapter:normalized_error(), map()}.
normalize_sse_event(_Event, #{terminal := true} = State) ->
    {error, #{code => invalid_response, reason => event_after_terminal}, State};
normalize_sse_event(
    #{event := <<"response.created">>, data := Data},
    State
) ->
    case decode_sse_data(Data) of
        {ok, #{<<"response">> := #{<<"id">> := Id}}}
                when is_binary(Id), byte_size(Id) > 0 ->
            Event = stream_event(
                message_started,
                Id,
                #{response_id => Id}
            ),
            {ok, [Event], State#{generation_id => Id}};
        _ ->
            {error, #{code => invalid_response}, State}
    end;
normalize_sse_event(
    #{event := <<"response.output_text.delta">>, data := Data},
    State
) ->
    case {
        maps:find(generation_id, State),
        decode_sse_data(Data)
    } of
        {{ok, GenerationId},
         {ok, #{
             <<"delta">> := Delta,
             <<"output_index">> := OutputIndex,
             <<"content_index">> := ContentIndex
         }}}
                when is_binary(Delta),
                     is_integer(OutputIndex),
                     OutputIndex >= 0,
                     is_integer(ContentIndex),
                     ContentIndex >= 0 ->
            Event = stream_event(
                content_delta,
                GenerationId,
                #{
                    text => Delta,
                    message_index => OutputIndex,
                    content_index => ContentIndex
                }
            ),
            {ok, [Event], State};
        _ ->
            {error, #{code => invalid_response}, State}
    end;
normalize_sse_event(
    #{event := <<"response.completed">>, data := Data},
    State
) ->
    case {
        maps:find(generation_id, State),
        decode_sse_data(Data)
    } of
        {{ok, GenerationId},
         {ok, #{<<"response">> := Response}}}
                when is_map(Response) ->
            case maps:get(<<"id">>, Response, undefined) of
                GenerationId ->
                    case normalize_response(Response) of
                        {ok, FinalResponse} ->
                            Message = maps:get(message, FinalResponse),
                            FinishReason = maps:get(
                                finish_reason,
                                FinalResponse
                            ),
                            Events = [
                                stream_event(
                                    message_completed,
                                    GenerationId,
                                    #{
                                        message => Message,
                                        finish_reason => FinishReason
                                    }
                                ),
                                stream_event(
                                    generation_completed,
                                    GenerationId,
                                    #{
                                        finish_reason => FinishReason
                                    }
                                )
                            ],
                            {ok, Events, State#{
                                terminal => true,
                                response => FinalResponse
                            }};
                        {error, Error} ->
                            {error, Error, State}
                    end;
                _OtherId ->
                    {error, #{
                        code => invalid_response,
                        reason => inconsistent_generation_id
                    }, State}
            end;
        _ ->
            {error, #{code => invalid_response}, State}
    end;
normalize_sse_event(
    #{event := <<"response.failed">>},
    State
) ->
    normalize_sse_failure(State);
normalize_sse_event(
    #{event := <<"error">>},
    State
) ->
    normalize_sse_failure(State);
normalize_sse_event(_Event, State) ->
    {ok, [], State}.

-spec decode_sse_data(binary()) -> {ok, map()} | {error, term()}.
decode_sse_data(Data) when is_binary(Data) ->
    try json:decode(Data) of
        Payload when is_map(Payload) ->
            {ok, Payload};
        _Other ->
            {error, invalid_json_payload}
    catch
        _:_ ->
            {error, invalid_json_payload}
    end;
decode_sse_data(_Data) ->
    {error, invalid_json_payload}.

-spec normalize_sse_failure(map()) ->
    {ok, [hayata_llm_adapter:stream_event()], map()} |
    {error, hayata_llm_adapter:normalized_error(), map()}.
normalize_sse_failure(#{generation_id := GenerationId} = State) ->
    Error = #{code => provider_error},
    Event = stream_event(
        generation_failed,
        GenerationId,
        #{error => Error}
    ),
    {ok, [Event], State#{terminal => true, error => Error}};
normalize_sse_failure(State) ->
    {error, #{code => invalid_response}, State}.

-spec stream_event(atom(), term(), map()) ->
    hayata_llm_adapter:stream_event().
stream_event(Type, GenerationId, Data) ->
    #{
        type => Type,
        generation_id => GenerationId,
        data => Data
    }.
