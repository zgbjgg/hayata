
-module(hayata_agent_tests).

-include_lib("eunit/include/eunit.hrl").

agent_finishes_without_nodes_test() ->
    Config = #{
        id => make_ref(),
        state => #{answer => 42},
        nodes => #{respond => fun(_State) -> #{} end},
        decision_policy => fun(Context) ->
            {finish, maps:get(state, Context)}
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        {ok, _InvocationId} = hayata_agent:run(Agent, hello),
        ?assertEqual(
            {ok, #{answer => 42}},
            hayata_agent:get_result(Agent)
        ),
        ?assertEqual(completed, maps:get(status, hayata_agent:get_info(Agent)))
    end).

node_execution_updates_context_test() ->
    Config = #{
        id => make_ref(),
        state => #{count => 0},
        nodes => #{
            increment => fun(State) ->
                #{count => maps:get(count, State) + 1}
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, increment, hello};
                1 -> {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        {ok, _InvocationId} = hayata_agent:run(Agent, start),
        await_status(Agent, completed, 100),
        ?assertEqual(#{count => 1}, hayata_agent:get_state(Agent)),
        ?assertEqual({ok, #{count => 1}}, hayata_agent:get_result(Agent))
    end).

rejects_invalid_node_test() ->
    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{respond => fun(_State) -> #{} end},
        decision_policy => fun(_Context) ->
            {next, missing_node, undefined}
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        ?assertMatch(
            {error, {unknown_node, missing_node}},
            hayata_agent:run(Agent, hello)
        )
    end).

recovers_after_node_failure_test() ->
    AgentId = make_ref(),
    FailureKey = {?MODULE, AgentId},
    persistent_term:put(FailureKey, true),

    Config = #{
        id => AgentId,
        state => #{attempt => 0},
        nodes => #{
            work => fun(State) ->
                case persistent_term:get(FailureKey) of
                    true ->
                        persistent_term:put(FailureKey, false),
                        erlang:error(first_attempt_failed);
                    false ->
                        #{attempt => maps:get(attempt, State) + 1}
                end
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, work, undefined};
                1 -> {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3
    },

    try
        with_agent(Config, fun(Agent) ->
            {ok, _FirstInvocation} =
                hayata_agent:run(Agent, first_attempt),

            await_terminal_status(Agent, 100),

            ?assertMatch(
                {error, _Reason},
                hayata_agent:get_result(Agent)
            ),

            {ok, _SecondInvocation} =
                hayata_agent:run(Agent, second_attempt),

            await_status(Agent, completed, 100),

            ?assertEqual(
                #{attempt => 1},
                hayata_agent:get_state(Agent)
            ),
            ?assertEqual(
                {ok, #{attempt => 1}},
                hayata_agent:get_result(Agent)
            )
        end)
    after
        persistent_term:erase(FailureKey)
    end.

policy_exception_sets_terminal_error_test() ->
    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{respond => fun(_State) -> #{} end},
        decision_policy => fun(_Context) ->
            erlang:error(policy_failed)
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        ?assertMatch(
            {error, {policy_exception, error, policy_failed, _Stacktrace}},
            hayata_agent:run(Agent, hello)
        ),

        Info = hayata_agent:get_info(Agent),
        ?assertMatch(
            {error, {policy_exception, error, policy_failed, _}},
            maps:get(status, Info)
        )
    end).

execution_timeout_cancels_node_test() ->
    Parent = self(),

    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{
            blocking_work => fun(_State) ->
                Parent ! {node_execution_started, self()},
                receive
                    continue ->
                        #{result => completed}
                end
            end
        },
        decision_policy => fun(_Context) ->
            {next, blocking_work, undefined}
        end,
        max_steps => 3,
        execution_timeout => 500
    },

    with_agent(Config, fun(Agent) ->
        {ok, _InvocationId} = hayata_agent:run(Agent, start),

        NodeExecutionPid = receive
            {node_execution_started, Pid} ->
                Pid
        after 2000 ->
            error(node_execution_start_timeout)
        end,

        try
            await_terminal_status(Agent, 300),

            ?assertEqual(
                {error, timeout},
                hayata_agent:get_result(Agent)
            ),

            Info = hayata_agent:get_info(Agent),

            ?assertEqual(
                {error, timeout},
                maps:get(status, Info)
            ),

            ?assertEqual(
                undefined,
                maps:get(active_execution, Info)
            ),

            ?assertNot(is_process_alive(NodeExecutionPid))
        after
            NodeExecutionPid ! continue
        end
    end).

recovers_after_execution_timeout_test() ->
    Parent = self(),
    NodeKey = {?MODULE, make_ref()},
    persistent_term:put(NodeKey, 0),

    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{
            work => fun(_State) ->
                Attempt = persistent_term:get(NodeKey),
                persistent_term:put(NodeKey, Attempt + 1),
                case Attempt of
                    0 ->
                        Parent ! {first_execution_started, self()},
                        receive
                            continue ->
                                #{result => stale}
                        end;
                    1 ->
                        #{result => fresh}
                end
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, work, undefined};
                1 -> {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3,
        execution_timeout => 500
    },

    try
        with_agent(Config, fun(Agent) ->
            {ok, _FirstInvocation} =
                hayata_agent:run(Agent, first_attempt),

            FirstExecutionPid = receive
                {first_execution_started, Pid} ->
                    Pid
            after 2000 ->
                error(first_execution_start_timeout)
            end,

            await_terminal_status(Agent, 300),

            ?assertEqual(
                {error, timeout},
                hayata_agent:get_result(Agent)
            ),

            {ok, _SecondInvocation} =
                hayata_agent:run(Agent, second_attempt),

            await_status(Agent, completed, 300),

            ?assertEqual(
                {ok, #{result => fresh}},
                hayata_agent:get_result(Agent)
            ),

            ?assertEqual(
                #{result => fresh},
                hayata_agent:get_state(Agent)
            ),

            FirstExecutionPid ! continue,
            timer:sleep(50),

            ?assertEqual(
                completed,
                maps:get(status, hayata_agent:get_info(Agent))
            ),

            ?assertEqual(
                {ok, #{result => fresh}},
                hayata_agent:get_result(Agent)
            )
        end)
    after
        persistent_term:erase(NodeKey)
    end.

completion_before_timeout_test() ->
    Config = #{
        id => make_ref(),
        state => #{answer => 42},
        nodes => #{respond => fun(_State) -> #{} end},
        decision_policy => fun(Context) ->
            {finish, maps:get(state, Context)}
        end,
        max_steps => 3,
        execution_timeout => 100
    },

    with_agent(Config, fun(Agent) ->
        {ok, _InvocationId} = hayata_agent:run(Agent, hello),

        ?assertEqual(
            completed,
            maps:get(status, hayata_agent:get_info(Agent))
        ),

        ?assertEqual(
            {ok, #{answer => 42}},
            hayata_agent:get_result(Agent)
        ),

        timer:sleep(200),

        Info = hayata_agent:get_info(Agent),

        ?assertEqual(completed, maps:get(status, Info)),
        ?assertEqual(
            {ok, #{answer => 42}},
            hayata_agent:get_result(Agent)
        ),
        ?assertEqual(undefined, maps:get(active_execution, Info))
    end).

ignores_stale_execution_notification_test() ->
    Parent = self(),
    NodeKey = {?MODULE, make_ref()},
    persistent_term:put(NodeKey, 0),

    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{
            work => fun(_State) ->
                Attempt = persistent_term:get(NodeKey),
                persistent_term:put(NodeKey, Attempt + 1),
                case Attempt of
                    0 ->
                        Parent ! {first_execution_started, self()},
                        receive
                            continue_first ->
                                #{result => stale}
                        end;
                    1 ->
                        Parent ! {second_execution_started, self()},
                        receive
                            continue_second ->
                                #{result => fresh}
                        end
                end
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, work, undefined};
                1 -> {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3,
        execution_timeout => 500
    },

    try
        with_agent(Config, fun(Agent) ->
            {ok, _FirstInvocation} =
                hayata_agent:run(Agent, first_attempt),

            _FirstExecutionPid = receive
                {first_execution_started, Pid1} ->
                    Pid1
            after 2000 ->
                error(first_execution_start_timeout)
            end,

            FirstInfo = hayata_agent:get_info(Agent),
            FirstExecution = maps:get(active_execution, FirstInfo),
            OldExecutionId = maps:get(execution_id, FirstExecution),

            await_terminal_status(Agent, 300),

            ?assertEqual(
                {error, timeout},
                hayata_agent:get_result(Agent)
            ),

            {ok, _SecondInvocation} =
                hayata_agent:run(Agent, second_attempt),

            SecondExecutionPid = receive
                {second_execution_started, Pid2} ->
                    Pid2
            after 2000 ->
                error(second_execution_start_timeout)
            end,

            SecondInfo = hayata_agent:get_info(Agent),
            SecondExecution = maps:get(active_execution, SecondInfo),

            ?assertNotEqual(
                OldExecutionId,
                maps:get(execution_id, SecondExecution)
            ),

            StaleResult = #{
                status => completed,
                errors => #{},
                results => #{
                    node_result => {ok, #{result => stale}}
                }
            },

            Agent ! {
                hayata_node_execution,
                work,
                OldExecutionId,
                StaleResult
            },

            timer:sleep(50),

            CurrentInfo = hayata_agent:get_info(Agent),

            ?assertEqual(running, maps:get(status, CurrentInfo)),
            ?assertEqual(
                SecondExecution,
                maps:get(active_execution, CurrentInfo)
            ),

            SecondExecutionPid ! continue_second,

            await_status(Agent, completed, 300),

            ?assertEqual(
                {ok, #{result => fresh}},
                hayata_agent:get_result(Agent)
            )
        end)
    after
        persistent_term:erase(NodeKey)
    end.

ignores_stale_invocation_timeout_test() ->
    Parent = self(),

    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{
            work => fun(_State) ->
                Parent ! {execution_started, self()},
                receive
                    continue ->
                        #{result => fresh}
                end
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, work, undefined};
                1 -> {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3,
        execution_timeout => 5000
    },

    with_agent(Config, fun(Agent) ->
        {ok, FirstInvocationId} =
            hayata_agent:run(Agent, first_attempt),

        ?assertEqual(
            {error, already_running},
            hayata_agent:run(Agent, overlapping_attempt)
        ),

        %% Let the first invocation finish before starting another.
        ExecutionPid = receive
            {execution_started, Pid} ->
                Pid
        after 2000 ->
            error(execution_start_timeout)
        end,

        ExecutionPid ! continue,
        await_status(Agent, completed, 300),

        {ok, SecondInvocationId} =
            hayata_agent:run(Agent, second_attempt),

        ?assertNotEqual(FirstInvocationId, SecondInvocationId),

        SecondExecutionPid = receive
            {execution_started, Pid2} ->
                Pid2
        after 2000 ->
            error(second_execution_start_timeout)
        end,

        Agent ! {invocation_timeout, FirstInvocationId},
        timer:sleep(50),

        Info = hayata_agent:get_info(Agent),

        ?assertEqual(running, maps:get(status, Info)),
        ?assertEqual(SecondInvocationId, maps:get(invocation_id, Info)),

        SecondExecutionPid ! continue,
        await_status(Agent, completed, 300),

        ?assertEqual(
            {ok, #{result => fresh}},
            hayata_agent:get_result(Agent)
        )
    end).

restarts_node_after_completed_invocation_test() ->
    AgentId = make_ref(),
    NodeKey = {?MODULE, AgentId},
    persistent_term:put(NodeKey, 0),

    Config = #{
        id => AgentId,
        state => #{},
        nodes => #{
            work => fun(_State) ->
                Attempt = persistent_term:get(NodeKey),
                persistent_term:put(NodeKey, Attempt + 1),
                #{attempt => Attempt + 1}
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, work, undefined};
                1 -> {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3
    },

    try
        with_agent(Config, fun(Agent) ->
            FirstNodePid = hayata_node:whereis(AgentId, work),
            ?assert(is_pid(FirstNodePid)),

            {ok, _FirstInvocation} =
                hayata_agent:run(Agent, first_attempt),

            await_status(Agent, completed, 300),

            {ok, _SecondInvocation} =
                hayata_agent:run(Agent, second_attempt),

            SecondNodePid = hayata_node:whereis(AgentId, work),

            await_status(Agent, completed, 300),

            ?assert(is_pid(SecondNodePid)),
            ?assertNotEqual(FirstNodePid, SecondNodePid),
            ?assertNot(is_process_alive(FirstNodePid)),

            ?assertEqual(
                {ok, #{attempt => 2}},
                hayata_agent:get_result(Agent)
            )
        end)
    after
        persistent_term:erase(NodeKey)
    end.

restarts_node_after_failed_invocation_test() ->
    AgentId = make_ref(),
    FailureKey = {?MODULE, AgentId},
    persistent_term:put(FailureKey, true),

    Config = #{
        id => AgentId,
        state => #{},
        nodes => #{
            work => fun(_State) ->
                case persistent_term:get(FailureKey) of
                    true ->
                        persistent_term:put(FailureKey, false),
                        erlang:error(first_attempt_failed);
                    false ->
                        #{result => recovered}
                end
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, work, undefined};
                1 -> {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3
    },

    try
        with_agent(Config, fun(Agent) ->
            FirstNodePid = hayata_node:whereis(AgentId, work),
            ?assert(is_pid(FirstNodePid)),

            {ok, _FirstInvocation} =
                hayata_agent:run(Agent, first_attempt),

            await_terminal_status(Agent, 300),

            ?assertMatch(
                {error, _Reason},
                hayata_agent:get_result(Agent)
            ),

            {ok, _SecondInvocation} =
                hayata_agent:run(Agent, second_attempt),

            SecondNodePid = hayata_node:whereis(AgentId, work),

            ?assert(is_pid(SecondNodePid)),
            ?assertNotEqual(FirstNodePid, SecondNodePid),
            ?assertNot(is_process_alive(FirstNodePid)),

            await_status(Agent, completed, 300),

            ?assertEqual(
                {ok, #{result => recovered}},
                hayata_agent:get_result(Agent)
            )
        end)
    after
        persistent_term:erase(FailureKey)
    end.

recovers_after_policy_failure_test() ->
    AgentId = make_ref(),
    FailureKey = {?MODULE, AgentId},
    persistent_term:put(FailureKey, true),

    Config = #{
        id => AgentId,
        state => #{},
        nodes => #{
            work => fun(_State) ->
                #{result => recovered}
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 ->
                    {next, work, undefined};
                1 ->
                    case persistent_term:get(FailureKey) of
                        true ->
                            persistent_term:put(FailureKey, false),
                            erlang:error(policy_failed);
                        false ->
                            {finish, maps:get(state, Context)}
                    end
            end
        end,
        max_steps => 3
    },

    try
        with_agent(Config, fun(Agent) ->
            {ok, _FirstInvocation} =
                hayata_agent:run(Agent, first_attempt),

            await_terminal_status(Agent, 300),

            ?assertMatch(
                {error, {policy_exception, error, policy_failed, _}},
                hayata_agent:get_result(Agent)
            ),

            {ok, _SecondInvocation} =
                hayata_agent:run(Agent, second_attempt),

            await_status(Agent, completed, 300),

            ?assertEqual(
                {ok, #{result => recovered}},
                hayata_agent:get_result(Agent)
            )
        end)
    after
        persistent_term:erase(FailureKey)
    end.

supervisor_restarts_killed_node_test() ->
    AgentId = make_ref(),

    Config = #{
        id => AgentId,
        state => #{},
        nodes => #{
            work => fun(_State) ->
                #{result => ok}
            end
        },
        decision_policy => fun(_Context) ->
            {finish, ok}
        end,
        max_steps => 3
    },

    with_agent(Config, fun(_Agent) ->
        FirstNodePid = hayata_node:whereis(AgentId, work),
        ?assert(is_pid(FirstNodePid)),

        exit(FirstNodePid, kill),

        SecondNodePid = await_new_node(AgentId, work, FirstNodePid, 100),

        ?assert(is_pid(SecondNodePid)),
        ?assertNotEqual(FirstNodePid, SecondNodePid),
        ?assertNot(is_process_alive(FirstNodePid))
    end).

fails_active_invocation_after_node_crash_test() ->
    Parent = self(),
    AgentId = make_ref(),
    NodeKey = {?MODULE, AgentId},
    persistent_term:put(NodeKey, 0),

    Config = #{
        id => AgentId,
        state => #{},
        nodes => #{
            work => fun(_State) ->
                Attempt = persistent_term:get(NodeKey),
                persistent_term:put(NodeKey, Attempt + 1),
                case Attempt of
                    0 ->
                        Parent ! {node_execution_started, self()},
                        receive
                            continue ->
                                #{result => stale}
                        end;
                    1 ->
                        #{result => recovered}
                end
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, work, undefined};
                1 -> {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3,
        execution_timeout => 500
    },

    try
        with_agent(Config, fun(Agent) ->
            NodePid = hayata_node:whereis(AgentId, work),
            ?assert(is_pid(NodePid)),

            {ok, _FirstInvocation} =
                hayata_agent:run(Agent, first_attempt),

            _ExecutionPid = receive
                {node_execution_started, Pid} ->
                    Pid
            after 2000 ->
                error(node_execution_start_timeout)
            end,

            exit(NodePid, kill),

            NewNodePid = await_new_node(
                AgentId,
                work,
                NodePid,
                100
            ),

            ?assert(is_pid(NewNodePid)),
            ?assertNot(is_process_alive(NodePid)),

            await_terminal_status(Agent, 300),

            ?assertEqual(
                {error, timeout},
                hayata_agent:get_result(Agent)
            ),

            {ok, _SecondInvocation} =
                hayata_agent:run(Agent, second_attempt),

            await_status(Agent, completed, 300),

            ?assertEqual(
                {ok, #{result => recovered}},
                hayata_agent:get_result(Agent)
            )
        end)
    after
        persistent_term:erase(NodeKey)
    end.

ignores_stale_notification_after_node_crash_test() ->
    Parent = self(),
    AgentId = make_ref(),
    NodeKey = {?MODULE, AgentId},
    persistent_term:put(NodeKey, 0),

    Config = #{
        id => AgentId,
        state => #{},
        nodes => #{
            work => fun(_State) ->
                Attempt = persistent_term:get(NodeKey),
                persistent_term:put(NodeKey, Attempt + 1),
                case Attempt of
                    0 ->
                        Parent ! {first_execution_started, self()},
                        receive
                            continue_first ->
                                #{result => stale}
                        end;
                    1 ->
                        Parent ! {second_execution_started, self()},
                        receive
                            continue_second ->
                                #{result => fresh}
                        end
                end
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, work, undefined};
                1 -> {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3,
        execution_timeout => 500
    },

    try
        with_agent(Config, fun(Agent) ->
            NodePid = hayata_node:whereis(AgentId, work),
            ?assert(is_pid(NodePid)),

            {ok, _FirstInvocation} =
                hayata_agent:run(Agent, first_attempt),

            FirstExecutionPid = receive
                {first_execution_started, Pid1} ->
                    Pid1
            after 2000 ->
                error(first_execution_start_timeout)
            end,

            FirstInfo = hayata_agent:get_info(Agent),
            FirstExecution = maps:get(active_execution, FirstInfo),
            OldExecutionId = maps:get(execution_id, FirstExecution),

            exit(NodePid, kill),

            _NewNodePid = await_new_node(
                AgentId,
                work,
                NodePid,
                100
            ),

            await_terminal_status(Agent, 300),

            ?assertEqual(
                {error, timeout},
                hayata_agent:get_result(Agent)
            ),

            {ok, _SecondInvocation} =
                hayata_agent:run(Agent, second_attempt),

            SecondExecutionPid = receive
                {second_execution_started, Pid2} ->
                    Pid2
            after 2000 ->
                error(second_execution_start_timeout)
            end,

            SecondInfo = hayata_agent:get_info(Agent),
            SecondExecution = maps:get(active_execution, SecondInfo),
            SecondExecutionId = maps:get(
                execution_id,
                SecondExecution
            ),

            ?assertNotEqual(OldExecutionId, SecondExecutionId),

            StaleResult = #{
                status => completed,
                errors => #{},
                results => #{
                    node_result => {ok, #{result => stale}}
                }
            },

            Agent ! {
                hayata_node_execution,
                work,
                OldExecutionId,
                StaleResult
            },

            timer:sleep(50),

            CurrentInfo = hayata_agent:get_info(Agent),

            ?assertEqual(running, maps:get(status, CurrentInfo)),
            ?assertEqual(
                SecondExecution,
                maps:get(active_execution, CurrentInfo)
            ),

            FirstExecutionPid ! continue_first,
            SecondExecutionPid ! continue_second,

            await_status(Agent, completed, 300),

            ?assertEqual(
                {ok, #{result => fresh}},
                hayata_agent:get_result(Agent)
            )
        end)
    after
        persistent_term:erase(NodeKey)
    end.

policy_exception_recovers_on_next_invocation_test() ->
    AgentId = make_ref(),
    PolicyKey = {?MODULE, AgentId},
    persistent_term:put(PolicyKey, true),

    Config = #{
        id => AgentId,
        state => #{answer => 42},
        nodes => #{respond => fun(_State) -> #{} end},
        decision_policy => fun(Context) ->
            case persistent_term:get(PolicyKey) of
                true ->
                    persistent_term:put(PolicyKey, false),
                    erlang:error(policy_failed);
                false ->
                    {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3
    },

    try
        with_agent(Config, fun(Agent) ->
            ?assertMatch(
                {error, {policy_exception, error, policy_failed, _}},
                hayata_agent:run(Agent, first_attempt)
            ),

            Info = hayata_agent:get_info(Agent),

            ?assertMatch(
                {error, {policy_exception, error, policy_failed, _}},
                maps:get(status, Info)
            ),

            {ok, _SecondInvocation} =
                hayata_agent:run(Agent, second_attempt),

            ?assertEqual(
                completed,
                maps:get(status, hayata_agent:get_info(Agent))
            ),

            ?assertEqual(
                {ok, #{answer => 42}},
                hayata_agent:get_result(Agent)
            )
        end)
    after
        persistent_term:erase(PolicyKey)
    end.

run_with_subscription_notifies_success_test() ->
    Config = #{
        id => make_ref(),
        state => #{answer => 42},
        nodes => #{respond => fun(_State) -> #{} end},
        decision_policy => fun(Context) ->
            {finish, maps:get(state, Context)}
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        {ok, InvocationId} =
            hayata_agent:run(Agent, hello, #{subscriber => self()}),

        receive
            {hayata_agent_result, InvocationId, {ok, Result}} ->
                ?assertEqual(#{answer => 42}, Result)
        after 1000 ->
            error(success_notification_timeout)
        end
    end).

run_with_subscription_notifies_timeout_test() ->
    Parent = self(),

    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{
            blocking_work => fun(_State) ->
                Parent ! {node_execution_started, self()},
                receive
                    continue -> #{result => completed}
                end
            end
        },
        decision_policy => fun(_Context) ->
            {next, blocking_work, undefined}
        end,
        max_steps => 3,
        execution_timeout => 200
    },

    with_agent(Config, fun(Agent) ->
        {ok, InvocationId} =
            hayata_agent:run(Agent, hello, #{subscriber => self()}),

        receive
            {node_execution_started, ExecutionPid} ->
                try
                    receive
                        {hayata_agent_result, InvocationId, {error, timeout}} ->
                            ?assertEqual(
                                {error, timeout},
                                hayata_agent:get_result(Agent)
                            )
                    after 2000 ->
                        error(timeout_notification_timeout)
                    end
                after
                    ExecutionPid ! continue
                end
        after 1000 ->
            error(node_execution_start_timeout)
        end
    end).


run_with_subscription_notifies_initial_policy_exception_test() ->
    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{respond => fun(_State) -> #{} end},
        decision_policy => fun(_Context) ->
            erlang:error(policy_failed)
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        Result = hayata_agent:run(Agent, hello, #{subscriber => self()}),

        ?assertMatch(
            {error, {policy_exception, error, policy_failed, _}},
            Result
        ),

        receive
            {hayata_agent_result, _InvocationId,
             {error, {policy_exception, error, policy_failed, _}}} ->
                ok
        after 1000 ->
            error(initial_policy_exception_notification_timeout)
        end,

        ?assertMatch(
            {error, {policy_exception, error, policy_failed, _}},
            hayata_agent:get_result(Agent)
        )
    end).

run_with_invalid_subscription_test() ->
    ?assertEqual(
        {error, invalid_subscriber},
        hayata_agent:run(self(), hello, #{subscriber => not_a_pid})
    ).

run_with_subscription_reuses_subscriber_test() ->
    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{respond => fun(_State) -> #{} end},
        decision_policy => fun(Context) ->
            {finish, maps:get(input, Context)}
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        {ok, FirstInvocation} =
            hayata_agent:run(Agent, first, #{subscriber => self()}),

        receive
            {hayata_agent_result, FirstInvocation, {ok, first}} ->
                ok
        after 1000 ->
            error(first_invocation_notification_timeout)
        end,

        {ok, SecondInvocation} =
            hayata_agent:run(Agent, second, #{subscriber => self()}),

        ?assertNotEqual(FirstInvocation, SecondInvocation),

        receive
            {hayata_agent_result, SecondInvocation, {ok, second}} ->
                ok
        after 1000 ->
            error(second_invocation_notification_timeout)
        end,

        ?assertEqual(
            {ok, second},
            hayata_agent:get_result(Agent)
        )
    end).

recovers_after_node_supervisor_restart_test() ->
    AgentId = make_ref(),

    Config = #{
        id => AgentId,
        state => #{},
        nodes => #{
            work => fun(_State) ->
                #{result => recovered}
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, work, undefined};
                1 -> {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3
    },

    {ok, SupPid} = hayata_agent_sup:start_link(Config),
    unlink(SupPid),

    try
        {ok, AgentPid} = hayata_agent_sup:agent(SupPid),
        {ok, OldNodeSupPid} =
            hayata_agent_sup:node_supervisor(SupPid),

        {ok, _FirstInvocation} =
            hayata_agent:run(AgentPid, first_attempt),

        await_status(AgentPid, completed, 300),

        ok = supervisor:terminate_child(
            SupPid,
            hayata_node_sup
        ),

        {ok, NewNodeSupPid} =
            supervisor:restart_child(SupPid, hayata_node_sup),

        ?assertNotEqual(OldNodeSupPid, NewNodeSupPid),

        {ok, _SecondInvocation} =
            hayata_agent:run(AgentPid, second_attempt),

        await_status(AgentPid, completed, 300),

        ?assertEqual(
            {ok, #{result => recovered}},
            hayata_agent:get_result(AgentPid)
        )
    after
        exit(SupPid, shutdown)
    end.

execution_timeout_cannot_interrupt_blocked_policy_test() ->
    Parent = self(),

    Config = #{
        id => make_ref(),
        state => #{answer => 42},
        nodes => #{respond => fun(_State) -> #{} end},
        decision_policy => fun(_Context) ->
            Parent ! policy_started,
            receive
                continue_policy ->
                    {finish, #{answer => 42}}
            end
        end,
        max_steps => 3,
        execution_timeout => 100
    },

    with_agent(Config, fun(Agent) ->
        _Caller = spawn(fun() ->
            Result = hayata_agent:run(Agent, hello),
            Parent ! {run_result, Result}
        end),

        receive
            policy_started ->
                ok
        after 1000 ->
            error(policy_start_timeout)
        end,

        receive
            {run_result, _UnexpectedResult} ->
                error(run_returned_before_policy_finished)
        after 250 ->
            ok
        end,

        Agent ! continue_policy,

        receive
            {run_result, {ok, _InvocationId}} ->
                ok;
            {run_result, OtherResult} ->
                error({unexpected_run_result, OtherResult})
        after 1000 ->
            error(run_response_timeout)
        end,

        await_terminal_status(Agent, 100),

        ?assertEqual(
            completed,
            maps:get(status, hayata_agent:get_info(Agent))
        )
    end).

telemetry_emits_start_and_stop_for_successful_invocation_test() ->
    Config = #{
        id => make_ref(),
        state => #{answer => 42},
        nodes => #{respond => fun(_State) -> #{} end},
        decision_policy => fun(Context) ->
            {finish, maps:get(state, Context)}
        end,
        max_steps => 3
    },

    ok = hayata_test_telemetry:ensure_telemetry_started(),
    {ok, HandlerId} = hayata_test_telemetry:attach(),

    try
        with_agent(Config, fun(Agent) ->
            {ok, InvocationId} = hayata_agent:run(Agent, hello),

            Events = hayata_test_telemetry:events(),
            AgentId = maps:get(id, Config),

            ?debugFmt("Telemetry events:~n~p~n", [Events]),

            ?assertMatch(
                [
                    {hayata_telemetry_event,
                     [hayata, agent, invocation, start],
                     _StartMeasurements,
                     #{agent_id := AgentId, invocation_id := InvocationId}},
                    {hayata_telemetry_event,
                     [hayata, agent, invocation, stop],
                     #{duration := Duration},
                     #{agent_id := AgentId,
                       invocation_id := InvocationId,
                       status := completed}}
                ] when is_integer(Duration),
                Events
            )
        end)
    after
        ok = hayata_test_telemetry:detach(HandlerId)
    end.

telemetry_emits_exception_for_failed_invocation_test() ->
    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{respond => fun(_State) -> #{} end},
        decision_policy => fun(_Context) ->
            {error, test_failure}
        end,
        max_steps => 3
    },

    ok = hayata_test_telemetry:ensure_telemetry_started(),
    {ok, HandlerId} = hayata_test_telemetry:attach(),

    try
        with_agent(Config, fun(Agent) ->
            ?assertEqual(
                {error, test_failure},
                hayata_agent:run(Agent, hello)
            ),

            Events = hayata_test_telemetry:events(),
            AgentId = maps:get(id, Config),

            ?assertMatch(
                [
                    {hayata_telemetry_event,
                     [hayata, agent, invocation, start],
                     _StartMeasurements,
                     #{agent_id := AgentId, invocation_id := _InvocationId1}},
                    {hayata_telemetry_event,
                     [hayata, agent, invocation, stop],
                     #{duration := Duration},
                     #{agent_id := AgentId, invocation_id := _InvocationId2, status := failed}} 
               ] when is_integer(Duration),
                Events
            )
        end)
    after
        ok = hayata_test_telemetry:detach(HandlerId)
    end.

telemetry_emits_exception_for_policy_exception_test() ->
    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{respond => fun(_State) -> #{} end},
        decision_policy => fun(_Context) ->
            erlang:error(policy_crashed)
        end,
        max_steps => 3
    },

    ok = hayata_test_telemetry:ensure_telemetry_started(),
    {ok, HandlerId} = hayata_test_telemetry:attach(),

    try
        with_agent(Config, fun(Agent) ->
            ?assertMatch(
                {error, {policy_exception, error, policy_crashed, _}},
                hayata_agent:run(Agent, hello)
            ),

            Events = hayata_test_telemetry:events(),
            AgentId = maps:get(id, Config),

            ?assertMatch(
                [
                    {
                        hayata_telemetry_event,
                        [hayata, agent, invocation, start],
                        _StartMeasurements,
                        #{
                            agent_id := AgentId,
                            invocation_id := InvocationId
                        }
                    },
                    {
                        hayata_telemetry_event,
                        [hayata, agent, invocation, exception],
                        #{duration := Duration},
                        #{
                            agent_id := AgentId,
                            invocation_id := InvocationId,
                            class := error
                        }
                    }
                ]
                when is_integer(Duration),
                Events
            )
        end)
    after
        ok = hayata_test_telemetry:detach(HandlerId)
    end.

parallel_results_preserve_order_and_isolate_state_test() ->
    Parent = self(),

    Config = #{
        id => make_ref(),
        state => #{original => true},
        nodes => #{
            first => fun(_State) ->
                Parent ! {parallel_started, first, self()},
                receive
                    continue_first -> #{first_result => 1}
                end
            end,
            second => fun(_State) ->
                Parent ! {parallel_started, second, self()},
                #{second_result => 2}
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 ->
                    {next, [first, second], undefined};
                2 ->
                    {finish, #{
                        state => maps:get(state, Context),
                        results => maps:get(parallel_results, Context)
                    }}
            end
        end,
        max_steps => 3,
        execution_timeout => 2000
    },

    with_agent(Config, fun(Agent) ->
        {ok, _InvocationId} = hayata_agent:run(Agent, start),

        FirstPid = receive
            {parallel_started, first, Pid1} -> Pid1
        after 2000 ->
            error(first_parallel_node_not_started)
        end,

        receive
            {parallel_started, second, _Pid2} -> ok
        after 2000 ->
            error(second_parallel_node_not_started)
        end,

        %% Let the first branch finish only after the second has completed.
        timer:sleep(50),
        FirstPid ! continue_first,

        await_status(Agent, completed, 300),

        ?assertEqual(
            {ok, #{
                state => #{original => true},
                results => [
                    #{first_result => 1},
                    #{second_result => 2}
                ]
            }},
            hayata_agent:get_result(Agent)
        ),

        ?assertEqual(
            #{original => true},
            hayata_agent:get_state(Agent)
        )
    end).

parallel_branch_failure_cancels_pending_branches_test() ->
    Parent = self(),

    Config = #{
        id => make_ref(),
        state => #{original => true},
        nodes => #{
            failing => fun(_State) ->
                erlang:error(parallel_branch_failed)
            end,
            blocking => fun(_State) ->
                Parent ! {blocking_branch_started, self()},
                receive
                    continue -> #{partial => true}
                end
            end
        },
        decision_policy => fun(_Context) ->
            {next, [failing, blocking], undefined}
        end,
        max_steps => 3,
        execution_timeout => 2000
    },

    with_agent(Config, fun(Agent) ->
        {ok, _InvocationId} = hayata_agent:run(Agent, start),

        BlockingPid = receive
            {blocking_branch_started, Pid} -> Pid
        after 2000 ->
            error(blocking_branch_not_started)
        end,

        await_terminal_status(Agent, 300),

        ?assertMatch(
            {error, _Reason},
            hayata_agent:get_result(Agent)
        ),

        ?assertEqual(
            #{original => true},
            hayata_agent:get_state(Agent)
        ),

        ?assertNot(is_process_alive(BlockingPid))
    end).

parallel_execution_timeout_cancels_all_branches_test() ->
    Parent = self(),

    Config = #{
        id => make_ref(),
        state => #{original => true},
        nodes => #{
            first => fun(_State) ->
                Parent ! {timeout_branch_started, first, self()},
                receive
                    continue -> #{first => done}
                end
            end,
            second => fun(_State) ->
                Parent ! {timeout_branch_started, second, self()},
                receive
                    continue -> #{second => done}
                end
            end
        },
        decision_policy => fun(_Context) ->
            {next, [first, second], undefined}
        end,
        max_steps => 3,
        execution_timeout => 300
    },

    with_agent(Config, fun(Agent) ->
        {ok, _InvocationId} = hayata_agent:run(Agent, start),

        FirstPid = receive
            {timeout_branch_started, first, Pid1} -> Pid1
        after 2000 ->
            error(first_timeout_branch_not_started)
        end,

        SecondPid = receive
            {timeout_branch_started, second, Pid2} -> Pid2
        after 2000 ->
            error(second_timeout_branch_not_started)
        end,

        await_terminal_status(Agent, 300),

        ?assertEqual(
            {error, timeout},
            hayata_agent:get_result(Agent)
        ),

        ?assertNot(is_process_alive(FirstPid)),
        ?assertNot(is_process_alive(SecondPid)),

        ?assertEqual(
            #{original => true},
            hayata_agent:get_state(Agent)
        )
    end).

parallel_unknown_node_is_rejected_before_execution_test() ->
    Parent = self(),

    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{
            first => fun(_State) ->
                Parent ! parallel_node_should_not_run,
                #{result => unexpected}
            end
        },
        decision_policy => fun(_Context) ->
            {next, [first, missing], undefined}
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        ?assertEqual(
            {error, {unknown_node, missing}},
            hayata_agent:run(Agent, start)
        ),

        receive
            parallel_node_should_not_run ->
                error(node_started_before_validation)
        after 100 ->
            ok
        end
    end).

