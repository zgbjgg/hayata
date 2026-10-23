
-module(hayata_parallel_example).

-export([run/0, run/1]).

-doc("Runs a parallel fan-out/fan-in example using Hayata.").
-spec run() -> {ok, map()} | {error, term()}.
run() ->
    run("Hello Hayata").

-doc("Runs the example with the provided input text.").
-spec run(string()) -> {ok, map()} | {error, term()}.
run(Input) when is_list(Input) ->
    AgentId = {hayata_parallel_example, make_ref()},

    Nodes = #{
        node_a => fun node_a/1,
        node_b => fun node_b/1,
        aggregator => fun aggregator/1
    },

    DecisionPolicy = fun decision_policy/1,

    Config = #{
        id => AgentId,
        state => #{
            input => Input,
            results => []
        },
        nodes => Nodes,
        decision_policy => DecisionPolicy,
        max_steps => 4,
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
    Input = maps:get(input, State),
    #{
        results => [
            lists:flatten(io_lib:format("Result from A: ~s", [Input]))
        ]
    }.

-spec node_b(map()) -> map().
node_b(State) ->
    Input = maps:get(input, State),
    #{
        results => [
            lists:flatten(io_lib:format("Result from B: ~s", [Input]))
        ]
    }.

-spec aggregator(map()) -> map().
aggregator(State) ->
    AggregatorInput = maps:get(input, State),
    Results = maps:get(results, AggregatorInput),

    OutputStrings = lists:append([
        maps:get(results, Result)
        || Result <- Results
    ]),

    #{results => OutputStrings ++ ["Finalized Workflow"]}.

-spec decision_policy(map()) -> tuple().
decision_policy(Context) ->
    case maps:get(step, Context) of
        0 ->
            State = maps:get(state, Context),
            Input = maps:get(input, State),
            {next, [node_a, node_b], Input};

        2 ->
            Results = maps:get(parallel_results, Context),
            {next, aggregator, #{results => Results}};

        3 ->
            {finish, maps:get(state, Context)}
    end.

-spec run_agent(pid()) -> {ok, map()} | {error, term()}.
run_agent(AgentSupPid) ->
    case hayata_agent_sup:agent(AgentSupPid) of
        {ok, AgentPid} ->
            case hayata_agent:run(AgentPid, start, self()) of
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
