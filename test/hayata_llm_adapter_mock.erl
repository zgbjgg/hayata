
-module(hayata_llm_adapter_mock).

-behaviour(hayata_llm_adapter).

-export([
    capabilities/1,
    generate/2,
    generate_stream/3
]).

-doc("Returns the capabilities supported by the mock adapter.").
-spec capabilities(map()) ->
    {ok, hayata_llm_adapter:capabilities()}.
capabilities(_Config) ->
    {ok, #{
        features => #{
            tool_calling => true,
            structured_output => true,
            streaming => true,
            embeddings => false
        },
        modalities => #{
            input => [text],
            output => [text]
        }
    }}.

-doc("Returns a deterministic normalized response for a valid request.").
-spec generate(map(), map()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
generate(Request, Config) when is_map(Request) ->
    case {
        maps:find(model, Request),
        maps:find(messages, Request)
    } of
        {{ok, Model}, {ok, Messages}}
                when is_binary(Model), is_list(Messages) ->
            ResponseMode = maps:get(response_mode, Config, text),
            {ok, response(ResponseMode)};
        _ ->
            {error, #{code => invalid_request}}
    end;
generate(_Request, _Config) ->
    {error, #{code => invalid_request}}.

-doc("Emits deterministic stream events and returns the final response.").
-spec generate_stream(map(), map(), hayata_llm_adapter:consumer()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
generate_stream(Request, Config, Consumer)
        when is_function(Consumer, 1) ->
    case generate(Request, Config) of
        {ok, Response} ->
            emit_events(stream_events(), Consumer, Response);
        {error, Reason} ->
            {error, Reason}
    end;
generate_stream(_Request, _Config, _Consumer) ->
    {error, #{code => invalid_request}}.

-spec response(atom()) -> hayata_llm_adapter:response().
response(text) ->
    #{
        message => #{
            role => assistant,
            content => [
                #{
                    type => text,
                    text => <<"Hello from Hayata.">>
                }
            ]
        },
        finish_reason => stop,
        usage => #{
            input_tokens => 1,
            output_tokens => 4,
            total_tokens => 5
        }
    };
response(tool_call) ->
    #{
        message => #{
            role => assistant,
            content => [],
            tool_calls => [
                #{
                    id => <<"call_123">>,
                    name => <<"get_weather">>,
                    arguments => #{city => <<"Mexico City">>}
                }
            ]
        },
        finish_reason => tool_calls
    };
response(invalid_tool_call) ->
    #{
        message => #{
            role => assistant,
            content => [],
            tool_calls => [
                #{
                    id => <<"call_123">>,
                    name => <<"get_weather">>,
                    arguments => <<"not a map">>
                }
            ]
        },
        finish_reason => tool_calls
    };
response(missing_message) ->
    #{
        finish_reason => stop,
        usage => #{
            input_tokens => 1,
            output_tokens => 1,
            total_tokens => 2
        }
    };
response(invalid_message_role) ->
    #{
        message => #{
            role => user,
            content => [
                #{
                    type => text,
                    text => <<"This role is invalid for a response.">>
                }
            ]
        },
        finish_reason => stop
    }.

-spec stream_events() -> [hayata_llm_adapter:stream_event()].
stream_events() ->
    GenerationId = make_ref(),
    [
        #{
            type => message_started,
            generation_id => GenerationId,
            data => #{}
        },
        #{
            type => content_delta,
            generation_id => GenerationId,
            data => #{text => <<"Hello ">>}
        },
        #{
            type => content_delta,
            generation_id => GenerationId,
            data => #{text => <<"from Hayata.">>}
        },
        #{
            type => message_completed,
            generation_id => GenerationId,
            data => #{finish_reason => stop}
        },
        #{
            type => generation_completed,
            generation_id => GenerationId,
            data => #{}
        }
    ].

-spec emit_events(
    [hayata_llm_adapter:stream_event()],
    hayata_llm_adapter:consumer(),
    hayata_llm_adapter:response()
) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
emit_events([], _Consumer, Response) ->
    {ok, Response};
emit_events([Event | Rest], Consumer, Response) ->
    case Consumer(Event) of
        ok ->
            emit_events(Rest, Consumer, Response);
        {error, Reason} ->
            {error, #{
                code => cancelled,
                reason => {consumer_rejected_event, Reason}
            }};
        _ ->
            {error, #{
                code => invalid_response,
                reason => invalid_consumer_result
            }}
    end.