parallel_duplicate_node_ids_are_rejected_test() ->
    Parent = self(),

    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{
            work => fun(_State) ->
                Parent ! parallel_duplicate_node_should_not_run,
                #{result => unexpected}
            end
        },
        decision_policy => fun(_Context) ->
            {next, [work, work], undefined}
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        ?assertEqual(
            {error, {invalid_parallel_nodes, duplicate_node_ids}},
            hayata_agent:run(Agent, start)
        ),

        receive
            parallel_duplicate_node_should_not_run ->
                error(duplicate_node_started_before_validation)
        after 100 ->
            ok
        end
    end).

parallel_results_are_cleared_after_next_transition_test() ->
    Config = #{
        id => make_ref(),
        state => #{original => true},
        nodes => #{
            first => fun(_State) ->
                #{first_result => 1}
            end,
            second => fun(_State) ->
                #{second_result => 2}
            end,
            aggregate => fun(_State) ->
                #{aggregated => true}
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 ->
                    ?assertEqual(
                        undefined,
                        maps:get(parallel_results, Context)
                    ),
                    {next, [first, second], undefined};

                2 ->
                    ?assertEqual(
                        [
                            #{first_result => 1},
                            #{second_result => 2}
                        ],
                        maps:get(parallel_results, Context)
                    ),
                    {next, aggregate, undefined};

                3 ->
                    ?assertEqual(
                        undefined,
                        maps:get(parallel_results, Context)
                    ),
                    {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 4
    },

    with_agent(Config, fun(Agent) ->
        {ok, _InvocationId} = hayata_agent:run(Agent, start),

        await_status(Agent, completed, 300),

        ?assertEqual(
            {ok, #{
                original => true,
                aggregated => true
            }},
            hayata_agent:get_result(Agent)
        )
    end).

