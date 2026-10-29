
-module(hayata_llm_non_cooperative_adapter).

-behaviour(hayata_llm_adapter).

-export([
    capabilities/1,
    generate/2,
    generate_stream/3
]).

capabilities(_Config) ->
    {ok, #{
        features => #{
            tool_calling => false,
            structured_output => false,
            streaming => true,
            embeddings => false
        },
        modalities => #{
            input => [text],
            output => [text]
        }
    }}.

generate(_Request, _Config) ->
    {ok, response()}.

generate_stream(_Request, _Config, Consumer) ->
    GenerationId = make_ref(),

    FirstEvent = #{
        type => message_started,
        generation_id => GenerationId,
        data => #{}
    },

    SecondEvent = #{
        type => content_delta,
        generation_id => GenerationId,
        data => #{text => <<"Unexpected">>}
    },

    %% Intentionally ignore the consumer's return values.
    _ = Consumer(FirstEvent),
    _ = Consumer(SecondEvent),

    {ok, response()}.

response() ->
    #{
        message => #{
            role => assistant,
            content => [
                #{
                    type => text,
                    text => <<"Completed">>
                }
            ]
        },
        finish_reason => stop
    }.
