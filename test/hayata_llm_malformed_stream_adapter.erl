-module(hayata_llm_malformed_stream_adapter).

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
    GenerationId = make_ref(),

    %% Missing generation_id: this event is malformed.
    InvalidEvent = #{
        type => content_delta,
        data => #{text => <<"Invalid event">>}
    },

    ValidEvent = #{
        type => content_delta,
        generation_id => GenerationId,
        data => #{text => <<"Must not be delivered">>}
    },

    %% Deliberately ignore the consumer results.
    _ = Consumer(InvalidEvent),
    _ = Consumer(ValidEvent),

    hayata_llm_adapter_mock:generate(Request, Config).