parallel_start_failure_cancels_started_branches_test() ->
    Parent = self(),
    Counter = counters:new(1, []),

    StartExecution = fun(
        NodePid,
        ExecutionId,
        EdgeTasks,
        TimeoutMs,
        Type,
        RecipientPid
    ) ->
        ok = counters:add(Counter, 1, 1),
        Count = counters:get(Counter, 1),
        case Count of
            1 ->
                Result = hayata_node:start_execution(
                    NodePid,
                    ExecutionId,
                    EdgeTasks,
                    TimeoutMs,
                    Type,
                    RecipientPid
                ),
                case Result of
                    {ok, ExecutionId} ->
                        Info = hayata_node:get_info(NodePid),
                        ActiveEdges = maps:values(
                            maps:get(active_edges, Info)
                        ),
                        case [
                            Pid
                            || #{
                                execution_id := ActiveExecutionId,
                                pid := Pid
                            } <- ActiveEdges,
                            ActiveExecutionId =:= ExecutionId
                        ] of
                            [BranchPid | _] ->
                                Parent ! {branch_started, BranchPid};
                            [] ->
                                ok
                        end,
                        Result;
                    _ ->
                        Result
                end;
            2 ->
                {error, injected_start_failure}
        end
    end,

    Config = #{
        id => make_ref(),
        state => #{original => true},
        nodes => #{
            first => fun(_State) ->
                receive
                    continue -> #{partial => true}
                end
            end,
            second => fun(_State) ->
                #{unexpected => true}
            end
        },
        decision_policy => fun(_Context) ->
            {next, [first, second], undefined}
        end,
        max_steps => 3,
        execution_timeout => 2000,
        execution_starter => StartExecution
    },

    with_agent(Config, fun(Agent) ->
        {error, {node_execution_start_failed, second, injected_start_failure}} =
            hayata_agent:run(Agent, start),

        BranchPid = receive
            {branch_started, Pid} -> Pid
        after 2000 ->
            error(first_branch_not_started)
        end,

        await_terminal_status(Agent, 300),

        ?assertMatch(
            {error, _Reason},
            hayata_agent:get_result(Agent)
        ),

        ?assertEqual(
            #{original => true},
            hayata_agent:get_state(Agent)
        ),

        ?assertNot(is_process_alive(BranchPid))
    end).

