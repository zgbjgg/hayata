
-module(hayata_stream_tests).

-include_lib("eunit/include/eunit.hrl").

flush_sends_event_test() ->
    InvocationId = make_ref(),
    Data = #{
        node_id => respond,
        execution_id => make_ref()
    },

    ?assertEqual(
        ok,
        hayata_stream:flush(
            self(),
            InvocationId,
            node_started,
            1,
            Data
        )
    ),

    receive
        {hayata_agent_event, InvocationId, Event} ->
            ?assertEqual(
                #{
                    type => node_started,
                    sequence => 1,
                    data => Data
                },
                Event
            )
    after 1000 ->
        error(stream_event_timeout)
    end.

flush_preserves_sequence_test() ->
    InvocationId = make_ref(),

    ok = hayata_stream:flush(
        self(),
        InvocationId,
        invocation_started,
        1,
        #{}
    ),
    ok = hayata_stream:flush(
        self(),
        InvocationId,
        node_started,
        2,
        #{node_id => work}
    ),

    receive
        {hayata_agent_event, InvocationId, FirstEvent} ->
            ?assertEqual(invocation_started, maps:get(type, FirstEvent)),
            ?assertEqual(1, maps:get(sequence, FirstEvent))
    after 1000 ->
        error(first_stream_event_timeout)
    end,

    receive
        {hayata_agent_event, InvocationId, SecondEvent} ->
            ?assertEqual(node_started, maps:get(type, SecondEvent)),
            ?assertEqual(2, maps:get(sequence, SecondEvent))
    after 1000 ->
        error(second_stream_event_timeout)
    end.

flush_preserves_event_data_test() ->
    InvocationId = make_ref(),
    Data = #{
        node_id => process_data,
        metadata => #{attempt => 3}
    },

    ok = hayata_stream:flush(
        self(),
        InvocationId,
        node_completed,
        7,
        Data
    ),

    receive
        {hayata_agent_event, InvocationId, Event} ->
            ?assertEqual(Data, maps:get(data, Event)),
            ?assertEqual(7, maps:get(sequence, Event))
    after 1000 ->
        error(stream_event_timeout)
    end.
