
-module(hayata_tool_loop_tests).

-include_lib("eunit/include/eunit.hrl").

run_returns_final_response_test() ->
    LLM = fun(_Request) ->
        {ok, text_response(<<"Hello!">>)}
    end,

    {ok, Result} = hayata_tool_loop:run(
        LLM,
        request(),
        [],
        5
    ),

    ?assertEqual(
        <<"Hello!">>,
        response_text(maps:get(response, Result))
    ),
    ?assertEqual(1, maps:get(iterations, Result)).

run_executes_tool_and_continues_test() ->
    Parent = self(),

    LLM = fun(Request) ->
        case maps:get(messages, Request) of
            [_UserMessage] ->
                {ok, tool_call_response()};

            Messages ->
                Parent ! {continued_messages, Messages},
                {ok, text_response(<<"It is 22 degrees.">>)}
        end
    end,

    {ok, Result} = hayata_tool_loop:run(
        LLM,
        request(),
        [weather_tool()],
        5
    ),

    ?assertEqual(
        <<"It is 22 degrees.">>,
        response_text(maps:get(response, Result))
    ),
    ?assertEqual(2, maps:get(iterations, Result)),

    receive
        {continued_messages, Messages} ->
            ?assert(
                lists:any(
                    fun(Message) ->
                        maps:get(role, Message, undefined) =:= tool
                    end,
                    Messages
                )
            )
    after 1000 ->
        error(missing_tool_result_message)
    end.

run_rejects_invalid_max_iterations_test() ->
    LLM = fun(_Request) ->
        {ok, text_response(<<"Hello!">>)}
    end,

    ?assertEqual(
        {error, invalid_max_iterations},
        hayata_tool_loop:run(
            LLM,
            request(),
            [],
            0
        )
    ).

run_stops_when_max_iterations_is_reached_test() ->
    LLM = fun(_Request) ->
        {ok, tool_call_response()}
    end,

    {error, max_iterations_reached} =
        hayata_tool_loop:run(
            LLM,
            request(),
            [weather_tool()],
            1
        ).

tool_result_is_valid_json_test() ->
    Message = #{
        role => tool,
        tool_call_id => <<"call_123">>,
        name => <<"get_weather">>,
        content => [
            #{
                type => text,
                text => iolist_to_binary(
                    json:encode(#{temperature => 22})
                )
            }
        ]
    },

    [Content] = maps:get(content, Message),

    ?assertEqual(
        #{<<"temperature">> => 22},
        json:decode(maps:get(text, Content))
    ).

run_executes_multiple_tools_in_order_test() ->
    Parent = self(),

    LLM = fun(Request) ->
        Messages = maps:get(messages, Request),

        case length(Messages) of
            1 ->
                {ok, multiple_tool_calls_response()};
            _ ->
                Parent ! {tool_loop_messages, Messages},
                {ok, text_response(<<"Weather and forecast retrieved.">>)}
        end
    end,

    Tools = [
        weather_tool(),
        forecast_tool()
    ],

    {ok, Result} = hayata_tool_loop:run(
        LLM,
        request(),
        Tools,
        5
    ),

    ?assertEqual(2, maps:get(iterations, Result)),

    receive
        {tool_loop_messages, Messages} ->
            ?assertEqual(4, length(Messages)),

            [_UserMessage, AssistantMessage, FirstTool, SecondTool] =
                Messages,

            ?assertEqual(
                assistant,
                maps:get(role, AssistantMessage)
            ),

            ?assertEqual(
                <<"call_weather">>,
                maps:get(tool_call_id, FirstTool)
            ),
            ?assertEqual(
                <<"get_weather">>,
                maps:get(name, FirstTool)
            ),

            ?assertEqual(
                <<"call_forecast">>,
                maps:get(tool_call_id, SecondTool)
            ),
            ?assertEqual(
                <<"get_forecast">>,
                maps:get(name, SecondTool)
            ),

            [FirstContent] = maps:get(content, FirstTool),
            [SecondContent] = maps:get(content, SecondTool),

            ?assertEqual(
                #{<<"temperature">> => 22},
                json:decode(maps:get(text, FirstContent))
            ),
            ?assertEqual(
                #{<<"forecast">> => <<"sunny">>},
                json:decode(maps:get(text, SecondContent))
            )
    after 1000 ->
        error(missing_tool_loop_messages)
    end.