telemetry_emits_stop_for_failed_invocation_test() ->
    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{respond => fun(_State) -> #{} end},
        decision_policy => fun(_Context) ->
            {error, test_failure}
        end,
        max_steps => 3
    },

    ok = hayata_test_telemetry:ensure_telemetry_started(),
    {ok, HandlerId} = hayata_test_telemetry:attach(),

    try
        with_agent(Config, fun(Agent) ->
            ?assertEqual(
                {error, test_failure},
                hayata_agent:run(Agent, hello)
            ),

            Events = hayata_test_telemetry:events(),
            AgentId = maps:get(id, Config),

            ?assertMatch(
                [
                    {
                        hayata_telemetry_event,
                        [hayata, agent, invocation, start],
                        _StartMeasurements,
                        #{
                            agent_id := AgentId,
                            invocation_id := InvocationId
                        }
                    },
                    {
                        hayata_telemetry_event,
                        [hayata, agent, invocation, stop],
                        #{duration := _},
                        #{
                            agent_id := AgentId,
                            invocation_id := InvocationId,
                            status := failed
                        }
                    }
                ],
                Events
            ),

            [
                {
                    hayata_telemetry_event,
                    [hayata, agent, invocation, stop],
                    #{duration := Duration},
                    _Metadata
                }
            ] = [
                Event
                || Event = {
                    hayata_telemetry_event,
                    [hayata, agent, invocation, stop],
                    _Measurements,
                    _EventMetadata
                } <- Events
            ],

            ?assert(is_integer(Duration)),
            ?assert(Duration >= 0)
        end)
    after
        ok = hayata_test_telemetry:detach(HandlerId)
    end.

telemetry_emits_stop_when_node_execution_start_fails_test() ->
    StartExecution = fun(
        _NodePid,
        _ExecutionId,
        _EdgeTasks,
        _TimeoutMs,
        _Type,
        _RecipientPid
    ) ->
        {error, injected_start_failure}
    end,

    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{
            work => fun(_State) ->
                #{result => unexpected}
            end
        },
        decision_policy => fun(_Context) ->
            {next, [work], undefined}
        end,
        max_steps => 3,
        execution_starter => StartExecution
    },

    ok = hayata_test_telemetry:ensure_telemetry_started(),
    {ok, HandlerId} = hayata_test_telemetry:attach(),

    try
        with_agent(Config, fun(Agent) ->
            ?assertEqual(
                {
                    error,
                    {
                        node_execution_start_failed,
                        work,
                        injected_start_failure
                    }
                },
                hayata_agent:run(Agent, hello)
            ),

            Result = hayata_agent:get_result(Agent),
            Events = hayata_test_telemetry:events(),
            AgentId = maps:get(id, Config),

            ?assertMatch(
                {
                    error,
                    {
                        node_execution_start_failed,
                        work,
                        injected_start_failure
                    }
                },
                Result
            ),

            ?assertMatch(
                [
                    {
                        hayata_telemetry_event,
                        [hayata, agent, invocation, start],
                        _StartMeasurements,
                        #{
                            agent_id := AgentId,
                            invocation_id := InvocationId
                        }
                    },
                    {
                        hayata_telemetry_event,
                        [hayata, agent, invocation, stop],
                        #{duration := _},
                        #{
                            agent_id := AgentId,
                            invocation_id := InvocationId,
                            status := failed
                        }
                    }
                ],
                Events
            ),

            [
                {
                    hayata_telemetry_event,
                    [hayata, agent, invocation, stop],
                    #{duration := Duration},
                    _Metadata
                }
            ] = [
                Event
                || Event = {
                    hayata_telemetry_event,
                    [hayata, agent, invocation, stop],
                    _Measurements,
                    _EventMetadata
                } <- Events
            ],

            ?assert(is_integer(Duration)),
            ?assert(Duration >= 0)
        end)
    after
        ok = hayata_test_telemetry:detach(HandlerId)
    end.

restores_active_invocation_without_reexecuting_test() ->
    AgentId = make_ref(),
    InvocationId = make_ref(),
    ExecutionId = make_ref(),
    ActiveExecution = #{
        node_id => work,
        execution_id => ExecutionId
    },
    Checkpoint = #{
        invocation_id => InvocationId,
        input => original_input,
        state => #{progress => 2},
        current_step => 1,
        active_execution => ActiveExecution,
        parallel_results => undefined,
        result => undefined,
        last_error => undefined,
        status => running
    },

    ok = hayata_task_store:ensure_started(),
    {ok, created} = hayata_task_store:create_invocation(
        AgentId,
        Checkpoint
    ),

    Config = #{
        id => AgentId,
        state => #{progress => 0},
        nodes => #{
            work => fun(_State) ->
                error(node_must_not_execute_during_recovery)
            end
        },
        decision_policy => fun(_Context) ->
            {finish, unexpected}
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        Info = hayata_agent:get_info(Agent),

        ?assertEqual(
            recovery_required,
            maps:get(status, Info)
        ),
        ?assertEqual(
            InvocationId,
            maps:get(invocation_id, Info)
        ),
        ?assertEqual(
            ActiveExecution,
            maps:get(active_execution, Info)
        ),
        ?assertEqual(
            #{progress => 2},
            hayata_agent:get_state(Agent)
        ),
        ?assertEqual(
          #{work => not_started},
          maps:get(recovery_tasks, Info)
        ),
        ?assertEqual(
            {error, recovery_required},
            hayata_agent:run(Agent, new_input)
        ),
        ?assertEqual(
            recovery_required,
            maps:get(status, hayata_agent:get_info(Agent))
        )
    end).

inspects_completed_task_during_recovery_test() ->
    AgentId = make_ref(),
    InvocationId = make_ref(),
    ExecutionId = make_ref(),
    ActiveExecution = #{
        node_id => work,
        execution_id => ExecutionId
    },
    Result = {ok, #{answer => 42}},
    Checkpoint = #{
        invocation_id => InvocationId,
        input => original_input,
        state => #{},
        current_step => 1,
        active_execution => ActiveExecution,
        parallel_results => undefined,
        result => undefined,
        last_error => undefined,
        status => running
    },

    ok = hayata_task_store:ensure_started(),
    {ok, created} = hayata_task_store:create_invocation(
        AgentId,
        Checkpoint
    ),
    ok = hayata_task_store:save_task_result(
        {AgentId, work, ExecutionId, node_result},
        Result
    ),

    Config = #{
        id => AgentId,
        state => #{},
        nodes => #{work => fun(_State) -> error(unexpected_execution) end},
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        Info = hayata_agent:get_info(Agent),

        ?assertEqual(
            #{work => {completed, Result}},
            maps:get(recovery_tasks, Info)
        ),
        ?assertEqual(
            recovery_required,
            maps:get(status, Info)
        )
    end).

inspects_parallel_tasks_during_recovery_test() ->
    AgentId = make_ref(),
    InvocationId = make_ref(),
    FirstExecutionId = make_ref(),
    SecondExecutionId = make_ref(),
    FirstResult = {ok, #{first => done}},
    ActiveExecution = #{
        type => parallel,
        node_ids => [first, second],
        pending => #{
            first => FirstExecutionId,
            second => SecondExecutionId
        },
        results => #{}
    },
    Checkpoint = #{
        invocation_id => InvocationId,
        input => original_input,
        state => #{},
        current_step => 2,
        active_execution => ActiveExecution,
        parallel_results => undefined,
        result => undefined,
        last_error => undefined,
        status => running
    },

    ok = hayata_task_store:ensure_started(),
    {ok, created} = hayata_task_store:create_invocation(
        AgentId,
        Checkpoint
    ),
    ok = hayata_task_store:save_task_result(
        {AgentId, first, FirstExecutionId, node_result},
        FirstResult
    ),
    {ok, execute} = hayata_task_store:claim_task(
        {AgentId, second, SecondExecutionId, node_result},
        #{}
    ),

    Config = #{
        id => AgentId,
        state => #{},
        nodes => #{
            first => fun(_State) -> error(unexpected_execution) end,
            second => fun(_State) -> error(unexpected_execution) end
        },
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        Info = hayata_agent:get_info(Agent),

        ?assertEqual(
            #{
                first => {completed, FirstResult},
                second => task_execution_uncertain
            },
            maps:get(recovery_tasks, Info)
        ),
        ?assertEqual(
            recovery_required,
            maps:get(status, Info)
        )
    end).

recovers_not_started_task_test() ->
    Parent = self(),
    AgentId = make_ref(),
    InvocationId = make_ref(),
    ExecutionId = make_ref(),
    NodeInput = #{
        progress => 1,
        input => selected_input
    },
    ActiveExecution = #{
        node_id => work,
        execution_id => ExecutionId,
        node_input => NodeInput
    },
    Checkpoint = #{
        invocation_id => InvocationId,
        input => original_input,
        state => #{progress => 1},
        current_step => 1,
        active_execution => ActiveExecution,
        parallel_results => undefined,
        result => undefined,
        last_error => undefined,
        status => running
    },
    Config = #{
        id => AgentId,
        state => #{progress => 0},
        nodes => #{
            work => fun(Input) ->
                Parent ! {node_executed, self(), Input},
                #{recovered => true}
            end
        },
        decision_policy => fun(Context) ->
            {finish, maps:get(state, Context)}
        end,
        max_steps => 3
    },

    ok = hayata_task_store:ensure_started(),
    {ok, created} = hayata_task_store:create_invocation(
        AgentId,
        Checkpoint
    ),

    with_agent(Config, fun(Agent) ->
        ?assertEqual(
            {ok, ExecutionId},
            hayata_agent:recover(Agent)
        ),

        receive
            {node_executed, _NodePid, NodeInput} ->
                ok
        after 2000 ->
            error(node_was_not_executed)
        end,

        await_status(Agent, completed, 300),

        ?assertEqual(
            {ok, #{progress => 1, recovered => true}},
            hayata_agent:get_result(Agent)
        )
    end).

recovers_completed_task_without_reexecution_test() ->
    Parent = self(),
    AgentId = make_ref(),
    InvocationId = make_ref(),
    ExecutionId = make_ref(),
    NodeInput = #{
        progress => 1,
        input => selected_input
    },
    ActiveExecution = #{
        node_id => work,
        execution_id => ExecutionId,
        node_input => NodeInput
    },
    StoredResult = {ok, #{recovered => true}},
    Checkpoint = #{
        invocation_id => InvocationId,
        input => original_input,
        state => #{progress => 1},
        current_step => 1,
        active_execution => ActiveExecution,
        parallel_results => undefined,
        result => undefined,
        last_error => undefined,
        status => running
    },
    Config = #{
        id => AgentId,
        state => #{progress => 0},
        nodes => #{
            work => fun(_Input) ->
                Parent ! node_must_not_execute_again,
                error(unexpected_reexecution)
            end
        },
        decision_policy => fun(Context) ->
            {finish, maps:get(state, Context)}
        end,
        max_steps => 3
    },

    ok = hayata_task_store:ensure_started(),
    {ok, created} = hayata_task_store:create_invocation(
        AgentId,
        Checkpoint
    ),
    ok = hayata_task_store:save_task_result(
        {AgentId, work, ExecutionId, node_result},
        StoredResult
    ),

    with_agent(Config, fun(Agent) ->
        ?assertEqual(
            {ok, ExecutionId},
            hayata_agent:recover(Agent)
        ),

        await_status(Agent, completed, 300),

        ?assertEqual(
            {ok, #{progress => 1, recovered => true}},
            hayata_agent:get_result(Agent)
        ),

        receive
            node_must_not_execute_again ->
                error(completed_task_was_reexecuted)
        after 100 ->
            ok
        end
    end).

rejects_uncertain_task_recovery_test() ->
    Parent = self(),
    AgentId = make_ref(),
    InvocationId = make_ref(),
    ExecutionId = make_ref(),
    NodeInput = #{
        progress => 1,
        input => selected_input
    },
    ActiveExecution = #{
        node_id => work,
        execution_id => ExecutionId,
        node_input => NodeInput
    },
    Checkpoint = #{
        invocation_id => InvocationId,
        input => original_input,
        state => #{progress => 1},
        current_step => 1,
        active_execution => ActiveExecution,
        parallel_results => undefined,
        result => undefined,
        last_error => undefined,
        status => running
    },
    Config = #{
        id => AgentId,
        state => #{progress => 0},
        nodes => #{
            work => fun(_Input) ->
                Parent ! uncertain_task_must_not_execute,
                #{unexpected => true}
            end
        },
        max_steps => 3
    },

    ok = hayata_task_store:ensure_started(),
    {ok, created} = hayata_task_store:create_invocation(
        AgentId,
        Checkpoint
    ),
    {ok, execute} = hayata_task_store:claim_task(
        {AgentId, work, ExecutionId, node_result},
        #{}
    ),

    with_agent(Config, fun(Agent) ->
        ?assertEqual(
            {error, task_execution_uncertain},
            hayata_agent:recover(Agent)
        ),

        ?assertEqual(
            recovery_required,
            maps:get(status, hayata_agent:get_info(Agent))
        ),

        receive
            uncertain_task_must_not_execute ->
                error(uncertain_task_was_reexecuted)
        after 100 ->
            ok
        end
    end).

