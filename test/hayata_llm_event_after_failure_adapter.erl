
-module(hayata_llm_event_after_failure_adapter).

-behaviour(hayata_llm_adapter).

-export([capabilities/1, generate/2, generate_stream/3]).

-define(GENERATION_ID, <<"event-after-failure-test">>).

-doc("Returns the capabilities supported by the mock adapter.").
-spec capabilities(map()) ->
    {ok, hayata_llm_adapter:capabilities()}.
capabilities(Config) ->
    hayata_llm_adapter_mock:capabilities(Config).

-doc("Delegates regular generation to the mock adapter.").
-spec generate(map(), map()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
generate(Request, Config) ->
    hayata_llm_adapter_mock:generate(Request, Config).

-doc("Attempts to emit a content event after a terminal failure event.").
-spec generate_stream(map(), map(), hayata_llm_adapter:consumer()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
generate_stream(_Request, _Config, Consumer) ->
    Events = [
        #{
            type => generation_failed,
            generation_id => ?GENERATION_ID,
            data => #{
                code => provider_error,
                reason => simulated_generation_failure
            }
        },
        #{
            type => content_delta,
            generation_id => ?GENERATION_ID,
            data => #{text => <<"This must not be emitted.">>}
        }
    ],
    emit_events(Events, Consumer).

-spec emit_events(
    [hayata_llm_adapter:stream_event()],
    hayata_llm_adapter:consumer()
) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
emit_events([], _Consumer) ->
    hayata_llm_adapter_mock:generate(#{model => <<"mock">>, messages => []}, #{});
emit_events([Event | Rest], Consumer) ->
    case Consumer(Event) of
        ok ->
            emit_events(Rest, Consumer);
        {error, Reason} ->
            {error, #{
                code => invalid_response,
                reason => Reason
            }};
        _ ->
            {error, #{
                code => invalid_response,
                reason => invalid_consumer_result
            }}
    end.
