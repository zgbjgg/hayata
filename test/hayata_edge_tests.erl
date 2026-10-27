-module(hayata_edge_tests).

-include_lib("eunit/include/eunit.hrl").

successful_execution_test() ->
    ok = hayata_task_store:ensure_started(),

    {ok, EdgePid} = hayata_edge:start(
        self(),
        edge_01,
        execution_01,
        fun(_Context) -> {ok, result_01} end
    ),
    MonitorRef = erlang:monitor(process, EdgePid),

    ?assertEqual(ok, hayata_edge:execute(EdgePid)),

    ?assertEqual(
        {hayata_edge_result, edge_01, execution_01, {ok, result_01}},
        receive_message()
    ),
    ?assertEqual(normal, receive_down(MonitorRef, EdgePid)).

controlled_error_test() ->
    ok = hayata_task_store:ensure_started(),

    {ok, EdgePid} = hayata_edge:start(
        self(),
        edge_02,
        execution_02,
        fun(_Context) -> {error, task_failed} end
    ),
    MonitorRef = erlang:monitor(process, EdgePid),

    ?assertEqual(ok, hayata_edge:execute(EdgePid)),

    ?assertEqual(
        {hayata_edge_result, edge_02, execution_02, {error, task_failed}},
        receive_message()
    ),
    ?assertEqual(
        {edge_failed, task_failed},
        receive_down(MonitorRef, EdgePid)
    ).

exception_test() ->
    ok = hayata_task_store:ensure_started(),

    {ok, EdgePid} = hayata_edge:start(
        self(),
        edge_03,
        execution_03,
        fun(_Context) -> erlang:error(task_crashed) end
    ),
    MonitorRef = erlang:monitor(process, EdgePid),

    ?assertEqual(ok, hayata_edge:execute(EdgePid)),

    Result = receive_message(),
    ?assertMatch(
        {hayata_edge_result, edge_03, execution_03,
            {error, {exception, error, task_crashed, _}}},
        Result
    ),
    ?assertMatch(
        {edge_failed, {exception, error, task_crashed, _}},
        receive_down(MonitorRef, EdgePid)
    ).

abrupt_termination_test() ->
    ok = hayata_task_store:ensure_started(),

    Parent = self(),
    ExecutionId = make_ref(),

    {ok, EdgePid} = hayata_edge:start(
        self(),
        edge_04,
        ExecutionId,
        fun(#{parent := ParentEdgePid}) ->
            Parent ! {task_started, ParentEdgePid},
            receive
                continue -> {ok, unexpected}
            end
        end
    ),

    MonitorRef = erlang:monitor(process, EdgePid),

    ?assertEqual(ok, hayata_edge:execute(EdgePid)),

    receive
        {task_started, EdgePid} -> ok
    after 1000 ->
        error(task_start_timeout)
    end,

    exit(EdgePid, kill),

    ?assertEqual(killed, receive_down(MonitorRef, EdgePid)),
    ?assertEqual(no_message, receive_optional_message()).

telemetry_emits_start_and_stop_for_successful_execution_test() ->
    ok = hayata_task_store:ensure_started(),

    ok = hayata_test_telemetry:ensure_telemetry_started(),
    {ok, HandlerId} = hayata_test_telemetry:attach(),

    try
        {ok, EdgePid} = hayata_edge:start(
            self(),
            edge_telemetry,
            execution_telemetry,
            fun(_Context) -> {ok, result_telemetry} end
        ),

        MonitorRef = erlang:monitor(process, EdgePid),
        ok = hayata_edge:execute(EdgePid),

        receive
            {hayata_edge_result, edge_telemetry,
                execution_telemetry, {ok, result_telemetry}} ->
                ok
        after 1000 ->
            error(edge_result_timeout)
        end,

        receive
            {'DOWN', MonitorRef, process, EdgePid, normal} ->
                ok
        after 1000 ->
            error(edge_down_timeout)
        end,

        Events = hayata_test_telemetry:events(),

        ?assertMatch(
            [
                {
                    hayata_telemetry_event,
                    [hayata, edge, start],
                    #{system_time := _},
                    #{
                        edge_id := edge_telemetry,
                        execution_id := execution_telemetry
                    }
                },
                {
                    hayata_telemetry_event,
                    [hayata, edge, stop],
                    #{duration := Duration},
                    #{
                        edge_id := edge_telemetry,
                        execution_id := execution_telemetry
                    }
                }
            ] when is_integer(Duration),
            Events
        )
    after
        ok = hayata_test_telemetry:detach(HandlerId)
    end.

