
-module(hayata_node_tests).

-include_lib("eunit/include/eunit.hrl").

registered_node_test() ->
    AgentId = make_ref(),
    NodeId = think_01,
    Name = think,

    with_node(AgentId, NodeId, Name, #{status => idle}, [], fun(Node) ->
        ?assertEqual(Node, hayata_node:whereis(AgentId, Name)),

        Info = hayata_node:get_info(Node),
        ?assertEqual(AgentId, maps:get(agent_id, Info)),
        ?assertEqual(NodeId, maps:get(node_id, Info)),
        ?assertEqual(Name, maps:get(name, Info))
    end).

agent_namespaces_test() ->
    AgentA = make_ref(),
    AgentB = make_ref(),

    with_node(AgentA, think_a, think, #{}, [], fun(NodeA) ->
        with_node(AgentB, think_b, think, #{}, [], fun(NodeB) ->
            ?assertNotEqual(NodeA, NodeB),
            ?assertEqual(NodeA, hayata_node:whereis(AgentA, think)),
            ?assertEqual(NodeB, hayata_node:whereis(AgentB, think))
        end)
    end).

initial_state_test() ->
    InitialState = #{status => idle},
    with_node(make_ref(), think_01, think, InitialState, [], fun(Node) ->
        ?assertEqual(InitialState, hayata_node:get_state(Node))
    end).

replace_state_test() ->
    with_node(make_ref(), think_01, think, #{status => idle}, [], fun(Node) ->
        NewState = #{status => running},
        ?assertEqual(ok, hayata_node:replace_state(Node, NewState)),
        ?assertEqual(NewState, hayata_node:get_state(Node))
    end).

update_state_test() ->
    InitialState = #{status => idle, retries => 0},
    with_node(make_ref(), think_01, think, InitialState, [], fun(Node) ->
        Updates = #{status => running, execution_id => 1},

        ?assertEqual(ok, hayata_node:update_state(Node, Updates)),
        ?assertEqual(
            #{
                status => running,
                retries => 0,
                execution_id => 1
            },
            hayata_node:get_state(Node)
        )
    end).

set_edges_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Edges = [tools, final],

        ?assertEqual(ok, hayata_node:set_edges(Node, Edges)),
        ?assertEqual(Edges, maps:get(edges, hayata_node:get_info(Node)))
    end).


track_edge_test() ->
    with_node(make_ref(), think_01, think, #{status => idle}, [], fun(Node) ->
        EdgePid = spawn(fun() ->
            receive
                stop -> ok
            end
        end),

        {ok, MonitorRef} = hayata_node:track_edge(Node, edge_01, EdgePid),

        Info = hayata_node:get_info(Node),
        ActiveEdges = maps:get(active_edges, Info),

        ?assertMatch(
            #{edge_id := edge_01, pid := EdgePid},
            maps:get(MonitorRef, ActiveEdges)
        ),

        EdgePid ! stop
    end).

edge_down_test() ->
    with_node(make_ref(), think_01, think, #{status => idle}, [], fun(Node) ->
        Parent = self(),
        EdgePid = spawn(fun() ->
            Parent ! {edge_ready, self()},
            receive
                stop -> ok
            end
        end),

        receive
            {edge_ready, EdgePid} -> ok
        after 1000 ->
            error(edge_start_timeout)
        end,

        {ok, _MonitorRef} = hayata_node:track_edge(Node, edge_02, EdgePid),
        EdgePid ! stop,

        ?assertEqual(
            #{status => idle},
            hayata_node:get_state(Node)
        ),

        await_edge_down(Node, 100)
    end).

start_edge_test() ->
    with_node(make_ref(), think_01, think, #{status => idle}, [], fun(Node) ->
        {ok, EdgePid} = hayata_node:start_edge(
            Node,
            edge_01,
            execution_01,
            fun() -> {ok, result_01} end
        ),

        ?assert(is_pid(EdgePid)),

        await_edge_result(Node, {edge_01, execution_01}, 100),
        await_edge_termination(Node, edge_01, execution_01, 100)
    end).

