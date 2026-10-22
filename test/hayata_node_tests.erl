
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
        TimeoutMs = 1200,
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

        timer:sleep(800),

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
            ElapsedMs < TimeoutMs + 250
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

            Node ! {
                hayata_edge_result,
                edge_01,
                execution_duplicate_result,
                {error, contradictory_failure}
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
                #{
                    {edge_01, execution_duplicate_result} =>
                        {ok, first_result}
                },
                maps:get(edge_results, Info)
            ),

            ?assertEqual(
                maps:get(edge_01, maps:get(results, Execution)),
                maps:get(
                    {edge_01, execution_duplicate_result},
                    maps:get(edge_results, Info)
                )
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

        Node ! {
            hayata_edge_result,
            edge_01,
            execution_terminal_results,
            {ok, late_result}
        },

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
        ),
        ?assertEqual(
            maps:get(edge_results, InfoBefore),
            maps:get(edge_results, InfoAfter)
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


reducer_recovery_preserves_edge_errors_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),

        EdgeTasks = [
            {edge_01, fun() ->
                {error, expected_failure}
            end},
            {edge_02, fun() ->
                Parent ! {second_edge_started, self()},
                receive
                    continue -> {ok, second_result}
                end
            end}
        ],

        ExecutionId = execution_recovery_preserves_error,

        {ok, ExecutionId} = hayata_node:start_execution(
            Node,
            ExecutionId,
            EdgeTasks,
            5000
        ),

        await_execution_error(
            Node,
            ExecutionId,
            edge_01,
            100
        ),

        InfoBefore = hayata_node:get_info(Node),
        ActiveReducersBefore = maps:get(active_reducers, InfoBefore),
        #{pid := OriginalReducer} = maps:get(
            ExecutionId,
            ActiveReducersBefore
        ),

        exit(OriginalReducer, kill),

        _ReplacementReducer = await_replacement_reducer(
            Node,
            ExecutionId,
            OriginalReducer,
            100
        ),

        SecondEdgePid = receive
            {second_edge_started, Pid} -> Pid
        after 1000 ->
            error(second_edge_start_timeout)
        end,

        SecondEdgePid ! continue,

        await_execution_completed(Node, ExecutionId, 200),

        InfoAfter = hayata_node:get_info(Node),
        Executions = maps:get(executions, InfoAfter),
        Execution = maps:get(ExecutionId, Executions),

        ?assertEqual(completed, maps:get(status, Execution)),
        ?assertEqual(
            #{edge_02 => {ok, second_result}},
            maps:get(results, Execution)
        ),
        ?assertEqual(
            #{edge_01 => expected_failure},
            maps:get(errors, Execution)
        ),
        ?assertEqual([], maps:get(pending_edges, Execution))
    end).

