
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
            hayata_agent:run(Agent, hello, self()),

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
            hayata_agent:run(Agent, hello, self()),

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
        Result = hayata_agent:run(Agent, hello, self()),

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
        {error, invalid_subscription_pid},
        hayata_agent:run(self(), hello, not_a_pid)
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
            hayata_agent:run(Agent, first, self()),

        receive
            {hayata_agent_result, FirstInvocation, {ok, first}} ->
                ok
        after 1000 ->
            error(first_invocation_notification_timeout)
        end,

        {ok, SecondInvocation} =
            hayata_agent:run(Agent, second, self()),

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
                       result := #{answer := 42}}}
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
                     #{agent_id := AgentId, invocation_id := _InvocationId}},
                    {hayata_telemetry_event,
                     [hayata, agent, invocation, exception],
                     #{duration := Duration},
                     #{agent_id := AgentId, reason := test_failure}}
                ] when is_integer(Duration),
                Events
            )
        end)
    after
        ok = hayata_test_telemetry:detach(HandlerId)
    end.

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
