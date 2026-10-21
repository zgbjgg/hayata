
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