reducer_recovery_with_edge_termination_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),
        Runs = atomics:new(1, []),
        ExecutionId = execution_recovery_edge_termination,

        EdgeTasks = [
            {edge_01, fun() ->
                atomics:add(Runs, 1, 1),
                Parent ! {edge_started, self()},
                receive
                    continue -> {ok, recovered_result}
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

        Info = hayata_node:get_info(Node),
        ActiveReducers = maps:get(active_reducers, Info),
        #{pid := OriginalReducer} = maps:get(
            ExecutionId,
            ActiveReducers
        ),

        EdgeMonitor = erlang:monitor(process, EdgePid),

        try
            ok = sys:suspend(Node),
            exit(OriginalReducer, kill),
            EdgePid ! continue,

            receive
                {'DOWN', EdgeMonitor, process, EdgePid, normal} ->
                    ok;
                {'DOWN', EdgeMonitor, process, EdgePid, Reason} ->
                    error({unexpected_edge_exit, Reason})
            after 1000 ->
                error(edge_termination_timeout)
            end
        after
            case sys:resume(Node) of
                ok -> ok;
                _ -> ok
            end
        end,

        await_execution_completed(Node, ExecutionId, 200),
        await_edge_termination(Node, edge_01, ExecutionId, 200),

        FinalInfo = hayata_node:get_info(Node),
        Executions = maps:get(executions, FinalInfo),
        Execution = maps:get(ExecutionId, Executions),

        ?assertEqual(completed, maps:get(status, Execution)),
        ?assertEqual(
            #{edge_01 => {ok, recovered_result}},
            maps:get(results, Execution)
        ),
        ?assertEqual(#{}, maps:get(errors, Execution)),
        ?assertEqual([], maps:get(pending_edges, Execution)),
        ?assertEqual(1, atomics:get(Runs, 1))
    end).

reducer_recovery_with_edge_failure_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),
        Runs = atomics:new(1, []),
        ExecutionId = execution_recovery_edge_failure,

        EdgeTasks = [
            {edge_01, fun() ->
                atomics:add(Runs, 1, 1),
                Parent ! {edge_started, self()},
                receive
                    continue -> {error, expected_failure}
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

        Info = hayata_node:get_info(Node),
        ActiveReducers = maps:get(active_reducers, Info),
        #{pid := OriginalReducer} = maps:get(
            ExecutionId,
            ActiveReducers
        ),

        EdgeMonitor = erlang:monitor(process, EdgePid),

        try
            ok = sys:suspend(Node),
            exit(OriginalReducer, kill),
            EdgePid ! continue,

            receive
                {'DOWN', EdgeMonitor, process, EdgePid,
                 {edge_failed, expected_failure}} ->
                    ok;
                {'DOWN', EdgeMonitor, process, EdgePid, Reason} ->
                    error({unexpected_edge_exit, Reason})
            after 1000 ->
                error(edge_termination_timeout)
            end
        after
            case sys:resume(Node) of
                ok -> ok;
                _ -> ok
            end
        end,

        await_execution_completed(Node, ExecutionId, 200),
        await_edge_failure_termination(Node, edge_01, ExecutionId, 200),

        FinalInfo = hayata_node:get_info(Node),
        Executions = maps:get(executions, FinalInfo),
        Execution = maps:get(ExecutionId, Executions),

        ?assertEqual(completed, maps:get(status, Execution)),
        ?assertEqual(#{}, maps:get(results, Execution)),
        ?assertEqual(
            #{edge_01 => expected_failure},
            maps:get(errors, Execution)
        ),
        ?assertEqual([], maps:get(pending_edges, Execution)),
        ?assertEqual(1, atomics:get(Runs, 1))
    end).

reducer_recovery_ignores_stale_result_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),
        ExecutionId = execution_stale_reducer_result,

        EdgeTasks = [
            {edge_01, fun() ->
                Parent ! {edge_started, self()},
                receive
                    continue -> {ok, actual_result}
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
        ActiveReducersBefore = maps:get(active_reducers, InfoBefore),
        #{pid := OriginalReducer} = maps:get(
            ExecutionId,
            ActiveReducersBefore
        ),

        exit(OriginalReducer, kill),

        ReplacementReducer = await_replacement_reducer(
            Node,
            ExecutionId,
            OriginalReducer,
            100
        ),

        StaleResult = #{
            status => completed,
            execution_id => ExecutionId,
            results => #{edge_01 => {ok, stale_result}},
            errors => #{},
            pending_edges => []
        },

        Node ! {
            hayata_reducer_result,
            OriginalReducer,
            ExecutionId,
            StaleResult
        },

        InfoAfterStaleResult = hayata_node:get_info(Node),
        ExecutionsAfterStaleResult = maps:get(
            executions,
            InfoAfterStaleResult
        ),
        ExecutionAfterStaleResult = maps:get(
            ExecutionId,
            ExecutionsAfterStaleResult
        ),
        ActiveReducersAfterStaleResult = maps:get(
            active_reducers,
            InfoAfterStaleResult
        ),
        #{pid := ActiveReducer} = maps:get(
            ExecutionId,
            ActiveReducersAfterStaleResult
        ),

        ?assertEqual(
            recovering,
            maps:get(status, ExecutionAfterStaleResult)
        ),
        ?assertEqual(
            #{},
            maps:get(results, ExecutionAfterStaleResult)
        ),
        ?assertEqual(
            ReplacementReducer,
            ActiveReducer
        ),

        EdgePid ! continue,

        await_execution_completed(Node, ExecutionId, 200),

        FinalInfo = hayata_node:get_info(Node),
        Executions = maps:get(executions, FinalInfo),
        Execution = maps:get(ExecutionId, Executions),

        ?assertEqual(completed, maps:get(status, Execution)),
        ?assertEqual(
            #{edge_01 => {ok, actual_result}},
            maps:get(results, Execution)
        ),
        ?assertEqual(#{}, maps:get(errors, Execution)),
        ?assertEqual([], maps:get(pending_edges, Execution))
    end).

