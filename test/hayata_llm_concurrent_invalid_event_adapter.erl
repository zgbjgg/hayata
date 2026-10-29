
-module(hayata_llm_concurrent_invalid_event_adapter).

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
        data => #{text => <<"Must not be delivered">>}
    },

    %% Wait until the coordinator has registered the invalid event.
    InvalidResult = Consumer(InvalidEvent),

    Parent = self(),

    CallbackPid = spawn(fun() ->
        Result = Consumer(ValidEvent),
        Parent ! {concurrent_callback_result, self(), Result}
    end),

    CallbackResult = receive
        {concurrent_callback_result, CallbackPid, Result} ->
            Result
    after 1000 ->
        {error, callback_timeout}
    end,

    case {InvalidResult, CallbackResult} of
        {{error, _}, {error, _}} ->
            hayata_llm_adapter_mock:generate(Request, Config);
        Results ->
            {error, #{
                code => unexpected_stream_behavior,
                results => Results
            }}
    end.
