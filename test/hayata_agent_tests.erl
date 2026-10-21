
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