reducer_recovery_failure_preserves_results_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),
        ExecutionId = execution_recovery_failure_preserves_results,

        EdgeTasks = [
            {edge_01, fun() ->
                {ok, first_result}
            end},
            {edge_02, fun() ->
                Parent ! {second_edge_started, self()},
                receive
                    continue -> {ok, second_result}
                end
            end}
        ],

        {ok, ExecutionId} = hayata_node:start_execution(
            Node,
            ExecutionId,
            EdgeTasks,
            5000
        ),

        await_execution_result(Node, ExecutionId, edge_01, 100),

        InfoBefore = hayata_node:get_info(Node),
        ActiveReducersBefore = maps:get(active_reducers, InfoBefore),
        #{pid := OriginalReducer} = maps:get(
            ExecutionId,
            ActiveReducersBefore
        ),

        SecondEdgePid = receive
            {second_edge_started, Pid} -> Pid
        after 1000 ->
            error(second_edge_start_timeout)
        end,

        exit(OriginalReducer, kill),

        ReplacementReducer = await_replacement_reducer(
            Node,
            ExecutionId,
            OriginalReducer,
            100
        ),

        exit(ReplacementReducer, kill),

        await_recovery_failed(Node, ExecutionId, 100),

        InfoAfterFailure = hayata_node:get_info(Node),
        ExecutionsAfterFailure = maps:get(
            executions,
            InfoAfterFailure
        ),
        ExecutionAfterFailure = maps:get(
            ExecutionId,
            ExecutionsAfterFailure
        ),

        ?assertMatch(
            {reducer_recovery_failed, _},
            maps:get(status, ExecutionAfterFailure)
        ),
        ?assertEqual(
            #{edge_01 => {ok, first_result}},
            maps:get(results, ExecutionAfterFailure)
        ),
        ?assertEqual(#{}, maps:get(errors, ExecutionAfterFailure)),

        SecondEdgePid ! continue,

        timer:sleep(20),

        FinalInfo = hayata_node:get_info(Node),
        FinalExecutions = maps:get(executions, FinalInfo),
        FinalExecution = maps:get(ExecutionId, FinalExecutions),

        ?assertMatch(
            {reducer_recovery_failed, _},
            maps:get(status, FinalExecution)
        ),
        ?assertEqual(
            #{edge_01 => {ok, first_result}},
            maps:get(results, FinalExecution)
        ),
        ?assertEqual(#{}, maps:get(errors, FinalExecution))
    end).

reducer_recovery_edge_completes_after_replacement_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),
        Runs = atomics:new(1, []),
        ExecutionId = execution_edge_after_replacement,

        EdgeTasks = [
            {edge_01, fun() ->
                atomics:add(Runs, 1, 1),
                Parent ! {edge_started, self()},
                receive
                    continue -> {ok, recovered_result}
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
        ActiveReducersBefore = maps:get(active_reducers, InfoBefore),
        #{pid := OriginalReducer} = maps:get(
            ExecutionId,
            ActiveReducersBefore
        ),

        exit(OriginalReducer, kill),

        ReplacementReducer = await_replacement_reducer(
            Node,
            ExecutionId,
            OriginalReducer,
            100
        ),

        EdgePid ! continue,

        await_execution_completed(Node, ExecutionId, 200),
        await_edge_termination(Node, edge_01, ExecutionId, 200),

        FinalInfo = hayata_node:get_info(Node),
        Executions = maps:get(executions, FinalInfo),
        Execution = maps:get(ExecutionId, Executions),
        ActiveReducers = maps:get(active_reducers, FinalInfo),

        ?assertEqual(completed, maps:get(status, Execution)),
        ?assertEqual(
            #{edge_01 => {ok, recovered_result}},
            maps:get(results, Execution)
        ),
        ?assertEqual(#{}, maps:get(errors, Execution)),
        ?assertEqual([], maps:get(pending_edges, Execution)),
        ?assertEqual(1, atomics:get(Runs, 1)),
        ?assertEqual(false, maps:is_key(ExecutionId, ActiveReducers)),
        ?assert(is_process_alive(ReplacementReducer) =:= false)
    end).

reducer_recovery_preserves_concurrent_edge_results_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),
        Runs = atomics:new(2, []),
        ExecutionId = execution_concurrent_edge_recovery,

        EdgeTasks = [
            {edge_01, fun() ->
                atomics:add(Runs, 1, 1),
                Parent ! {edge_started, edge_01, self()},
                receive
                    continue -> {ok, result_01}
                end
            end},
            {edge_02, fun() ->
                atomics:add(Runs, 2, 1),
                Parent ! {edge_started, edge_02, self()},
                receive
                    continue -> {error, expected_failure}
                end
            end}
        ],

        {ok, ExecutionId} = hayata_node:start_execution(
            Node,
            ExecutionId,
            EdgeTasks,
            5000
        ),

        EdgePids = receive_edge_pids(2, #{}),

        InfoBefore = hayata_node:get_info(Node),
        ActiveReducersBefore = maps:get(active_reducers, InfoBefore),
        #{pid := OriginalReducer} = maps:get(
            ExecutionId,
            ActiveReducersBefore
        ),

        EdgeMonitors = [
            {EdgeId, Pid, erlang:monitor(process, Pid)}
            || {EdgeId, Pid} <- maps:to_list(EdgePids)
        ],

        try
            ok = sys:suspend(Node),
            exit(OriginalReducer, kill),

            maps:foreach(
                fun(_EdgeId, Pid) ->
                    Pid ! continue
                end,
                EdgePids
            ),

            lists:foreach(
                fun({EdgeId, Pid, MonitorRef}) ->
                    receive
                        {'DOWN', MonitorRef, process, Pid, Reason}
                                when EdgeId =:= edge_01,
                                     Reason =:= normal ->
                            ok;
                        {'DOWN', MonitorRef, process, Pid,
                         {edge_failed, expected_failure}}
                                when EdgeId =:= edge_02 ->
                            ok;
                        {'DOWN', MonitorRef, process, Pid, Reason} ->
                            error({unexpected_edge_exit, EdgeId, Reason})
                    after 1000 ->
                        error({edge_termination_timeout, EdgeId})
                    end
                end,
                EdgeMonitors
            )
        after
            case sys:resume(Node) of
                ok -> ok;
                _ -> ok
            end
        end,

        await_execution_completed(Node, ExecutionId, 200),

        FinalInfo = hayata_node:get_info(Node),
        Executions = maps:get(executions, FinalInfo),
        Execution = maps:get(ExecutionId, Executions),

        ?assertEqual(completed, maps:get(status, Execution)),
        ?assertEqual(
            #{edge_01 => {ok, result_01}},
            maps:get(results, Execution)
        ),
        ?assertEqual(
            #{edge_02 => expected_failure},
            maps:get(errors, Execution)
        ),
        ?assertEqual([], maps:get(pending_edges, Execution)),
        ?assertEqual(1, atomics:get(Runs, 1)),
        ?assertEqual(1, atomics:get(Runs, 2))
    end).


