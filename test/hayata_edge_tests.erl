-module(hayata_edge_tests).

-include_lib("eunit/include/eunit.hrl").

successful_execution_test() ->
    {ok, EdgePid} = hayata_edge:start(
        self(),
        edge_01,
        execution_01,
        fun() -> {ok, result_01} end
    ),
    MonitorRef = erlang:monitor(process, EdgePid),

    ?assertEqual(ok, hayata_edge:execute(EdgePid)),

    ?assertEqual(
        {hayata_edge_result, edge_01, execution_01, {ok, result_01}},
        receive_message()
    ),
    ?assertEqual(normal, receive_down(MonitorRef, EdgePid)).

controlled_error_test() ->
    {ok, EdgePid} = hayata_edge:start(
        self(),
        edge_02,
        execution_02,
        fun() -> {error, task_failed} end
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
    {ok, EdgePid} = hayata_edge:start(
        self(),
        edge_03,
        execution_03,
        fun() -> erlang:error(task_crashed) end
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
    Parent = self(),
    {ok, EdgePid} = hayata_edge:start(
        self(),
        edge_04,
        execution_04,
        fun() ->
            Parent ! {task_started, self()},
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
    ok = hayata_test_telemetry:ensure_telemetry_started(),
    {ok, HandlerId} = hayata_test_telemetry:attach(),

    try
        {ok, EdgePid} = hayata_edge:start(
            self(),
            edge_telemetry,
            execution_telemetry,
            fun() -> {ok, result_telemetry} end
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
    ok = hayata_test_telemetry:ensure_telemetry_started(),
    {ok, HandlerId} = hayata_test_telemetry:attach(),

    try
        {ok, EdgePid} = hayata_edge:start(
            self(),
            edge_telemetry_error,
            execution_telemetry_error,
            fun() -> {error, task_failed} end
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
    ok = hayata_test_telemetry:ensure_telemetry_started(),
    {ok, HandlerId} = hayata_test_telemetry:attach(),

    try
        {ok, EdgePid} = hayata_edge:start(
            self(),
            edge_telemetry_exception,
            execution_telemetry_exception,
            fun() -> erlang:error(task_crashed) end
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
                    } = Metadata
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