rejects_recovery_when_node_is_not_running_test() ->
    Parent = self(),
    AgentId = make_ref(),
    InvocationId = make_ref(),
    ExecutionId = make_ref(),
    NodeInput = #{
        progress => 1,
        input => selected_input
    },
    ActiveExecution = #{
        node_id => work,
        execution_id => ExecutionId,
        node_input => NodeInput
    },
    Checkpoint = #{
        invocation_id => InvocationId,
        input => original_input,
        state => #{progress => 1},
        current_step => 1,
        active_execution => ActiveExecution,
        parallel_results => undefined,
        result => undefined,
        last_error => undefined,
        status => running
    },
    Config = #{
        id => AgentId,
        state => #{progress => 0},
        nodes => #{
            work => fun(_Input) ->
                Parent ! node_must_not_execute,
                #{unexpected => true}
            end
        },
        max_steps => 3
    },

    ok = hayata_task_store:ensure_started(),
    {ok, created} = hayata_task_store:create_invocation(
        AgentId,
        Checkpoint
    ),

    with_agent(Config, fun(Agent) ->
        {ok, SupervisorPid} = gen_server:call(
            Agent,
            get_supervisor_pid
        ),
        {ok, NodeSupPid} = hayata_agent_sup:node_supervisor(
            SupervisorPid
        ),

        ok = hayata_node_sup:stop_node(
            NodeSupPid,
            work
        ),

        ?assertEqual(
            undefined,
            hayata_node:whereis(AgentId, work)
        ),

        ?assertEqual(
            {error, {node_not_running, work}},
            hayata_agent:recover(Agent)
        ),

        ?assertEqual(
            recovery_required,
            maps:get(status, hayata_agent:get_info(Agent))
        ),

        ?assertEqual(
            {error, no_result},
            hayata_agent:get_result(Agent)
        ),

        receive
            node_must_not_execute ->
                error(node_executed_without_recovery_target)
        after 100 ->
            ok
        end
    end).

rejects_recovery_when_checkpoint_persistence_fails_test() ->
    Parent = self(),
    AgentId = make_ref(),
    InvocationId = make_ref(),
    ExecutionId = make_ref(),
    NodeInput = #{
        progress => 1,
        input => selected_input
    },
    ActiveExecution = #{
        node_id => work,
        execution_id => ExecutionId,
        node_input => NodeInput
    },
    Checkpoint = #{
        invocation_id => InvocationId,
        input => original_input,
        state => #{progress => 1},
        current_step => 1,
        active_execution => ActiveExecution,
        parallel_results => undefined,
        result => undefined,
        last_error => undefined,
        status => running
    },
    Config = #{
        id => AgentId,
        state => #{progress => 0},
        nodes => #{
            work => fun(_Input) ->
                Parent ! node_must_not_execute,
                #{unexpected => true}
            end
        },
        max_steps => 3
    },

    ok = hayata_task_store:ensure_started(),
    {ok, created} = hayata_task_store:create_invocation(
        AgentId,
        Checkpoint
    ),

    with_agent(Config, fun(Agent) ->
        {atomic, ok} = mnesia:change_table_access_mode(
            hayata_invocation_checkpoint,
            read_only
        ),

        try
            ?assertMatch(
                {error, {checkpoint_save_failed, _}},
                hayata_agent:recover(Agent)
            ),

            ?assertEqual(
                recovery_required,
                maps:get(status, hayata_agent:get_info(Agent))
            ),

            receive
                node_must_not_execute ->
                    error(node_executed_after_checkpoint_failure)
            after 100 ->
                ok
            end
        after
            {atomic, ok} = mnesia:change_table_access_mode(
                hayata_invocation_checkpoint,
                read_write
            )
        end
    end).

rejects_recovery_mismatch_without_stale_checkpoint_test() ->
    Parent = self(),
    AgentId = make_ref(),
    InvocationId = make_ref(),
    ExecutionId = make_ref(),
    NodeInput = #{
        progress => 1,
        input => selected_input
    },
    ActiveExecution = #{
        node_id => work,
        execution_id => ExecutionId,
        node_input => NodeInput
    },
    Checkpoint = #{
        invocation_id => InvocationId,
        input => original_input,
        state => #{progress => 1},
        current_step => 1,
        active_execution => ActiveExecution,
        parallel_results => undefined,
        result => undefined,
        last_error => undefined,
        status => running
    },
    Config = #{
        id => AgentId,
        state => #{progress => 0},
        nodes => #{
            work => fun(_Input) ->
                Parent ! recovered_node_must_not_execute,
                #{unexpected => true}
            end
        },
        max_steps => 3
    },

    ok = hayata_task_store:ensure_started(),
    {ok, created} = hayata_task_store:create_invocation(
        AgentId,
        Checkpoint
    ),

    with_agent(Config, fun(Agent) ->
        NodePid = hayata_node:whereis(AgentId, work),
        BlockedTask = fun(_Context) ->
            Parent ! conflicting_execution_started,
            receive
                continue_conflicting_execution -> ok
            end
        end,

        {ok, ExecutionId} = hayata_node:start_execution(
            NodePid,
            ExecutionId,
            [{other_edge, BlockedTask}],
            30000,
            isolated,
            self()
        ),

        receive
            conflicting_execution_started -> ok
        after 2000 ->
            error(conflicting_execution_did_not_start)
        end,

        ?assertEqual(
            {error, recovery_execution_mismatch},
            hayata_agent:recover(Agent)
        ),

        Info = hayata_agent:get_info(Agent),

        ?assertEqual(
            recovery_required,
            maps:get(status, Info)
        ),

        {ok, PersistedCheckpoint} =
            hayata_task_store:get_invocation(
                AgentId,
                InvocationId
            ),

        ?assertEqual(
            running,
            maps:get(status, PersistedCheckpoint)
        ),

        ?assertEqual(
            {error, no_result},
            hayata_agent:get_result(Agent)
        ),

        receive
            recovered_node_must_not_execute ->
                error(node_executed_after_recovery_mismatch)
        after 100 ->
            ok
        end,

        NodePid ! continue_conflicting_execution
    end).

rejects_recovery_when_checkpoint_rollback_fails_test() ->
    Parent = self(),
    AgentId = make_ref(),
    InvocationId = make_ref(),
    ExecutionId = make_ref(),
    NodeInput = #{
        progress => 1,
        input => selected_input
    },
    ActiveExecution = #{
        node_id => work,
        execution_id => ExecutionId,
        node_input => NodeInput
    },
    Checkpoint = #{
        invocation_id => InvocationId,
        input => original_input,
        state => #{progress => 1},
        current_step => 1,
        active_execution => ActiveExecution,
        parallel_results => undefined,
        result => undefined,
        last_error => undefined,
        status => running
    },
    Config = #{
        id => AgentId,
        state => #{progress => 0},
        nodes => #{
            work => fun(_Input) ->
                Parent ! recovered_node_must_not_execute,
                #{unexpected => true}
            end
        },
        max_steps => 3
    },

    ok = hayata_task_store:ensure_started(),
    {ok, created} = hayata_task_store:create_invocation(
        AgentId,
        Checkpoint
    ),

    with_agent(Config, fun(Agent) ->
        NodePid = hayata_node:whereis(AgentId, work),
        BlockedTask = fun(_Context) ->
            Parent ! conflicting_execution_started,
            receive
                continue_conflicting_execution -> ok
            end
        end,

        {ok, ExecutionId} = hayata_node:start_execution(
            NodePid,
            ExecutionId,
            [{other_edge, BlockedTask}],
            30000,
            isolated,
            self()
        ),

        receive
            conflicting_execution_started -> ok
        after 2000 ->
            error(conflicting_execution_did_not_start)
        end,

        {ok, InitialCheckpoint} =
            hayata_task_store:get_invocation(
                AgentId,
                InvocationId
            ),
        InitialUpdatedAt = maps:get(
            updated_at,
            InitialCheckpoint
        ),

        %% Hold the node until the intermediate checkpoint is saved.
        timer:sleep(10),
        ok = sys:suspend(NodePid),

        spawn(fun() ->
            Parent ! {
                recovery_result,
                hayata_agent:recover(Agent)
            }
        end),

        try
            _UpdatedCheckpoint = await_checkpoint_update(
                AgentId,
                InvocationId,
                InitialUpdatedAt,
                200
            ),

            %% The running checkpoint is saved; force rollback to fail.
            {atomic, ok} = mnesia:change_table_access_mode(
                hayata_invocation_checkpoint,
                read_only
            ),

            ok = sys:resume(NodePid),

            receive
                {recovery_result, Result} ->
                    ?assertMatch(
                        {
                            error,
                            {
                                recovery_failed_checkpoint_rollback_failed,
                                recovery_execution_mismatch,
                                _
                            }
                        },
                        Result
                    )
            after 2000 ->
                error(recovery_result_timeout)
            end,

            ?assertEqual(
                recovery_required,
                maps:get(status, hayata_agent:get_info(Agent))
            ),

            %% Rollback failed, so the intermediate checkpoint remains.
            {ok, PersistedCheckpoint} =
                hayata_task_store:get_invocation(
                    AgentId,
                    InvocationId
                ),

            ?assertEqual(
                running,
                maps:get(status, PersistedCheckpoint)
            ),

            ?assertEqual(
                {error, no_result},
                hayata_agent:get_result(Agent)
            ),

            receive
                recovered_node_must_not_execute ->
                    error(node_executed_after_recovery_failure)
            after 100 ->
                ok
            end
        after
            _ = sys:resume(NodePid),
            {atomic, ok} = mnesia:change_table_access_mode(
                hayata_invocation_checkpoint,
                read_write
            ),
            NodePid ! continue_conflicting_execution
        end
    end).