reducer_recovery_processes_queued_results_before_timeout_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),
        ExecutionId = execution_queued_results_before_timeout,

        EdgeTasks = [
            {edge_01, fun() ->
                Parent ! {edge_started, edge_01, self()},
                receive
                    continue -> {ok, result_01}
                end
            end},
            {edge_02, fun() ->
                Parent ! {edge_started, edge_02, self()},
                receive
                    continue -> {ok, result_02}
                end
            end}
        ],

        {ok, ExecutionId} = hayata_node:start_execution(
            Node,
            ExecutionId,
            EdgeTasks,
            5000
        ),

        EdgePids = receive_edge_pids(2, #{}),

        InfoBefore = hayata_node:get_info(Node),
        ActiveReducersBefore = maps:get(active_reducers, InfoBefore),
        #{pid := OriginalReducer} = maps:get(
            ExecutionId,
            ActiveReducersBefore
        ),

        exit(OriginalReducer, kill),

        ReplacementReducer = await_replacement_reducer(
            Node,
            ExecutionId,
            OriginalReducer,
            100
        ),

        try
            ok = sys:suspend(ReplacementReducer),

            ReplacementReducer ! {
                hayata_reducer_edge_result,
                edge_01,
                ExecutionId,
                {ok, result_01}
            },
            ReplacementReducer ! {
                hayata_reducer_edge_result,
                edge_02,
                ExecutionId,
                {ok, result_02}
            },
            ReplacementReducer ! {
                reducer_timeout,
                ExecutionId
            }
        after
            case sys:resume(ReplacementReducer) of
                ok -> ok;
                _ -> ok
            end
        end,

        await_execution_completed(Node, ExecutionId, 200),

        FinalInfo = hayata_node:get_info(Node),
        Executions = maps:get(executions, FinalInfo),
        Execution = maps:get(ExecutionId, Executions),

        ?assertEqual(completed, maps:get(status, Execution)),
        ?assertEqual(
            #{
                edge_01 => {ok, result_01},
                edge_02 => {ok, result_02}
            },
            maps:get(results, Execution)
        ),
        ?assertEqual(#{}, maps:get(errors, Execution)),
        ?assertEqual([], maps:get(pending_edges, Execution)),
        ?assertEqual(
            false,
            maps:is_key(
                ExecutionId,
                maps:get(active_reducers, FinalInfo)
            )
        ),

        maps:foreach(
            fun(_EdgeId, EdgePid) ->
                EdgePid ! continue
            end,
            EdgePids
        )
    end).

