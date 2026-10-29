
-module(hayata_llm_in_flight_invalid_event_adapter).

-behaviour(hayata_llm_adapter).

-export([
    capabilities/1,
    generate/2,
    generate_stream/3
]).

capabilities(Config) ->
    hayata_llm_adapter_mock:capabilities(Config).

generate(Request, Config) ->
    hayata_llm_adapter_mock:generate(Request, Config).

generate_stream(Request, Config, Consumer) ->
    _AdapterOwner = maps:get(adapter_owner, Config),
    GenerationId = make_ref(),

    ValidEvent = #{
        type => content_delta,
        generation_id => GenerationId,
        data => #{text => <<"In flight">>}
    },

    InvalidEvent = #{
        type => unknown_event,
        generation_id => GenerationId,
        data => #{}
    },

    spawn(fun() ->
        Consumer(ValidEvent)
    end),

    receive
        consumer_started ->
            ok
    after 1000 ->
        error(consumer_did_not_start)
    end,

    %% This event fails while the valid callback remains in flight.
    InvalidResult = Consumer(InvalidEvent),

    case InvalidResult of
        {error, _Reason} ->
            hayata_llm_adapter_mock:generate(Request, Config);
        OtherResult ->
            {error, #{
                code => unexpected_stream_behavior,
                result => OtherResult
            }}
    end.