telemetry_emits_stop_for_controlled_error_test() ->
    ok = hayata_task_store:ensure_started(),

    ok = hayata_test_telemetry:ensure_telemetry_started(),
    {ok, HandlerId} = hayata_test_telemetry:attach(),

    try
        {ok, EdgePid} = hayata_edge:start(
            self(),
            edge_telemetry_error,
            execution_telemetry_error,
            fun(_Context) -> {error, task_failed} end
        ),

        MonitorRef = erlang:monitor(process, EdgePid),
        ok = hayata_edge:execute(EdgePid),

        receive
            {
                hayata_edge_result,
                edge_telemetry_error,
                execution_telemetry_error,
                {error, task_failed}
            } ->
                ok
        after 1000 ->
            error(edge_result_timeout)
        end,

        receive
            {
                'DOWN',
                MonitorRef,
                process,
                EdgePid,
                {edge_failed, task_failed}
            } ->
                ok
        after 1000 ->
            error(edge_down_timeout)
        end,

        Events = hayata_test_telemetry:events(),

        ?assertMatch(
            [
                {
                    hayata_telemetry_event,
                    [hayata, edge, start],
                    #{system_time := _},
                    #{
                        edge_id := edge_telemetry_error,
                        execution_id := execution_telemetry_error
                    }
                },
                {
                    hayata_telemetry_event,
                    [hayata, edge, stop],
                    #{duration := Duration},
                    #{
                        edge_id := edge_telemetry_error,
                        execution_id := execution_telemetry_error
                    }
                }
            ] when is_integer(Duration),
            Events
        )
    after
        ok = hayata_test_telemetry:detach(HandlerId)
    end.

telemetry_emits_exception_for_task_exception_test() ->
    ok = hayata_task_store:ensure_started(),

    ok = hayata_test_telemetry:ensure_telemetry_started(),
    {ok, HandlerId} = hayata_test_telemetry:attach(),

    try
        {ok, EdgePid} = hayata_edge:start(
            self(),
            edge_telemetry_exception,
            execution_telemetry_exception,
            fun(_Context) -> erlang:error(task_crashed) end
        ),

        MonitorRef = erlang:monitor(process, EdgePid),
        ok = hayata_edge:execute(EdgePid),

        receive
            {
                hayata_edge_result,
                edge_telemetry_exception,
                execution_telemetry_exception,
                {error, {exception, error, task_crashed, _Stacktrace}}
            } ->
                ok
        after 1000 ->
            error(edge_result_timeout)
        end,

        receive
            {
                'DOWN',
                MonitorRef,
                process,
                EdgePid,
                {edge_failed, {exception, error, task_crashed, _}}
            } ->
                ok
        after 1000 ->
            error(edge_down_timeout)
        end,

        Events = hayata_test_telemetry:events(),

        ?assertMatch(
            [
                {
                    hayata_telemetry_event,
                    [hayata, edge, start],
                    #{system_time := _},
                    #{
                        edge_id := edge_telemetry_exception,
                        execution_id := execution_telemetry_exception
                    }
                },
                {
                    hayata_telemetry_event,
                    [hayata, edge, exception],
                    #{duration := Duration},
                    #{
                        edge_id := edge_telemetry_exception,
                        execution_id := execution_telemetry_exception,
                        class := error
                    } = _Metadata
                }
            ]
            when is_integer(Duration),
            Events
        ),

        [{hayata_telemetry_event, _, _, _},
         {hayata_telemetry_event, _, _, Metadata}] = Events,
        ?assertNot(maps:is_key(reason, Metadata)),
        ?assertNot(maps:is_key(stacktrace, Metadata))
    after
        ok = hayata_test_telemetry:detach(HandlerId)
    end.

