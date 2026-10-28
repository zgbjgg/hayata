-module(hayata_stream_example).

-export([run/0]).

run() ->
    AgentId = streaming_example,

    StreamingNode = fun(Context) ->
        Streamer = maps:get(hayata_streamer, Context),

        io:format("Node started processing.~n"),

        ok = Streamer(#{chunk => <<"Hello">>}),
        timer:sleep(500),

        ok = Streamer(#{chunk => <<" from">>}),
        timer:sleep(500),

        ok = Streamer(#{chunk => <<" Hayata!">>}),

        #{answer => <<"Hello from Hayata!">>}
    end,

    Nodes = #{
        streaming_node => StreamingNode
    },

    DecisionPolicy = fun(Context) ->
        case maps:get(step, Context) of
            0 ->
                {next, streaming_node, #{}};
            1 ->
                {finish, maps:get(state, Context)}
        end
    end,

    Config = #{
        id => AgentId,
        state => #{},
        nodes => Nodes,
        decision_policy => DecisionPolicy,
        max_steps => 3,
        execution_timeout => 5000
    },

    case hayata_sup:start_agent(Config) of
        {ok, AgentSupPid} ->
            try
                run_agent(AgentSupPid)
            after
                hayata_sup:stop_agent(AgentSupPid)
            end;
        {error, Reason} ->
            {error, {agent_start_failed, Reason}}
    end.

run_agent(AgentSupPid) ->
    case hayata_agent_sup:agent(AgentSupPid) of
        {ok, AgentPid} ->
            case hayata_agent:run(
                AgentPid,
                #{input => <<"Start streaming">>},
                #{
                    subscriber => self(),
                    stream => true
                }
            ) of
                {ok, InvocationId} ->
                    io:format("Invocation started: ~p~n", [InvocationId]),
                    await_result(InvocationId, 50);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

await_result(_InvocationId, 0) ->
    {error, notification_timeout};
await_result(InvocationId, Attempts) ->
    receive
        {hayata_agent_event, InvocationId, Event} ->
            print_event(Event),
            await_result(InvocationId, Attempts);
        {hayata_agent_result, InvocationId, {ok, Result}} ->
            io:format("Final result: ~p~n", [Result]),
            {ok, Result};
        {hayata_agent_result, InvocationId, {error, Reason}} ->
            io:format("Invocation failed: ~p~n", [Reason]),
            {error, Reason}
    after 1000 ->
        await_result(InvocationId, Attempts - 1)
    end.

print_event(Event) ->
    Type = maps:get(type, Event),
    Sequence = maps:get(sequence, Event),
    Data = maps:get(data, Event),

    io:format(
        "[~p] ~p: ~p~n",
        [Sequence, Type, Data]
    ).
