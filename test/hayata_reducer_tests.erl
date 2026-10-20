-module(hayata_reducer_tests).

-include_lib("eunit/include/eunit.hrl").

single_edge_completion_test() ->
    {ok, Reducer, MonitorRef} = start_reducer([edge_01], 1000),

    Reducer ! {
        hayata_reducer_edge_result,
        edge_01,
        execution_01,
        {ok, result_01}
    },

    Result = receive_result(),
    ?assertEqual(completed, maps:get(status, Result)),
    ?assertEqual(
        #{edge_01 => {ok, result_01}},
        maps:get(results, Result)
    ),
    ?assertEqual(#{}, maps:get(errors, Result)),
    ?assertEqual(normal, receive_down(MonitorRef, Reducer)).

multiple_edges_completion_test() ->
    {ok, Reducer, MonitorRef} = start_reducer([edge_01, edge_02], 1000),

    Reducer ! {
        hayata_reducer_edge_result,
        edge_01,
        execution_01,
        {ok, result_01}
    },
    Reducer ! {
        hayata_reducer_edge_result,
        edge_02,
        execution_01,
        {ok, result_02}
    },

    Result = receive_result(),
    ?assertEqual(completed, maps:get(status, Result)),
    ?assertEqual(
        #{
            edge_01 => {ok, result_01},
            edge_02 => {ok, result_02}
        },
        maps:get(results, Result)
    ),
    ?assertEqual(normal, receive_down(MonitorRef, Reducer)).

edge_error_test() ->
    {ok, Reducer, MonitorRef} = start_reducer([edge_01, edge_02], 1000),

    Reducer ! {
        hayata_reducer_edge_result,
        edge_01,
        execution_01,
        {error, task_failed}
    },
    Reducer ! {
        hayata_reducer_edge_result,
        edge_02,
        execution_01,
        {ok, result_02}
    },

    Result = receive_result(),
    ?assertEqual(completed, maps:get(status, Result)),
    ?assertEqual(
        #{edge_01 => task_failed},
        maps:get(errors, Result)
    ),
    ?assertEqual(
        #{edge_02 => {ok, result_02}},
        maps:get(results, Result)
    ),
    ?assertEqual(normal, receive_down(MonitorRef, Reducer)).

duplicate_result_test() ->
    {ok, Reducer, _MonitorRef} = start_reducer([edge_01, edge_02], 1000),

    Reducer ! {
        hayata_reducer_edge_result,
        edge_01,
        execution_01,
        {ok, first_result}
    },
    Reducer ! {
        hayata_reducer_edge_result,
        edge_01,
        execution_01,
        {ok, duplicate_result}
    },
    Reducer ! {
        hayata_reducer_edge_result,
        edge_02,
        execution_01,
        {ok, result_02}
    },

    Result = receive_result(),
    ?assertEqual(
        {ok, first_result},
        maps:get(edge_01, maps:get(results, Result))
    ).

timeout_test() ->
    {ok, Reducer, MonitorRef} = start_reducer([edge_01, edge_02], 10),

    Result = receive_result(),
    ?assertEqual(timed_out, maps:get(status, Result)),
    ?assertEqual(
        [edge_01, edge_02],
        maps:get(pending_edges, Result)
    ),
    ?assertEqual(normal, receive_down(MonitorRef, Reducer)).

empty_execution_test() ->
    {ok, Reducer, MonitorRef} = start_reducer([], 1000),

    Result = receive_result(),
    ?assertEqual(completed, maps:get(status, Result)),
    ?assertEqual([], maps:get(pending_edges, Result)),
    ?assertEqual(normal, receive_down(MonitorRef, Reducer)).

start_reducer(ExpectedEdges, TimeoutMs) ->
    Config = #{
        node_pid => self(),
        execution_id => execution_01,
        expected_edges => ExpectedEdges,
        timeout_ms => TimeoutMs
    },
    case hayata_reducer:start(Config) of
        {ok, Reducer} ->
            MonitorRef = erlang:monitor(process, Reducer),
            Reducer ! {
                hayata_reducer_activate,
                execution_01
            },
            {ok, Reducer, MonitorRef};
        {error, Reason} ->
            {error, Reason}
    end.

receive_result() ->
    receive
        {hayata_reducer_result, execution_01, Result} ->
            Result
    after 1000 ->
        error(reducer_result_timeout)
    end.

receive_down(MonitorRef, Reducer) ->
    receive
        {'DOWN', MonitorRef, process, Reducer, Reason} ->
            Reason
    after 1000 ->
        error(reducer_down_timeout)
    end.
