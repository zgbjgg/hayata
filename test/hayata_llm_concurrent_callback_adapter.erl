-module(hayata_llm_concurrent_callback_adapter).

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

generate_stream(_Request, Config, Consumer) ->
    AdapterOwner = maps:get(adapter_owner, Config),

    spawn(fun() ->
        Consumer(#{
            type => content_delta,
            generation_id => make_ref(),
            data => #{text => <<"Concurrent">>}
        })
    end),

    receive
        consumer_started ->
            {ok, response()}
    after 1000 ->
        {error, timeout}
    end.

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