duplicate_edge_down_preserves_execution_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),
        ExecutionId = execution_duplicate_edge_down,

        EdgeTasks = [
            {edge_01, fun() ->
                Parent ! {edge_started, self()},
                receive
                    continue -> {ok, actual_result}
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
        ActiveEdgesBefore = maps:get(active_edges, InfoBefore),

        {MonitorRef, EdgeInfo} = hd(maps:to_list(ActiveEdgesBefore)),
        ?assertEqual(EdgePid, maps:get(pid, EdgeInfo)),

        EdgePid ! continue,

        await_execution_completed(Node, ExecutionId, 200),
        await_edge_termination(Node, edge_01, ExecutionId, 200),

        InfoAfterTermination = hayata_node:get_info(Node),
        ExecutionsAfterTermination = maps:get(
            executions,
            InfoAfterTermination
        ),
        ExecutionAfterTermination = maps:get(
            ExecutionId,
            ExecutionsAfterTermination
        ),
        LastEvent = maps:get(last_edge_event, InfoAfterTermination),

        ?assertEqual(
            #{edge_01 => {ok, actual_result}},
            maps:get(results, ExecutionAfterTermination)
        ),
        ?assertEqual(#{}, maps:get(errors, ExecutionAfterTermination)),
        ?assertEqual([], maps:get(pending_edges, ExecutionAfterTermination)),
        ?assertEqual(
            #{},
            maps:get(active_edges, InfoAfterTermination)
        ),

        Node ! {'DOWN', MonitorRef, process, EdgePid, normal},

        InfoAfterDuplicate = hayata_node:get_info(Node),
        ExecutionsAfterDuplicate = maps:get(
            executions,
            InfoAfterDuplicate
        ),
        ExecutionAfterDuplicate = maps:get(
            ExecutionId,
            ExecutionsAfterDuplicate
        ),

        ?assertEqual(
            completed,
            maps:get(status, ExecutionAfterDuplicate)
        ),
        ?assertEqual(
            #{edge_01 => {ok, actual_result}},
            maps:get(results, ExecutionAfterDuplicate)
        ),
        ?assertEqual(#{}, maps:get(errors, ExecutionAfterDuplicate)),
        ?assertEqual([], maps:get(pending_edges, ExecutionAfterDuplicate)),
        ?assertEqual(
            #{},
            maps:get(active_edges, InfoAfterDuplicate)
        ),
        ?assertEqual(
            LastEvent,
            maps:get(last_edge_event, InfoAfterDuplicate)
        )
    end).

edge_failure_result_and_down_are_deduplicated_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        ExecutionId = execution_edge_failure_deduplication,

        EdgeTasks = [
            {edge_01, fun() ->
                {error, expected_failure}
            end}
        ],

        ?assertEqual(
            {ok, ExecutionId},
            hayata_node:start_execution(
                Node,
                ExecutionId,
                EdgeTasks,
                5000
            )
        ),

        await_execution_completed(Node, ExecutionId, 200),
        await_edge_failure_termination(
            Node,
            edge_01,
            ExecutionId,
            200
        ),

        Info = hayata_node:get_info(Node),
        Executions = maps:get(executions, Info),
        Execution = maps:get(ExecutionId, Executions),

        ?assertEqual(completed, maps:get(status, Execution)),
        ?assertEqual(#{}, maps:get(results, Execution)),
        ?assertEqual(
            #{edge_01 => expected_failure},
            maps:get(errors, Execution)
        ),
        ?assertEqual([], maps:get(pending_edges, Execution))
    end).

start_execution_notifies_recipient_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        ExecutionId = execution_notification,
        RecipientPid = self(),

        EdgeTasks = [
            {edge_01, fun() -> {ok, result_01} end}
        ],

        ?assertEqual(
            {ok, ExecutionId},
            hayata_node:start_execution(
                Node,
                ExecutionId,
                EdgeTasks,
                1000,
                RecipientPid
            )
        ),

        await_execution_completed(Node, ExecutionId, 200),

        receive
            {
                hayata_node_execution,
                think_01,
                ExecutionId,
                FinalResult
            } ->
                ?assertEqual(completed, maps:get(status, FinalResult)),
                ?assertEqual(
                    #{edge_01 => {ok, result_01}},
                    maps:get(results, FinalResult)
                ),
                ?assertEqual(#{}, maps:get(errors, FinalResult)),
                ?assertEqual([], maps:get(pending_edges, FinalResult))
        after 1000 ->
            error(execution_notification_timeout)
        end
    end).

start_execution_notification_is_not_duplicated_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        ExecutionId = execution_notification_deduplication,
        RecipientPid = self(),

        {ok, ExecutionId} = hayata_node:start_execution(
            Node,
            ExecutionId,
            [{edge_01, fun() -> {ok, result_01} end}],
            1000,
            RecipientPid
        ),

        await_execution_completed(Node, ExecutionId, 200),

        receive
            {
                hayata_node_execution,
                think_01,
                ExecutionId,
                #{status := completed}
            } ->
                ok
        after 1000 ->
            error(execution_notification_timeout)
        end,

        Info = hayata_node:get_info(Node),
        ActiveReducers = maps:get(active_reducers, Info),
        ?assertEqual(false, maps:is_key(ExecutionId, ActiveReducers)),

        %% A late duplicate result must not notify the recipient again.
        Node ! {
            hayata_edge_result,
            edge_01,
            ExecutionId,
            {ok, duplicate_result}
        },

        _ = hayata_node:get_info(Node),

        receive
            {hayata_node_execution, think_01, ExecutionId, _} ->
                error(duplicate_execution_notification)
        after 50 ->
            ok
        end
    end).

repeated_reducer_failure_notifies_recipient_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),
        ExecutionId = execution_recovery_failure_notification,

        EdgeTasks = [
            {edge_01, fun() ->
                Parent ! {edge_started, self()},
                receive
                    continue -> {ok, result_01}
                end
            end}
        ],

        ?assertEqual(
            {ok, ExecutionId},
            hayata_node:start_execution(
                Node,
                ExecutionId,
                EdgeTasks,
                5000,
                Parent
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
            ExecutionId,
            ActiveReducers
        ),

        exit(OriginalReducer, kill),

        ReplacementReducer = await_replacement_reducer(
            Node,
            ExecutionId,
            OriginalReducer,
            100
        ),

        exit(ReplacementReducer, kill),

        await_recovery_failed(Node, ExecutionId, 100),

        receive
            {
                hayata_node_execution,
                think_01,
                ExecutionId,
                FinalResult
            } ->
                ?assertMatch(
                    {reducer_recovery_failed, _},
                    maps:get(status, FinalResult)
                )
        after 1000 ->
            error(execution_notification_timeout)
        end,

        %% A terminal execution must not notify a second time.
        InfoAfterFailure = hayata_node:get_info(Node),
        Execution = maps:get(
            ExecutionId,
            maps:get(executions, InfoAfterFailure)
        ),
        ?assertMatch(
            {reducer_recovery_failed, _},
            maps:get(status, Execution)
        ),

        EdgePid ! continue,

        receive
            {hayata_node_execution, think_01, ExecutionId, _} ->
                error(duplicate_execution_notification)
        after 50 ->
            ok
        end
    end).

cancel_execution_test() ->
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
            {ok, execution_cancel},
            hayata_node:start_execution(
                Node,
                execution_cancel,
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
        #{pid := ReducerPid} = maps:get(execution_cancel, ActiveReducers),

        ?assertEqual(
            ok,
            hayata_node:cancel_execution(Node, execution_cancel)
        ),

        ?assertNot(is_process_alive(EdgePid)),
        ?assertNot(is_process_alive(ReducerPid)),

        FinalInfo = hayata_node:get_info(Node),
        Executions = maps:get(executions, FinalInfo),
        Execution = maps:get(execution_cancel, Executions),

        ?assertEqual(cancelled, maps:get(status, Execution)),
        ?assertEqual(0, map_size(maps:get(active_edges, FinalInfo))),
        ?assertEqual(0, map_size(maps:get(active_reducers, FinalInfo)))
    end).

cancel_execution_isolation_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),

        FirstEdgeTasks = [
            {edge_01, fun() ->
                Parent ! {edge_started, execution_01, self()},
                receive
                    continue -> {ok, result_01}
                end
            end}
        ],

        SecondEdgeTasks = [
            {edge_02, fun() ->
                Parent ! {edge_started, execution_02, self()},
                receive
                    continue -> {ok, result_02}
                end
            end}
        ],

        ?assertEqual(
            {ok, execution_01},
            hayata_node:start_execution(
                Node,
                execution_01,
                FirstEdgeTasks,
                5000
            )
        ),

        ?assertEqual(
            {ok, execution_02},
            hayata_node:start_execution(
                Node,
                execution_02,
                SecondEdgeTasks,
                5000
            )
        ),

        FirstEdgePid = receive
            {edge_started, execution_01, FirstPid} ->
                FirstPid
        after 1000 ->
            error(first_edge_start_timeout)
        end,

        SecondEdgePid = receive
            {edge_started, execution_02, SecondPid} ->
                SecondPid
        after 1000 ->
            error(second_edge_start_timeout)
        end,

        ?assert(is_process_alive(FirstEdgePid)),
        ?assert(is_process_alive(SecondEdgePid)),

        ?assertEqual(
            ok,
            hayata_node:cancel_execution(Node, execution_01)
        ),

        ?assertNot(is_process_alive(FirstEdgePid)),
        ?assert(is_process_alive(SecondEdgePid)),

        Info = hayata_node:get_info(Node),
        Executions = maps:get(executions, Info),

        FirstExecution = maps:get(execution_01, Executions),
        SecondExecution = maps:get(execution_02, Executions),

        ?assertEqual(cancelled, maps:get(status, FirstExecution)),
        ?assertNotEqual(cancelled, maps:get(status, SecondExecution)),

        SecondEdgePid ! continue,

        await_execution_completed(Node, execution_02, 200),

        FinalInfo = hayata_node:get_info(Node),
        FinalExecutions = maps:get(executions, FinalInfo),

        ?assertEqual(
            cancelled,
            maps:get(status, maps:get(execution_01, FinalExecutions))
        ),
        ?assertEqual(
            completed,
            maps:get(status, maps:get(execution_02, FinalExecutions))
        )
    end).