run_recovers_from_unknown_tool_test() ->
    Parent = self(),

    LLM = fun(Request) ->
        Messages = maps:get(messages, Request),

        case length(Messages) of
            1 ->
                {ok, unknown_tool_call_response()};
            _ ->
                Parent ! {recovery_messages, Messages},
                {ok, text_response(<<"I could not retrieve the forecast.">>)}
        end
    end,

    {ok, Result} = hayata_tool_loop:run(
        LLM,
        request(),
        [weather_tool()],
        5
    ),

    ?assertEqual(2, maps:get(iterations, Result)),

    receive
        {recovery_messages, Messages} ->
            [_UserMessage, _AssistantMessage, ToolMessage] = Messages,

            ?assertEqual(tool, maps:get(role, ToolMessage)),
            ?assertEqual(
                <<"call_unknown">>,
                maps:get(tool_call_id, ToolMessage)
            ),

            [Content] = maps:get(content, ToolMessage),
            Error = json:decode(maps:get(text, Content)),

            ?assertEqual(
                <<"tool_execution_failed">>,
                maps:get(<<"error">>, Error)
            )
    after 1000 ->
        error(missing_unknown_tool_result)
    end.

run_recovers_from_invalid_tool_arguments_test() ->
    Parent = self(),

    LLM = fun(Request) ->
        Messages = maps:get(messages, Request),

        case length(Messages) of
            1 ->
                {ok, invalid_tool_arguments_response()};
            _ ->
                Parent ! {recovery_messages, Messages},
                {ok, text_response(<<"The weather request was invalid.">>)}
        end
    end,

    {ok, Result} = hayata_tool_loop:run(
        LLM,
        request(),
        [weather_tool()],
        5
    ),

    ?assertEqual(2, maps:get(iterations, Result)),

    receive
        {recovery_messages, Messages} ->
            [_UserMessage, _AssistantMessage, ToolMessage] = Messages,

            ?assertEqual(tool, maps:get(role, ToolMessage)),
            ?assertEqual(
                <<"call_invalid_arguments">>,
                maps:get(tool_call_id, ToolMessage)
            ),

            [Content] = maps:get(content, ToolMessage),
            Error = json:decode(maps:get(text, Content)),

            ?assertEqual(
                <<"tool_execution_failed">>,
                maps:get(<<"error">>, Error)
            )
    after 1000 ->
        error(missing_invalid_arguments_result)
    end.

run_recovers_from_tool_handler_exception_test() ->
    Parent = self(),

    FailingTool = #{
        name => <<"get_weather">>,
        description => <<"Gets the current weather for a city.">>,
        parameters => #{
            type => object,
            properties => #{
                city => #{type => string}
            },
            required => [<<"city">>]
        },
        handler => fun(_Arguments) ->
            erlang:error(weather_service_unavailable)
        end
    },

    LLM = fun(Request) ->
        Messages = maps:get(messages, Request),

        case length(Messages) of
            1 ->
                {ok, tool_call_response()};
            _ ->
                Parent ! {recovery_messages, Messages},
                {ok, text_response(<<"Weather service is unavailable.">>)}
        end
    end,

    {ok, Result} = hayata_tool_loop:run(
        LLM,
        request(),
        [FailingTool],
        5
    ),

    ?assertEqual(2, maps:get(iterations, Result)),

    receive
        {recovery_messages, Messages} ->
            [_UserMessage, _AssistantMessage, ToolMessage] = Messages,

            ?assertEqual(tool, maps:get(role, ToolMessage)),
            ?assertEqual(
                <<"call_123">>,
                maps:get(tool_call_id, ToolMessage)
            ),

            [Content] = maps:get(content, ToolMessage),
            Error = json:decode(maps:get(text, Content)),

            ?assertEqual(
                <<"tool_execution_failed">>,
                maps:get(<<"error">>, Error)
            )
    after 1000 ->
        error(missing_handler_exception_result)
    end.

