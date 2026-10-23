-module(hayata_task_launcher_tests).

-include_lib("eunit/include/eunit.hrl").

execute_and_persist_result_test() ->
    ok = hayata_task_store:ensure_started(),

    with_supervisor(fun() ->
        TaskKey = new_task_key(),
        Parent = self(),

        TaskFun = fun() ->
            Parent ! task_executed,
            {ok, computed_result}
        end,

        {ok, _Pid} = hayata_task_launcher_sup:start_task(#{
            task_key => TaskKey,
            task_fun => TaskFun,
            notify_pid => self(),
            metadata => #{node_id => compute, step => 1}
        }),

        receive
            task_executed ->
                ok
        after 1000 ->
            error(task_execution_timeout)
        end,

        receive
            {hayata_task_result, TaskKey, {ok, computed_result}} ->
                ok
        after 1000 ->
            error(task_result_timeout)
        end,

        {ok, Checkpoint} = hayata_task_store:get_task(TaskKey),

        ?assertEqual(completed, maps:get(status, Checkpoint)),
        ?assertEqual(
            {ok, computed_result},
            maps:get(result, Checkpoint)
        ),
        ?assertEqual(compute, maps:get(node_id, Checkpoint)),
        ?assertEqual(1, maps:get(step, Checkpoint))
    end).

completed_task_is_not_executed_again_test() ->
    ok = hayata_task_store:ensure_started(),

    with_supervisor(fun() ->
        TaskKey = new_task_key(),
        Parent = self(),
        Result = {ok, recovered_result},

        ok = hayata_task_store:save_task_result(TaskKey, Result),

        TaskFun = fun() ->
            Parent ! task_must_not_execute,
            {ok, unexpected_result}
        end,

        {ok, _Pid} = hayata_task_launcher_sup:start_task(#{
            task_key => TaskKey,
            task_fun => TaskFun,
            notify_pid => self()
        }),

        receive
            {hayata_task_result, TaskKey, Result} ->
                ok
        after 1000 ->
            error(recovered_result_timeout)
        end,

        receive
            task_must_not_execute ->
                error(completed_task_was_executed_again)
        after 100 ->
            ok
        end
    end).

running_task_is_not_executed_again_test() ->
    ok = hayata_task_store:ensure_started(),

    with_supervisor(fun() ->
        TaskKey = new_task_key(),
        Parent = self(),

        ?assertEqual(
            {ok, execute},
            hayata_task_store:claim_task(
                TaskKey,
                #{node_id => external_operation, step => 1}
            )
        ),

        TaskFun = fun() ->
            Parent ! uncertain_task_was_reexecuted,
            {ok, unexpected_result}
        end,

        {ok, _Pid} = hayata_task_launcher_sup:start_task(#{
            task_key => TaskKey,
            task_fun => TaskFun,
            notify_pid => self()
        }),

        receive
            {
                hayata_task_result,
                TaskKey,
                {error, task_execution_uncertain}
            } ->
                ok
        after 1000 ->
            error(uncertain_result_timeout)
        end,

        receive
            uncertain_task_was_reexecuted ->
                error(uncertain_task_was_reexecuted)
        after 100 ->
            ok
        end
    end).

task_exception_is_persisted_test() ->
    ok = hayata_task_store:ensure_started(),

    with_supervisor(fun() ->
        TaskKey = new_task_key(),

        {ok, _Pid} = hayata_task_launcher_sup:start_task(#{
            task_key => TaskKey,
            task_fun => fun() -> erlang:error(task_failed) end,
            notify_pid => self()
        }),

        receive
            {
                hayata_task_result,
                TaskKey,
                {error, {exception, error, task_failed, Stacktrace}}
            } ->
                ?assert(is_list(Stacktrace))
        after 1000 ->
            error(task_exception_timeout)
        end,

        {ok, Checkpoint} = hayata_task_store:get_task(TaskKey),

        ?assertEqual(completed, maps:get(status, Checkpoint)),
        ?assertMatch(
            {error, {exception, error, task_failed, _}},
            maps:get(result, Checkpoint)
        )
    end).

new_task_key() ->
    {
        make_ref(),
        make_ref(),
        task_launcher_test,
        make_ref()
    }.

with_supervisor(TestFun) ->
    {ok, SupPid} = hayata_task_launcher_sup:start_link(),
    unlink(SupPid),
    try
        TestFun()
    after
        exit(SupPid, shutdown)
    end.
