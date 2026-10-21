
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

        Execution = maps:get(execution_01, Executions),

        ?assert(
            lists:member(
                maps:get(status, Execution),
                [starting, running, completed]
            )
        ),
        ?assertEqual(
            [edge_01, edge_02],
            maps:get(edge_ids, Execution)
        ),
        ?assertEqual(1000, maps:get(timeout_ms, Execution))
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

        await_execution_result(Node, execution_recovery, edge_01, 100),

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

repeated_reducer_failure_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),

        EdgeTasks = [
            {edge_01, fun() ->
                Parent ! {edge_started, self()},
                receive
                    continue -> {ok, result_01}
                end
            end}
        ],

        ?assertEqual(
            {ok, execution_repeated_failure},
            hayata_node:start_execution(
                Node,
                execution_repeated_failure,
                EdgeTasks,
                5000
            )
        ),

        EdgePid = receive
            {edge_started, Pid} -> Pid
        after 1000 ->
            error(edge_start_timeout)
        end,

        Info = hayata_node:get_info(Node),
        ActiveReducers = maps:get(active_reducers, Info),
        #{pid := OriginalReducer} = maps:get(
            execution_repeated_failure,
            ActiveReducers
        ),

        exit(OriginalReducer, kill),

        ReplacementReducer = await_replacement_reducer(
            Node,
            execution_repeated_failure,
            OriginalReducer,
            100
        ),

        exit(ReplacementReducer, kill),

        await_recovery_failed(
            Node,
            execution_repeated_failure,
            100
        ),

        EdgePid ! continue
    end).

reducer_recovery_preserves_deadline_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),
        TimeoutMs = 600,
        StartedAt = erlang:monotonic_time(millisecond),

        EdgeTasks = [
            {edge_01, fun() ->
                Parent ! {edge_started, self()},
                receive
                    continue -> {ok, result_01}
                end
            end}
        ],

        ?assertEqual(
            {ok, execution_deadline},
            hayata_node:start_execution(
                Node,
                execution_deadline,
                EdgeTasks,
                TimeoutMs
            )
        ),

        _EdgePid = receive
            {edge_started, Pid} -> Pid
        after 1000 ->
            error(edge_start_timeout)
        end,

        timer:sleep(350),

        Info = hayata_node:get_info(Node),
        ActiveReducers = maps:get(active_reducers, Info),
        #{pid := OriginalReducer} = maps:get(
            execution_deadline,
            ActiveReducers
        ),

        exit(OriginalReducer, kill),

        _ReplacementReducer = await_replacement_reducer(
            Node,
            execution_deadline,
            OriginalReducer,
            100
        ),

        await_execution_status(
            Node,
            execution_deadline,
            timed_out,
            100
        ),

        ElapsedMs = erlang:monotonic_time(millisecond) - StartedAt,

        ?assert(
            ElapsedMs < TimeoutMs + 400
        )
    end).

edge_crash_during_execution_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),

        EdgeTasks = [
            {edge_01, fun() ->
                Parent ! {edge_started, self()},
                receive
                    continue -> {ok, result_01}
                end
            end}
        ],

        ?assertEqual(
            {ok, execution_edge_crash},
            hayata_node:start_execution(
                Node,
                execution_edge_crash,
                EdgeTasks,
                5000
            )
        ),

        EdgePid = receive
            {edge_started, Pid} -> Pid
        after 1000 ->
            error(edge_start_timeout)
        end,

        exit(EdgePid, kill),

        await_execution_error(
            Node,
            execution_edge_crash,
            edge_01,
            200
        ),

        Info = hayata_node:get_info(Node),
        Executions = maps:get(executions, Info),
        Execution = maps:get(execution_edge_crash, Executions),

        ?assertEqual(completed, maps:get(status, Execution)),
        ?assertMatch(
            #{edge_01 := _},
            maps:get(errors, Execution)
        ),
        ?assertEqual(
            [],
            maps:get(pending_edges, Execution)
        )
    end).