recovers_parallel_execution_with_not_started_branch_test() ->
    Parent = self(),
    AgentId = make_ref(),
    InvocationId = make_ref(),
    ExecutionId = make_ref(),
    ActiveExecution = #{
        type => parallel,
        node_ids => [work],
        node_input => #{progress => 1, input => original_input},
        pending => #{work => ExecutionId},
        results => #{}
    },
    Checkpoint = #{
        invocation_id => InvocationId,
        input => original_input,
        state => #{progress => 1},
        current_step => 1,
        active_execution => ActiveExecution,
        parallel_results => undefined,
        result => undefined,
        last_error => undefined,
        status => running
    },
    Config = #{
        id => AgentId,
        state => #{progress => 0},
        nodes => #{
            work => fun(_State) ->
                Parent ! {parallel_branch_executed, self()},
                #{recovered => true}
            end
        },
        decision_policy => fun(Context) ->
            {finish, maps:get(parallel_results, Context)}
        end,
        max_steps => 3
    },

    ok = hayata_task_store:ensure_started(),
    {ok, created} = hayata_task_store:create_invocation(
        AgentId,
        Checkpoint
    ),

    with_agent(Config, fun(Agent) ->
        ?assertEqual(
            #{work => not_started},
            maps:get(recovery_tasks, hayata_agent:get_info(Agent))
        ),

        ?assertEqual(
            {ok, ExecutionId},
            hayata_agent:recover(Agent)
        ),

        receive
            {parallel_branch_executed, _Pid} ->
                ok
        after 2000 ->
            error(parallel_branch_recovery_timeout)
        end,

        await_status(Agent, completed, 300),

        ?assertEqual(
            {ok, [#{recovered => true}]},
            hayata_agent:get_result(Agent)
        )
    end).

recovers_parallel_execution_with_multiple_not_started_branches_test() ->
    Parent = self(),
    AgentId = make_ref(),
    InvocationId = make_ref(),
    FirstExecutionId = make_ref(),
    SecondExecutionId = make_ref(),
    ActiveExecution = #{
        type => parallel,
        node_ids => [alpha, beta],
        node_input => #{
            progress => 1,
            input => original_input
        },
        pending => #{
            alpha => FirstExecutionId,
            beta => SecondExecutionId
        },
        results => #{}
    },
    Checkpoint = #{
        invocation_id => InvocationId,
        input => original_input,
        state => #{progress => 1},
        current_step => 1,
        active_execution => ActiveExecution,
        parallel_results => undefined,
        result => undefined,
        last_error => undefined,
        status => running
    },
    Config = #{
        id => AgentId,
        state => #{progress => 0},
        nodes => #{
            alpha => fun(_State) ->
                Parent ! {parallel_branch_executed, alpha},
                #{alpha => recovered}
            end,
            beta => fun(_State) ->
                Parent ! {parallel_branch_executed, beta},
                #{beta => recovered}
            end
        },
        decision_policy => fun(Context) ->
            {finish, maps:get(parallel_results, Context)}
        end,
        max_steps => 3
    },

    ok = hayata_task_store:ensure_started(),
    {ok, created} = hayata_task_store:create_invocation(
        AgentId,
        Checkpoint
    ),

    with_agent(Config, fun(Agent) ->
        ?assertEqual(
            #{alpha => not_started, beta => not_started},
            maps:get(recovery_tasks, hayata_agent:get_info(Agent))
        ),

        ?assertMatch({ok, _}, hayata_agent:recover(Agent)),

        ExecutedBranches = [
            receive
                {parallel_branch_executed, NodeId} ->
                    NodeId
            after 2000 ->
                error(parallel_branch_recovery_timeout)
            end
            || _ <- [alpha, beta]
        ],

        ?assertEqual(
            [alpha, beta],
            lists:sort(ExecutedBranches)
        ),

        await_status(Agent, completed, 300),

        ?assertEqual(
            {ok, [
                #{alpha => recovered},
                #{beta => recovered}
            ]},
            hayata_agent:get_result(Agent)
        )
    end).

cancels_started_parallel_recovery_branches_on_failure_test() ->
    Parent = self(),
    AgentId = make_ref(),
    InvocationId = make_ref(),
    FirstExecutionId = make_ref(),
    SecondExecutionId = make_ref(),
    ActiveExecution = #{
        type => parallel,
        node_ids => [alpha, beta],
        node_input => #{
            progress => 1,
            input => original_input
        },
        pending => #{
            alpha => FirstExecutionId,
            beta => SecondExecutionId
        },
        results => #{}
    },
    Checkpoint = #{
        invocation_id => InvocationId,
        input => original_input,
        state => #{progress => 1},
        current_step => 1,
        active_execution => ActiveExecution,
        parallel_results => undefined,
        result => undefined,
        last_error => undefined,
        status => running
    },
    Config = #{
        id => AgentId,
        state => #{progress => 0},
        nodes => #{
            alpha => fun(_State) ->
                Parent ! {alpha_branch_started, self()},
                receive
                    continue_alpha ->
                        #{alpha => recovered}
                end
            end,
            beta => fun(_State) ->
                Parent ! beta_should_not_execute,
                #{beta => unexpected}
            end
        },
        decision_policy => fun(Context) ->
            {finish, maps:get(parallel_results, Context)}
        end,
        max_steps => 3
    },

    ok = hayata_task_store:ensure_started(),
    {ok, created} = hayata_task_store:create_invocation(
        AgentId,
        Checkpoint
    ),

    with_agent(Config, fun(Agent) ->
        BetaPid = hayata_node:whereis(AgentId, beta),
        BlockedTask = fun(_Context) ->
            Parent ! {conflicting_beta_execution_started, self()},
            receive
                 continue_conflicting_beta_execution -> ok
            end
        end,

        {ok, SecondExecutionId} = hayata_node:start_execution(
            BetaPid,
            SecondExecutionId,
            [{other_edge, BlockedTask}],
            30000,
            isolated,
            self()
        ),

        BlockedTaskPid = receive
            {conflicting_beta_execution_started, Pid} ->
                Pid
        after 2000 ->
            error(conflicting_beta_execution_did_not_start)
        end,

        ?assertEqual(
            {error, {
                parallel_node_recovery_failed,
                beta,
                recovery_execution_mismatch
            }},
            hayata_agent:recover(Agent)
        ),

        %% Alpha may be cancelled before its task function starts.
        %% Verify the execution state instead of relying on a message
        %% sent from inside the task function.
        AlphaPid = hayata_node:whereis(AgentId, alpha),
        AlphaInfo = hayata_node:get_info(AlphaPid),
        AlphaExecution = maps:get(
            FirstExecutionId,
            maps:get(executions, AlphaInfo)
        ),

        ?assertEqual(
            cancelled,
            maps:get(status, AlphaExecution)
        ),

        RemainingAlphaEdges = [
            Edge
            || Edge <- maps:values(maps:get(active_edges, AlphaInfo)),
               maps:get(execution_id, Edge) =:= FirstExecutionId
        ],

        ?assertEqual([], RemainingAlphaEdges),

        ?assertEqual(
            recovery_required,
            maps:get(status, hayata_agent:get_info(Agent))
        ),

        %% The persisted checkpoint should be restored to its
        %% pre-recovery status rather than left as running.
        {ok, PersistedCheckpoint} = hayata_task_store:get_invocation(
            AgentId,
            InvocationId
        ),

        ?assertEqual(
            running,
            maps:get(status, PersistedCheckpoint)
        ),

        ?assertEqual(
            {error, no_result},
            hayata_agent:get_result(Agent)
        ),

        receive
            beta_should_not_execute ->
                error(beta_node_executed_despite_recovery_failure)
        after 100 ->
            ok
        end,

        %% Release the deliberately blocked conflicting execution.
        BetaPid ! continue_conflicting_beta_execution,
        BlockedTaskPid ! continue_conflicting_beta_execution
    end).

restores_active_invocation_after_supervisor_restart_test() ->
    AgentId = make_ref(),
    InvocationId = make_ref(),
    ExecutionId = make_ref(),
    NodeInput = #{input => original_input, progress => 1},
    ActiveExecution = #{
        node_id => alpha,
        execution_id => ExecutionId,
        node_input => NodeInput
    },
    Checkpoint = #{
        agent_id => AgentId,
        invocation_id => InvocationId,
        status => running,
        input => original_input,
        state => #{progress => 1},
        current_step => 1,
        active_execution => ActiveExecution
    },
    Config = #{
        id => AgentId,
        state => #{},
        nodes => #{
            alpha => fun(_Input) ->
                #{recovered => true}
            end
        },
        decision_policy => fun(Context) ->
            {finish, maps:get(state, Context)}
        end,
        max_steps => 3
    },

    ok = hayata_task_store:ensure_started(),
    {ok, created} = hayata_task_store:create_invocation(
        AgentId,
        Checkpoint
    ),

    {ok, FirstSup} = hayata_agent_sup:start_link(Config),
    unlink(FirstSup),
    {ok, FirstAgent} = hayata_agent_sup:agent(FirstSup),

    try
        ?assertEqual(
            recovery_required,
            maps:get(status, hayata_agent:get_info(FirstAgent))
        )
    after
        FirstSupMonitor = erlang:monitor(process, FirstSup),
        exit(FirstSup, shutdown),

        receive
            {'DOWN', FirstSupMonitor, process, FirstSup, _Reason} ->
                ok
        after 5000 ->
           error(first_supervisor_shutdown_timeout)
        end
    end,

    {ok, SecondSup} = hayata_agent_sup:start_link(Config),
    unlink(SecondSup),

    try
        {ok, SecondAgent} = hayata_agent_sup:agent(SecondSup),
        Info = hayata_agent:get_info(SecondAgent),

        ?assertEqual(
            recovery_required,
            maps:get(status, Info)
        ),
        ?assertEqual(
            InvocationId,
            maps:get(invocation_id, Info)
        ),
        ?assertEqual(
            ActiveExecution,
            maps:get(active_execution, Info)
        ),
        ?assertEqual(
            #{progress => 1},
            hayata_agent:get_state(SecondAgent)
        )
    after
        exit(SecondSup, shutdown)
    end.

run_options_subscriber_receives_terminal_result_test() ->
    Config = run_options_test_config(),

    with_agent(Config, fun(Agent) ->
        {ok, InvocationId} = hayata_agent:run(
            Agent,
            hello,
            #{subscriber => self()}
        ),

        receive
            {hayata_agent_result, InvocationId, {ok, Result}} ->
                ?assertEqual(#{answer => 42}, Result)
        after 1000 ->
            error(terminal_result_notification_timeout)
        end
    end).

run_options_stream_true_preserves_terminal_result_test() ->
    Config = run_options_test_config(),

    with_agent(Config, fun(Agent) ->
        {ok, InvocationId} = hayata_agent:run(
            Agent,
            hello,
            #{
                subscriber => self(),
                stream => true
            }
        ),

        receive
            {hayata_agent_result, InvocationId, {ok, Result}} ->
                ?assertEqual(#{answer => 42}, Result)
        after 1000 ->
            error(terminal_result_notification_timeout)
        end
    end).

run_options_stream_false_is_accepted_test() ->
    Config = run_options_test_config(),

    with_agent(Config, fun(Agent) ->
        {ok, _InvocationId} = hayata_agent:run(
            Agent,
            hello,
            #{
                subscriber => self(),
                stream => false
            }
        ),

        ?assertEqual(
            {ok, #{answer => 42}},
            hayata_agent:get_result(Agent)
        )
    end).

run_options_stream_defaults_to_false_test() ->
    Config = run_options_test_config(),

    with_agent(Config, fun(Agent) ->
        {ok, _InvocationId} = hayata_agent:run(
            Agent,
            hello,
            #{subscriber => self()}
        ),

        ?assertEqual(
            {ok, #{answer => 42}},
            hayata_agent:get_result(Agent)
        )
    end).

run_options_rejects_invalid_subscriber_test() ->
    ?assertEqual(
        {error, invalid_subscriber},
        hayata_agent:run(
            self(),
            hello,
            #{subscriber => not_a_pid}
        )
    ).

run_options_rejects_stream_without_subscriber_test() ->
    ?assertEqual(
        {error, subscriber_required_for_stream},
        hayata_agent:run(
            self(),
            hello,
            #{stream => true}
        )
    ).

run_options_rejects_invalid_stream_value_test() ->
    ?assertEqual(
        {error, invalid_stream_option},
        hayata_agent:run(
            self(),
            hello,
            #{
                subscriber => self(),
                stream => yes
            }
        )
    ).

run_options_rejects_unknown_option_test() ->
    ?assertEqual(
        {error, {unknown_run_option, unsupported}},
        hayata_agent:run(
            self(),
            hello,
            #{
                subscriber => self(),
                unsupported => true
            }
        )
    ).

run_options_rejects_non_map_test() ->
    ?assertEqual(
        {error, invalid_run_options},
        hayata_agent:run(self(), hello, not_a_map)
    ).


run_options_stream_emits_invocation_lifecycle_test() ->
    Config = run_options_test_config(),

    with_agent(Config, fun(Agent) ->
        {ok, InvocationId} = hayata_agent:run(
            Agent,
            hello,
            #{subscriber => self(), stream => true}
        ),

        receive
            {hayata_agent_event, InvocationId, StartedEvent} ->
                ?assertEqual(
                    #{
                        type => invocation_started,
                        sequence => 1,
                        data => #{}
                    },
                    StartedEvent
                )
        after 1000 ->
            error(invocation_started_timeout)
        end,

        receive
            {hayata_agent_event, InvocationId, CompletedEvent} ->
                ?assertEqual(
                    invocation_completed,
                    maps:get(type, CompletedEvent)
                ),
                ?assertEqual(2, maps:get(sequence, CompletedEvent)),
                ?assertEqual(
                    #{result => #{answer => 42}},
                    maps:get(data, CompletedEvent)
                )
        after 1000 ->
            error(invocation_completed_timeout)
        end,

        receive
            {hayata_agent_result, InvocationId, {ok, Result}} ->
                ?assertEqual(#{answer => 42}, Result)
        after 1000 ->
            error(terminal_result_notification_timeout)
        end
    end).