run_does_not_execute_tool_at_iteration_limit_test() ->
    Parent = self(),

    Tool = #{
        name => <<"get_weather">>,
        description => <<"Gets the current weather for a city.">>,
        parameters => #{
            type => object,
            properties => #{
                city => #{type => string}
            },
            required => [<<"city">>]
        },
        handler => fun(_Arguments) ->
            Parent ! tool_executed,
            {ok, #{temperature => 22}}
        end
    },

    LLM = fun(_Request) ->
        {ok, tool_call_response()}
    end,

    Result = hayata_tool_loop:run(
        LLM,
        request(),
        [Tool],
        1
    ),

    ?assertEqual(
        {error, max_iterations_reached},
        Result
    ),

    receive
        tool_executed ->
            error(tool_executed_after_iteration_limit)
    after 0 ->
        ok
    end.

run_propagates_llm_provider_error_test() ->
    Parent = self(),

    Tool = #{
        name => <<"get_weather">>,
        description => <<"Gets the current weather for a city.">>,
        parameters => #{
            type => object,
            properties => #{
                city => #{type => string}
            },
            required => [<<"city">>]
        },
        handler => fun(_Arguments) ->
            Parent ! tool_executed,
            {ok, #{temperature => 22}}
        end
    },

    LLM = fun(_Request) ->
        {error, provider_unavailable}
    end,

    Result = hayata_tool_loop:run(
        LLM,
        request(),
        [Tool],
        5
    ),

    ?assertEqual(
        {error, {llm_failed, provider_unavailable}},
        Result
    ),

    receive
        tool_executed ->
            error(tool_executed_after_provider_failure)
    after 0 ->
        ok
    end.

run_rejects_invalid_finish_reason_test() ->
    LLM = fun(_Request) ->
        {ok, #{
            message => #{
                role => assistant,
                content => [
                    #{
                        type => text,
                        text => <<"Hello">>
                    }
                ]
            },
            finish_reason => unknown_reason
        }}
    end,

    Request = #{
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
    },

    ?assertEqual(
        {error, {llm_failed, invalid_llm_response}},
        hayata_tool_loop:run(LLM, Request, [], 3)
    ).

run_rejects_tool_calls_finish_reason_without_calls_test() ->
    LLM = fun(_Request) ->
        {ok, #{
            message => #{
                role => assistant,
                content => [
                    #{
                        type => text,
                        text => <<"No tool calls were returned.">>
                    }
                ]
            },
            finish_reason => tool_calls
        }}
    end,

    ?assertEqual(
        {error, {llm_failed, invalid_llm_response}},
        hayata_tool_loop:run(LLM, request(), [], 3)
    ).

run_rejects_tool_calls_with_stop_finish_reason_test() ->
    LLM = fun(_Request) ->
        {ok, #{
            message => #{
                role => assistant,
                content => [],
                tool_calls => [
                    #{
                        id => <<"call_123">>,
                        name => <<"get_weather">>,
                        arguments => #{city => <<"Mexico City">>}
                    }
                ]
            },
            finish_reason => stop
        }}
    end,

    ?assertEqual(
        {error, {llm_failed, invalid_llm_response}},
        hayata_tool_loop:run(
            LLM,
            request(),
            [weather_tool()],
            3
        )
    ).

