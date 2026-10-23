-module(hayata_cycle_example).

-export([run/0]).

-doc("Runs a cyclic graph using Hayata's current agent API.").
-spec run() -> {ok, map()} | {error, term()}.
run() ->
    AgentId = cycle_example,

    Nodes = #{
        node_a => fun node_a/1,
        node_b => fun node_b/1
    },

    Config = #{
        id => AgentId,
        state => #{
            counter => 0,
            historial => [],
            last_node => undefined
        },
        nodes => Nodes,
        decision_policy => fun decision_policy/1,
        max_steps => 10,
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

-spec node_a(map()) -> map().
node_a(State) ->
    Counter = maps:get(counter, State, 0),
    History = maps:get(historial, State, []),
    io:format(
        "--- Executing Node A (Current counter: ~p) ---~n",
        [Counter]
    ),
    #{
        counter => Counter + 1,
        historial => History ++ ["Passed through A"],
        last_node => node_a
    }.

-spec node_b(map()) -> map().
node_b(State) ->
    Counter = maps:get(counter, State, 0),
    History = maps:get(historial, State, []),
    io:format(
        "--- Executing Node B (Current counter: ~p) ---~n",
        [Counter]
    ),
    #{
        counter => Counter + 1,
        historial => History ++ ["Passed through B"],
        last_node => node_b
    }.

-spec decision_policy(map()) ->
    {next, atom(), term()} | {finish, map()}.
decision_policy(Context) ->
    State = maps:get(state, Context),
    Counter = maps:get(counter, State, 0),
    LastNode = maps:get(last_node, State, undefined),

    case Counter >= 4 of
        true ->
            {finish, State};
        false ->
            next_node(LastNode)
    end.

-spec next_node(undefined | node_a | node_b) ->
    {next, atom(), map()}.
next_node(undefined) ->
    {next, node_a, #{}};
next_node(node_a) ->
    {next, node_b, #{}};
next_node(node_b) ->
    {next, node_a, #{}}.

-spec run_agent(pid()) -> {ok, map()} | {error, term()}.
run_agent(AgentSupPid) ->
    case hayata_agent_sup:agent(AgentSupPid) of
        {ok, AgentPid} ->
            case hayata_agent:run(AgentPid, #{}, self()) of
                {ok, InvocationId} ->
                    await_result(InvocationId, 100);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec await_result(reference(), non_neg_integer()) ->
    {ok, map()} | {error, term()}.
await_result(_InvocationId, 0) ->
    {error, notification_timeout};
await_result(InvocationId, Attempts) ->
    receive
        {hayata_agent_result, InvocationId, {ok, Result}} ->
            {ok, Result};
        {hayata_agent_result, InvocationId, {error, Reason}} ->
            {error, Reason}
    after 100 ->
        await_result(InvocationId, Attempts - 1)
    end.
