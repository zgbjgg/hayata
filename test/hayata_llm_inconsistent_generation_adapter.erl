
-module(hayata_llm_inconsistent_generation_adapter).

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
    FirstEvent = #{
        type => content_delta,
        generation_id => generation_one,
        data => #{text => <<"First event">>}
    },

    SecondEvent = #{
        type => message_completed,
        generation_id => generation_two,
        data => #{}
    },

    %% The first event establishes the generation identifier.
    _ = Consumer(FirstEvent),

    %% Deliberately ignore the rejection of the second event.
    _ = Consumer(SecondEvent),

    hayata_llm_adapter_mock:generate(Request, Config).