edge_result_preserved_after_down_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),
        EdgeTasks = [
            {edge_01, fun() ->
                Parent ! {edge_started, self()},
                receive
                    continue -> {ok, actual_result}
                end
            end}
        ],

        ExecutionId = execution_result_then_down,

        {ok, ExecutionId} = hayata_node:start_execution(
            Node,
            ExecutionId,
            EdgeTasks,
            5000
        ),

        EdgePid = receive
            {edge_started, Pid} -> Pid
        after 1000 ->
            error(edge_start_timeout)
        end,

        EdgePid ! continue,

        await_execution_completed(Node, ExecutionId, 200),
        await_edge_termination(Node, edge_01, ExecutionId, 200),

        Info = hayata_node:get_info(Node),
        Executions = maps:get(executions, Info),
        Execution = maps:get(ExecutionId, Executions),

        ?assertEqual(completed, maps:get(status, Execution)),
        ?assertEqual(
            #{edge_01 => {ok, actual_result}},
            maps:get(results, Execution)
        ),
        ?assertEqual(#{}, maps:get(errors, Execution)),
        ?assertEqual([], maps:get(pending_edges, Execution))
    end).

duplicate_edge_result_preserves_first_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),
        EdgeTasks = [
            {edge_01, fun() ->
                Parent ! {edge_started, self()},
                receive
                    continue -> {ok, actual_result}
                end
            end}
        ],

        {ok, execution_duplicate_result} =
            hayata_node:start_execution(
                Node,
                execution_duplicate_result,
                EdgeTasks,
                5000
            ),

        EdgePid = receive
            {edge_started, Pid} -> Pid
        after 1000 ->
            error(edge_start_timeout)
        end,

        try
            Node ! {
                hayata_edge_result,
                edge_01,
                execution_duplicate_result,
                {ok, first_result}
            },

            Node ! {
                hayata_edge_result,
                edge_01,
                execution_duplicate_result,
                {ok, duplicate_result}
            },

            %% get_info is processed after both messages,
            %% sent to this process to the same node
            Info = hayata_node:get_info(Node),
            Executions = maps:get(executions, Info),
            Execution = maps:get(
                execution_duplicate_result,
                Executions
            ),

            ?assertEqual(
                {ok, first_result},
                maps:get(
                    edge_01,
                    maps:get(results, Execution)
                )
            ),
            ?assertEqual(#{}, maps:get(errors, Execution))
        after
            exit(EdgePid, kill)
        end
    end).

duplicate_reducer_result_preserves_terminal_state_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        TaskFun = fun() ->
            receive
                release_edge ->
                    first_result
            end
        end,

        ExecutionId = execution_duplicate_final_result,

        {ok, ExecutionId} = hayata_node:start_execution(
            Node,
            ExecutionId,
            [{edge_01, TaskFun}],
            5000
        ),

        FirstResult = #{
            status => completed,
            results => #{edge_01 => {ok, first_result}},
            errors => #{},
            pending_edges => []
        },

        DuplicateResult = #{
            status => completed,
            results => #{edge_01 => {ok, duplicate_result}},
            errors => #{edge_02 => duplicate_error},
            pending_edges => [edge_03]
        },

        InfoBefore = hayata_node:get_info(Node),

        ActiveReducers = maps:get(active_reducers, InfoBefore),
        Reducer = maps:get(ExecutionId, ActiveReducers),
        ReducerPid = maps:get(pid, Reducer),

        Node ! {hayata_reducer_result, ReducerPid, ExecutionId, FirstResult},
        Node ! {hayata_reducer_result, ReducerPid, ExecutionId, DuplicateResult},

        Info = hayata_node:get_info(Node),
        Executions = maps:get(executions, Info),
        Execution = maps:get(ExecutionId, Executions),

        ?assertEqual(completed, maps:get(status, Execution)),
        ?assertEqual(
            #{edge_01 => {ok, first_result}},
            maps:get(results, Execution)
        ),
        ?assertEqual(#{}, maps:get(errors, Execution)),
        ?assertEqual([], maps:get(pending_edges, Execution))
    end).

