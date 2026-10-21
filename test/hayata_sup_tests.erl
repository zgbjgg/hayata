
-module(hayata_sup_tests).

-include_lib("eunit/include/eunit.hrl").

start_agent_test() ->
    with_hayata_sup(fun() ->
        Config = agent_config(make_ref()),
        {ok, AgentSupPid} = hayata_sup:start_agent(Config),

        ?assert(is_process_alive(AgentSupPid)),
        ?assertEqual(
            {ok, AgentSupPid},
            find_agent(AgentSupPid)
        )
    end).

starts_multiple_agents_test() ->
    with_hayata_sup(fun() ->
        {ok, AgentSupA} = hayata_sup:start_agent(
            agent_config(make_ref())
        ),
        {ok, AgentSupB} = hayata_sup:start_agent(
            agent_config(make_ref())
        ),

        ?assertNotEqual(AgentSupA, AgentSupB),
        ?assert(is_process_alive(AgentSupA)),
        ?assert(is_process_alive(AgentSupB)),

        Agents = hayata_sup:agents(),
        ?assert(lists:keymember(AgentSupA, 2, Agents)),
        ?assert(lists:keymember(AgentSupB, 2, Agents))
    end).

stop_agent_test() ->
    with_hayata_sup(fun() ->
        {ok, AgentSupA} = hayata_sup:start_agent(
            agent_config(make_ref())
        ),
        {ok, AgentSupB} = hayata_sup:start_agent(
            agent_config(make_ref())
        ),

        ?assertEqual(ok, hayata_sup:stop_agent(AgentSupA)),
        ?assertNot(is_process_alive(AgentSupA)),
        ?assert(is_process_alive(AgentSupB)),

        Agents = hayata_sup:agents(),
        ?assertNot(lists:keymember(AgentSupA, 2, Agents)),
        ?assert(lists:keymember(AgentSupB, 2, Agents))
    end).

stop_unknown_agent_test() ->
    with_hayata_sup(fun() ->
        ?assertEqual(
            {error, agent_not_found},
            hayata_sup:stop_agent(spawn(fun() -> ok end))
        )
    end).

rejects_invalid_config_test() ->
    with_hayata_sup(fun() ->
        ?assertEqual(
            {error, invalid_config},
            hayata_sup:start_agent(not_a_map)
        )
    end).

agents_when_supervisor_not_started_test() ->
    case whereis(hayata_sup) of
        undefined ->
            ?assertEqual(
                {error, not_started},
                hayata_sup:agents()
            );
        _Pid ->
            ok
    end.

agent_config(AgentId) ->
    #{
        id => AgentId,
        nodes => #{
            think => fun(_State) -> #{} end
        }
    }.

find_agent(AgentSupPid) ->
    case lists:keymember(
        AgentSupPid,
        2,
        hayata_sup:agents()
    ) of
        true ->
            {ok, AgentSupPid};
        false ->
            {error, agent_not_found}
    end.

with_hayata_sup(TestFun) ->
    case whereis(hayata_sup) of
        undefined ->
            {ok, SupPid} = hayata_sup:start_link(),
            unlink(SupPid),
            try
                TestFun()
            after
                exit(SupPid, shutdown),
                wait_for_exit(SupPid)
            end;
        _SupPid ->
            TestFun()
    end.

wait_for_exit(SupPid) ->
    MonitorRef = erlang:monitor(process, SupPid),
    receive
        {'DOWN', MonitorRef, process, SupPid, _Reason} ->
            ok
    after 5000 ->
        erlang:demonitor(MonitorRef, [flush]),
        error(supervisor_shutdown_timeout)
    end.