cancel_nonexistent_execution_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        ?assertEqual(
            {error, execution_not_found},
            hayata_node:cancel_execution(Node, nonexistent_execution)
        ),

        Info = hayata_node:get_info(Node),
        ?assertEqual(#{}, maps:get(executions, Info))
    end).

cancel_completed_execution_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        EdgeTasks = [
            {edge_01, fun() -> {ok, result_01} end}
        ],

        ?assertEqual(
            {ok, execution_completed},
            hayata_node:start_execution(
                Node,
                execution_completed,
                EdgeTasks,
                5000
            )
        ),

        await_execution_completed(Node, execution_completed, 200),

        ?assertEqual(
            {error, execution_not_active},
            hayata_node:cancel_execution(Node, execution_completed)
        ),

        Info = hayata_node:get_info(Node),
        Executions = maps:get(executions, Info),
        Execution = maps:get(execution_completed, Executions),

        ?assertEqual(completed, maps:get(status, Execution))
    end).

cancel_already_cancelled_execution_test() ->
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
            {ok, execution_cancelled},
            hayata_node:start_execution(
                Node,
                execution_cancelled,
                EdgeTasks,
                5000
            )
        ),

        EdgePid = receive
            {edge_started, Pid} -> Pid
        after 1000 ->
            error(edge_start_timeout)
        end,

        ?assertEqual(
            ok,
            hayata_node:cancel_execution(Node, execution_cancelled)
        ),

        ?assertNot(is_process_alive(EdgePid)),

        ?assertEqual(
            {error, execution_not_active},
            hayata_node:cancel_execution(Node, execution_cancelled)
        ),

        Info = hayata_node:get_info(Node),
        Executions = maps:get(executions, Info),
        Execution = maps:get(execution_cancelled, Executions),

        ?assertEqual(cancelled, maps:get(status, Execution))
    end).

cancel_execution_notifies_recipient_test() ->
    with_node(make_ref(), think_01, think, #{}, [], fun(Node) ->
        Parent = self(),
        ExecutionId = execution_cancel_notification,

        EdgeTasks = [
            {edge_01, fun() ->
                Parent ! {edge_started, self()},
                receive
                    continue -> {ok, result_01}
                end
            end}
        ],

        ?assertEqual(
            {ok, ExecutionId},
            hayata_node:start_execution(
                Node,
                ExecutionId,
                EdgeTasks,
                5000,
                Parent
            )
        ),

        EdgePid = receive
            {edge_started, Pid} -> Pid
        after 1000 ->
            error(edge_start_timeout)
        end,

        ?assertEqual(
            ok,
            hayata_node:cancel_execution(Node, ExecutionId)
        ),

        ?assertNot(is_process_alive(EdgePid)),

        receive
            {
                hayata_node_execution,
                think_01,
                ExecutionId,
                FinalResult
            } ->
                ?assertEqual(cancelled, maps:get(status, FinalResult)),
                ?assertNot(is_process_alive(EdgePid)) 
       after 1000 ->
            error(cancellation_notification_timeout)
        end
    end).