terminal_execution_does_not_recover_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        {ok, execution_terminal_down} =
            hayata_node:start_execution(
                Node,
                execution_terminal_down,
                [{edge_01, fun() -> {ok, result_01} end}],
                5000
            ),

        await_execution_completed(
            Node,
            execution_terminal_down,
            200
        ),

        Info = hayata_node:get_info(Node),
        Executions = maps:get(executions, Info),
        Execution = maps:get(execution_terminal_down, Executions),

        ?assertEqual(completed, maps:get(status, Execution)),
        ?assertEqual(
            false,
            maps:is_key(
                execution_terminal_down,
                maps:get(active_reducers, Info)
            )
        )
    end).

terminal_execution_preserves_results_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        {ok, execution_terminal_results} =
            hayata_node:start_execution(
                Node,
                execution_terminal_results,
                [{edge_01, fun() -> {ok, result_01} end}],
                5000
            ),

        await_execution_completed(
            Node,
            execution_terminal_results,
            200
        ),

        InfoBefore = hayata_node:get_info(Node),
        ExecutionsBefore = maps:get(executions, InfoBefore),
        ExecutionBefore = maps:get(
            execution_terminal_results,
            ExecutionsBefore
        ),

        ?assertEqual(completed, maps:get(status, ExecutionBefore)),

        Node ! unrelated_message,

        InfoAfter = hayata_node:get_info(Node),
        ExecutionsAfter = maps:get(executions, InfoAfter),
        ExecutionAfter = maps:get(
            execution_terminal_results,
            ExecutionsAfter
        ),

        ?assertEqual(
            maps:get(status, ExecutionBefore),
            maps:get(status, ExecutionAfter)
        ),
        ?assertEqual(
            maps:get(results, ExecutionBefore),
            maps:get(results, ExecutionAfter)
        ),
        ?assertEqual(
            maps:get(errors, ExecutionBefore),
            maps:get(errors, ExecutionAfter)
        )
    end).


terminal_execution_ignores_late_reducer_down_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),
        ExecutionId = execution_late_reducer_down,

        EdgeTasks = [
            {edge_01, fun() ->
                Parent ! {edge_started, self()},
                receive
                    continue -> {ok, result_01}
                end
            end}
        ],

        {ok, ExecutionId} = hayata_node:start_execution(
            Node,
            ExecutionId,
            EdgeTasks,
            5000
        ),

        EdgePid = receive
            {edge_started, Pid} -> Pid
        after 1000 ->
            error(edge_start_timeout)
        end,

        InfoBefore = hayata_node:get_info(Node),
        ActiveReducers = maps:get(active_reducers, InfoBefore),
        #{pid := ReducerPid, monitor_ref := MonitorRef} =
            maps:get(ExecutionId, ActiveReducers),

        EdgePid ! continue,

        await_execution_completed(Node, ExecutionId, 200),

        InfoCompleted = hayata_node:get_info(Node),
        ExecutionsCompleted = maps:get(executions, InfoCompleted),
        ExecutionCompleted = maps:get(
            ExecutionId,
            ExecutionsCompleted
        ),

        ?assertEqual(
            completed,
            maps:get(status, ExecutionCompleted)
        ),

        %% Simulate a stale DOWN notification from the original reducer.
        Node ! {'DOWN', MonitorRef, process, ReducerPid, killed},

        InfoAfter = hayata_node:get_info(Node),
        ExecutionsAfter = maps:get(executions, InfoAfter),
        ExecutionAfter = maps:get(ExecutionId, ExecutionsAfter),

        ?assertEqual(
            completed,
            maps:get(status, ExecutionAfter)
        ),
        ?assertEqual(
            maps:get(results, ExecutionCompleted),
            maps:get(results, ExecutionAfter)
        ),
        ?assertEqual(
            maps:get(errors, ExecutionCompleted),
            maps:get(errors, ExecutionAfter)
        ),
        ?assertEqual(
            false,
            maps:is_key(ExecutionId, maps:get(active_reducers, InfoAfter))
        )
    end).

