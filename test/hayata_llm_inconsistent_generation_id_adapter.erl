
-module(hayata_llm_inconsistent_generation_id_adapter).

-behaviour(hayata_llm_adapter).

-export([capabilities/1, generate/2, generate_stream/3]).

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

-doc("Emits events with inconsistent generation identifiers.").
-spec generate_stream(map(), map(), hayata_llm_adapter:consumer()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
generate_stream(_Request, _Config, Consumer) ->
    Events = [
        #{
            type => message_started,
            generation_id => <<"generation-first">>,
            data => #{}
        },
        #{
            type => content_delta,
            generation_id => <<"generation-second">>,
            data => #{text => <<"This event must be rejected.">>}
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