run_options_stream_emits_invocation_failed_test() ->
    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{
            work => fun(_State) ->
                erlang:error(expected_failure)
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, work, undefined};
                1 -> {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        {ok, InvocationId} = hayata_agent:run(
            Agent,
            hello,
            #{subscriber => self(), stream => true}
        ),

        StartedMessage = receive
            {hayata_agent_event, StartId, StartEvent}
                    when StartId =:= InvocationId ->
                {StartId, StartEvent}
        after 1000 ->
            error(invocation_started_timeout)
        end,

        {_, StartedEvent} = StartedMessage,
        ?assertEqual(
            invocation_started,
            maps:get(type, StartedEvent)
        ),
        ?assertEqual(1, maps:get(sequence, StartedEvent)),

        NodeStartedMessage = receive
            {hayata_agent_event, NodeStartId, NodeStartEvent}
                    when NodeStartId =:= InvocationId ->
                {NodeStartId, NodeStartEvent}
        after 1000 ->
            error(node_started_timeout)
        end,

        {_, NodeStartedEvent} = NodeStartedMessage,
        ?assertEqual(
            node_started,
            maps:get(type, NodeStartedEvent)
        ),
        ?assertEqual(2, maps:get(sequence, NodeStartedEvent)),

        FailedMessage = receive
            {hayata_agent_event, FailureId, FailureEvent}
                    when FailureId =:= InvocationId ->
                {FailureId, FailureEvent}
        after 1000 ->
            error(invocation_failed_timeout)
        end,

        {_, FailedEvent} = FailedMessage,
        ?assertEqual(
            invocation_failed,
            maps:get(type, FailedEvent)
        ),
        ?assertEqual(3, maps:get(sequence, FailedEvent)),

        ?assertMatch(
            #{
                reason := {
                    node_execution_failed,
                    #{
                        node_result := {
                            node_exception,
                            error,
                            expected_failure,
                            _
                        }
                    }
                }
            },
            maps:get(data, FailedEvent)
        ),

        ResultMessage = receive
            {hayata_agent_result, ResultId, Outcome}
                    when ResultId =:= InvocationId ->
                {ResultId, Outcome}
        after 1000 ->
            error(terminal_result_notification_timeout)
        end,

        {_, Result} = ResultMessage,

        ?assertMatch({error, {node_execution_failed, _}}, Result)
    end).


run_options_stream_emits_node_lifecycle_test() ->
    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{
            work => fun(_State) ->
                #{answer => 42}
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, work, undefined};
                1 -> {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        {ok, InvocationId} = hayata_agent:run(
            Agent,
            hello,
            #{subscriber => self(), stream => true}
        ),

        StartedMessage = receive
            {hayata_agent_event, StartId, StartEvent}
                    when StartId =:= InvocationId ->
                {StartId, StartEvent}
        after 1000 ->
            error(invocation_started_timeout)
        end,

        {_, StartedEvent} = StartedMessage,
        ?assertEqual(
            invocation_started,
            maps:get(type, StartedEvent)
        ),
        ?assertEqual(1, maps:get(sequence, StartedEvent)),

        NodeStartedMessage = receive
            {hayata_agent_event, NodeStartId, NodeStartEvent}
                    when NodeStartId =:= InvocationId ->
                {NodeStartId, NodeStartEvent}
        after 1000 ->
            error(node_started_timeout)
        end,

        {_, NodeStartedEvent} = NodeStartedMessage,
        ?assertEqual(
            node_started,
            maps:get(type, NodeStartedEvent)
        ),
        ?assertEqual(2, maps:get(sequence, NodeStartedEvent)),

        NodeStartedData = maps:get(data, NodeStartedEvent),
        ?assertEqual(work, maps:get(node_id, NodeStartedData)),
        ?assert(is_reference(maps:get(execution_id, NodeStartedData))),

        NodeCompletedMessage = receive
            {hayata_agent_event, NodeCompleteId, NodeCompleteEvent}
                    when NodeCompleteId =:= InvocationId ->
                {NodeCompleteId, NodeCompleteEvent}
        after 1000 ->
            error(node_completed_timeout)
        end,

        {_, NodeCompletedEvent} = NodeCompletedMessage,
        ?assertEqual(
            node_completed,
            maps:get(type, NodeCompletedEvent)
        ),
        ?assertEqual(3, maps:get(sequence, NodeCompletedEvent)),

        NodeCompletedData = maps:get(data, NodeCompletedEvent),
        ?assertEqual(work, maps:get(node_id, NodeCompletedData)),
        ?assertEqual(
            maps:get(execution_id, NodeStartedData),
            maps:get(execution_id, NodeCompletedData)
        ),

        CompletedMessage = receive
            {hayata_agent_event, CompleteId, CompleteEvent}
                    when CompleteId =:= InvocationId ->
                {CompleteId, CompleteEvent}
        after 1000 ->
            error(invocation_completed_timeout)
        end,

        {_, CompletedEvent} = CompletedMessage,
        ?assertEqual(
            invocation_completed,
            maps:get(type, CompletedEvent)
        ),
        ?assertEqual(4, maps:get(sequence, CompletedEvent)),
        ?assertEqual(
            #{result => #{answer => 42}},
            maps:get(data, CompletedEvent)
        ),

        receive
            {hayata_agent_result, InvocationId, {ok, Result}} ->
                ?assertEqual(#{answer => 42}, Result)
        after 1000 ->
            error(terminal_result_notification_timeout)
        end
    end).

run_options_stream_emits_parallel_node_lifecycle_test() ->
    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{
            alpha => fun(_State) ->
                #{alpha => completed}
            end,
            beta => fun(_State) ->
                #{beta => completed}
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, [alpha, beta], undefined};
                2 -> {finish, maps:get(parallel_results, Context)}
            end
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        {ok, InvocationId} = hayata_agent:run(
            Agent,
            hello,
            #{subscriber => self(), stream => true}
        ),

        StartedMessage = receive
            {hayata_agent_event, StartId, StartEvent}
                    when StartId =:= InvocationId ->
                {StartId, StartEvent}
        after 1000 ->
            error(invocation_started_timeout)
        end,

        {_, StartedEvent} = StartedMessage,
        ?assertEqual(
            invocation_started,
            maps:get(type, StartedEvent)
        ),
        ?assertEqual(1, maps:get(sequence, StartedEvent)),

        NodeStartedEvents = [
            receive
                {hayata_agent_event, StartNodeId, StartNodeEvent}
                        when StartNodeId =:= InvocationId ->
                    StartNodeEvent
            after 1000 ->
                error(node_started_timeout)
            end
            || _ <- [alpha, beta]
        ],

        ?assertEqual(
            [2, 3],
            lists:sort([
                maps:get(sequence, Event)
                || Event <- NodeStartedEvents
            ])
        ),

        StartedByNode = maps:from_list([
            begin
                Data = maps:get(data, Event),
                {
                    maps:get(node_id, Data),
                    maps:get(execution_id, Data)
                }
            end
            || Event <- NodeStartedEvents
        ]),

        ?assertEqual(
            [alpha, beta],
            lists:sort(maps:keys(StartedByNode))
        ),

        NodeCompletedEvents = [
            receive
                {hayata_agent_event, CompleteNodeId, CompleteNodeEvent}
                        when CompleteNodeId =:= InvocationId ->
                    CompleteNodeEvent
            after 2000 ->
                error(node_completed_timeout)
            end
            || _ <- [alpha, beta]
        ],

        ?assertEqual(
            [4, 5],
            lists:sort([
                maps:get(sequence, Event)
                || Event <- NodeCompletedEvents
            ])
        ),

        CompletedByNode = maps:from_list([
            begin
                Data = maps:get(data, Event),
                {
                    maps:get(node_id, Data),
                    maps:get(execution_id, Data)
                }
            end
            || Event <- NodeCompletedEvents
        ]),

        ?assertEqual(
            lists:sort(maps:keys(StartedByNode)),
            lists:sort(maps:keys(CompletedByNode))
        ),

        ?assertEqual(StartedByNode, CompletedByNode),

        CompletedMessage = receive
            {hayata_agent_event, CompleteId, CompleteEvent}
                    when CompleteId =:= InvocationId ->
                {CompleteId, CompleteEvent}
        after 2000 ->
            error(invocation_completed_timeout)
        end,

        {_, InvocationCompletedEvent} = CompletedMessage,
        ?assertEqual(
            invocation_completed,
            maps:get(type, InvocationCompletedEvent)
        ),
        ?assertEqual(6, maps:get(sequence, InvocationCompletedEvent)),

        ResultMessage = receive
            {hayata_agent_result, ResultId, Outcome}
                    when ResultId =:= InvocationId ->
                {ResultId, Outcome}
        after 1000 ->
            error(terminal_result_notification_timeout)
        end,

        {_, Result} = ResultMessage,
        ?assertMatch({ok, _}, Result)
    end).