node_crash_terminates_active_edges_test() ->
    Parent = self(),
    {ok, Node} = hayata_node:start_link(
        make_ref(),
        think_01,
        think,
        #{},
        []
    ),
    unlink(Node),
    NodeMonitor = erlang:monitor(process, Node),

    try
        ?assertEqual(
            {ok, execution_node_crash},
            hayata_node:start_execution(
                Node,
                execution_node_crash,
                [
                    {edge_01, fun() ->
                        Parent ! {edge_started, self()},
                        receive
                            continue -> {ok, result_01}
                        end
                    end}
                ],
                5000
            )
        ),

        EdgePid = receive
            {edge_started, Pid} -> Pid
        after 1000 ->
            error(edge_start_timeout)
        end,
        EdgeMonitor = erlang:monitor(process, EdgePid),

        exit(Node, kill),

        receive
            {'DOWN', NodeMonitor, process, Node, killed} -> ok
        after 1000 ->
            error(node_termination_timeout)
        end,

        receive
            {'DOWN', EdgeMonitor, process, EdgePid, _Reason} -> ok
        after 1000 ->
            ?assertNot(is_process_alive(EdgePid))
        end,

        ?assertNot(is_process_alive(EdgePid))
    after
        case process_info(self(), messages) of
            {messages, Messages} ->
                case lists:keyfind(edge_started, 1, Messages) of
                    {edge_started, StartedPid} ->
                        StartedPid ! continue;  
                    false ->
                        ok
                end;
            undefined ->
                ok
        end
    end.

telemetry_emits_start_and_stop_for_successful_execution_test() ->
    ok = hayata_test_telemetry:ensure_telemetry_started(),
    {ok, HandlerId} = hayata_test_telemetry:attach(),

    AgentId = make_ref(),
    NodeId = telemetry_node,
    ExecutionId = telemetry_execution,

    try
        with_node(AgentId, NodeId, think, #{}, [], fun(Node) ->
            {ok, ExecutionId} = hayata_node:start_execution(
                Node,
                ExecutionId,
                [{edge_telemetry, fun() -> {ok, result} end}],
                1000,
                self()
            ),

            receive
                {hayata_node_execution, NodeId, ExecutionId,
                    #{status := completed}} ->
                    ok
            after 2000 ->
                error(node_execution_timeout)
            end,

            Events = hayata_test_telemetry:events(),
            NodeEvents = [
                Event
                || Event = {hayata_telemetry_event, _Name, _Measurements,
                    #{agent_id := EventAgentId,
                      node_id := EventNodeId,
                      execution_id := EventExecutionId}} <- Events,
                   EventAgentId =:= AgentId,
                   EventNodeId =:= NodeId,
                   EventExecutionId =:= ExecutionId
            ],

            ?assertMatch(
                [
                    {
                        hayata_telemetry_event,
                        [hayata, node, execution, start],
                        #{system_time := _},
                        #{
                            agent_id := AgentId,
                            node_id := NodeId,
                            execution_id := ExecutionId
                        }
                    },
                    {
                        hayata_telemetry_event,
                        [hayata, node, execution, stop],
                        #{duration := Duration},
                        #{
                            agent_id := AgentId,
                            node_id := NodeId,
                            execution_id := ExecutionId,
                            status := completed
                        }
                    }
                ] when is_integer(Duration) andalso Duration >= 0,
                NodeEvents
            )
        end)
    after
        ok = hayata_test_telemetry:detach(HandlerId)
    end.

telemetry_emits_stop_for_cancelled_execution_test() ->
    ok = hayata_test_telemetry:ensure_telemetry_started(),
    {ok, HandlerId} = hayata_test_telemetry:attach(),

    AgentId = make_ref(),
    NodeId = telemetry_cancel_node,
    ExecutionId = telemetry_cancel_execution,
    Parent = self(),

    try
        with_node(AgentId, NodeId, think, #{}, [], fun(Node) ->
            Task = fun() ->
                Parent ! {telemetry_task_started, self()},
                receive
                    continue -> {ok, result}
                end
            end,

            {ok, ExecutionId} = hayata_node:start_execution(
                Node,
                ExecutionId,
                [{edge_telemetry, Task}],
                5000,
                self()
            ),

            receive
                {telemetry_task_started, _Pid} -> ok
            after 1000 ->
                error(edge_start_timeout)
            end,

            ?assertEqual(
                ok,
                hayata_node:cancel_execution(Node, ExecutionId)
            ),

            Info = hayata_node:get_info(Node),
            Execution = maps:get(
                ExecutionId,
                maps:get(executions, Info)
            ),
            ?assertEqual(cancelled, maps:get(status, Execution)),

            Events = hayata_test_telemetry:events(),
            NodeEvents = [
                Event
                || Event = {hayata_telemetry_event, _Name, _Measurements,
                    #{agent_id := EventAgentId,
                      node_id := EventNodeId,
                      execution_id := EventExecutionId}} <- Events,
                   EventAgentId =:= AgentId,
                   EventNodeId =:= NodeId,
                   EventExecutionId =:= ExecutionId
            ],

            ?assertMatch(
                [
                    {
                        hayata_telemetry_event,
                        [hayata, node, execution, start],
                        #{system_time := _},
                        #{
                            agent_id := AgentId,
                            node_id := NodeId,
                            execution_id := ExecutionId
                        }
                    },
                    {
                        hayata_telemetry_event,
                        [hayata, node, execution, stop],
                        #{duration := Duration},
                        #{
                            agent_id := AgentId,
                            node_id := NodeId,
                            execution_id := ExecutionId,
                            status := cancelled
                        }
                    }
                ] when is_integer(Duration) andalso Duration >= 0,
                NodeEvents
            )
        end)
    after
        ok = hayata_test_telemetry:detach(HandlerId)
    end.

