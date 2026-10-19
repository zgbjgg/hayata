
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


track_edge_test() ->
    with_node(make_ref(), think_01, think, #{status => idle}, [], fun(Node) ->
        EdgePid = spawn(fun() ->
            receive
                stop -> ok
            end
        end),

        {ok, MonitorRef} = hayata_node:track_edge(Node, edge_01, EdgePid),

        Info = hayata_node:get_info(Node),
        ActiveEdges = maps:get(active_edges, Info),

        ?assertMatch(
            #{edge_id := edge_01, pid := EdgePid},
            maps:get(MonitorRef, ActiveEdges)
        ),

        EdgePid ! stop
    end).

edge_down_test() ->
    with_node(make_ref(), think_01, think, #{status => idle}, [], fun(Node) ->
        Parent = self(),
        EdgePid = spawn(fun() ->
            Parent ! {edge_ready, self()},
            receive
                stop -> ok
            end
        end),

        receive
            {edge_ready, EdgePid} -> ok
        after 1000 ->
            error(edge_start_timeout)
        end,

        {ok, _MonitorRef} = hayata_node:track_edge(Node, edge_02, EdgePid),
        EdgePid ! stop,

        ?assertEqual(
            #{status => idle},
            hayata_node:get_state(Node)
        ),

        await_edge_down(Node, 100)
    end).

await_edge_down(_Node, 0) ->
    error(edge_down_timeout);
await_edge_down(Node, Attempts) ->
    Info = hayata_node:get_info(Node),
    ActiveEdges = maps:get(active_edges, Info),
    LastEvent = maps:get(last_edge_event, Info),

    case {map_size(ActiveEdges), LastEvent} of
        {0, #{edge_id := edge_02, reason := normal}} ->
            ok;
        _ ->
            timer:sleep(10),
            await_edge_down(Node, Attempts - 1)
    end.


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
