
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