run_recovers_from_non_serializable_tool_result_test() ->
    Parent = self(),

    Tool = #{
        name => <<"get_weather">>,
        description => <<"Gets the current weather for a city.">>,
        parameters => #{
            type => object,
            properties => #{
                city => #{type => string}
            },
            required => [<<"city">>]
        },
        handler => fun(_Arguments) ->
            {ok, self()}
        end
    },

    LLM = fun(Request) ->
        Messages = maps:get(messages, Request),

        case length(Messages) of
            1 ->
                {ok, tool_call_response()};
            _ ->
                Parent ! {recovery_messages, Messages},
                {ok, text_response(<<"Tool result handled.">>)}
        end
    end,

    {ok, Result} = hayata_tool_loop:run(
        LLM,
        request(),
        [Tool],
        5
    ),

    ?assertEqual(2, maps:get(iterations, Result)),

    receive
        {recovery_messages, Messages} ->
            [_UserMessage, _AssistantMessage, ToolMessage] = Messages,
            [Content] = maps:get(content, ToolMessage),
            EncodedResult = maps:get(text, Content),

            ?assertEqual(
                #{<<"error">> => <<"tool_result_not_serializable">>},
                json:decode(EncodedResult)
            )
    after 1000 ->
        error(missing_non_serializable_tool_result)
    end.

run_propagates_llm_error_after_tool_execution_test() ->
    Parent = self(),

    Tool = #{
        name => <<"get_weather">>,
        description => <<"Gets the current weather for a city.">>,
        parameters => #{
            type => object,
            properties => #{
                city => #{type => string}
            },
            required => [<<"city">>]
        },
        handler => fun(_Arguments) ->
            Parent ! tool_executed_after_first_response,
            {ok, #{temperature => 22}}
        end
    },

    LLM = fun(Request) ->
        case length(maps:get(messages, Request)) of
            1 ->
                {ok, tool_call_response()};
            _ ->
                {error, provider_unavailable}
        end
    end,

    Result = hayata_tool_loop:run(
        LLM,
        request(),
        [Tool],
        5
    ),

    ?assertEqual(
        {error, {llm_failed, provider_unavailable}},
        Result
    ),

    receive
        tool_executed_after_first_response ->
            ok
    after 1000 ->
        error(tool_was_not_executed)
    end.

run_preserves_assistant_content_with_tool_calls_test() ->
    Parent = self(),

    AssistantMessage = #{
        role => assistant,
        content => [
            #{
                type => text,
                text => <<"I will check the current weather.">>
            }
        ],
        tool_calls => [
            #{
                id => <<"call_123">>,
                name => <<"get_weather">>,
                arguments => #{city => <<"Mexico City">>}
            }
        ]
    },

    LLM = fun(Request) ->
        case maps:get(messages, Request) of
            [_UserMessage] ->
                {ok, #{
                    message => AssistantMessage,
                    finish_reason => tool_calls
                }};
            Messages ->
                Parent ! {messages_after_tool_call, Messages},
                {ok, text_response(<<"It is 22 degrees.">>)}
        end
    end,

    {ok, Result} = hayata_tool_loop:run(
        LLM,
        request(),
        [weather_tool()],
        5
    ),

    ?assertEqual(2, maps:get(iterations, Result)),
    ?assertEqual(
        <<"It is 22 degrees.">>,
        response_text(maps:get(response, Result))
    ),

    receive
        {messages_after_tool_call, Messages} ->
            [_UserMessage, PreservedAssistant, ToolMessage] = Messages,

            ?assertEqual(assistant, maps:get(role, PreservedAssistant)),
            ?assertEqual(
                <<"I will check the current weather.">>,
                response_text(#{message => PreservedAssistant})
            ),
            ?assertEqual(
                <<"call_123">>,
                maps:get(tool_call_id, ToolMessage)
            )
    after 1000 ->
        error(messages_after_tool_call_not_received)
    end.

run_rejects_mixed_valid_and_invalid_tool_calls_test() ->
    Parent = self(),

    Tool = #{
        name => <<"get_weather">>,
        description => <<"Gets the current weather for a city.">>,
        parameters => #{
            type => object,
            properties => #{city => #{type => string}},
            required => [<<"city">>]
        },
        handler => fun(_Arguments) ->
            Parent ! tool_was_executed,
            {ok, #{temperature => 22}}
        end
    },

    Response = #{
        message => #{
            role => assistant,
            content => [],
            tool_calls => [
                #{
                    id => <<"call_valid">>,
                    name => <<"get_weather">>,
                    arguments => #{city => <<"Puebla">>}
                },
                #{
                    id => <<>>,
                    name => <<"get_weather">>,
                    arguments => #{city => <<"Mexico City">>}
                }
            ]
        },
        finish_reason => tool_calls
    },

    LLM = fun(_Request) -> {ok, Response} end,

    ?assertEqual(
        {error, {llm_failed, invalid_llm_response}},
        hayata_tool_loop:run(LLM, request(), [Tool], 5)
    ),

    receive
        tool_was_executed ->
            error(invalid_tool_call_was_partially_executed)
    after 100 ->
        ok
    end.