start_execution_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        EdgeTasks = [
            {edge_01, fun() -> {ok, result_01} end},
            {edge_02, fun() -> {ok, result_02} end}
        ],

        ?assertEqual(
            {ok, execution_01},
            hayata_node:start_execution(
                Node,
                execution_01,
                EdgeTasks,
                1000
            )
        ),

        Info = hayata_node:get_info(Node),
        Executions = maps:get(executions, Info),

        ?assertMatch(
            #{
                status := running,
                edge_ids := [edge_01, edge_02],
                timeout_ms := 1000
            },
            maps:get(execution_01, Executions)
        )
    end).

duplicate_execution_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        ?assertEqual(
            {ok, execution_01},
            hayata_node:start_execution(Node, execution_01, [], 1000)
        ),
        ?assertEqual(
            {error, execution_already_exists},
            hayata_node:start_execution(Node, execution_01, [], 1000)
        )
    end).

invalid_execution_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        ?assertEqual(
            {error, invalid_timeout},
            hayata_node:start_execution(Node, execution_01, [], -1)
        ),
        ?assertEqual(
            {error, invalid_edge_tasks},
            hayata_node:start_execution(Node, execution_02, not_a_list, 1000)
        ),
        ?assertEqual(
            {error, invalid_edge_task},
            hayata_node:start_execution(
                Node,
                execution_03,
                [{edge_01, not_a_function}],
                1000
            )
        ),
        ?assertEqual(
            {error, duplicate_edge_id},
            hayata_node:start_execution(
                Node,
                execution_04,
                [
                    {edge_01, fun() -> {ok, first} end},
                    {edge_01, fun() -> {ok, second} end}
                ],
                1000
            )
        ),

        ?assertEqual(
            #{},
            maps:get(executions, hayata_node:get_info(Node))
        )
    end).


reducer_recovery_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),
        FirstRuns = atomics:new(1, []),
        SecondRuns = atomics:new(1, []),

        EdgeTasks = [
            {edge_01, fun() ->
                atomics:add(FirstRuns, 1, 1),
                {ok, first_result}
            end},
            {edge_02, fun() ->
                atomics:add(SecondRuns, 1, 1),
                Parent ! {second_edge_started, self()},
                receive
                    continue -> {ok, second_result}
                end
            end}
        ],

        {ok, execution_recovery} = hayata_node:start_execution(
            Node,
            execution_recovery,
            EdgeTasks,
            5000
        ),

        await_execution_result(Node, edge_01, 100),

        Info = hayata_node:get_info(Node),
        ActiveReducers = maps:get(active_reducers, Info),
        #{pid := OriginalReducer} = maps:get(
            execution_recovery,
            ActiveReducers
        ),

        exit(OriginalReducer, kill),

        ReplacementReducer = await_replacement_reducer(
            Node,
            execution_recovery,
            OriginalReducer,
            100
        ),

        ?assert(is_pid(ReplacementReducer)),
        ?assertNotEqual(OriginalReducer, ReplacementReducer),

        SecondEdgePid = receive
            {second_edge_started, Pid} -> Pid
        after 1000 ->
            error(second_edge_start_timeout)
        end,

        SecondEdgePid ! continue,

        await_execution_completed(Node, execution_recovery, 200),

        FinalInfo = hayata_node:get_info(Node),
        Executions = maps:get(executions, FinalInfo),
        Execution = maps:get(execution_recovery, Executions),

        ?assertEqual(completed, maps:get(status, Execution)),
        ?assertEqual(
            {ok, first_result},
            maps:get(edge_01, maps:get(results, Execution))
        ),
        ?assertEqual(
            {ok, second_result},
            maps:get(edge_02, maps:get(results, Execution))
        ),
        ?assertEqual(1, atomics:get(FirstRuns, 1)),
        ?assertEqual(1, atomics:get(SecondRuns, 1))
    end).

