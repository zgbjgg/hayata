-module(hayata_llm_late_callback_adapter).

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
    put(hayata_late_stream_consumer, Consumer),
    {ok, response()}.

response() ->
    #{
        message => #{
            role => assistant,
            content => [
                #{type => text, text => <<"Completed">>}
            ]
        },
        finish_reason => stop
    }.
