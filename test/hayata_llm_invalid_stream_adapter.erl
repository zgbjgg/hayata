
-module(hayata_llm_invalid_stream_adapter).

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

    InvalidEvent = #{
        type => unknown_event,
        generation_id => GenerationId,
        data => #{}
    },

    ValidEvent = #{
        type => content_delta,
        generation_id => GenerationId,
        data => #{text => <<"This must not be delivered">>}
    },

    %% Deliberately ignore both consumer results.
    _ = Consumer(InvalidEvent),
    _ = Consumer(ValidEvent),

    hayata_llm_adapter_mock:generate(Request, Config).
