
-module(hayata_llm_adapter_tests).

-include_lib("eunit/include/eunit.hrl").

capabilities_test() ->
    {ok, Capabilities} =
        hayata_llm_adapter_mock:capabilities(#{}),

    Features = maps:get(features, Capabilities),

    ?assertEqual(true, maps:get(tool_calling, Features)),
    ?assertEqual(true, maps:get(streaming, Features)),
    ?assertEqual(false, maps:get(embeddings, Features)).

generate_returns_normalized_response_test() ->
    Request = valid_request(),

    {ok, Response} =
        hayata_llm_adapter_mock:generate(Request, #{}),

    Message = maps:get(message, Response),

    ?assertEqual(assistant, maps:get(role, Message)),
    ?assertEqual(stop, maps:get(finish_reason, Response)),
    ?assertMatch(
        [#{type := text, text := _}],
        maps:get(content, Message)
    ).

generate_rejects_invalid_request_test() ->
    ?assertEqual(
        {error, #{code => invalid_request}},
        hayata_llm_adapter_mock:generate(#{}, #{})
    ).

stream_emits_events_in_order_test() ->
    Parent = self(),
    Consumer = fun(Event) ->
        Parent ! {llm_event, Event},
        ok
    end,

    {ok, Response} =
        hayata_llm_adapter_mock:generate_stream(
            valid_request(),
            #{},
            Consumer
        ),

    Events = collect_events(5, []),

    ?assertEqual(
        [
            message_started,
            content_delta,
            content_delta,
            message_completed,
            generation_completed
        ],
        [maps:get(type, Event) || Event <- Events]
    ),

    GenerationIds = lists:usort([
        maps:get(generation_id, Event)
        || Event <- Events
    ]),

    ?assertEqual(1, length(GenerationIds)),
    ?assertEqual(stop, maps:get(finish_reason, Response)).

stream_stops_when_consumer_rejects_event_test() ->
    Consumer = fun(_Event) ->
        {error, subscriber_unavailable}
    end,

    ?assertEqual(
        {error, #{
            code => cancelled,
            reason => {
                consumer_rejected_event,
                subscriber_unavailable
            }
        }},
        hayata_llm_adapter_mock:generate_stream(
            valid_request(),
            #{},
            Consumer
        )
    ).

stream_rejects_invalid_request_test() ->
    Consumer = fun(_Event) -> ok end,

    ?assertEqual(
        {error, #{code => invalid_request}},
        hayata_llm_adapter_mock:generate_stream(
            #{},
            #{},
            Consumer
        )
    ).

-spec valid_request() -> hayata_llm_adapter:request().
valid_request() ->
    #{
        model => <<"mock-model">>,
        messages => [
            #{
                role => user,
                content => [
                    #{
                        type => text,
                        text => <<"Hello">>
                    }
                ]
            }
        ]
    }.

-spec collect_events(
    non_neg_integer(),
    [hayata_llm_adapter:stream_event()]
) -> [hayata_llm_adapter:stream_event()].
collect_events(0, Acc) ->
    lists:reverse(Acc);
collect_events(Count, Acc) ->
    receive
        {llm_event, Event} ->
            collect_events(Count - 1, [Event | Acc])
    after 1000 ->
        error({missing_stream_events, Count})
    end.