run_options_stream_emits_partial_node_results_test() ->
    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{
            work => fun(Context) ->
                Streamer = maps:get(hayata_streamer, Context),
                ok = Streamer(#{chunk => first}),
                ok = Streamer(#{chunk => second}),
                #{answer => 42}
           end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, work, undefined};
                1 -> {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        {ok, InvocationId} = hayata_agent:run(
            Agent,
            hello,
            #{subscriber => self(), stream => true}
        ),

        StartedEvent = receive
            {hayata_agent_event, InvocationId, Event1} ->
                Event1
        after 1000 ->
            error(invocation_started_timeout)
        end,
        ?assertEqual(
            invocation_started,
            maps:get(type, StartedEvent)
        ),

        NodeStartedEvent = receive
            {hayata_agent_event, InvocationId, Event2} ->
                Event2
        after 1000 ->
            error(node_started_timeout)
        end,
        ?assertEqual(
            node_started,
            maps:get(type, NodeStartedEvent)
        ),

        PartialEvents = [
            receive
                {hayata_agent_event, InvocationId, Event} ->
                    Event
            after 1000 ->
                error(node_partial_result_timeout)
            end
            || _ <- [first, second]
        ],

        ?assertEqual(
            [node_partial_result, node_partial_result],
            [maps:get(type, Event) || Event <- PartialEvents]
        ),

        ?assertEqual(
            [3, 4],
            [maps:get(sequence, Event) || Event <- PartialEvents]
        ),

        ?assertEqual(
            [#{chunk => first}, #{chunk => second}],
            [
                maps:get(result, maps:get(data, Event))
                || Event <- PartialEvents
            ]
        ),

        NodeCompletedEvent = receive
            {hayata_agent_event, InvocationId, Event3} ->
                Event3
        after 1000 ->
            error(node_completed_timeout)
        end,
        ?assertEqual(
            node_completed,
            maps:get(type, NodeCompletedEvent)
        ),
        ?assertEqual(5, maps:get(sequence, NodeCompletedEvent)),

        InvocationCompletedEvent = receive
            {hayata_agent_event, InvocationId, Event4} ->
                Event4
        after 1000 ->
            error(invocation_completed_timeout)
        end,
        ?assertEqual(
            invocation_completed,
            maps:get(type, InvocationCompletedEvent)
        ),
        ?assertEqual(6, maps:get(sequence, InvocationCompletedEvent)),

        receive
            {hayata_agent_result, InvocationId, {ok, Result}} ->
                ?assertEqual(#{answer => 42}, Result)
        after 1000 ->
            error(terminal_result_notification_timeout)
        end
    end).

run_options_stream_emits_parallel_partial_results_test() ->
    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{
            alpha => fun(Context) ->
                Streamer = maps:get(hayata_streamer, Context),
                ok = Streamer(#{node => alpha, chunk => first}),
                ok = Streamer(#{node => alpha, chunk => second}),
                #{alpha => completed}
            end,
            beta => fun(Context) ->
                Streamer = maps:get(hayata_streamer, Context),
                ok = Streamer(#{node => beta, chunk => first}),
                #{beta => completed}
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, [alpha, beta], undefined};
                2 -> {finish, maps:get(parallel_results, Context)}
            end
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        {ok, InvocationId} = hayata_agent:run(
            Agent,
            hello,
            #{subscriber => self(), stream => true}
        ),

        Events = collect_stream_events(InvocationId, []),

        PartialEvents = [
            Event
            || Event <- Events,
               maps:get(type, Event) =:= node_partial_result
        ],

        ?assertEqual(3, length(PartialEvents)),

        PartialData = [
            maps:get(data, Event)
            || Event <- PartialEvents
        ],

        AlphaEvents = [
            Data
            || Data <- PartialData,
               maps:get(node_id, Data) =:= alpha
        ],

        BetaEvents = [
            Data
            || Data <- PartialData,
               maps:get(node_id, Data) =:= beta
        ],

        ?assertEqual(2, length(AlphaEvents)),
        ?assertEqual(1, length(BetaEvents)),

        ?assertEqual(
            [#{node => alpha, chunk => first},
             #{node => alpha, chunk => second}],
            [maps:get(result, Data) || Data <- AlphaEvents]
        ),

        ?assertEqual(
            [#{node => beta, chunk => first}],
            [maps:get(result, Data) || Data <- BetaEvents]
        ),

        AlphaExecutionIds = lists:usort([
            maps:get(execution_id, Data)
            || Data <- AlphaEvents
        ]),
        BetaExecutionIds = lists:usort([
            maps:get(execution_id, Data)
            || Data <- BetaEvents
        ]),

        ?assertEqual(1, length(AlphaExecutionIds)),
        ?assertEqual(1, length(BetaExecutionIds)),
        ?assertNotEqual(AlphaExecutionIds, BetaExecutionIds),

        Sequences = [
            maps:get(sequence, Event)
            || Event <- Events
        ],

        ?assertEqual(
            lists:seq(1, length(Events)),
            Sequences
        ),

        NodeCompletedSequences = [
            maps:get(sequence, Event)
            || Event <- Events,
               maps:get(type, Event) =:= node_completed
        ],

        PartialSequences = [
            maps:get(sequence, Event)
            || Event <- PartialEvents
        ],

        ?assert(lists:all(
            fun(PartialSequence) ->
                lists:any(
                    fun(CompletedSequence) ->
                        PartialSequence < CompletedSequence
                    end,
                    NodeCompletedSequences
                )
            end,
            PartialSequences
        ))
    end).

run_options_stream_disabled_does_not_inject_streamer_test() ->
    Parent = self(),

    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{
            work => fun(Context) ->
                Parent ! {
                    streamer_available,
                    maps:is_key(hayata_streamer, Context)
                },
                #{answer => 42}
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, work, undefined};
                1 -> {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        {ok, InvocationId} = hayata_agent:run(
            Agent,
            hello,
            #{subscriber => self(), stream => false}
        ),

        receive
            {streamer_available, Available} ->
                ?assertEqual(false, Available)
        after 1000 ->
            error(streamer_availability_timeout)
        end,

        receive
            {hayata_agent_result, InvocationId, {ok, Result}} ->
                ?assertEqual(#{answer => 42}, Result)
        after 1000 ->
            error(terminal_result_notification_timeout)
        end,

        receive
            {hayata_agent_event, InvocationId, _Event} ->
                error(unexpected_stream_event)
        after 100 ->
            ok
        end
    end).

run_options_stream_rejects_stale_partial_result_test() ->
    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{
            work => fun(Context) ->
                Streamer = maps:get(hayata_streamer, Context),
                ok = Streamer(#{chunk => first}),
                #{answer => 42}
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, work, undefined};
                1 -> {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        {ok, InvocationId} = hayata_agent:run(
            Agent,
            hello,
            #{subscriber => self(), stream => true}
        ),

        %% Consume the initial lifecycle events.
        receive
            {hayata_agent_event, InvocationId, Event1} ->
                ?assertEqual(
                    invocation_started,
                    maps:get(type, Event1)
                )
        after 1000 ->
            error(invocation_started_timeout)
        end,

        receive
            {hayata_agent_event, InvocationId, Event2} ->
                ?assertEqual(
                    node_started,
                    maps:get(type, Event2)
                )
        after 1000 ->
            error(node_started_timeout)
        end,

        %% Wait until the node has completed before submitting a stale
        %% partial result. The execution reference is intentionally wrong.
        receive
            {hayata_agent_event, InvocationId, Event3} ->
                ?assertEqual(
                    node_partial_result,
                    maps:get(type, Event3)
                )
        after 1000 ->
            error(node_partial_result_timeout)
        end,

        receive
            {hayata_agent_event, InvocationId, Event4} ->
                ?assertEqual(
                    node_completed,
                    maps:get(type, Event4)
                )
        after 1000 ->
            error(node_completed_timeout)
        end,

        receive
            {hayata_agent_event, InvocationId, Event5} ->
                ?assertEqual(
                    invocation_completed,
                    maps:get(type, Event5)
                )
        after 1000 ->
            error(invocation_completed_timeout)
        end,

        receive
            {hayata_agent_result, InvocationId, {ok, Result0}} ->
                ?assertEqual(#{answer => 42}, Result0)
        after 1000 ->
            error(terminal_result_notification_timeout)
        end,

        Result = gen_server:call(
            Agent,
            {
                hayata_node_partial_result,
                InvocationId,
                work,
                make_ref(),
                node_result,
                #{chunk => stale}
            }
        ),

        ?assertEqual({error, stale_execution}, Result),

        receive
            {hayata_agent_event, InvocationId, Event6} ->
                error({unexpected_event_after_stale_result, Event6})
        after 100 ->
            ok
        end
    end).

llm_is_available_to_node_test() ->
    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{
            ask_llm => fun(Context) ->
                LLM = maps:get(hayata_llm, Context),
                Messages = [
                    #{
                        role => user,
                        content => [
                            #{
                                type => text,
                                text => <<"Hello">>
                            }
                        ]
                    }
                ],
                case LLM(#{messages => Messages}) of
                    {ok, Response} ->
                        #{llm_response => Response};
                    {error, Reason} ->
                        #{llm_error => Reason}
                end
            end
        },
        llm => #{
            adapter => hayata_llm_adapter_mock,
            model => <<"mock-model">>
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 ->
                    {next, ask_llm, undefined};
                1 ->
                    {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        {ok, _InvocationId} = hayata_agent:run(Agent, start),
        await_status(Agent, completed, 100),
        {ok, Result} = hayata_agent:get_result(Agent),

        ?assertMatch(
            #{
                llm_response := #{
                    message := #{
                        role := assistant,
                        content := [_ | _]
                    },
                    finish_reason := stop
                }
            },
            Result
        )
    end).

conversation_memory_preserves_messages_test() ->
    Config = conversation_memory_test_config(true),

    with_agent(Config, fun(Agent) ->
        {ok, _} = hayata_agent:run(Agent, first),
        await_status(Agent, completed, 100),

        {ok, FirstResult} = hayata_agent:get_result(Agent),
        ?assertEqual([first], maps:get(messages, FirstResult)),

        {ok, _} = hayata_agent:run(Agent, second),
        await_status(Agent, completed, 100),

        {ok, SecondResult} = hayata_agent:get_result(Agent),
        ?assertEqual(
            [first, second],
            maps:get(messages, SecondResult)
        )
    end).

conversation_memory_disabled_resets_state_test() ->
    Config = conversation_memory_test_config(false),

    with_agent(Config, fun(Agent) ->
        {ok, _} = hayata_agent:run(Agent, first),
        await_status(Agent, completed, 100),

        {ok, _} = hayata_agent:run(Agent, second),
        await_status(Agent, completed, 100),

        {ok, Result} = hayata_agent:get_result(Agent),
        ?assertEqual([second], maps:get(messages, Result))
    end).

conversation_memory_does_not_preserve_transient_state_test() ->
    Config = (conversation_memory_test_config(true))#{
        state => #{
            messages => [],
            temporary => initial
        },
        nodes => #{
            update_history => fun(Context) ->
                Messages = maps:get(messages, Context, []),
                Input = maps:get(input, Context),
                #{
                    messages => Messages ++ [Input],
                    temporary => changed
                }
            end
        }
    },

    with_agent(Config, fun(Agent) ->
        {ok, _} = hayata_agent:run(Agent, first),
        await_status(Agent, completed, 100),

        {ok, _} = hayata_agent:run(Agent, second),
        await_status(Agent, completed, 100),

        {ok, Result} = hayata_agent:get_result(Agent),
        ?assertEqual([first, second], maps:get(messages, Result)),
        ?assertEqual(changed, maps:get(temporary, Result))
    end).

tool_loop_is_available_to_node_test() ->
    Config = #{
        id => make_ref(),
        state => #{},
        nodes => #{
            ask_llm_with_tool_loop => fun(Context) ->
                ToolLoop = maps:get(hayata_tool_loop, Context),
                Messages = [
                    #{
                        role => user,
                        content => [
                            #{
                                type => text,
                                text => <<"Hello">>
                            }
                        ]
                    }
                ],
                Request = #{messages => Messages},

                case ToolLoop(Request, [], 3) of
                    {ok, Result} ->
                        #{tool_loop_result => Result};
                    {error, Reason} ->
                        #{tool_loop_error => Reason}
                end
            end
        },
        llm => #{
            adapter => hayata_llm_adapter_mock,
            model => <<"mock-model">>,
            provider_config => #{response_mode => text}
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 ->
                    {next, ask_llm_with_tool_loop, undefined};
                1 ->
                    {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3
    },

    with_agent(Config, fun(Agent) ->
        {ok, _InvocationId} = hayata_agent:run(Agent, start),
        await_status(Agent, completed, 100),
        {ok, Result} = hayata_agent:get_result(Agent),

        ?assertMatch(
            #{
                tool_loop_result := #{
                    response := #{
                        finish_reason := stop
                    },
                    iterations := 1
                }
            },
            Result
        )
    end).
conversation_memory_test_config(Enabled) ->
    #{
        id => make_ref(),
        state => #{messages => [], temporary => initial},
        conversation_memory => Enabled,
        nodes => #{
            update_history => fun(Context) ->
                Messages = maps:get(messages, Context, []),
                Input = maps:get(input, Context),
                #{
                    messages => Messages ++ [Input],
                    temporary => changed
                }
            end
        },
        decision_policy => fun(Context) ->
            case maps:get(step, Context) of
                0 -> {next, update_history, maps:get(input, Context)};
                1 -> {finish, maps:get(state, Context)}
            end
        end,
        max_steps => 3
    }.

await_terminal_status(_Agent, 0) ->
    error(agent_terminal_status_timeout);
await_terminal_status(Agent, Attempts) ->
    Status = maps:get(status, hayata_agent:get_info(Agent)),
    case Status of
        completed ->
            ok;
        {error, _Reason} ->
            ok;
        _ ->
            timer:sleep(10),
            await_terminal_status(Agent, Attempts - 1)
    end.

with_agent(Config, TestFun) ->
    ok = hayata_task_store:ensure_started(),

    {ok, SupPid} = hayata_agent_sup:start_link(Config),
    unlink(SupPid),
    try
        {ok, AgentPid} = hayata_agent_sup:agent(SupPid),
        TestFun(AgentPid)
    after
        exit(SupPid, shutdown)
    end.

await_status(_Agent, _Status, 0) ->
    error(agent_status_timeout);
await_status(Agent, Status, Attempts) ->
    Info = hayata_agent:get_info(Agent),
    case maps:get(status, Info) of
        Status ->
            ok;
        _ ->
            timer:sleep(10),
            await_status(Agent, Status, Attempts - 1)
    end.

await_new_node(_AgentId, _NodeId, _OldPid, 0) ->
    error(node_restart_timeout);
await_new_node(AgentId, NodeId, OldPid, Attempts) ->
    case hayata_node:whereis(AgentId, NodeId) of
        NewPid when is_pid(NewPid), NewPid =/= OldPid ->
            NewPid;
        _ ->
            timer:sleep(10),
            await_new_node(
                AgentId,
                NodeId,
                OldPid,
                Attempts - 1
            )
    end.

await_checkpoint_update(_AgentId, _InvocationId, _PreviousUpdatedAt, 0) ->
    error(checkpoint_update_timeout);
await_checkpoint_update(AgentId, InvocationId, PreviousUpdatedAt, Attempts) ->
    case hayata_task_store:get_invocation(AgentId, InvocationId) of
        {ok, Checkpoint} ->
            case maps:get(updated_at, Checkpoint) =/= PreviousUpdatedAt of
                true ->
                    Checkpoint;
                false ->
                    timer:sleep(10),
                    await_checkpoint_update(
                        AgentId,
                        InvocationId,
                        PreviousUpdatedAt,
                        Attempts - 1
                    )
            end;
        {error, Reason} ->
            error({checkpoint_read_failed, Reason})
    end.

run_options_test_config() ->
    #{
        id => make_ref(),
        state => #{answer => 42},
        nodes => #{
            respond => fun(_State) -> #{} end
        },
        decision_policy => fun(Context) ->
            {finish, maps:get(state, Context)}
        end,
        max_steps => 3
    }.

collect_stream_events(InvocationId, Acc) ->
    receive
        {hayata_agent_event, InvocationId, Event} ->
            collect_stream_events(InvocationId, [Event | Acc]);
        {hayata_agent_result, InvocationId, _Outcome} ->
            lists:reverse(Acc)
    after 3000 ->
        error(stream_events_timeout)
    end.
