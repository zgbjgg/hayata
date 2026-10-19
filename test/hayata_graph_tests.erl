
-module(hayata_graph_tests).

-include_lib("eunit/include/eunit.hrl").

empty_state_test() ->
    with_graph(fun(Graph) ->
        ?assertEqual(#{}, hayata_graph:get_state(Graph))
    end).

initial_state_test() ->
    InitialState = #{
        status => idle,
        nodes => #{}
    },
    with_graph(InitialState, fun(Graph) ->
        ?assertEqual(InitialState, hayata_graph:get_state(Graph))
    end).

replace_state_test() ->
    with_graph(fun(Graph) ->
        NewState = #{status => running},
        ?assertEqual(ok, hayata_graph:replace_state(Graph, NewState)),
        ?assertEqual(NewState, hayata_graph:get_state(Graph))
    end).

update_state_test() ->
    InitialState = #{
        status => idle,
        nodes => #{think => running}
    },
    with_graph(InitialState, fun(Graph) ->
        Updates = #{
            status => running,
            execution_id => 1
        },
        ?assertEqual(ok, hayata_graph:update_state(Graph, Updates)),
        ?assertEqual(
            #{
                status => running,
                nodes => #{think => running},
                execution_id => 1
            },
            hayata_graph:get_state(Graph)
        )
    end).

with_graph(TestFun) ->
    with_graph(#{}, TestFun).

with_graph(InitialState, TestFun) ->
    {ok, Graph} = hayata_graph:start_link(InitialState),
    try
        TestFun(Graph)
    after
        gen_server:stop(Graph)
    end.
