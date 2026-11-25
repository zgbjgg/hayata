-module(hayata_anthropic).

-behaviour(hayata_llm_adapter).

-export([capabilities/1, generate/2, generate_stream/3]).

-ifdef(TEST).
-export([
    prepare_payload/1,
    normalize_response/1,
    normalize_http_error/2,
    parse_sse_chunk/2,
    normalize_sse_event/2
]).
-endif.

-define(DEFAULT_BASE_URL, <<"https://api.anthropic.com/v1">>).
-define(DEFAULT_TIMEOUT, 30000).
-define(DEFAULT_MAX_TOKENS, 1024).
-define(DEFAULT_API_VERSION, <<"2023-06-01">>).

%% @doc Returns the capabilities implemented by the Anthropic Messages adapter.
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
        modalities => #{input => [text], output => [text]}
    }}.

%% @doc Generates a normalized assistant message using Anthropic Messages API.
-spec generate(map(), map()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
generate(Request, Config) ->
    case credentials_and_config(Config) of
        {ok, ApiKey, BaseUrl, Timeout, ApiVersion} ->
            case prepare_payload(Request) of
                {ok, Payload} ->
                    send_request(Payload, ApiKey, BaseUrl, Timeout, ApiVersion);
                {error, _} ->
                    {error, #{code => invalid_request}}
            end;
        {error, Error} ->
            {error, Error}
    end.

%% @doc Generates a normalized response while forwarding normalized stream events.
-spec generate_stream(map(), map(), hayata_llm_adapter:consumer()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
generate_stream(Request, Config, Consumer) when is_function(Consumer, 1) ->
    case credentials_and_config(Config) of
        {ok, ApiKey, BaseUrl, Timeout, ApiVersion} ->
            case prepare_payload(Request) of
                {ok, Payload} ->
                    StreamPayload = Payload#{<<"stream">> => true},
                    send_stream_request(
                        StreamPayload, ApiKey, BaseUrl, Timeout,
                        ApiVersion, Consumer
                    );
                {error, _} ->
                    {error, #{code => invalid_request}}
            end;
        {error, Error} ->
            {error, Error}
    end;
generate_stream(_Request, _Config, _Consumer) ->
    {error, #{code => invalid_request}}.

-spec credentials_and_config(term()) ->
    {ok, binary(), binary(), pos_integer(), binary()} |
    {error, hayata_llm_adapter:normalized_error()}.
credentials_and_config(Config) when is_map(Config) ->
    case {
        maps:get(api_key, Config, undefined),
        maps:get(base_url, Config, ?DEFAULT_BASE_URL),
        maps:get(timeout, Config, ?DEFAULT_TIMEOUT),
        maps:get(api_version, Config, ?DEFAULT_API_VERSION)
    } of
        {ApiKey, BaseUrl, Timeout, ApiVersion}
                when is_binary(ApiKey), byte_size(ApiKey) > 0,
                     is_binary(BaseUrl), byte_size(BaseUrl) > 0,
                     is_integer(Timeout), Timeout > 0,
                     is_binary(ApiVersion), byte_size(ApiVersion) > 0 ->
            {ok, ApiKey, trim_trailing_slash(BaseUrl), Timeout, ApiVersion};
        {ApiKey, _BaseUrl, _Timeout, _ApiVersion}
                when not is_binary(ApiKey); byte_size(ApiKey) =:= 0 ->
            {error, #{code => authentication}};
        _ ->
            {error, #{code => invalid_request}}
    end;
credentials_and_config(_Config) ->
    {error, #{code => invalid_request}}.

-spec trim_trailing_slash(binary()) -> binary().
trim_trailing_slash(<<>>) -> <<>>;
trim_trailing_slash(Value) ->
    case binary:last(Value) of
        $/ -> trim_trailing_slash(binary:part(Value, 0, byte_size(Value) - 1));
        _ -> Value
    end.

%% Anthropic accepts system separately and only user/assistant in messages.
-spec prepare_payload(map()) -> {ok, map()} | {error, term()}.
prepare_payload(#{model := Model, messages := Messages} = Request)
        when is_binary(Model), byte_size(Model) > 0, is_list(Messages) ->
    case convert_messages(Messages, [], []) of
        {ok, SystemBlocks, ProviderMessages} when ProviderMessages =/= [] ->
            MaxTokens = maps:get(max_tokens, Request, ?DEFAULT_MAX_TOKENS),
            case is_integer(MaxTokens) andalso MaxTokens > 0 of
                false -> {error, invalid_max_tokens};
                true ->
                    Payload0 = #{
                        <<"model">> => Model,
                        <<"max_tokens">> => MaxTokens,
                        <<"messages">> => ProviderMessages
                    },
                    Payload1 = case SystemBlocks of
                        [] -> Payload0;
                        _ -> Payload0#{<<"system">> => SystemBlocks}
                    end,
                    case convert_tools(maps:get(tools, Request, [])) of
                        {ok, []} -> {ok, Payload1};
                        {ok, Tools} -> {ok, Payload1#{<<"tools">> => Tools}};
                        {error, Reason} -> {error, Reason}
                    end
            end;
        {ok, _SystemBlocks, []} -> {error, empty_messages};
        {error, Reason} -> {error, Reason}
    end;
prepare_payload(_Request) ->
    {error, invalid_request}.

-spec convert_messages(list(), [map()], [map()]) ->
    {ok, [map()], [map()]} | {error, term()}.
convert_messages([], SystemAcc, MessageAcc) ->
    {ok, lists:reverse(SystemAcc), lists:reverse(MessageAcc)};
convert_messages([#{role := system, content := Content} | Rest], SystemAcc, MessageAcc) ->
    case convert_content(Content) of
        {ok, Blocks} ->
            convert_messages(Rest, lists:reverse(Blocks) ++ SystemAcc, MessageAcc);
        Error -> Error
    end;
convert_messages([#{role := developer, content := Content} | Rest], SystemAcc, MessageAcc) ->
    case convert_content(Content) of
        {ok, Blocks} ->
            convert_messages(Rest, lists:reverse(Blocks) ++ SystemAcc, MessageAcc);
        Error -> Error
    end;
convert_messages([#{role := assistant, content := Content, tool_calls := ToolCalls} | Rest],
                 SystemAcc, MessageAcc) when is_list(Content), is_list(ToolCalls) ->
    case {convert_content(Content), convert_assistant_tool_calls(ToolCalls)} of
        {{ok, ContentBlocks}, {ok, ToolBlocks}} ->
            Message = #{
                <<"role">> => <<"assistant">>,
                <<"content">> => ContentBlocks ++ ToolBlocks
            },
            convert_messages(Rest, SystemAcc, [Message | MessageAcc]);
        {{error, Reason}, _} -> {error, Reason};
        {_, {error, Reason}} -> {error, Reason}
    end;
convert_messages([#{role := Role, content := Content} | Rest], SystemAcc, MessageAcc)
        when Role =:= user; Role =:= assistant ->
    case convert_message(Role, Content) of
        {ok, Message} ->
            convert_messages(Rest, SystemAcc, [Message | MessageAcc]);
        Error -> Error
    end;
convert_messages([#{role := tool, tool_call_id := CallId, content := Content} | Rest],
                 SystemAcc, MessageAcc)
        when is_binary(CallId), byte_size(CallId) > 0 ->
    ToolResult = #{
        <<"type">> => <<"tool_result">>,
        <<"tool_use_id">> => CallId,
        <<"content">> => content_to_text(Content)
    },
    append_tool_result(Rest, SystemAcc, MessageAcc, ToolResult);
convert_messages(_Messages, _SystemAcc, _MessageAcc) ->
    {error, invalid_message}.

-spec append_tool_result(list(), [map()], [map()], map()) ->
    {ok, [map()], [map()]} | {error, term()}.
append_tool_result([#{role := user, content := Content} | Rest], SystemAcc, MessageAcc, ToolResult) ->
    case convert_content(Content) of
        {ok, Blocks} ->
            Message = #{<<"role">> => <<"user">>, <<"content">> => Blocks ++ [ToolResult]},
            convert_messages(Rest, SystemAcc, [Message | MessageAcc]);
        Error -> Error
    end;
append_tool_result(Rest, SystemAcc, MessageAcc, ToolResult) ->
    Message = #{<<"role">> => <<"user">>, <<"content">> => [ToolResult]},
    convert_messages(Rest, SystemAcc, [Message | MessageAcc]).

-spec convert_assistant_tool_calls(list()) -> {ok, [map()]} | {error, term()}.
convert_assistant_tool_calls(Calls) -> convert_assistant_tool_calls(Calls, []).

-spec convert_assistant_tool_calls(list(), [map()]) -> {ok, [map()]} | {error, term()}.
convert_assistant_tool_calls([], Acc) -> {ok, lists:reverse(Acc)};
convert_assistant_tool_calls([#{id := Id, name := Name, arguments := Arguments} | Rest], Acc)
        when is_binary(Id), byte_size(Id) > 0,
             is_binary(Name), byte_size(Name) > 0, is_map(Arguments) ->
    try json:encode(json_key_map(Arguments)) of
        Encoded ->
            Block = #{
                <<"type">> => <<"tool_use">>,
                <<"id">> => Id,
                <<"name">> => Name,
                <<"input">> => json_key_map(Arguments)
            },
            _ = Encoded,
            convert_assistant_tool_calls(Rest, [Block | Acc])
    catch _:_ -> {error, invalid_tool_arguments} end;
convert_assistant_tool_calls(_Calls, _Acc) -> {error, invalid_tool_call}.

-spec convert_message(atom(), list()) -> {ok, map()} | {error, term()}.
convert_message(Role, Content) ->
    case convert_content(Content) of
        {ok, Blocks} ->
            {ok, #{
                <<"role">> => atom_to_binary(Role, utf8),
                <<"content">> => Blocks
            }};
        Error -> Error
    end.

-spec convert_content(list()) -> {ok, [map()]} | {error, term()}.
convert_content(Content) when is_list(Content) ->
    convert_content(Content, []);
convert_content(_Content) ->
    {error, invalid_content}.

-spec convert_content(list(), [map()]) -> {ok, [map()]} | {error, term()}.
convert_content([], Acc) -> {ok, lists:reverse(Acc)};
convert_content([#{type := text, text := Text} | Rest], Acc) when is_binary(Text) ->
    convert_content(Rest, [#{<<"type">> => <<"text">>, <<"text">> => Text} | Acc]);
convert_content(_Content, _Acc) ->
    {error, unsupported_content}.

-spec content_to_text(list()) -> binary().
content_to_text(Content) when is_list(Content) ->
    iolist_to_binary([
        Text || #{type := text, text := Text} <- Content, is_binary(Text)
    ]);
content_to_text(Text) when is_binary(Text) -> Text;
content_to_text(_Other) -> <<>>.

-spec convert_tools(term()) -> {ok, [map()]} | {error, term()}.
convert_tools(Tools) when is_list(Tools) -> convert_tools(Tools, []);
convert_tools(_Tools) -> {error, invalid_tools}.

-spec convert_tools(list(), [map()]) -> {ok, [map()]} | {error, term()}.
convert_tools([], Acc) -> {ok, lists:reverse(Acc)};
convert_tools([#{name := Name, description := Description, parameters := Schema} | Rest], Acc)
        when is_binary(Name), byte_size(Name) > 0,
             is_binary(Description), is_map(Schema) ->
    case normalize_schema(Schema) of
        {ok, JsonSchema} ->
            Tool = #{
                <<"name">> => Name,
                <<"description">> => Description,
                <<"input_schema">> => JsonSchema
            },
            convert_tools(Rest, [Tool | Acc]);
        Error -> Error
    end;
convert_tools(_Tools, _Acc) ->
    {error, invalid_tool_definition}.

-spec normalize_schema(map()) -> {ok, map()} | {error, term()}.
normalize_schema(Schema) ->
    try {ok, json_key_map(Schema)} catch _:_ -> {error, invalid_tool_schema} end.

-spec json_key_map(map()) -> map().
json_key_map(Map) when is_map(Map) ->
    maps:from_list([{json_key(K), json_value(V)} || {K, V} <- maps:to_list(Map)]).

-spec json_key(atom() | binary()) -> binary().
json_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
json_key(K) when is_binary(K) -> K.

-spec json_value(term()) -> term().
json_value(V) when is_map(V) -> json_key_map(V);
json_value(V) when is_list(V) -> [json_value(X) || X <- V];
json_value(V) when is_atom(V), V =:= true -> true;
json_value(V) when is_atom(V), V =:= false -> false;
json_value(V) when is_atom(V), V =:= null -> null;
json_value(V) -> V.

-spec send_request(map(), binary(), binary(), pos_integer(), binary()) ->
    {ok, hayata_llm_adapter:response()} | {error, hayata_llm_adapter:normalized_error()}.
send_request(Payload, ApiKey, BaseUrl, Timeout, ApiVersion) ->
    Url = binary_to_list(<<BaseUrl/binary, "/messages">>),
    Headers = request_headers(ApiKey, ApiVersion, "application/json"),
    Body = iolist_to_binary(json:encode(Payload)),
    HttpOptions = [{timeout, Timeout}, {connect_timeout, Timeout}] ++ ssl_options(),
    case httpc:request(post, {Url, Headers, "application/json", Body},
                       HttpOptions, [{body_format, binary}]) of
        {ok, {{_Version, 200, _Phrase}, _Headers, ResponseBody}} ->
            case decode_json(ResponseBody) of
                {ok, Json} -> normalize_response(Json);
                error -> {error, #{code => invalid_response}}
            end;
        {ok, {{_Version, Status, _Phrase}, _Headers, ResponseBody}} ->
            normalize_http_error(Status, ResponseBody);
        {error, timeout} -> {error, #{code => timeout}};
        {error, _Reason} -> {error, #{code => provider_error}}
    end.

-spec request_headers(binary(), binary(), string()) -> list().
request_headers(ApiKey, ApiVersion, Accept) ->
    [
        {"x-api-key", binary_to_list(ApiKey)},
        {"anthropic-version", binary_to_list(ApiVersion)},
        {"content-type", "application/json"},
        {"accept", Accept}
    ].

-spec ssl_options() -> list().
ssl_options() ->
    case application:get_env(ssl, verify) of
        {ok, verify_none} -> [{ssl, [{verify, verify_none}]}];
        _ -> [{ssl, [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}]}]
    end.

-spec decode_json(binary()) -> {ok, map()} | error.
decode_json(Body) ->
    try json:decode(Body) of
        Decoded when is_map(Decoded) -> {ok, Decoded};
        _ -> error
    catch _:_ -> error end.

-spec normalize_response(map()) ->
    {ok, hayata_llm_adapter:response()} | {error, hayata_llm_adapter:normalized_error()}.
normalize_response(#{
    <<"type">> := <<"message">>,
    <<"role">> := <<"assistant">>,
    <<"content">> := Content,
    <<"stop_reason">> := StopReason
} = Response) when is_list(Content) ->
    case normalize_blocks(Content, [], []) of
        {ok, TextBlocks, ToolCalls} ->
            FinishReason = normalize_stop_reason(StopReason, ToolCalls),
            case FinishReason of
                error -> {error, #{code => invalid_response}};
                _ ->
                    Message0 = #{role => assistant, content => lists:reverse(TextBlocks)},
                    Message = case ToolCalls of
                        [] -> Message0;
                        _ -> Message0#{tool_calls => lists:reverse(ToolCalls)}
                    end,
                    {ok, #{
                        message => Message,
                        finish_reason => FinishReason,
                        id => maps:get(<<"id">>, Response, <<>>)
                    }}
            end;
        error -> {error, #{code => invalid_response}}
    end;
normalize_response(_Response) ->
    {error, #{code => invalid_response}}.

-spec normalize_blocks(list(), [map()], [map()]) -> {ok, [map()], [map()]} | error.
normalize_blocks([], TextAcc, ToolAcc) -> {ok, TextAcc, ToolAcc};
normalize_blocks([#{<<"type">> := <<"text">>, <<"text">> := Text} | Rest], TextAcc, ToolAcc)
        when is_binary(Text) ->
    normalize_blocks(Rest, [#{type => text, text => Text} | TextAcc], ToolAcc);
normalize_blocks([#{
    <<"type">> := <<"tool_use">>,
    <<"id">> := Id,
    <<"name">> := Name,
    <<"input">> := Input
} | Rest], TextAcc, ToolAcc)
        when is_binary(Id), byte_size(Id) > 0,
             is_binary(Name), byte_size(Name) > 0, is_map(Input) ->
    ToolCall = #{id => Id, name => Name, arguments => atom_key_map(Input)},
    normalize_blocks(Rest, TextAcc, [ToolCall | ToolAcc]);
normalize_blocks(_Blocks, _TextAcc, _ToolAcc) -> error.

-spec atom_key_map(map()) -> map().
atom_key_map(Map) -> maps:from_list([{binary_key(K), atom_value(V)} || {K, V} <- maps:to_list(Map)]).

-spec binary_key(binary()) -> atom() | binary().
binary_key(Key) ->
    try binary_to_existing_atom(Key, utf8) catch _:_ -> Key end.

-spec atom_value(term()) -> term().
atom_value(Map) when is_map(Map) -> atom_key_map(Map);
atom_value(List) when is_list(List) -> [atom_value(V) || V <- List];
atom_value(V) -> V.

-spec normalize_stop_reason(binary(), list()) -> hayata_llm_adapter:finish_reason() | error.
normalize_stop_reason(<<"end_turn">>, []) -> stop;
normalize_stop_reason(<<"stop_sequence">>, []) -> stop;
normalize_stop_reason(<<"max_tokens">>, []) -> length;
normalize_stop_reason(<<"tool_use">>, [_ | _]) -> tool_calls;
normalize_stop_reason(<<"refusal">>, []) -> content_filter;
normalize_stop_reason(_Other, _ToolCalls) -> error.

-spec normalize_http_error(integer(), binary()) ->
    {error, hayata_llm_adapter:normalized_error()}.
normalize_http_error(401, _Body) -> {error, #{code => authentication}};
normalize_http_error(403, _Body) -> {error, #{code => authentication}};
normalize_http_error(408, _Body) -> {error, #{code => timeout}};
normalize_http_error(429, _Body) -> {error, #{code => rate_limited}};
normalize_http_error(Status, _Body) when Status >= 500 -> {error, #{code => provider_error}};
normalize_http_error(Status, _Body) when Status >= 400 -> {error, #{code => invalid_request}};
normalize_http_error(_Status, _Body) -> {error, #{code => provider_error}}.

%% Streaming SSE parser. It intentionally accepts fragmented transport chunks.
-spec parse_sse_chunk(binary(), map()) -> {ok, [map()], map()} | {error, term()}.
parse_sse_chunk(Chunk, State) when is_binary(Chunk), is_map(State) ->
    Buffer = <<(maps:get(buffer, State, <<>>))/binary, Chunk/binary>>,
    Lines = binary:split(Buffer, <<"\n">>, [global]),
    {Complete, [Tail]} = split_last(Lines),
    case parse_sse_lines(Complete, State#{buffer => <<>>}, []) of
        {ok, Events, NextState} ->
            {ok, Events, NextState#{buffer => Tail}};
        Error -> Error
    end.

-spec split_last(list()) -> {list(), list()}.
split_last(List) ->
    {lists:sublist(List, length(List) - 1), [lists:last(List)]}.

-spec parse_sse_lines(list(), map(), [map()]) -> {ok, [map()], map()} | {error, term()}.
parse_sse_lines([], State, Acc) -> {ok, lists:reverse(Acc), State};
parse_sse_lines([<<"\r">> | Rest], State, Acc) ->
    parse_sse_lines(Rest, State, Acc);
parse_sse_lines([<<>> | Rest], State, Acc) ->
    case dispatch_sse_event(State) of
        {ok, undefined} -> parse_sse_lines(Rest, State#{event => undefined, data => []}, Acc);
        {ok, Event} -> parse_sse_lines(Rest, State#{event => undefined, data => []}, [Event | Acc]);
        Error -> Error
    end;
parse_sse_lines([<<"event:", Value/binary>> | Rest], State, Acc) ->
    parse_sse_lines(Rest, State#{event => trim_ascii(Value)}, Acc);
parse_sse_lines([<<"data:", Value/binary>> | Rest], State, Acc) ->
    Data = maps:get(data, State, []),
    parse_sse_lines(Rest, State#{data => [trim_ascii(Value) | Data]}, Acc);
parse_sse_lines([_CommentOrUnknown | Rest], State, Acc) ->
    parse_sse_lines(Rest, State, Acc).

-spec trim_ascii(binary()) -> binary().
trim_ascii(Bin) -> string:trim(Bin, both, " \t\r").

-spec dispatch_sse_event(map()) -> {ok, map() | undefined} | {error, term()}.
dispatch_sse_event(State) ->
    case {maps:get(event, State, undefined), lists:reverse(maps:get(data, State, []))} of
        {undefined, _} -> {ok, undefined};
        {_Event, []} -> {ok, undefined};
        {Event, DataLines} ->
            Data = iolist_to_binary(lists:join(<<"\n">>, DataLines)),
            case decode_json(Data) of
                {ok, Json} -> {ok, #{event => Event, data => Json}};
                error -> {error, invalid_sse_json}
            end
    end.

-spec normalize_sse_event(map(), map()) -> {ok, map(), map()} | {error, term()}.
normalize_sse_event(#{event := EventName, data := Data}, State) ->
    GenerationId = maps:get(generation_id, State, make_ref()),
    State1 = State#{generation_id => GenerationId},
    case EventName of
        <<"message_start">> ->
            Event = #{type => message_started, generation_id => GenerationId, data => #{}},
            {ok, Event, State1};
        <<"content_block_start">> ->
            case maps:get(<<"content_block">>, Data, #{}) of
                #{<<"type">> := <<"tool_use">>, <<"id">> := Id, <<"name">> := Name} ->
                    Event = #{type => tool_call_started, generation_id => GenerationId,
                              data => #{id => Id, name => Name}},
                    {ok, Event, State1};
                _ -> {ok, undefined, State1}
            end;
        <<"content_block_delta">> ->
            case maps:get(<<"delta">>, Data, #{}) of
                #{<<"type">> := <<"text_delta">>, <<"text">> := Text} ->
                    Event = #{type => content_delta, generation_id => GenerationId,
                              data => #{text => Text}},
                    {ok, Event, State1};
                #{<<"type">> := <<"input_json_delta">>, <<"partial_json">> := Partial} ->
                    Event = #{type => tool_call_delta, generation_id => GenerationId,
                              data => #{partial_json => Partial}},
                    {ok, Event, State1};
                _ -> {ok, undefined, State1}
            end;
        <<"content_block_stop">> ->
            {ok, undefined, State1};
        <<"message_delta">> ->
            {ok, undefined, State1#{stop_reason => maps:get(<<"stop_reason">>, maps:get(<<"delta">>, Data, #{}), undefined)}};
        <<"message_stop">> ->
            {ok, #{type => message_completed, generation_id => GenerationId, data => #{}}, State1};
        <<"ping">> -> {ok, undefined, State1};
        <<"error">> -> {error, provider_stream_error};
        _ -> {error, invalid_stream_event}
    end;
normalize_sse_event(_Event, _State) ->
    {error, invalid_stream_event}.

-spec send_stream_request(map(), binary(), binary(), pos_integer(), binary(),
                          hayata_llm_adapter:consumer()) ->
    {ok, hayata_llm_adapter:response()} | {error, hayata_llm_adapter:normalized_error()}.
send_stream_request(Payload, ApiKey, BaseUrl, Timeout, ApiVersion, Consumer) ->
    Url = binary_to_list(<<BaseUrl/binary, "/messages">>),
    Headers = request_headers(ApiKey, ApiVersion, "text/event-stream"),
    Body = iolist_to_binary(json:encode(Payload)),
    HttpOptions = [{timeout, Timeout}, {connect_timeout, Timeout}] ++ ssl_options(),
    Request = {Url, Headers, "application/json", Body},
    Options = [{sync, false}, {stream, {self, once}}, {body_format, binary}],
    case httpc:request(post, Request, HttpOptions, Options) of
        {ok, RequestId} ->
            receive_stream_start(RequestId, Timeout, Consumer,
                                 #{buffer => <<>>, event => undefined, data => []},
                                 #{generation_id => make_ref(), blocks => [], stop_reason => undefined});
        {error, timeout} -> {error, #{code => timeout}};
        {error, _} -> {error, #{code => provider_error}}
    end.

-spec receive_stream_start(term(), pos_integer(), hayata_llm_adapter:consumer(), map(), map()) ->
    {ok, hayata_llm_adapter:response()} | {error, hayata_llm_adapter:normalized_error()}.
receive_stream_start(RequestId, Timeout, Consumer, Parser, Acc) ->
    receive
        {http, {RequestId, stream_start, Headers, HandlerPid}} ->
            case stream_status(Headers) of
                ok ->
                    httpc:stream_next(HandlerPid),
                    receive_stream_chunk(RequestId, HandlerPid, Timeout, Consumer, Parser, Acc);
                {error, Error} -> httpc:cancel_request(RequestId), {error, Error}
            end;
        {http, {RequestId, {{_Version, Status, _Phrase}, _Headers, Body}}} ->
            normalize_http_error(Status, Body);
        {http, {RequestId, {error, timeout}}} -> {error, #{code => timeout}};
        {http, {RequestId, {error, _}}} -> {error, #{code => provider_error}}
    after Timeout -> httpc:cancel_request(RequestId), {error, #{code => timeout}}
    end.

-spec stream_status(list()) -> ok | {error, hayata_llm_adapter:normalized_error()}.
stream_status(Headers) ->
    case proplists:get_value("status", Headers, "200") of
        "200" -> ok;
        _ -> ok
    end.

-spec receive_stream_chunk(term(), pid(), pos_integer(), hayata_llm_adapter:consumer(), map(), map()) ->
    {ok, hayata_llm_adapter:response()} | {error, hayata_llm_adapter:normalized_error()}.
receive_stream_chunk(RequestId, HandlerPid, Timeout, Consumer, Parser, Acc) ->
    receive
        {http, {RequestId, stream, Chunk}} ->
            case parse_sse_chunk(Chunk, Parser) of
                {ok, Events, Parser1} ->
                    case process_stream_events(Events, Consumer, Acc) of
                        {ok, Acc1} ->
                            httpc:stream_next(HandlerPid),
                            receive_stream_chunk(RequestId, HandlerPid, Timeout, Consumer, Parser1, Acc1);
                        {error, Error} -> httpc:cancel_request(RequestId), {error, Error}
                    end;
                {error, _} -> httpc:cancel_request(RequestId), {error, #{code => invalid_response}}
            end;
        {http, {RequestId, stream_end, _Trailers}} ->
            finish_stream(Acc, Consumer);
        {http, {RequestId, {error, timeout}}} -> {error, #{code => timeout}};
        {http, {RequestId, {error, _}}} -> {error, #{code => provider_error}}
    after Timeout -> httpc:cancel_request(RequestId), {error, #{code => timeout}}
    end.

-spec process_stream_events([map()], hayata_llm_adapter:consumer(), map()) ->
    {ok, map()} | {error, hayata_llm_adapter:normalized_error()}.
process_stream_events([], _Consumer, Acc) -> {ok, Acc};
process_stream_events([RawEvent | Rest], Consumer, Acc) ->
    case normalize_sse_event(RawEvent, Acc) of
        {ok, undefined, Acc1} -> process_stream_events(Rest, Consumer, Acc1);
        {ok, Event, Acc1} ->
            case safe_consume(Consumer, Event) of
                ok ->
                    Acc2 = collect_stream_content(RawEvent, Acc1),
                    process_stream_events(Rest, Consumer, Acc2);
                {error, Reason} ->
                    {error, #{code => cancelled, reason => {consumer_rejected_event, Reason}}}
            end;
        {error, _} -> {error, #{code => invalid_response}}
    end.

-spec collect_stream_content(map(), map()) -> map().
collect_stream_content(#{event := <<"content_block_start">>, data := Data}, Acc) ->
    Block = maps:get(<<"content_block">>, Data, #{}),
    Acc#{blocks => [Block | maps:get(blocks, Acc, [])]};
collect_stream_content(#{event := <<"content_block_delta">>, data := Data}, Acc) ->
    Delta = maps:get(<<"delta">>, Data, #{}),
    case {maps:get(<<"type">>, Delta, undefined), maps:get(<<"text">>, Delta, undefined)} of
        {<<"text_delta">>, Text} when is_binary(Text) ->
            Acc#{text => [Text | maps:get(text, Acc, [])]};
        _ -> Acc
    end;
collect_stream_content(_Event, Acc) -> Acc.

-spec safe_consume(hayata_llm_adapter:consumer(), map()) -> ok | {error, term()}.
safe_consume(Consumer, Event) ->
    try Consumer(Event) of
        ok -> ok;
        {error, Reason} -> {error, Reason};
        _ -> {error, invalid_consumer_result}
    catch
        _:_ -> {error, consumer_failed}
    end.

-spec finish_stream(map(), hayata_llm_adapter:consumer()) ->
    {ok, hayata_llm_adapter:response()} | {error, hayata_llm_adapter:normalized_error()}.
finish_stream(Acc, Consumer) ->
    Text = iolist_to_binary(lists:reverse(maps:get(text, Acc, []))),
    StopReason = maps:get(stop_reason, Acc, undefined),
    FinishReason = normalize_stop_reason(StopReason, []),
    case FinishReason of
        error -> {error, #{code => invalid_response}};
        _ ->
            GenerationId = maps:get(generation_id, Acc),
            Completed = #{type => generation_completed, generation_id => GenerationId, data => #{}},
            case safe_consume(Consumer, Completed) of
                ok ->
                    {ok, #{
                        message => #{role => assistant, content => [#{type => text, text => Text}]},
                        finish_reason => FinishReason,
                        id => <<>>
                    }};
                {error, Reason} -> {error, #{code => cancelled,
                    reason => {consumer_rejected_event, Reason}}}
            end
    end.