telemetry_emits_exception_for_reducer_recovery_failure_test() ->
    ok = hayata_test_telemetry:ensure_telemetry_started(),
    {ok, HandlerId} = hayata_test_telemetry:attach(),

    AgentId = make_ref(),
    NodeId = telemetry_recovery_node,
    ExecutionId = telemetry_recovery_execution,
    Parent = self(),

    try
        with_node(AgentId, NodeId, think, #{}, [], fun(Node) ->
            EdgeTasks = [
                {edge_01, fun() ->
                    {ok, first_result}
                end},
                {edge_02, fun() ->
                    Parent ! {telemetry_recovery_edge_started, self()},
                    receive
                        continue -> {ok, second_result}
                    end
                end}
            ],

            {ok, ExecutionId} = hayata_node:start_execution(
                Node,
                ExecutionId,
                EdgeTasks,
                5000
            ),

            await_execution_result(Node, ExecutionId, edge_01, 100),

            SecondEdgePid = receive
                {telemetry_recovery_edge_started, Pid} -> Pid
            after 1000 ->
                error(second_edge_start_timeout)
            end,

            InfoBefore = hayata_node:get_info(Node),
            ActiveReducersBefore = maps:get(active_reducers, InfoBefore),
            #{pid := OriginalReducer} = maps:get(
                ExecutionId,
                ActiveReducersBefore
            ),

            exit(OriginalReducer, kill),

            ReplacementReducer = await_replacement_reducer(
                Node,
                ExecutionId,
                OriginalReducer,
                100
            ),

            exit(ReplacementReducer, kill),

            await_recovery_failed(Node, ExecutionId, 100),

            InfoAfter = hayata_node:get_info(Node),
            Executions = maps:get(executions, InfoAfter),
            Execution = maps:get(ExecutionId, Executions),

            ?assertMatch(
                {reducer_recovery_failed, _},
                maps:get(status, Execution)
            ),

            Events = hayata_test_telemetry:events(),
            NodeEvents = [
                Event
                || Event = {
                    hayata_telemetry_event,
                    _Name,
                    _Measurements,
                    #{
                        agent_id := EventAgentId,
                        node_id := EventNodeId,
                        execution_id := EventExecutionId
                    }
                } <- Events,
                EventAgentId =:= AgentId,
                EventNodeId =:= NodeId,
                EventExecutionId =:= ExecutionId
            ],

            ?assertMatch(
                [
                    {
                        hayata_telemetry_event,
                        [hayata, node, execution, start],
                        #{system_time := _},
                        #{
                            agent_id := AgentId,
                            node_id := NodeId,
                            execution_id := ExecutionId
                        }
                    },
                    {
                        hayata_telemetry_event,
                        [hayata, node, execution, exception],
                        #{duration := Duration},
                        #{
                            agent_id := AgentId,
                            node_id := NodeId,
                            execution_id := ExecutionId,
                            status := {reducer_recovery_failed, _}
                        }
                    }
                ] when is_integer(Duration) andalso Duration >= 0,
                NodeEvents
            ),

            SecondEdgePid ! continue
        end)
    after
        ok = hayata_test_telemetry:detach(HandlerId)
    end.

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

await_edge_failure_termination(_Node, _EdgeId, _ExecutionId, 0) ->
    error(edge_failure_termination_timeout);
await_edge_failure_termination(Node, EdgeId, ExecutionId, Attempts) ->
    Info = hayata_node:get_info(Node),
    ActiveEdges = maps:get(active_edges, Info),
    LastEvent = maps:get(last_edge_event, Info),

    case {map_size(ActiveEdges), LastEvent} of
        {0, #{
            edge_id := EdgeId,
            execution_id := ExecutionId,
            reason := {edge_failed, expected_failure}
        }} ->
            ok;
        _ ->
            timer:sleep(10),
            await_edge_failure_termination(
                Node,
                EdgeId,
                ExecutionId,
                Attempts - 1
            )
    end.

receive_edge_pids(0, EdgePids) ->
    EdgePids;
receive_edge_pids(Count, EdgePids) ->
    receive
        {edge_started, EdgeId, Pid} ->
            receive_edge_pids(
                Count - 1,
                maps:put(EdgeId, Pid, EdgePids)
            )
    after 1000 ->
        error(edge_start_timeout)
    end.
