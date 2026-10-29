
-module(hayata_llm_generation_failed_stream_adapter).

-behaviour(hayata_llm_adapter).

-export([
    capabilities/1,
    generate/2,
    generate_stream/3
]).

-doc("Returns the mock adapter capabilities.").
-spec capabilities(map()) ->
    {ok, hayata_llm_adapter:capabilities()}.
capabilities(Config) ->
    hayata_llm_adapter_mock:capabilities(Config).

-doc("Returns the mock adapter response.").
-spec generate(map(), map()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
generate(Request, Config) ->
    hayata_llm_adapter_mock:generate(Request, Config).

-doc("Emits a generation failure and returns the normalized error.").
-spec generate_stream(
    map(),
    map(),
    hayata_llm_adapter:consumer()
) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
generate_stream(_Request, _Config, Consumer) ->
    GenerationId = <<"generation-failure-test">>,
    Event = #{
        type => generation_failed,
        generation_id => GenerationId,
        data => #{
            code => provider_error,
            reason => simulated_generation_failure
        }
    },

    case Consumer(Event) of
        ok ->
            {error, #{
                code => provider_error,
                reason => simulated_generation_failure
            }};
        {error, Reason} ->
            {error, #{
                code => cancelled,
                reason => {consumer_rejected_event, Reason}
            }};
        _Other ->
            {error, #{
                code => invalid_response,
                reason => invalid_consumer_result
            }}
    end.
