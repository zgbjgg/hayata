
-module(hayata_llm_provider_error_stream_adapter).

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

-doc("Returns a provider error without emitting stream events.").
-spec generate_stream(map(), map(), hayata_llm_adapter:consumer()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
generate_stream(_Request, _Config, _Consumer) ->
    {error, #{
        code => provider_error,
        reason => simulated_provider_failure
    }}.