completed_checkpoint_is_reused_after_edge_restart_test() ->
    ok = hayata_task_store:ensure_started(),

    Parent = self(),
    AgentId = make_ref(),
    ExecutionId = make_ref(),
    EdgeId = make_ref(),
    Metadata = #{agent_id => AgentId},
    ExpectedResult = {ok, #{processed => true}},

    Task = fun(_Context) ->
        {ok, #{processed => true}}
    end,

    {ok, FirstEdgePid} = hayata_edge:start(
        self(),
        undefined,
        EdgeId,
        ExecutionId,
        Task,
        Metadata
    ),
    FirstMonitor = erlang:monitor(process, FirstEdgePid),

    ok = hayata_edge:execute(FirstEdgePid),

    ?assertEqual(
        {
            hayata_edge_result,
            EdgeId,
            ExecutionId,
            ExpectedResult
        },
        receive_message()
    ),
    ?assertEqual(
        normal,
        receive_down(FirstMonitor, FirstEdgePid)
    ),

    RetryTask = fun(#{parent := ParentEdgePid2}) ->
        Parent ! {task_reexecuted, ParentEdgePid2},
        {ok, unexpected_result}
    end,

    {ok, SecondEdgePid} = hayata_edge:start(
        self(),
        undefined,
        EdgeId,
        ExecutionId,
        RetryTask,
        Metadata
    ),
    SecondMonitor = erlang:monitor(process, SecondEdgePid),

    ok = hayata_edge:execute(SecondEdgePid),

    ?assertEqual(
        {
            hayata_edge_result,
            EdgeId,
            ExecutionId,
            ExpectedResult
        },
        receive_message()
    ),
    ?assertEqual(
        normal,
        receive_down(SecondMonitor, SecondEdgePid)
    ),

    receive
        {task_reexecuted, SecondEdgePid} ->
            ?assert(false)
    after 50 ->
        ok
    end.

running_checkpoint_is_not_reexecuted_after_edge_restart_test() ->
    ok = hayata_task_store:ensure_started(),

    Parent = self(),
    AgentId = make_ref(),
    ExecutionId = make_ref(),
    EdgeId = make_ref(),
    Metadata = #{agent_id => AgentId},

    Task = fun(#{parent := ParentEdgePid}) ->
        Parent ! {task_started, ParentEdgePid},
        receive
            continue -> {ok, completed}
        end
    end,

    {ok, FirstEdgePid} = hayata_edge:start(
        self(),
        undefined,
        EdgeId,
        ExecutionId,
        Task,
        Metadata
    ),
    FirstMonitor = erlang:monitor(process, FirstEdgePid),

    ok = hayata_edge:execute(FirstEdgePid),

    receive
        {task_started, FirstEdgePid} -> ok
    after 1000 ->
        error(task_start_timeout)
    end,

    exit(FirstEdgePid, kill),

    ?assertEqual(
        killed,
        receive_down(FirstMonitor, FirstEdgePid)
    ),

    RetryTask = fun(#{parent := ParentEdgePid2}) ->
        Parent ! {task_reexecuted, ParentEdgePid2},
        {ok, unexpected_result}
    end,

    {ok, SecondEdgePid} = hayata_edge:start(
        self(),
        undefined,
        EdgeId,
        ExecutionId,
        RetryTask,
        Metadata
    ),
    SecondMonitor = erlang:monitor(process, SecondEdgePid),

    ok = hayata_edge:execute(SecondEdgePid),

    ?assertEqual(
        {
            hayata_edge_result,
            EdgeId,
            ExecutionId,
            {error, task_execution_uncertain}
        },
        receive_message()
    ),

    ?assertEqual(
        {edge_failed, task_execution_uncertain},
        receive_down(SecondMonitor, SecondEdgePid)
    ),

    receive
        {task_reexecuted, SecondEdgePid} ->
            ?assert(false)
    after 50 ->
        ok
    end.


different_nodes_use_independent_checkpoints_test() ->
    ok = hayata_task_store:ensure_started(),

    AgentId = make_ref(),
    ExecutionId = make_ref(),
    EdgeId = make_ref(),

    FirstMetadata = #{
        agent_id => AgentId,
        node_id => node_a
    },
    SecondMetadata = #{
        agent_id => AgentId,
        node_id => node_b
    },

    {ok, FirstEdgePid} = hayata_edge:start(
        self(),
        undefined,
        EdgeId,
        ExecutionId,
        fun(_Context) -> {ok, result_a} end,
        FirstMetadata
    ),

    FirstMonitor = erlang:monitor(process, FirstEdgePid),
    ok = hayata_edge:execute(FirstEdgePid),

    ?assertEqual(
        {hayata_edge_result, EdgeId, ExecutionId, {ok, result_a}},
        receive_message()
    ),
    ?assertEqual(
        normal,
        receive_down(FirstMonitor, FirstEdgePid)
    ),

    {ok, SecondEdgePid} = hayata_edge:start(
        self(),
        undefined,
        EdgeId,
        ExecutionId,
        fun(_Context) -> {ok, result_b} end,
        SecondMetadata
    ),

    SecondMonitor = erlang:monitor(process, SecondEdgePid),
    ok = hayata_edge:execute(SecondEdgePid),

    ?assertEqual(
        {hayata_edge_result, EdgeId, ExecutionId, {ok, result_b}},
        receive_message()
    ),
    ?assertEqual(
        normal,
        receive_down(SecondMonitor, SecondEdgePid)
    ).

receive_message() ->
    receive
        Message = {hayata_edge_result, _, _, _} ->
            Message
    after 1000 ->
        error(result_timeout)
    end.

receive_down(MonitorRef, EdgePid) ->
    receive
        {'DOWN', MonitorRef, process, EdgePid, Reason} ->
            Reason
    after 1000 ->
        error(down_timeout)
    end.

receive_optional_message() ->
    receive
        {hayata_edge_result, _, _, _} = Message ->
            Message
    after 50 ->
        no_message
    end.
