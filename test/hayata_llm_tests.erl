
-module(hayata_llm_tests).

-include_lib("eunit/include/eunit.hrl").

validate_config_test() ->
    ?assertEqual(ok, hayata_llm:validate_config(config())).

validate_config_rejects_missing_adapter_test() ->
    ?assertEqual(
        {error, invalid_config},
        hayata_llm:validate_config(#{
            model => <<"mock-model">>
        })
    ).

validate_config_rejects_empty_model_test() ->
    ?assertEqual(
        {error, invalid_config},
        hayata_llm:validate_config(#{
            adapter => hayata_llm_adapter_mock,
            model => <<>>
        })
    ).

capabilities_returns_adapter_capabilities_test() ->
    {ok, Capabilities} = hayata_llm:capabilities(config()),

    Features = maps:get(features, Capabilities),

    ?assertEqual(true, maps:get(tool_calling, Features)),
    ?assertEqual(true, maps:get(streaming, Features)).

generate_uses_configured_model_test() ->
    {ok, Response} = hayata_llm:generate(
        config(),
        valid_request()
    ),

    ?assertEqual(
        assistant,
        maps:get(role, maps:get(message, Response))
    ).

generate_rejects_model_mismatch_test() ->
    Request = (valid_request())#{
        model => <<"different-model">>
    },

    ?assertEqual(
        {error, #{
            code => invalid_request,
            reason => model_mismatch
        }},
        hayata_llm:generate(config(), Request)
    ).

generate_rejects_missing_messages_test() ->
    ?assertEqual(
        {error, #{
            code => invalid_request,
            reason => invalid_messages
        }},
        hayata_llm:generate(config(), #{})
    ).

generate_stream_forwards_events_test() ->
    Parent = self(),

    Consumer = fun(Event) ->
        Parent ! {llm_event, Event},
        ok
    end,

    {ok, Response} = hayata_llm:generate_stream(
        config(),
        valid_request(),
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

    ?assertEqual(
        stop,
        maps:get(finish_reason, Response)
    ).

generate_stream_propagates_consumer_error_test() ->
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
        hayata_llm:generate_stream(
            config(),
            valid_request(),
            Consumer
        )
    ).

generate_stream_rejects_invalid_consumer_test() ->
    ?assertEqual(
        {error, #{code => invalid_request}},
        hayata_llm:generate_stream(
            config(),
            valid_request(),
            invalid_consumer
        )
    ).

generate_preserves_tool_calls_test() ->
    Config = (config())#{
        provider_config => #{response_mode => tool_call}
    },

    {ok, Response} = hayata_llm:generate(Config, valid_request()),

    ?assertEqual(tool_calls, maps:get(finish_reason, Response)),

    Message = maps:get(message, Response),
    [ToolCall] = maps:get(tool_calls, Message),

    ?assertEqual(<<"call_123">>, maps:get(id, ToolCall)),
    ?assertEqual(<<"get_weather">>, maps:get(name, ToolCall)),
    ?assertEqual(
        #{city => <<"Mexico City">>},
        maps:get(arguments, ToolCall)
    ).

generate_rejects_invalid_tool_calls_test() ->
    Config = (config())#{
        provider_config => #{response_mode => invalid_tool_call}
    },

    ?assertEqual(
        {error, #{code => invalid_response}},
        hayata_llm:generate(Config, valid_request())
    ).

generate_rejects_missing_message_test() ->
    Config = (config())#{
        provider_config => #{response_mode => missing_message}
    },

    ?assertEqual(
        {error, #{code => invalid_response}},
        hayata_llm:generate(Config, valid_request())
    ).

-spec config() -> hayata_llm:config().
config() ->
    #{
        adapter => hayata_llm_adapter_mock,
        model => <<"mock-model">>,
        provider_config => #{}
    }.

-spec valid_request() -> map().
valid_request() ->
    #{
        messages => [
            #{
                role => user,
                content => [
                    #{type => text, text => <<"Hello">>}
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