run_rejects_unexpected_llm_response_shapes_test() ->
    InvalidResponses = [
        unexpected_response,
        {ok, not_a_map},
        {ok, #{}},
        {ok, #{
            message => #{
                role => user,
                content => []
            },
            finish_reason => stop
        }}
    ],

    lists:foreach(
        fun(LLMResult) ->
            LLM = fun(_Request) -> LLMResult end,

            ?assertEqual(
                {error, {llm_failed, invalid_llm_response}},
                hayata_tool_loop:run(LLM, request(), [], 3)
            )
        end,
        InvalidResponses
    ).

run_recovers_from_explicit_tool_error_test() ->
    Parent = self(),

    Tool = #{
        name => <<"get_weather">>,
        description => <<"Gets the current weather for a city.">>,
        parameters => #{
            type => object,
            properties => #{city => #{type => string}},
            required => [<<"city">>]
        },
        handler => fun(_Arguments) ->
            {error, weather_service_unavailable}
        end
    },

    LLM = fun(Request) ->
        case length(maps:get(messages, Request)) of
            1 ->
                {ok, tool_call_response()};
            _ ->
                Parent ! {messages_after_tool_error,
                    maps:get(messages, Request)},
                {ok, text_response(<<"Weather is temporarily unavailable.">>)}
        end
    end,

    {ok, Result} = hayata_tool_loop:run(
        LLM,
        request(),
        [Tool],
        5
    ),

    ?assertEqual(2, maps:get(iterations, Result)),
    ?assertEqual(
        <<"Weather is temporarily unavailable.">>,
        response_text(maps:get(response, Result))
    ),

    receive
        {messages_after_tool_error, Messages} ->
            [_UserMessage, _AssistantMessage, ToolMessage] = Messages,
            [Content] = maps:get(content, ToolMessage),
            Error = json:decode(maps:get(text, Content)),

            ?assertEqual(
                #{<<"error">> => <<"tool_execution_failed">>},
                Error
            )
    after 1000 ->
        error(missing_tool_error_result)
    end.

run_handles_llm_callback_exception_test() ->
    LLM = fun(_Request) ->
        erlang:error(provider_crashed)
    end,

    ?assertEqual(
        {error, {llm_failed, llm_call_failed}},
        hayata_tool_loop:run(LLM, request(), [], 3)
    ).

run_rejects_unexpected_llm_return_value_test() ->
    InvalidReturns = [
        ok,
        undefined,
        {ok, <<"not a response map">>},
        {unexpected, response}
    ],

    lists:foreach(
        fun(InvalidReturn) ->
            LLM = fun(_Request) -> InvalidReturn end,

            ?assertEqual(
                {error, {llm_failed, invalid_llm_response}},
                hayata_tool_loop:run(LLM, request(), [], 3)
            )
        end,
        InvalidReturns
    ).

