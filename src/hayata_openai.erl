
-module(hayata_openai).

-behaviour(hayata_llm_adapter).

-export([
    capabilities/1,
    generate/2
]).

-define(DEFAULT_BASE_URL, <<"https://api.openai.com/v1">>).
-define(DEFAULT_TIMEOUT, 30000).

-doc("Returns the capabilities currently implemented by the OpenAI adapter.").
-spec capabilities(map()) ->
    {ok, hayata_llm_adapter:capabilities()} |
    {error, hayata_llm_adapter:normalized_error()}.
capabilities(_Config) ->
    {ok, #{
        features => #{
            tool_calling => false,
            structured_output => false,
            streaming => false,
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
prepare_payload(#{model := Model, messages := Messages})
        when is_binary(Model), is_list(Messages) ->
    case convert_messages(Messages, []) of
        {ok, Input} ->
            {ok, #{
                <<"model">> => Model,
                <<"input">> => Input
            }};
        {error, Reason} ->
            {error, Reason}
    end;
prepare_payload(_Request) ->
    {error, invalid_request}.

-spec convert_messages(list(), list()) ->
    {ok, list()} | {error, term()}.
convert_messages([], Acc) ->
    {ok, lists:reverse(Acc)};
convert_messages([Message | Rest], Acc) ->
    case convert_message(Message) of
        {ok, Converted} ->
            convert_messages(Rest, [Converted | Acc]);
        {error, Reason} ->
            {error, Reason}
    end.

-spec convert_message(map()) ->
    {ok, map()} | {error, term()}.
convert_message(#{role := Role, content := Content})
        when is_atom(Role), is_list(Content) ->
    case lists:member(Role, [system, developer, user, assistant]) of
        true ->
            case convert_content(Content, []) of
                {ok, TextBlocks} ->
                    {ok, #{
                        <<"role">> => atom_to_binary(Role, utf8),
                        <<"content">> => lists:reverse(TextBlocks)
                    }};
                {error, Reason} ->
                    {error, Reason}
            end;
        false ->
            {error, unsupported_message_role}
    end;
convert_message(_Message) ->
    {error, invalid_message}.

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
normalize_response(#{<<"status">> := <<"completed">>,
                     <<"output">> := Output} = Response) ->
    case extract_text(Output, []) of
        {ok, Text} when byte_size(Text) > 0 ->
            {ok, #{
                message => #{
                    role => assistant,
                    content => [#{type => text, text => Text}]
                },
                finish_reason => stop,
                id => maps:get(<<"id">>, Response, undefined)
            }};
        {ok, _EmptyText} ->
            {error, #{code => invalid_response}};
        {error, _Reason} ->
            {error, #{code => invalid_response}}
    end;
normalize_response(#{<<"status">> := <<"incomplete">>,
                     <<"incomplete_details">> := Details}) ->
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
