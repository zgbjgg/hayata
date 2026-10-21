-module(hayata_agent_sup_tests).

-include_lib("eunit/include/eunit.hrl").

starts_agent_infrastructure_test() ->
    AgentId = make_ref(),
    Config = #{
        id => AgentId,
        nodes => #{
            think => fun(_State) -> #{} end,
            respond => fun(_State) -> #{} end
        }
    },

    with_agent_sup(Config, fun(SupPid) ->
        {ok, NodeSupPid} = hayata_agent_sup:node_supervisor(SupPid),
        ?assert(is_process_alive(NodeSupPid)),
        ?assert(is_pid(hayata_node:whereis(AgentId, think))),
        ?assert(is_pid(hayata_node:whereis(AgentId, respond)))
    end).

agents_have_isolated_nodes_test() ->
    AgentA = make_ref(),
    AgentB = make_ref(),
    NodeFun = fun(_State) -> #{} end,

    ConfigA = #{id => AgentA, nodes => #{think => NodeFun}},
    ConfigB = #{id => AgentB, nodes => #{think => NodeFun}},

    with_agent_sup(ConfigA, fun(_SupA) ->
        with_agent_sup(ConfigB, fun(_SupB) ->
            NodeA = hayata_node:whereis(AgentA, think),
            NodeB = hayata_node:whereis(AgentB, think),

            ?assert(is_pid(NodeA)),
            ?assert(is_pid(NodeB)),
            ?assertNotEqual(NodeA, NodeB)
        end)
    end).

stops_and_restarts_node_test() ->
    AgentId = make_ref(),
    Config = #{
        id => AgentId,
        nodes => #{think => fun(_State) -> #{} end}
    },

    with_agent_sup(Config, fun(SupPid) ->
        {ok, NodeSupPid} = hayata_agent_sup:node_supervisor(SupPid),
        OriginalPid = hayata_node:whereis(AgentId, think),

        ?assertEqual(ok, hayata_node_sup:stop_node(NodeSupPid, think)),
        ?assertEqual(undefined, hayata_node:whereis(AgentId, think)),

        {ok, NewPid} = hayata_node_sup:start_node(
            NodeSupPid,
            think,
            #{},
            [],
            AgentId
        ),

        ?assert(is_pid(NewPid)),
        ?assertNotEqual(OriginalPid, NewPid),
        ?assertEqual(NewPid, hayata_node:whereis(AgentId, think))
    end).

rejects_invalid_config_test() ->
    ?assertEqual(
        {error, invalid_config},
        hayata_agent_sup:start_link(#{nodes => #{}})
    ).

rejects_empty_catalog_test() ->
    ?assertEqual(
        {error, empty_node_catalog},
        hayata_agent_sup:start_link(#{id => empty_agent, nodes => #{}})
    ).

rejects_invalid_node_definition_test() ->
    ?assertEqual(
        {error, {invalid_node_definition, think}},
        hayata_agent_sup:start_link(#{
            id => invalid_agent,
            nodes => #{think => not_a_function}
        })
    ).

with_agent_sup(Config, TestFun) ->
    {ok, SupPid} = hayata_agent_sup:start_link(Config),
    unlink(SupPid),
    try
        TestFun(SupPid)
    after
        exit(SupPid, shutdown),
        receive
            {'EXIT', SupPid, _Reason} -> ok
        after 0 ->
            ok
        end
    end.