terminal_execution_preserves_timeout_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),
        ExecutionId = execution_terminal_timeout,

        EdgeTasks = [
            {edge_01, fun() ->
                Parent ! {edge_started, self()},
                receive
                    continue -> {ok, late_result}
                end
            end}
        ],

        {ok, ExecutionId} = hayata_node:start_execution(
            Node,
            ExecutionId,
            EdgeTasks,
            100
        ),

        await_execution_status(Node, ExecutionId, timed_out, 200),

        InfoBefore = hayata_node:get_info(Node),
        ExecutionBefore = maps:get(
            ExecutionId,
            maps:get(executions, InfoBefore)
        ),

        ?assertEqual(timed_out, maps:get(status, ExecutionBefore)),

        EdgePid = receive
            {edge_started, Pid} -> Pid
        after 1000 ->
            error(edge_start_timeout)
        end,

        EdgePid ! continue,

        timer:sleep(20),

        InfoAfter = hayata_node:get_info(Node),
        ExecutionAfter = maps:get(
            ExecutionId,
            maps:get(executions, InfoAfter)
        ),

        ?assertEqual(timed_out, maps:get(status, ExecutionAfter)),
        ?assertEqual(
            maps:get(results, ExecutionBefore),
            maps:get(results, ExecutionAfter)
        ),

        EdgeResultKey = {edge_01, ExecutionId},

        EdgeResultsBefore = maps:get(edge_results, InfoBefore),
        EdgeResultsAfter = maps:get(edge_results, InfoAfter),

        ?assertEqual(
            maps:find(EdgeResultKey, EdgeResultsBefore),
            maps:find(EdgeResultKey, EdgeResultsAfter)
        )
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


await_execution_result(_Node, _ExecutionId, _EdgeId, 0) ->
    error(execution_result_timeout);
await_execution_result(Node, ExecutionId, EdgeId, Attempts) ->
    Info = hayata_node:get_info(Node),
    Executions = maps:get(executions, Info),
    Execution = maps:get(ExecutionId, Executions),
    Results = maps:get(results, Execution),
    case maps:is_key(EdgeId, Results) of
        true ->
            ok;
        false ->
            timer:sleep(10),
            await_execution_result(Node, ExecutionId, EdgeId, Attempts - 1)
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


await_recovery_failed(_Node, _ExecutionId, 0) ->
    error(reducer_recovery_failure_timeout);
await_recovery_failed(Node, ExecutionId, Attempts) ->
    Info = hayata_node:get_info(Node),
    Executions = maps:get(executions, Info),
    Execution = maps:get(ExecutionId, Executions),
    case maps:get(status, Execution) of
        {reducer_recovery_failed, _Reason} ->
            ok;
        _ ->
            timer:sleep(10),
            await_recovery_failed(
                Node,
                ExecutionId,
                Attempts - 1
            )
    end.


await_execution_status(_Node, _ExecutionId, _Status, 0) ->
    error(execution_status_timeout);
await_execution_status(Node, ExecutionId, Status, Attempts) ->
    Info = hayata_node:get_info(Node),
    Executions = maps:get(executions, Info),
    Execution = maps:get(ExecutionId, Executions),
    case maps:get(status, Execution) of
        Status ->
            ok;
        _ ->
            timer:sleep(10),
            await_execution_status(
                Node,
                ExecutionId,
                Status,
                Attempts - 1
            )
    end.


await_execution_error(_Node, _ExecutionId, _EdgeId, 0) ->
    error(execution_error_timeout);
await_execution_error(Node, ExecutionId, EdgeId, Attempts) ->
    Info = hayata_node:get_info(Node),
    Executions = maps:get(executions, Info),
    Execution = maps:get(ExecutionId, Executions),
    Errors = maps:get(errors, Execution),
    case maps:is_key(EdgeId, Errors) of
        true ->
            ok;
        false ->
            timer:sleep(10),
            await_execution_error(
                Node,
                ExecutionId,
                EdgeId,
                Attempts - 1
            )
    end.
