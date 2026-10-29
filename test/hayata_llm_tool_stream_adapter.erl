
-module(hayata_llm_tool_stream_adapter).

-behaviour(hayata_llm_adapter).

-export([capabilities/1, generate/2, generate_stream/3]).

-define(GENERATION_ID, <<"tool-stream-test">>).

-doc("Returns the capabilities supported by the mock adapter.").
-spec capabilities(map()) ->
    {ok, hayata_llm_adapter:capabilities()}.
capabilities(Config) ->
    hayata_llm_adapter_mock:capabilities(Config).

-doc("Returns a normalized response containing a tool call.").
-spec generate(map(), map()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
generate(_Request, _Config) ->
    {ok, response()}.

-doc("Emits tool-call lifecycle events and returns the normalized response.").
-spec generate_stream(map(), map(), hayata_llm_adapter:consumer()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
generate_stream(_Request, _Config, Consumer) ->
    Events = [
        #{
            type => tool_call_started,
            generation_id => ?GENERATION_ID,
            data => #{
                id => <<"call_123">>,
                name => <<"get_weather">>
            }
        },
        #{
            type => tool_call_delta,
            generation_id => ?GENERATION_ID,
            data => #{
                id => <<"call_123">>,
                arguments_delta => <<"{\"city\":\"Mexico City\"}">>
            }
        },
        #{
            type => tool_call_completed,
            generation_id => ?GENERATION_ID,
            data => #{
                id => <<"call_123">>,
                name => <<"get_weather">>,
                arguments => #{city => <<"Mexico City">>}
            }
        },
        #{
            type => generation_completed,
            generation_id => ?GENERATION_ID,
            data => #{}
        }
    ],
    emit_events(Events, Consumer).

-spec response() -> hayata_llm_adapter:response().
response() ->
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
    }.

-spec emit_events(
    [hayata_llm_adapter:stream_event()],
    hayata_llm_adapter:consumer()
) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
emit_events([], _Consumer) ->
    {ok, response()};
emit_events([Event | Rest], Consumer) ->
    case Consumer(Event) of
        ok ->
            emit_events(Rest, Consumer);
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