await_edge_down(_Node, 0) ->
    error(edge_down_timeout);
await_edge_down(Node, Attempts) ->
    Info = hayata_node:get_info(Node),
    ActiveEdges = maps:get(active_edges, Info),
    LastEvent = maps:get(last_edge_event, Info),

    case {map_size(ActiveEdges), LastEvent} of
        {0, #{edge_id := edge_02, reason := normal}} ->
            ok;
        _ ->
            timer:sleep(10),
            await_edge_down(Node, Attempts - 1)
    end.

with_node(AgentId, NodeId, Name, InitialState, Edges, TestFun) ->
    {ok, Node} = hayata_node:start_link(
        AgentId,
        NodeId,
        Name,
        InitialState,
        Edges
    ),
    try
        TestFun(Node)
    after
        gen_server:stop(Node)
    end.

await_edge_result(_Node, _Key, 0) ->
    error(edge_result_timeout);
await_edge_result(Node, Key, Attempts) ->
    Info = hayata_node:get_info(Node),
    Results = maps:get(edge_results, Info),
    case maps:find(Key, Results) of
        {ok, {ok, result_01}} ->
            ok;
        error ->
            timer:sleep(10),
            await_edge_result(Node, Key, Attempts - 1);
        _ ->
            error(unexpected_edge_result)
    end.

await_edge_termination(_Node, _EdgeId, _ExecutionId, 0) ->
    error(edge_termination_timeout);
await_edge_termination(Node, EdgeId, ExecutionId, Attempts) ->
    Info = hayata_node:get_info(Node),
    ActiveEdges = maps:get(active_edges, Info),
    LastEvent = maps:get(last_edge_event, Info),
    case {map_size(ActiveEdges), LastEvent} of
        {0, #{edge_id := EdgeId,
              execution_id := ExecutionId,
              reason := normal}} ->
            ok;
        _ ->
            timer:sleep(10),
            await_edge_termination(
                Node,
                EdgeId,
                ExecutionId,
                Attempts - 1
            )
    end.


await_execution_result(_Node, _EdgeId, 0) ->
    error(execution_result_timeout);
await_execution_result(Node, EdgeId, Attempts) ->
    Info = hayata_node:get_info(Node),
    Executions = maps:get(executions, Info),
    Execution = maps:get(execution_recovery, Executions),
    Results = maps:get(results, Execution),
    case maps:is_key(EdgeId, Results) of
        true ->
            ok;
        false ->
            timer:sleep(10),
            await_execution_result(Node, EdgeId, Attempts - 1)
    end.

await_replacement_reducer(_Node, _ExecutionId, _OriginalPid, 0) ->
    error(reducer_recovery_timeout);
await_replacement_reducer(Node, ExecutionId, OriginalPid, Attempts) ->
    Info = hayata_node:get_info(Node),
    ActiveReducers = maps:get(active_reducers, Info),
    case maps:find(ExecutionId, ActiveReducers) of
        {ok, #{pid := Pid, recovered := true}} when Pid =/= OriginalPid ->
            Pid;
        _ ->
            timer:sleep(10),
            await_replacement_reducer(
                Node,
                ExecutionId,
                OriginalPid,
                Attempts - 1
            )
    end.

await_execution_completed(_Node, _ExecutionId, 0) ->
    error(execution_completion_timeout);
await_execution_completed(Node, ExecutionId, Attempts) ->
    Info = hayata_node:get_info(Node),
    Executions = maps:get(executions, Info),
    Execution = maps:get(ExecutionId, Executions),
    case maps:get(status, Execution) of
        completed ->
            ok;
        _ ->
            timer:sleep(10),
            await_execution_completed(Node, ExecutionId, Attempts - 1)
    end.