run_rejects_malformed_response_fields_test() ->
    InvalidResponses = [
        #{
            message => #{
                role => assistant,
                content => <<"not a list">>
            },
            finish_reason => stop
        },
        #{
            message => #{
                role => assistant,
                content => []
            },
            finish_reason => <<"stop">>
        }
    ],

    lists:foreach(
        fun(Response) ->
            LLM = fun(_Request) -> {ok, Response} end,

            ?assertEqual(
                {error, {llm_failed, invalid_llm_response}},
                hayata_tool_loop:run(LLM, request(), [], 3)
            )
        end,
        InvalidResponses
    ).

-spec request() -> map().
request() ->
    #{
        model => <<"mock-model">>,
        messages => [
            #{
                role => user,
                content => [
                    #{type => text, text => <<"What is the weather?">>}
                ]
            }
        ]
    }.

-spec text_response(binary()) -> map().
text_response(Text) ->
    #{
        message => #{
            role => assistant,
            content => [
                #{type => text, text => Text}
            ]
        },
        finish_reason => stop
    }.

-spec tool_call_response() -> map().
tool_call_response() ->
    #{
        message => #{
            role => assistant,
            content => [],
            tool_calls => [
                #{
                    id => <<"call_123">>,
                    name => <<"get_weather">>,
                    arguments => #{city => <<"Mexico City">>}
                }
            ]
        },
        finish_reason => tool_calls
    }.

-spec response_text(map()) -> binary().
response_text(Response) ->
    Message = maps:get(message, Response),
    [Block] = maps:get(content, Message),
    maps:get(text, Block).

-spec weather_tool() -> map().
weather_tool() ->
    #{
        name => <<"get_weather">>,
        description => <<"Gets the current weather for a city.">>,
        parameters => #{
            type => object,
            properties => #{
                city => #{
                    type => string,
                    description => <<"City to look up.">>
                }
            },
            required => [<<"city">>]
        },
        handler => fun(_Arguments) ->
            {ok, #{temperature => 22}}
        end
    }.


-spec multiple_tool_calls_response() -> map().
multiple_tool_calls_response() ->
    #{
        message => #{
            role => assistant,
            content => [],
            tool_calls => [
                #{
                    id => <<"call_weather">>,
                    name => <<"get_weather">>,
                    arguments => #{city => <<"Mexico City">>}
                },
                #{
                    id => <<"call_forecast">>,
                    name => <<"get_forecast">>,
                    arguments => #{city => <<"Mexico City">>}
                }
            ]
        },
        finish_reason => tool_calls
    }.

-spec forecast_tool() -> map().
forecast_tool() ->
    #{
        name => <<"get_forecast">>,
        description => <<"Gets the forecast for a city.">>,
        parameters => #{
            type => object,
            properties => #{
                city => #{
                    type => string,
                    description => <<"City to look up.">>
                }
            },
            required => [<<"city">>]
        },
        handler => fun(_Arguments) ->
            {ok, #{forecast => <<"sunny">>}}
        end
    }.


-spec unknown_tool_call_response() -> map().
unknown_tool_call_response() ->
    #{
        message => #{
            role => assistant,
            content => [],
            tool_calls => [
                #{
                    id => <<"call_unknown">>,
                    name => <<"get_forecast">>,
                    arguments => #{city => <<"Mexico City">>}
                }
            ]
        },
        finish_reason => tool_calls
    }.

-spec invalid_tool_arguments_response() -> map().
invalid_tool_arguments_response() ->
    #{
        message => #{
            role => assistant,
            content => [],
            tool_calls => [
                #{
                    id => <<"call_invalid_arguments">>,
                    name => <<"get_weather">>,
                    arguments => #{
                        city => 123
                    }
                }
            ]
        },
        finish_reason => tool_calls
    }.
