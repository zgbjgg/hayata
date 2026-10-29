
-module(hayata_openai_tests).

-include_lib("eunit/include/eunit.hrl").

openai_streaming_capability_test() ->
    {ok, Capabilities} = hayata_openai:capabilities(#{}),
    Features = maps:get(features, Capabilities),

    ?assertEqual(true, maps:get(streaming, Features)).

missing_api_key_test() ->
    ?assertEqual(
        {error, #{code => authentication}},
        hayata_openai:generate(valid_request(), #{})
    ).

empty_api_key_test() ->
    ?assertEqual(
        {error, #{code => authentication}},
        hayata_openai:generate(
            valid_request(),
            #{api_key => <<>>}
        )
    ).

missing_messages_test() ->
    ?assertEqual(
        {error, #{code => invalid_request}},
        hayata_openai:generate(
            #{model => <<"test-model">>},
            #{api_key => <<"test-key">>}
        )
    ).

unsupported_role_test() ->
    Request = #{
        model => <<"test-model">>,
        messages => [
            #{
                role => tool,
                content => [
                    #{type => text, text => <<"Hello">>}
                ]
            }
        ]
    },

    ?assertEqual(
        {error, #{code => invalid_request}},
        hayata_openai:generate(
            Request,
            #{api_key => <<"test-key">>}
        )
    ).

unsupported_content_test() ->
    Request = #{
        model => <<"test-model">>,
        messages => [
            #{
                role => user,
                content => [
                    #{type => image, url => <<"https://example.com/image.png">>}
                ]
            }
        ]
    },

    ?assertEqual(
        {error, #{code => invalid_request}},
        hayata_openai:generate(
            Request,
            #{api_key => <<"test-key">>}
        )
    ).

http_request_is_normalized_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody =
        <<"{\"id\":\"resp_test\",\"status\":\"completed\","
          "\"output\":[{\"type\":\"message\",\"content\":["
          "{\"type\":\"output_text\",\"text\":\"Hello from OpenAI\"}"
          "]}]}">>,

    {Port, ServerPid, TestRef} = start_http_server(ResponseBody),

    Config = #{
        api_key => <<"test-key">>,
        base_url => list_to_binary(
            "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/v1"
        ),
        timeout => 5000
    },

    try
        Result = hayata_openai:generate(valid_request(), Config),

        ?assertEqual(
            {ok, #{
                message => #{
                    role => assistant,
                    content => [
                        #{
                            type => text,
                            text => <<"Hello from OpenAI">>
                        }
                    ]
                },
                finish_reason => stop,
                id => <<"resp_test">>
            }},
            Result
        ),

        receive
            {http_request, TestRef, RequestLine, Headers, Body} ->
                ?assertMatch(
                    <<"POST /v1/responses", _/binary>>,
                    RequestLine
                ),

                LowerHeaders = list_to_binary(
                    string:lowercase(binary_to_list(Headers))
                ),

                ?assertNotEqual(
                    nomatch,
                    binary:match(
                        LowerHeaders,
                        <<"authorization: bearer test-key">>
                    )
                ),

                Payload = json:decode(Body),

                ?assertEqual(
                    <<"test-model">>,
                    maps:get(<<"model">>, Payload)
                ),

                [Message] = maps:get(<<"input">>, Payload),

                ?assertEqual(
                    <<"user">>,
                    maps:get(<<"role">>, Message)
                )
        after 5000 ->
            error(http_request_not_received)
        end
    after
        exit(ServerPid, kill)
    end.

http_rate_limit_is_normalized_test() ->
    {ok, _} = application:ensure_all_started(inets),

    {Port, ServerPid, _TestRef} = start_http_server(
        429,
        <<"{\"error\":{\"message\":\"Rate limit exceeded\"}}">>
    ),

    Config = #{
        api_key => <<"test-key">>,
        base_url => list_to_binary(
            "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/v1"
        ),
        timeout => 5000
    },

    try
        ?assertEqual(
            {error, #{code => rate_limited}},
            hayata_openai:generate(valid_request(), Config)
        )
    after
        exit(ServerPid, kill)
    end.

http_incomplete_response_is_normalized_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody =
        <<"{\"status\":\"incomplete\","
          "\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}">>,

    {Port, ServerPid, _TestRef} = start_http_server(ResponseBody),
    Config = http_test_config(Port),

    try
        ?assertEqual(
            {error, #{
                code => provider_error,
                reason => max_output_tokens
            }},
            hayata_openai:generate(valid_request(), Config)
        )
    after
        exit(ServerPid, kill)
    end.

http_invalid_json_is_normalized_test() ->
    {ok, _} = application:ensure_all_started(inets),

    {Port, ServerPid, _TestRef} = start_http_server(<<"not-json">>),
    Config = http_test_config(Port),

    try
        ?assertEqual(
            {error, #{code => invalid_response}},
            hayata_openai:generate(valid_request(), Config)
        )
    after
        exit(ServerPid, kill)
    end.

invalid_base_url_test() ->
    ?assertEqual(
        {error, #{code => invalid_request}},
        hayata_openai:generate(
            valid_request(),
            #{
                api_key => <<"test-key">>,
                base_url => 123
            }
        )
    ).

invalid_timeout_test() ->
    ?assertEqual(
        {error, #{code => invalid_request}},
        hayata_openai:generate(
            valid_request(),
            #{
                api_key => <<"test-key">>,
                timeout => 0
            }
        )
    ).

http_authentication_error_is_normalized_test() ->
    {ok, _} = application:ensure_all_started(inets),

    {Port, ServerPid, _TestRef} = start_http_server(
        401,
        <<"{\"error\":{\"message\":\"Invalid API key\"}}">>
    ),

    Config = http_test_config(Port),

    try
        ?assertEqual(
            {error, #{code => authentication}},
            hayata_openai:generate(valid_request(), Config)
        )
    after
        exit(ServerPid, kill)
    end.

http_completed_response_without_text_is_invalid_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody =
        <<"{\"status\":\"completed\",\"output\":[]}">>,

    {Port, ServerPid, _TestRef} = start_http_server(ResponseBody),
    Config = http_test_config(Port),

    try
        ?assertEqual(
            {error, #{code => invalid_response}},
            hayata_openai:generate(valid_request(), Config)
        )
    after
        exit(ServerPid, kill)
    end.

http_completed_response_with_unsupported_output_is_invalid_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody =
        <<"{\"status\":\"completed\",\"output\":["
          "{\"type\":\"function_call\",\"name\":\"test_tool\"}"
          "]}">>,

    {Port, ServerPid, _TestRef} = start_http_server(ResponseBody),
    Config = http_test_config(Port),

    try
        ?assertEqual(
            {error, #{code => invalid_response}},
            hayata_openai:generate(valid_request(), Config)
        )
    after
        exit(ServerPid, kill)
    end.

http_invalid_request_is_normalized_test() ->
    {ok, _} = application:ensure_all_started(inets),

    {Port, ServerPid, _TestRef} = start_http_server(
        400,
        <<"{\"error\":{\"message\":\"Invalid request\"}}">>
    ),

    Config = http_test_config(Port),

    try
        ?assertEqual(
            {error, #{code => invalid_request}},
            hayata_openai:generate(valid_request(), Config)
        )
    after
        exit(ServerPid, kill)
    end.

http_provider_error_is_normalized_test() ->
    {ok, _} = application:ensure_all_started(inets),

    {Port, ServerPid, _TestRef} = start_http_server(
        500,
        <<"{\"error\":{\"message\":\"Internal server error\"}}">>
    ),

    Config = http_test_config(Port),

    try
        ?assertEqual(
            {error, #{code => provider_error}},
            hayata_openai:generate(valid_request(), Config)
        )
    after
        exit(ServerPid, kill)
    end.

http_forbidden_is_normalized_test() ->
    {ok, _} = application:ensure_all_started(inets),

    {Port, ServerPid, _TestRef} = start_http_server(
        403,
        <<"{\"error\":{\"message\":\"Forbidden\"}}">>
    ),

    Config = http_test_config(Port),

    try
        ?assertEqual(
            {error, #{code => authentication}},
            hayata_openai:generate(valid_request(), Config)
        )
    after
        exit(ServerPid, kill)
    end.

http_gateway_timeout_is_normalized_test() ->
    {ok, _} = application:ensure_all_started(inets),

    {Port, ServerPid, _TestRef} = start_http_server(
        504,
        <<"{\"error\":{\"message\":\"Gateway timeout\"}}">>
    ),

    Config = http_test_config(Port),

    try
        ?assertEqual(
            {error, #{code => timeout}},
            hayata_openai:generate(valid_request(), Config)
        )
    after
        exit(ServerPid, kill)
    end.

parse_sse_fragmented_event_test() ->
    State = #{buffer => <<>>, event => undefined, data => []},

    {Events1, State1} = hayata_openai:parse_sse_chunk(
        <<"event: response.created\r\ndata: {\"id\":">>,
        State
    ),

    ?assertEqual([], Events1),

    {Events2, State2} = hayata_openai:parse_sse_chunk(
        <<"\"resp_1\"}\r\n\r\n">>,
        State1
    ),

    Expected = [
        #{
            event => <<"response.created">>,
            data => <<"{\"id\":\"resp_1\"}">>
        }
    ],

    ?assertEqual(Expected, Events2),
    ?assertEqual(<<>>, maps:get(buffer, State2)).

parse_sse_multiple_events_test() ->
    State = #{buffer => <<>>, event => undefined, data => []},
    Chunk = <<
        "event: first\n",
        "data: one\n",
        "\n",
        "event: second\n",
        "data: two\n",
        "\n"
    >>,

    {Events, _State1} = hayata_openai:parse_sse_chunk(Chunk, State),

    ?assertEqual(
        [
            #{event => <<"first">>, data => <<"one">>},
            #{event => <<"second">>, data => <<"two">>}
        ],
        Events
    ).

parse_sse_multiline_data_test() ->
    State = #{buffer => <<>>, event => undefined, data => []},
    Chunk = <<"data: first\ndata: second\n\n">>,

    {Events, _State1} = hayata_openai:parse_sse_chunk(Chunk, State),

    ?assertEqual(
        [#{event => <<"message">>, data => <<"first\nsecond">>}],
        Events
    ).

parse_sse_ignores_comments_test() ->
    State = #{buffer => <<>>, event => undefined, data => []},
    Chunk = <<": keep-alive\n", "data: hello\n\n">>,

    {Events, _State1} = hayata_openai:parse_sse_chunk(Chunk, State),

    ?assertEqual(
        [#{event => <<"message">>, data => <<"hello">>}],
        Events
    ).

normalize_sse_response_created_test() ->
    State = #{},
    Event = #{
        event => <<"response.created">>,
        data => <<"{\"response\":{\"id\":\"resp_1\"}}">>
    },

    {ok, [Normalized], NextState} =
        hayata_openai:normalize_sse_event(Event, State),

    ?assertEqual(message_started, maps:get(type, Normalized)),
    ?assertEqual(<<"resp_1">>, maps:get(generation_id, Normalized)),
    ?assertEqual(<<"resp_1">>, maps:get(generation_id, NextState)).

normalize_sse_text_delta_test() ->
    State = #{generation_id => <<"resp_1">>},
    Event = #{
        event => <<"response.output_text.delta">>,
        data => <<
            "{\"delta\":\"Hello\","
            "\"output_index\":0,"
            "\"content_index\":0}"
        >>
    },

    {ok, [Normalized], _NextState} =
        hayata_openai:normalize_sse_event(Event, State),

    ?assertEqual(content_delta, maps:get(type, Normalized)),
    ?assertEqual(<<"resp_1">>, maps:get(generation_id, Normalized)),
    ?assertEqual(
        #{
            text => <<"Hello">>,
            message_index => 0,
            content_index => 0
        },
        maps:get(data, Normalized)
    ).

normalize_sse_completed_test() ->
    State = #{generation_id => <<"resp_1">>},
    Event = #{
        event => <<"response.completed">>,
        data => <<
            "{\"response\":{"
            "\"id\":\"resp_1\","
            "\"status\":\"completed\","
            "\"output\":[{"
            "\"type\":\"message\","
            "\"content\":[{"
            "\"type\":\"output_text\","
            "\"text\":\"Hello\""
            "}]}]}}"
        >>
    },

    {ok, NormalizedEvents, NextState} =
        hayata_openai:normalize_sse_event(Event, State),

    ?assertEqual(
        [message_completed, generation_completed],
        [maps:get(type, Item) || Item <- NormalizedEvents]
    ),
    ?assertEqual(true, maps:get(terminal, NextState)),
    ?assertEqual(
        <<"Hello">>,
        maps:get(
            text,
            hd(maps:get(content, maps:get(message, maps:get(response, NextState))))
        )
    ).

normalize_sse_failed_test() ->
    State = #{generation_id => <<"resp_1">>},
    Event = #{event => <<"response.failed">>, data => <<"{}">>},

    {ok, [Normalized], NextState} =
        hayata_openai:normalize_sse_event(Event, State),

    ?assertEqual(generation_failed, maps:get(type, Normalized)),
    ?assertEqual(true, maps:get(terminal, NextState)),
    ?assertEqual(
        #{code => provider_error},
        maps:get(error, maps:get(data, Normalized))
    ).

normalize_sse_rejects_event_after_terminal_test() ->
    State = #{generation_id => <<"resp_1">>, terminal => true},
    Event = #{
        event => <<"response.output_text.delta">>,
        data => <<"{}">>
    },

    ?assertMatch(
        {error, #{code := invalid_response}, _},
        hayata_openai:normalize_sse_event(Event, State)
    ).

http_stream_failure_notifies_consumer_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody = <<
        "event: response.created\n",
        "data: {\"response\":{\"id\":\"resp_failed\"}}\n\n",
        "event: response.failed\n",
        "data: {\"response\":{\"id\":\"resp_failed\","
        "\"status\":\"failed\"}}\n\n"
    >>,

    {Port, ServerPid} = start_http_stream_server(ResponseBody),
    Config = http_test_config(Port),
    Parent = self(),
    TestRef = make_ref(),

    Consumer = fun(Event) ->
        Parent ! {stream_event, TestRef, Event},
        ok
    end,

    try
        Result = hayata_openai:generate_stream(
            valid_request(),
            Config,
            Consumer
        ),

        ?assertEqual(
            {error, #{code => provider_error}},
            Result
        ),

        receive
            {stream_event, _, Event} ->
                ?assertEqual(
                    message_started,
                    maps:get(type, Event)
                )
        after 5000 ->
            error(message_started_event_not_received)
        end,

        receive
            {stream_event, _, Event2} ->
                ?assertEqual(
                    generation_failed,
                    maps:get(type, Event2)
                )
        after 5000 ->
            error(generation_failed_event_not_received)
        end
    after
        exit(ServerPid, kill)
    end.

http_stream_completed_response_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody = <<
        "event: response.created\n",
        "data: {\"response\":{\"id\":\"resp_stream\"}}\n\n",
        "event: response.output_text.delta\n",
        "data: {\"delta\":\"Hello\","
        "\"output_index\":0,\"content_index\":0}\n\n",
        "event: response.completed\n",
        "data: {\"response\":{"
        "\"id\":\"resp_stream\","
        "\"status\":\"completed\","
        "\"output\":[{"
        "\"type\":\"message\","
        "\"content\":[{"
        "\"type\":\"output_text\","
        "\"text\":\"Hello\""
        "}]}]}}\n\n"
    >>,

    {Port, ServerPid} = start_http_stream_server(ResponseBody),
    Config = http_test_config(Port),
    Parent = self(),
    TestRef = make_ref(),

    Consumer = fun(Event) ->
        Parent ! {stream_event, TestRef, Event},
        ok
    end,

    try
        Result = hayata_openai:generate_stream(
            valid_request(),
            Config,
            Consumer
        ),

        ?assertEqual(
            {ok, #{
                message => #{
                    role => assistant,
                    content => [
                        #{type => text, text => <<"Hello">>}
                    ]
                },
                finish_reason => stop,
                id => <<"resp_stream">>
            }},
            Result
        ),

        EventTypes = receive_stream_event_types(TestRef, 4, []),

        ?assertEqual(
            [
                message_started,
                content_delta,
                message_completed,
                generation_completed
            ],
            EventTypes
        ),

        receive
            {http_stream_request, _RequestLine, _Headers, Body} ->
                Payload = json:decode(Body),
                ?assertEqual(true, maps:get(<<"stream">>, Payload))
        after 5000 ->
            error(http_request_not_received)
        end
    after
        exit(ServerPid, kill)
    end.

http_stream_consumer_cancellation_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody = <<
        "event: response.created\n",
        "data: {\"response\":{\"id\":\"resp_cancelled\"}}\n\n",
        "event: response.output_text.delta\n",
        "data: {\"delta\":\"Hello\","
        "\"output_index\":0,\"content_index\":0}\n\n"
    >>,

    {Port, ServerPid} = start_http_stream_server(ResponseBody),
    Config = http_test_config(Port),
    Parent = self(),
    TestRef = make_ref(),

    Consumer = fun(Event) ->
        Parent ! {stream_event, TestRef, Event},
        {error, consumer_stopped}
    end,

    try
        Result = hayata_openai:generate_stream(
            valid_request(),
            Config,
            Consumer
        ),

        ?assertEqual(
            {error, #{
                code => cancelled,
                reason => consumer_stopped
            }},
            Result
        ),

        receive
            {stream_event, _, Event} ->
                ?assertEqual(
                    message_started,
                    maps:get(type, Event)
                )
        after 5000 ->
            error(message_started_event_not_received)
        end,

        receive
            {stream_event, _, _UnexpectedEvent} ->
                error(event_received_after_cancellation)
        after 100 ->
            ok
        end
    after
        exit(ServerPid, kill)
    end.

http_stream_fragmented_event_test() ->
    {ok, _} = application:ensure_all_started(inets),

    Chunk1 = <<
        "event: response.created\n",
        "data: {\"response\":{\"id\":"
    >>,

    Chunk2 = <<
        "\"resp_fragmented\"}}\n\n",
        "event: response.output_text.delta\n",
        "data: {\"delta\":\"Hello\","
        "\"output_index\":0,\"content_index\":0}\n\n",
        "event: response.completed\n",
        "data: {\"response\":{"
        "\"id\":\"resp_fragmented\","
        "\"status\":\"completed\","
        "\"output\":[{"
        "\"type\":\"message\","
        "\"content\":[{"
        "\"type\":\"output_text\","
        "\"text\":\"Hello\""
        "}]}]}}\n\n"
    >>,

    {Port, ServerPid} = start_http_stream_server_chunks([
        Chunk1,
        Chunk2
    ]),
    Config = http_test_config(Port),
    Parent = self(),
    TestRef = make_ref(),

    Consumer = fun(Event) ->
        Parent ! {stream_event, TestRef, Event},
        ok
    end,

    try
        Result = hayata_openai:generate_stream(
            valid_request(),
            Config,
            Consumer
        ),

        ?assertEqual(
            {ok, #{
                message => #{
                    role => assistant,
                    content => [
                        #{type => text, text => <<"Hello">>}
                    ]
                },
                finish_reason => stop,
                id => <<"resp_fragmented">>
            }},
            Result
        ),

        ?assertEqual(
            [
                message_started,
                content_delta,
                message_completed,
                generation_completed
            ],
            receive_stream_event_types(TestRef, 4, [])
        )
    after
        exit(ServerPid, kill)
    end.

http_stream_rejects_invalid_content_type_test() ->
    {ok, _} = application:ensure_all_started(inets),

    {Port, ServerPid} = start_http_stream_server_with_content_type(
        <<"{}">>,
        <<"application/json">>
    ),

    Config = http_test_config(Port),

    try
        Result = hayata_openai:generate_stream(
            valid_request(),
            Config,
            fun(_Event) -> ok end
        ),

        ?assertEqual(
            {error, #{code => invalid_response}},
            Result
        )
    after
        exit(ServerPid, kill)
    end.

http_stream_rate_limit_is_normalized_test() ->
    {ok, _} = application:ensure_all_started(inets),

    {Port, ServerPid, _TestRef} = start_http_server(
        429,
        <<"{\"error\":{\"message\":\"Rate limit exceeded\"}}">>
    ),

    Config = http_test_config(Port),

    try
        Result = hayata_openai:generate_stream(
            valid_request(),
            Config,
            fun(_Event) -> ok end
        ),

        ?assertEqual(
            {error, #{code => rate_limited}},
            Result
        )
    after
        exit(ServerPid, kill)
    end.

http_stream_authentication_error_is_normalized_test() ->
    {ok, _} = application:ensure_all_started(inets),

    {Port, ServerPid, _TestRef} = start_http_server(
        401,
        <<"{\"error\":{\"message\":\"Invalid API key\"}}">>
    ),

    Config = http_test_config(Port),

    try
        Result = hayata_openai:generate_stream(
            valid_request(),
            Config,
            fun(_Event) -> ok end
        ),

        ?assertEqual(
            {error, #{code => authentication}},
            Result
        )
    after
        exit(ServerPid, kill)
    end.

http_stream_ended_without_completion_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody = <<
        "event: response.created\n",
        "data: {\"response\":{\"id\":\"resp_incomplete\"}}\n\n",
        "event: response.output_text.delta\n",
        "data: {\"delta\":\"Partial\","
        "\"output_index\":0,\"content_index\":0}\n\n"
    >>,

    {Port, ServerPid} = start_http_stream_server(ResponseBody),
    Config = http_test_config(Port),
    Parent = self(),
    TestRef = make_ref(),

    Consumer = fun(Event) ->
        Parent ! {stream_event, TestRef, Event},
        ok
    end,

    try
        Result = hayata_openai:generate_stream(
            valid_request(),
            Config,
            Consumer
        ),

        ?assertEqual(
            {error, #{code => invalid_response}},
            Result
        ),

        EventTypes = receive_stream_event_types(TestRef, 2, []),

        ?assertEqual(
            [message_started, content_delta],
            EventTypes
        )
    after
        exit(ServerPid, kill)
    end.

http_stream_rejects_malformed_text_delta_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody = <<
        "event: response.created\n",
        "data: {\"response\":{\"id\":\"resp_malformed\"}}\n\n",
        "event: response.output_text.delta\n",
        "data: {\"delta\":\"Hello\","
        "\"output_index\":0}\n\n"
    >>,

    {Port, ServerPid} = start_http_stream_server(ResponseBody),
    Config = http_test_config(Port),
    Parent = self(),
    TestRef = make_ref(),

    Consumer = fun(Event) ->
        Parent ! {stream_event, TestRef, Event},
        ok
    end,

    try
        Result = hayata_openai:generate_stream(
            valid_request(),
            Config,
            Consumer
        ),

        ?assertEqual(
            {error, #{code => invalid_response}},
            Result
        ),

        receive
            {stream_event, _, Event} ->
                ?assertEqual(
                    message_started,
                    maps:get(type, Event)
                )
        after 5000 ->
            error(message_started_event_not_received)
        end,

        receive
            {stream_event, _, _UnexpectedEvent} ->
                error(malformed_delta_was_emitted)
        after 100 ->
            ok
        end
    after
        exit(ServerPid, kill)
    end.

http_stream_rejects_inconsistent_generation_id_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody = <<
        "event: response.created\n",
        "data: {\"response\":{\"id\":\"resp_original\"}}\n\n",
        "event: response.completed\n",
        "data: {\"response\":{"
        "\"id\":\"resp_different\","
        "\"status\":\"completed\","
        "\"output\":[{"
        "\"type\":\"message\","
        "\"content\":[{"
        "\"type\":\"output_text\","
        "\"text\":\"Hello\""
        "}]}]}}\n\n"
    >>,

    {Port, ServerPid} = start_http_stream_server(ResponseBody),
    Config = http_test_config(Port),
    Parent = self(),
    TestRef = make_ref(),

    Consumer = fun(Event) ->
        Parent ! {stream_event, TestRef, Event},
        ok
    end,

    try
        Result = hayata_openai:generate_stream(
            valid_request(),
            Config,
            Consumer
        ),

        ?assertEqual(
            {error, #{
                code => invalid_response,
                reason => inconsistent_generation_id
            }},
            Result
        ),

        receive
            {stream_event, _, Event} ->
                ?assertEqual(
                    message_started,
                    maps:get(type, Event)
                )
        after 5000 ->
            error(message_started_event_not_received)
        end,

        receive
            {stream_event, _, _UnexpectedEvent} ->
                error(completion_event_received_for_inconsistent_id)
        after 100 ->
            ok
        end
    after
        exit(ServerPid, kill)
    end.

http_stream_rejects_malformed_response_created_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody = <<
        "event: response.created\n",
        "data: {\"response\":{\"status\":\"in_progress\"}}\n\n"
    >>,

    {Port, ServerPid} = start_http_stream_server(ResponseBody),
    Config = http_test_config(Port),

    try
        Result = hayata_openai:generate_stream(
            valid_request(),
            Config,
            fun(_Event) -> ok end
        ),

        ?assertEqual(
            {error, #{code => invalid_response}},
            Result
        )
    after
        exit(ServerPid, kill)
    end.

http_stream_rejects_failure_before_response_created_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody = <<
        "event: response.failed\n",
        "data: {\"response\":{\"status\":\"failed\"}}\n\n"
    >>,

    {Port, ServerPid} = start_http_stream_server(ResponseBody),
    Config = http_test_config(Port),

    try
        Result = hayata_openai:generate_stream(
            valid_request(),
            Config,
            fun(_Event) -> ok end
        ),

        ?assertEqual(
            {error, #{code => invalid_response}},
            Result
        )
    after
        exit(ServerPid, kill)
    end.

http_stream_consumer_exception_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody = <<
        "event: response.created\n",
        "data: {\"response\":{\"id\":\"resp_consumer_error\"}}\n\n"
    >>,

    {Port, ServerPid} = start_http_stream_server(ResponseBody),
    Config = http_test_config(Port),

    Consumer = fun(_Event) ->
        erlang:error(consumer_boom)
    end,

    try
        Result = hayata_openai:generate_stream(
            valid_request(),
            Config,
            Consumer
        ),

        ?assertEqual(
            {error, #{
                code => cancelled,
                reason => consumer_failed
            }},
            Result
        )
    after
        exit(ServerPid, kill)
    end.

http_stream_consumer_invalid_return_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody = <<
        "event: response.created\n",
        "data: {\"response\":{\"id\":\"resp_consumer_invalid\"}}\n\n"
    >>,

    {Port, ServerPid} = start_http_stream_server(ResponseBody),
    Config = http_test_config(Port),

    Consumer = fun(_Event) ->
        unexpected_result
    end,

    try
        Result = hayata_openai:generate_stream(
            valid_request(),
            Config,
            Consumer
        ),

        ?assertEqual(
            {error, #{code => invalid_response}},
            Result
        )
    after
        exit(ServerPid, kill)
    end.

http_stream_rejects_invalid_created_json_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody = <<
        "event: response.created\n",
        "data: not-json\n\n"
    >>,

    {Port, ServerPid} = start_http_stream_server(ResponseBody),
    Config = http_test_config(Port),

    try
        Result = hayata_openai:generate_stream(
            valid_request(),
            Config,
            fun(_Event) -> ok end
        ),

        ?assertEqual(
            {error, #{code => invalid_response}},
            Result
        )
    after
        exit(ServerPid, kill)
    end.

http_stream_rejects_invalid_delta_json_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody = <<
        "event: response.created\n",
        "data: {\"response\":{\"id\":\"resp_invalid_delta\"}}\n\n",
        "event: response.output_text.delta\n",
        "data: not-json\n\n"
    >>,

    {Port, ServerPid} = start_http_stream_server(ResponseBody),
    Config = http_test_config(Port),
    Parent = self(),
    TestRef = make_ref(),

    Consumer = fun(Event) ->
        Parent ! {stream_event, TestRef, Event},
        ok
    end,

    try
        Result = hayata_openai:generate_stream(
            valid_request(),
            Config,
            Consumer
        ),

        ?assertEqual(
            {error, #{code => invalid_response}},
            Result
        ),

        receive
            {stream_event, _, Event} ->
                ?assertEqual(
                    message_started,
                    maps:get(type, Event)
                )
        after 5000 ->
            error(message_started_event_not_received)
        end,

        receive
            {stream_event, _, _UnexpectedEvent} ->
                error(invalid_delta_was_emitted)
        after 100 ->
            ok
        end
    after
        exit(ServerPid, kill)
    end.

http_stream_timeout_test() ->
    {ok, _} = application:ensure_all_started(inets),

    {Port, ServerPid} = start_http_stream_server_stalling(),
    Config = (http_test_config(Port))#{timeout => 200},

    try
        Result = hayata_openai:generate_stream(
            valid_request(),
            Config,
            fun(_Event) -> ok end
        ),

        ?assertEqual(
            {error, #{code => timeout}},
            Result
        )
    after
        exit(ServerPid, kill)
    end.

http_function_call_is_normalized_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody = <<
        "{\"id\":\"resp_tools\",",
        "\"status\":\"completed\",",
        "\"output\":[{",
        "\"type\":\"function_call\",",
        "\"call_id\":\"call_123\",",
        "\"name\":\"get_weather\",",
        "\"arguments\":\"{\\\"city\\\":\\\"Mexico City\\\"}\"",
        "}]}">>,

    {Port, ServerPid, _TestRef} = start_http_server(ResponseBody),
    Config = http_test_config(Port),

    try
        ?assertEqual(
            {ok, #{
                message => #{
                    role => assistant,
                    content => [],
                    tool_calls => [
                        #{
                            id => <<"call_123">>,
                            name => <<"get_weather">>,
                            arguments => #{
                                <<"city">> => <<"Mexico City">>
                            }
                        }
                    ]
                },
                finish_reason => tool_calls,
                id => <<"resp_tools">>
            }},
            hayata_openai:generate(valid_request(), Config)
        )
    after
        exit(ServerPid, kill)
    end.

http_multiple_function_calls_preserve_order_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody = <<
        "{\"id\":\"resp_multiple_tools\",",
        "\"status\":\"completed\",",
        "\"output\":[",
        "{",
        "\"type\":\"function_call\",",
        "\"call_id\":\"call_first\",",
        "\"name\":\"get_weather\",",
        "\"arguments\":\"{\\\"city\\\":\\\"Puebla\\\"}\"",
        "},",
        "{",
        "\"type\":\"function_call\",",
        "\"call_id\":\"call_second\",",
        "\"name\":\"get_forecast\",",
        "\"arguments\":\"{\\\"city\\\":\\\"Mexico City\\\"}\"",
        "}",
        "]}">>,

    {Port, ServerPid, _TestRef} = start_http_server(ResponseBody),
    Config = http_test_config(Port),

    try
        Result = hayata_openai:generate(valid_request(), Config),

        ?assertMatch(
            {ok, #{
                finish_reason := tool_calls,
                message := #{
                    tool_calls := [
                        #{id := <<"call_first">>},
                        #{id := <<"call_second">>}
                    ]
                }
            }},
            Result
        )
    after
        exit(ServerPid, kill)
    end.

http_function_call_with_invalid_arguments_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody = <<
        "{\"id\":\"resp_invalid_tools\",",
        "\"status\":\"completed\",",
        "\"output\":[{",
        "\"type\":\"function_call\",",
        "\"call_id\":\"call_invalid\",",
        "\"name\":\"get_weather\",",
        "\"arguments\":\"not-json\"",
        "}]}">>,

    {Port, ServerPid, _TestRef} = start_http_server(ResponseBody),
    Config = http_test_config(Port),

    try
        ?assertEqual(
            {error, #{code => invalid_response}},
            hayata_openai:generate(valid_request(), Config)
        )
    after
        exit(ServerPid, kill)
    end.


http_tool_definition_is_sent_to_openai_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody =
        <<"{\"id\":\"resp_tool_definition\","
          "\"status\":\"completed\","
          "\"output\":[{"
          "\"type\":\"message\","
          "\"content\":[{"
          "\"type\":\"output_text\","
          "\"text\":\"Ready\""
          "}]}]}">>,

    {Port, ServerPid, TestRef} = start_http_server(ResponseBody),
    Config = http_test_config(Port),

    Tool = #{
        name => <<"get_weather">>,
        description => <<"Get the current weather">>,
        parameters => #{
            type => object,
            properties => #{
                city => #{type => string}
            },
            required => [city]
        },
        handler => fun(_Arguments) -> {ok, <<"sunny">>} end
    },

    Request = (valid_request())#{tools => [
        maps:without([handler], Tool)
    ]},

    try
        ?assertMatch(
            {ok, #{finish_reason := stop}},
            hayata_openai:generate(Request, Config)
        ),

        receive
            {http_request, TestRef, _RequestLine, _Headers, Body} ->
                ?assertNotEqual(
                    nomatch,
                    binary:match(Body, <<"\"tools\"">>)
                ),
                Payload = json:decode(Body),

                [OpenAITool] = maps:get(<<"tools">>, Payload),

                ?assertEqual(
                    <<"function">>,
                    maps:get(<<"type">>, OpenAITool)
                ),
                ?assertEqual(
                     <<"get_weather">>,
                     maps:get(<<"name">>, OpenAITool)
                ),
                ?assertEqual(
                    <<"Get the current weather">>,
                    maps:get(<<"description">>, OpenAITool)
                ),

                Parameters = maps:get(<<"parameters">>, OpenAITool),

                ?assertEqual(
                    <<"object">>,
                    maps:get(<<"type">>, Parameters)
                ),
                ?assertEqual(
                    [<<"city">>],
                    maps:get(<<"required">>, Parameters)
                ),

                Properties = maps:get(<<"properties">>, Parameters),
                City = maps:get(<<"city">>, Properties),

                ?assertEqual(
                    <<"string">>,
                    maps:get(<<"type">>, City))
        after 5000 ->
            error(http_request_not_received)
        end
    after
        exit(ServerPid, kill)
    end.

http_request_without_tools_omits_tools_field_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody =
        <<"{\"id\":\"resp_without_tools\","
          "\"status\":\"completed\","
          "\"output\":[{"
          "\"type\":\"message\","
          "\"content\":[{"
          "\"type\":\"output_text\","
          "\"text\":\"Hello\""
          "}]}]}">>,

    {Port, ServerPid, TestRef} = start_http_server(ResponseBody),
    Config = http_test_config(Port),

    try
        ?assertMatch(
            {ok, #{finish_reason := stop}},
            hayata_openai:generate(valid_request(), Config)
        ),

        receive
            {http_request, TestRef, _RequestLine, _Headers, Body} ->
                Payload = json:decode(Body),
                ?assertEqual(false, maps:is_key(<<"tools">>, Payload))
        after 5000 ->
            error(http_request_not_received)
        end
    after
        exit(ServerPid, kill)
    end.

http_tool_history_is_converted_to_responses_input_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody =
        <<"{\"id\":\"resp_tool_history\","
          "\"status\":\"completed\","
          "\"output\":[{"
          "\"type\":\"message\","
          "\"content\":[{"
          "\"type\":\"output_text\","
          "\"text\":\"The weather is sunny.\""
          "}]}]}">>,

    {Port, ServerPid, TestRef} = start_http_server(ResponseBody),
    Config = http_test_config(Port),

    [UserMessage] = maps:get(messages, valid_request()),

    AssistantMessage = #{
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

    ToolMessage = #{
        role => tool,
        tool_call_id => <<"call_123">>,
        name => <<"get_weather">>,
        content => [
            #{
                type => text,
                text => <<"{\"temperature\":22}">>
            }
        ]
    },

    Request = (valid_request())#{
        messages => [
            UserMessage,
            AssistantMessage,
            ToolMessage
        ]
    },

    try
        ?assertMatch(
            {ok, #{finish_reason := stop}},
            hayata_openai:generate(Request, Config)
        ),

        receive
            {http_request, TestRef, _RequestLine, _Headers, Body} ->
                Payload = json:decode(Body),
                Input = maps:get(<<"input">>, Payload),

                ?assertEqual(3, length(Input)),

                [UserInput, FunctionCall, FunctionOutput] = Input,

                ?assertEqual(
                    <<"user">>,
                    maps:get(<<"role">>, UserInput)
                ),
 
                ?assertEqual(
                    <<"function_call">>,
                    maps:get(<<"type">>, FunctionCall)
                ),
                ?assertEqual(
                    <<"call_123">>,
                    maps:get(<<"call_id">>, FunctionCall)
                ),
                ?assertEqual(
                    <<"get_weather">>,
                    maps:get(<<"name">>, FunctionCall)
                ),
                ?assertEqual(
                    #{<<"city">> => <<"Mexico City">>},
                    json:decode(maps:get(<<"arguments">>, FunctionCall))
                ),

                ?assertEqual(
                    <<"function_call_output">>,
                    maps:get(<<"type">>, FunctionOutput)
                ),
                ?assertEqual(
                    <<"call_123">>,
                    maps:get(<<"call_id">>, FunctionOutput)
                ),
                ?assertEqual(
                    <<"{\"temperature\":22}">>,
                    maps:get(<<"output">>, FunctionOutput)
                )
        after 5000 ->
            error(http_request_not_received)
        end
    after
        exit(ServerPid, kill)
    end.

http_tool_loop_completes_end_to_end_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ToolCallResponse =
        <<"{\"id\":\"resp_tool_call\","
          "\"status\":\"completed\","
          "\"output\":[{"
          "\"type\":\"function_call\","
          "\"call_id\":\"call_123\","
          "\"name\":\"get_weather\","
          "\"arguments\":\"{\\\"city\\\":\\\"Mexico City\\\"}\""
          "}]}">>,

    FinalResponse =
        <<"{\"id\":\"resp_final\","
          "\"status\":\"completed\","
          "\"output\":[{"
          "\"type\":\"message\","
          "\"content\":[{"
          "\"type\":\"output_text\","
          "\"text\":\"The weather is sunny.\""
          "}]}]}">>,

    {Port, ServerPid, TestRef} =
        start_http_server_sequence([
            ToolCallResponse,
            FinalResponse
        ]),

    Config = http_test_config(Port),

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
        handler => fun(Arguments) ->
            case maps:get(<<"city">>, Arguments) of
                <<"Mexico City">> ->
                    {ok, #{temperature => 22, conditions => <<"sunny">>}};
                _ ->
                    {error, unknown_city}
            end
        end
    },

    Request = #{
        model => <<"mock-model">>,
        messages => [
            #{
                role => user,
                content => [
                    #{
                        type => text,
                        text => <<"What is the weather in Mexico City?">>
                    }
                ]
            }
        ]
    },

    LLM = fun(LLMRequest) ->
        hayata_openai:generate(LLMRequest, Config)
    end,

    try
        {ok, Result} = hayata_tool_loop:run(
            LLM,
            Request,
            [Tool],
            5
        ),

        ?assertEqual(2, maps:get(iterations, Result)),
        ?assertEqual(
            <<"The weather is sunny.">>,
            response_text(maps:get(response, Result))
        ),

        receive
            {http_request, TestRef, _Line1, _Headers1, Body1} ->
                Payload1 = json:decode(Body1),
                Input1 = maps:get(<<"input">>, Payload1),

                ?assertEqual(1, length(Input1)),
                ?assert(maps:is_key(<<"tools">>, Payload1))
        after 5000 ->
            error(first_http_request_not_received)
        end,

        receive
            {http_request, TestRef, _Line2, _Headers2, Body2} ->
                Payload2 = json:decode(Body2),
                Input2 = maps:get(<<"input">>, Payload2),

                ?assertEqual(3, length(Input2)),

                [_UserInput, FunctionCall, FunctionOutput] = Input2,

                ?assertEqual(
                    <<"function_call">>,
                    maps:get(<<"type">>, FunctionCall)
                ),
                ?assertEqual(
                    <<"call_123">>,
                    maps:get(<<"call_id">>, FunctionCall)
                ),

                ?assertEqual(
                    <<"function_call_output">>,
                    maps:get(<<"type">>, FunctionOutput)
                ),
                ?assertEqual(
                    <<"call_123">>,
                    maps:get(<<"call_id">>, FunctionOutput)
                ),

                Output = json:decode(
                    maps:get(<<"output">>, FunctionOutput)
                ),

                ?assertEqual(22, maps:get(<<"temperature">>, Output)),
                ?assertEqual(<<"sunny">>, maps:get(<<"conditions">>, Output))
        after 5000 ->
            error(second_http_request_not_received)
        end
    after
        exit(ServerPid, kill)
    end.

http_tool_loop_completes_multiple_tool_rounds_test() ->
    {ok, _} = application:ensure_all_started(inets),

    WeatherCallResponse =
        <<"{\"id\":\"resp_weather_call\","
          "\"status\":\"completed\","
          "\"output\":[{"
          "\"type\":\"function_call\","
          "\"call_id\":\"call_weather\","
          "\"name\":\"get_weather\","
          "\"arguments\":\"{\\\"city\\\":\\\"Mexico City\\\"}\""
          "}]}">>,

    ForecastCallResponse =
        <<"{\"id\":\"resp_forecast_call\","
          "\"status\":\"completed\","
          "\"output\":[{"
          "\"type\":\"function_call\","
          "\"call_id\":\"call_forecast\","
          "\"name\":\"get_forecast\","
          "\"arguments\":\"{\\\"city\\\":\\\"Mexico City\\\"}\""
          "}]}">>,

    FinalResponse =
        <<"{\"id\":\"resp_final\","
          "\"status\":\"completed\","
          "\"output\":[{"
          "\"type\":\"message\","
          "\"content\":[{"
          "\"type\":\"output_text\","
          "\"text\":\"The weather is sunny and the forecast is clear.\""
          "}]}]}">>,

    {Port, ServerPid, TestRef} =
        start_http_server_sequence([
            WeatherCallResponse,
            ForecastCallResponse,
            FinalResponse
        ]),

    Config = http_test_config(Port),

    WeatherTool = #{
        name => <<"get_weather">>,
        description => <<"Gets the current weather for a city.">>,
        parameters => #{
            type => object,
            properties => #{
                city => #{type => string}
            },
            required => [<<"city">>]
        },
        handler => fun(Arguments) ->
            case maps:get(<<"city">>, Arguments) of
                <<"Mexico City">> ->
                    {ok, #{
                        temperature => 22,
                        conditions => <<"sunny">>
                    }};
                _ ->
                    {error, unknown_city}
            end
        end
    },

    ForecastTool = #{
        name => <<"get_forecast">>,
        description => <<"Gets the forecast for a city.">>,
        parameters => #{
            type => object,
            properties => #{
                city => #{type => string}
            },
            required => [<<"city">>]
        },
        handler => fun(Arguments) ->
            case maps:get(<<"city">>, Arguments) of
                <<"Mexico City">> ->
                    {ok, #{forecast => <<"clear">>}};
                _ ->
                    {error, unknown_city}
            end
        end
    },

    Request = #{
        model => <<"mock-model">>,
        messages => [
            #{
                role => user,
                content => [
                    #{
                        type => text,
                        text => <<"Give me the weather and forecast for Mexico City.">>
                    }
                ]
            }
        ]
    },

    LLM = fun(LLMRequest) ->
        hayata_openai:generate(LLMRequest, Config)
    end,

    try
        {ok, Result} = hayata_tool_loop:run(
            LLM,
            Request,
            [WeatherTool, ForecastTool],
            5
        ),

        ?assertEqual(3, maps:get(iterations, Result)),
        ?assertEqual(
            <<"The weather is sunny and the forecast is clear.">>,
            response_text(maps:get(response, Result))
        ),

        receive
            {http_request, TestRef, _Line1, _Headers1, Body1} ->
                Payload1 = json:decode(Body1),
                Input1 = maps:get(<<"input">>, Payload1),

                ?assertEqual(1, length(Input1)),
                ?assert(maps:is_key(<<"tools">>, Payload1))
        after 5000 ->
            error(first_http_request_not_received)
        end,

        receive
            {http_request, TestRef, _Line2, _Headers2, Body2} ->
                Payload2 = json:decode(Body2),
                Input2 = maps:get(<<"input">>, Payload2),

                ?assertEqual(3, length(Input2)),

                [_User2, WeatherCall, WeatherOutput] = Input2,

                ?assertEqual(
                    <<"call_weather">>,
                    maps:get(<<"call_id">>, WeatherCall)
                ),
                ?assertEqual(
                    <<"function_call_output">>,
                    maps:get(<<"type">>, WeatherOutput)
                ),
                ?assertEqual(
                    <<"call_weather">>,
                    maps:get(<<"call_id">>, WeatherOutput)
                ),

                WeatherResult = json:decode(
                    maps:get(<<"output">>, WeatherOutput)
                ),

                ?assertEqual(
                    22,
                    maps:get(<<"temperature">>, WeatherResult)
                ),
                ?assertEqual(
                    <<"sunny">>,
                    maps:get(<<"conditions">>, WeatherResult)
                )
        after 5000 ->
            error(second_http_request_not_received)
        end,

        receive
            {http_request, TestRef, _Line3, _Headers3, Body3} ->
                Payload3 = json:decode(Body3),
                Input3 = maps:get(<<"input">>, Payload3),

                ?assertEqual(5, length(Input3)),

                [
                    _User3,
                    WeatherCall3,
                    WeatherOutput3,
                    ForecastCall3,
                    ForecastOutput3
                ] = Input3,

                ?assertEqual(
                    <<"function_call">>,
                    maps:get(<<"type">>, ForecastCall3)
                ),
                ?assertEqual(
                    <<"call_forecast">>,
                    maps:get(<<"call_id">>, ForecastCall3)
                ),
                ?assertEqual(
                    <<"get_forecast">>,
                    maps:get(<<"name">>, ForecastCall3)
                ),

                ?assertEqual(
                    <<"function_call_output">>,
                    maps:get(<<"type">>, ForecastOutput3)
                ),
                ?assertEqual(
                    <<"call_forecast">>,
                    maps:get(<<"call_id">>, ForecastOutput3)
                ),

                ForecastResult = json:decode(
                    maps:get(<<"output">>, ForecastOutput3)
                ),

                ?assertEqual(
                    <<"clear">>,
                    maps:get(<<"forecast">>, ForecastResult)
                ),

                %% The first round must remain in the conversation.
                ?assertEqual(
                    <<"call_weather">>,
                    maps:get(<<"call_id">>, WeatherCall3)
                ),
                ?assertEqual(
                    <<"call_weather">>,
                    maps:get(<<"call_id">>, WeatherOutput3)
                )
        after 5000 ->
            error(third_http_request_not_received)
        end
    after
        exit(ServerPid, kill)
    end.

http_tool_loop_propagates_server_error_after_tool_execution_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ToolCallResponse =
        <<"{\"id\":\"resp_tool_call\","
          "\"status\":\"completed\","
          "\"output\":[{"
          "\"type\":\"function_call\","
          "\"call_id\":\"call_123\","
          "\"name\":\"get_weather\","
          "\"arguments\":\"{\\\"city\\\":\\\"Mexico City\\\"}\""
          "}]}">>,

    ServerError =
        <<"{\"error\":{\"message\":\"Internal server error\"}}">>,

    {Port, ServerPid, TestRef} =
        start_http_server_sequence([
            {200, ToolCallResponse},
            {500, ServerError}
        ]),

    Config = http_test_config(Port),
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
            Parent ! weather_tool_executed,
            {ok, #{temperature => 22}}
        end
    },

    LLM = fun(LLMRequest) ->
        hayata_openai:generate(LLMRequest, Config)
    end,

    try
        Result = hayata_tool_loop:run(
            LLM,
            valid_request(),
            [Tool],
            5
        ),

        ?assertEqual(
            {error, {llm_failed, #{code => provider_error}}},
            Result
        ),

        receive
            weather_tool_executed ->
                ok
        after 1000 ->
            error(weather_tool_was_not_executed)
        end,

        receive
            {http_request, TestRef, _Line1, _Headers1, Body1} ->
                Payload1 = json:decode(Body1),
                ?assertEqual(
                    1,
                    length(maps:get(<<"input">>, Payload1))
                )
        after 5000 ->
            error(first_http_request_not_received)
        end,

        receive
            {http_request, TestRef, _Line2, _Headers2, Body2} ->
                Payload2 = json:decode(Body2),
                Input2 = maps:get(<<"input">>, Payload2),

                ?assertEqual(3, length(Input2)),
                ?assert(maps:is_key(<<"tools">>, Payload2))
        after 5000 ->
            error(second_http_request_not_received)
        end
    after
        exit(ServerPid, kill)
    end.

http_tool_loop_propagates_rate_limit_after_tool_execution_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ToolCallResponse =
        <<"{\"id\":\"resp_tool_call\","
          "\"status\":\"completed\","
          "\"output\":[{"
          "\"type\":\"function_call\","
          "\"call_id\":\"call_123\","
          "\"name\":\"get_weather\","
          "\"arguments\":\"{\\\"city\\\":\\\"Mexico City\\\"}\""
          "}]}">>,

    RateLimitResponse =
        <<"{\"error\":{\"message\":\"Rate limit exceeded\"}}">>,

    {Port, ServerPid, TestRef} =
        start_http_server_sequence([
            {200, ToolCallResponse},
            {429, RateLimitResponse}
        ]),

    Config = http_test_config(Port),
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
            Parent ! weather_tool_executed,
            {ok, #{temperature => 22}}
        end
    },

    LLM = fun(LLMRequest) ->
        hayata_openai:generate(LLMRequest, Config)
    end,

    try
        Result = hayata_tool_loop:run(
            LLM,
            valid_request(),
            [Tool],
            5
        ),

        ?assertEqual(
            {error, {llm_failed, #{code => rate_limited}}},
            Result
        ),

        receive
            weather_tool_executed ->
                ok
        after 1000 ->
            error(weather_tool_was_not_executed)
        end,

        receive
            {http_request, TestRef, _Line1, _Headers1, _Body1} ->
                ok
        after 5000 ->
            error(first_http_request_not_received)
        end,

        receive
            {http_request, TestRef, _Line2, _Headers2, _Body2} ->
                ok
        after 5000 ->
            error(second_http_request_not_received)
        end
    after
        exit(ServerPid, kill)
    end.

http_tool_loop_propagates_incomplete_response_after_tool_execution_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ToolCallResponse =
        <<"{\"id\":\"resp_tool_call\","
          "\"status\":\"completed\","
          "\"output\":[{"
          "\"type\":\"function_call\","
          "\"call_id\":\"call_123\","
          "\"name\":\"get_weather\","
          "\"arguments\":\"{\\\"city\\\":\\\"Mexico City\\\"}\""
          "}]}">>,

    IncompleteResponse =
        <<"{\"status\":\"incomplete\","
          "\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}">>,

    {Port, ServerPid, TestRef} =
        start_http_server_sequence([
            ToolCallResponse,
            IncompleteResponse
        ]),

    Config = http_test_config(Port),
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
            Parent ! weather_tool_executed,
            {ok, #{temperature => 22}}
        end
    },

    LLM = fun(LLMRequest) ->
        hayata_openai:generate(LLMRequest, Config)
    end,

    try
        ?assertEqual(
            {error, {llm_failed, #{
                code => provider_error,
                reason => max_output_tokens
            }}},
            hayata_tool_loop:run(
                LLM,
                valid_request(),
                [Tool],
                5
            )
        ),

        receive
            weather_tool_executed ->
                ok
        after 1000 ->
            error(weather_tool_was_not_executed)
        end,

        receive
            {http_request, TestRef, _Line1, _Headers1, _Body1} ->
                ok
        after 5000 ->
            error(first_http_request_not_received)
        end,

        receive
            {http_request, TestRef, _Line2, _Headers2, _Body2} ->
                ok
        after 5000 ->
            error(second_http_request_not_received)
        end
    after
        exit(ServerPid, kill)
    end.

http_response_preserves_text_and_tool_calls_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody =
        <<"{\"id\":\"resp_mixed\","
          "\"status\":\"completed\","
          "\"output\":["
          "{"
          "\"type\":\"message\","
          "\"content\":[{"
          "\"type\":\"output_text\","
          "\"text\":\"I will check the weather first.\""
          "}]"
          "},"
          "{"
          "\"type\":\"function_call\","
          "\"call_id\":\"call_123\","
          "\"name\":\"get_weather\","
          "\"arguments\":\"{\\\"city\\\":\\\"Mexico City\\\"}\""
          "}"
          "]}">>,

    {Port, ServerPid, TestRef} = start_http_server(ResponseBody),
    Config = http_test_config(Port),

    try
        {ok, Response} = hayata_openai:generate(
            valid_request(),
            Config
        ),

        Message = maps:get(message, Response),

        ?assertEqual(assistant, maps:get(role, Message)),
        ?assertEqual(tool_calls, maps:get(finish_reason, Response)),

        [TextBlock] = maps:get(content, Message),
        ?assertEqual(
            <<"I will check the weather first.">>,
            maps:get(text, TextBlock)
        ),

        [ToolCall] = maps:get(tool_calls, Message),
        ?assertEqual(<<"call_123">>, maps:get(id, ToolCall)),
        ?assertEqual(<<"get_weather">>, maps:get(name, ToolCall)),
        ?assertEqual(
            #{<<"city">> => <<"Mexico City">>},
            maps:get(arguments, ToolCall)
        ),

        receive
            {http_request, TestRef, _Line, _Headers, _Body} ->
                ok
        after 5000 ->
            error(http_request_not_received)
        end
    after
        exit(ServerPid, kill)
    end.

http_tool_call_with_invalid_json_arguments_is_rejected_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody =
        <<"{\"id\":\"resp_invalid_arguments\","
          "\"status\":\"completed\","
          "\"output\":[{"
          "\"type\":\"function_call\","
          "\"call_id\":\"call_123\","
          "\"name\":\"get_weather\","
          "\"arguments\":\"{invalid-json}\""
          "}]}">>,

    {Port, ServerPid, _TestRef} = start_http_server(ResponseBody),
    Config = http_test_config(Port),

    try
        ?assertEqual(
            {error, #{code => invalid_response}},
            hayata_openai:generate(valid_request(), Config)
        )
    after
        exit(ServerPid, kill)
    end.

http_tool_call_without_call_id_is_rejected_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody =
        <<"{\"id\":\"resp_missing_call_id\","
          "\"status\":\"completed\","
          "\"output\":[{"
          "\"type\":\"function_call\","
          "\"name\":\"get_weather\","
          "\"arguments\":\"{\\\"city\\\":\\\"Mexico City\\\"}\""
          "}]}">>,

    {Port, ServerPid, _TestRef} = start_http_server(ResponseBody),
    Config = http_test_config(Port),

    try
        ?assertEqual(
            {error, #{code => invalid_response}},
            hayata_openai:generate(valid_request(), Config)
        )
    after
        exit(ServerPid, kill)
    end.

http_tool_call_with_empty_call_id_is_rejected_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody =
        <<"{\"id\":\"resp_empty_call_id\","
          "\"status\":\"completed\","
          "\"output\":[{"
          "\"type\":\"function_call\","
          "\"call_id\":\"\","
          "\"name\":\"get_weather\","
          "\"arguments\":\"{\\\"city\\\":\\\"Mexico City\\\"}\""
          "}]}">>,

    {Port, ServerPid, _TestRef} = start_http_server(ResponseBody),
    Config = http_test_config(Port),

    try
        ?assertEqual(
            {error, #{code => invalid_response}},
            hayata_openai:generate(valid_request(), Config)
        )
    after
        exit(ServerPid, kill)
    end.

openai_tool_calling_capability_test() ->
    {ok, Capabilities} = hayata_openai:capabilities(#{}),
    Features = maps:get(features, Capabilities),

    ?assertEqual(true, maps:get(tool_calling, Features)).

openai_capabilities_contract_test() ->
    {ok, Capabilities} = hayata_openai:capabilities(#{}),

    Features = maps:get(features, Capabilities),

    ?assertEqual(
        #{
            tool_calling => true,
            structured_output => false,
            streaming => true,
            embeddings => false
        },
        Features
    ),

    ?assertEqual(
        #{
            input => [text],
            output => [text]
        },
        maps:get(modalities, Capabilities)
    ).

openai_capabilities_are_independent_of_config_test() ->
    {ok, DefaultCapabilities} = hayata_openai:capabilities(#{}),

    {ok, CustomCapabilities} = hayata_openai:capabilities(#{
        api_key => <<"test-key">>,
        base_url => <<"https://example.com/v1">>,
        timeout => 5000
    }),

    ?assertEqual(DefaultCapabilities, CustomCapabilities).

http_mixed_valid_and_malformed_tool_calls_are_rejected_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody =
        <<"{\"id\":\"resp_mixed_invalid\","
          "\"status\":\"completed\","
          "\"output\":["
          "{"
          "\"type\":\"function_call\","
          "\"call_id\":\"call_valid\","
          "\"name\":\"get_weather\","
          "\"arguments\":\"{\\\"city\\\":\\\"Puebla\\\"}\""
          "},"
          "{"
          "\"type\":\"function_call\","
          "\"name\":\"get_weather\","
          "\"arguments\":\"{\\\"city\\\":\\\"Mexico City\\\"}\""
          "}"
          "]}">>,

    {Port, ServerPid, _TestRef} = start_http_server(ResponseBody),
    Config = http_test_config(Port),

    try
        ?assertEqual(
            {error, #{code => invalid_response}},
            hayata_openai:generate(valid_request(), Config)
        )
    after
        exit(ServerPid, kill)
    end.

http_tool_history_preserves_unicode_and_nested_arguments_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody =
        <<"{\"id\":\"resp_history_unicode\","
          "\"status\":\"completed\","
          "\"output\":[{"
          "\"type\":\"message\","
          "\"content\":[{"
          "\"type\":\"output_text\","
          "\"text\":\"OK\""
          "}]}]}">>,

    {Port, ServerPid, TestRef} = start_http_server(ResponseBody),
    Config = http_test_config(Port),

    [UserMessage] = maps:get(messages, valid_request()),

    Arguments = #{
        city => unicode:characters_to_binary("Puebla, México 🌦️"),
        note => <<>>,
        options => #{
            units => unicode:characters_to_binary("°C"),
            days => [1, 2],
            enabled => true
        }
    },

    AssistantMessage = #{
        role => assistant,
        content => [],
        tool_calls => [
            #{
                id => <<"call_unicode">>,
                name => <<"get_weather">>,
                arguments => Arguments
            }
        ]
    },

    Request = (valid_request())#{
        messages => [UserMessage, AssistantMessage]
    },

    try
        ?assertMatch(
            {ok, #{finish_reason := stop}},
            hayata_openai:generate(Request, Config)
        ),

        receive
            {http_request, TestRef, _Line, _Headers, Body} ->
                Payload = json:decode(Body),
                [_, FunctionCall] = maps:get(<<"input">>, Payload),
                EncodedArguments = maps:get(
                    <<"arguments">>,
                    FunctionCall
                ),
                DecodedArguments = json:decode(EncodedArguments),

                ?assertEqual(
                    <<"call_unicode">>,
                    maps:get(<<"call_id">>, FunctionCall)
                ),
                ?assertEqual(
                    unicode:characters_to_binary("Puebla, México 🌦️"),
                    maps:get(<<"city">>, DecodedArguments)
                ),
                ?assertEqual(
                    unicode:characters_to_binary("°C"),
                    maps:get(<<"units">>, maps:get(<<"options">>, DecodedArguments))
                ),
                ?assertEqual(
                    <<>>,
                    maps:get(<<"note">>, DecodedArguments)
                ),
                ?assertEqual(
                    #{
                        <<"units">> => unicode:characters_to_binary("°C"),
                        <<"days">> => [1, 2],
                        <<"enabled">> => true
                    },
                    maps:get(<<"options">>, DecodedArguments)
                )
        after 5000 ->
            error(http_request_not_received)
        end
    after
        exit(ServerPid, kill)
    end.

http_tool_history_preserves_empty_tool_output_test() ->
    {ok, _} = application:ensure_all_started(inets),

    ResponseBody =
        <<"{\"id\":\"resp_empty_output\","
          "\"status\":\"completed\","
          "\"output\":[{"
          "\"type\":\"message\","
          "\"content\":[{"
          "\"type\":\"output_text\","
          "\"text\":\"OK\""
          "}]}]}">>,

    {Port, ServerPid, TestRef} = start_http_server(ResponseBody),
    Config = http_test_config(Port),

    [UserMessage] = maps:get(messages, valid_request()),

    AssistantMessage = #{
        role => assistant,
        content => [],
        tool_calls => [
            #{
                id => <<"call_empty">>,
                name => <<"get_weather">>,
                arguments => #{city => <<"Puebla">>}
            }
        ]
    },

    ToolMessage = #{
        role => tool,
        tool_call_id => <<"call_empty">>,
        name => <<"get_weather">>,
        content => [#{type => text, text => <<>>}]
    },

    Request = (valid_request())#{
        messages => [UserMessage, AssistantMessage, ToolMessage]
    },

    try
        ?assertMatch(
            {ok, #{finish_reason := stop}},
            hayata_openai:generate(Request, Config)
        ),

        receive
            {http_request, TestRef, _Line, _Headers, Body} ->
                Payload = json:decode(Body),
                [_, _, FunctionOutput] = maps:get(
                    <<"input">>,
                    Payload
                ),

                ?assertEqual(
                    <<"function_call_output">>,
                    maps:get(<<"type">>, FunctionOutput)
                ),
                ?assertEqual(
                    <<"call_empty">>,
                    maps:get(<<"call_id">>, FunctionOutput)
                ),
                ?assertEqual(
                    <<>>,
                    maps:get(<<"output">>, FunctionOutput)
                )
        after 5000 ->
            error(http_request_not_received)
        end
    after
        exit(ServerPid, kill)
    end.

-spec receive_stream_event_types(
    reference(),
    non_neg_integer(),
    [atom()]
) -> [atom()].
receive_stream_event_types(_TestRef, 0, Acc) ->
    lists:reverse(Acc);
receive_stream_event_types(TestRef, Count, Acc) ->
    receive
        {stream_event, TestRef, Event} ->
            receive_stream_event_types(
                TestRef,
                Count - 1,
                [maps:get(type, Event) | Acc]
            )
    after 5000 ->
        error({stream_event_not_received, Count})
    end.

-spec http_test_config(inet:port_number()) -> map().
http_test_config(Port) ->
    #{
        api_key => <<"test-key">>,
        base_url => list_to_binary(
            "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/v1"
        ),
        timeout => 5000
    }.

-spec start_http_server(binary()) -> {inet:port_number(), pid()}.
start_http_server(ResponseBody) ->
    start_http_server(200, ResponseBody).

-spec start_http_server(
    non_neg_integer(),
    binary()
) -> {inet:port_number(), pid()}.
start_http_server(Status, ResponseBody) ->
    {ok, ListenSocket} = gen_tcp:listen(0, [
        binary,
        {packet, raw},
        {active, false},
        {reuseaddr, true}
    ]),

    {ok, {_Address, Port}} = inet:sockname(ListenSocket),

    Parent = self(),
    TestRef = make_ref(),

    ServerPid = spawn(fun() ->
        try
            {ok, Socket} = gen_tcp:accept(ListenSocket, 5000),
            {RequestLine, Headers, Body} = read_http_request(Socket),
            Parent ! {http_request, TestRef, RequestLine, Headers, Body},

            Response = <<
                "HTTP/1.1 ",
                (integer_to_binary(Status))/binary,
                " ",
                (status_reason(Status))/binary,
                "\r\n",
                "Content-Type: application/json\r\n",
                "Content-Length: ",
                (integer_to_binary(byte_size(ResponseBody)))/binary,
                "\r\nConnection: close\r\n\r\n",
                ResponseBody/binary
            >>,

            ok = gen_tcp:send(Socket, Response),
            gen_tcp:close(Socket),
            gen_tcp:close(ListenSocket)
        catch
            Class:Reason:Stacktrace ->
                Parent ! {http_server_error, Class, Reason, Stacktrace},
                erlang:raise(Class, Reason, Stacktrace)
        end
    end),

    {Port, ServerPid, TestRef}.

-spec start_http_stream_server_with_content_type(binary(), binary()) ->
    {inet:port_number(), pid()}.
start_http_stream_server_with_content_type(ResponseBody, ContentType) ->
    {ok, ListenSocket} = gen_tcp:listen(0, [
        binary,
        {packet, raw},
        {active, false},
        {reuseaddr, true}
    ]),

    {ok, {_Address, Port}} = inet:sockname(ListenSocket),
    Parent = self(),

    ServerPid = spawn(fun() ->
        try
            {ok, Socket} = gen_tcp:accept(ListenSocket, 5000),
            {RequestLine, Headers, Body} = read_http_request(Socket),
            Parent ! {http_stream_request, RequestLine, Headers, Body},

            Response = <<
                "HTTP/1.1 200 OK\r\n",
                "Content-Type: ",
                ContentType/binary,
                "\r\n",
                "Content-Length: ",
                (integer_to_binary(byte_size(ResponseBody)))/binary,
                "\r\n",
                "Connection: close\r\n\r\n",
                ResponseBody/binary
            >>,

            ok = gen_tcp:send(Socket, Response),
            gen_tcp:close(Socket),
            gen_tcp:close(ListenSocket)
        catch
            Class:Reason:Stacktrace ->
                Parent ! {
                    http_server_error,
                    Class,
                    Reason,
                    Stacktrace
                },
                erlang:raise(Class, Reason, Stacktrace)
        end
    end),

    {Port, ServerPid}.

-spec start_http_stream_server_chunks([binary()]) ->
    {inet:port_number(), pid()}.
start_http_stream_server_chunks(Chunks) ->
    {ok, ListenSocket} = gen_tcp:listen(0, [
        binary,
        {packet, raw},
        {active, false},
        {reuseaddr, true}
    ]),

    {ok, {_Address, Port}} = inet:sockname(ListenSocket),
    Parent = self(),
    ResponseBody = iolist_to_binary(Chunks),

    ServerPid = spawn(fun() ->
        try
            {ok, Socket} = gen_tcp:accept(ListenSocket, 5000),
            {RequestLine, Headers, Body} = read_http_request(Socket),
            Parent ! {
                http_stream_request,
                RequestLine,
                Headers,
                Body
            },

            ResponseHeaders = <<
                "HTTP/1.1 200 OK\r\n",
                "Content-Type: text/event-stream\r\n",
                "Content-Length: ",
                (integer_to_binary(byte_size(ResponseBody)))/binary,
                "\r\n",
                "Connection: close\r\n\r\n"
            >>,

            ok = gen_tcp:send(Socket, ResponseHeaders),

            lists:foreach(
                fun(Chunk) ->
                    ok = gen_tcp:send(Socket, Chunk),
                    timer:sleep(50)
                end,
                Chunks
            ),

            gen_tcp:close(Socket),
            gen_tcp:close(ListenSocket)
        catch
            Class:Reason:Stacktrace ->
                Parent ! {
                    http_server_error,
                    Class,
                    Reason,
                    Stacktrace
                },
                erlang:raise(Class, Reason, Stacktrace)
        end
    end),

    {Port, ServerPid}.

-spec start_http_stream_server(binary()) ->
    {inet:port_number(), pid()}.
start_http_stream_server(ResponseBody) ->
    start_http_stream_server_with_content_type(
        ResponseBody,
        <<"text/event-stream">>
    ).

-spec start_http_stream_server_stalling() ->
    {inet:port_number(), pid()}.
start_http_stream_server_stalling() ->
    {ok, ListenSocket} = gen_tcp:listen(0, [
        binary,
        {packet, raw},
        {active, false},
        {reuseaddr, true}
    ]),

    {ok, {_Address, Port}} = inet:sockname(ListenSocket),
    Parent = self(),

    ServerPid = spawn(fun() ->
        try
            {ok, Socket} = gen_tcp:accept(ListenSocket, 5000),
            {_RequestLine, _Headers, _Body} =
                read_http_request(Socket),

            ResponseHeaders = <<
                "HTTP/1.1 200 OK\r\n",
                "Content-Type: text/event-stream\r\n",
                "Content-Length: 100\r\n",
                "Connection: close\r\n\r\n"
            >>,

            ok = gen_tcp:send(Socket, ResponseHeaders),

            %% Keep the connection open without sending stream data.
            timer:sleep(2000),

            gen_tcp:close(Socket),
            gen_tcp:close(ListenSocket)
        catch
            Class:Reason:Stacktrace ->
                Parent ! {
                    http_stream_stalling_server_error,
                    Class,
                    Reason,
                    Stacktrace
                },
                erlang:raise(Class, Reason, Stacktrace)
        end
    end),

    {Port, ServerPid}.

-spec start_http_server_sequence([binary()]) ->
    {inet:port_number(), pid(), reference()}.
start_http_server_sequence(ResponseBodies) ->
    {ok, ListenSocket} = gen_tcp:listen(0, [
        binary,
        {packet, raw},
        {active, false},
        {reuseaddr, true}
    ]),

    {ok, {_Address, Port}} = inet:sockname(ListenSocket),

    Parent = self(),
    TestRef = make_ref(),

    ServerPid = spawn(fun() ->
        try
            serve_http_sequence(
                ListenSocket,
                Parent,
                TestRef,
                ResponseBodies,
                1
            )
        catch
            Class:Reason:Stacktrace ->
                Parent ! {
                    http_server_error,
                    TestRef,
                    Class,
                    Reason,
                    Stacktrace
                },
                erlang:raise(Class, Reason, Stacktrace)
        end
    end),

    {Port, ServerPid, TestRef}.

-spec serve_http_sequence(
    port(),
    pid(),
    reference(),
    [binary() | {non_neg_integer(), binary()}],
    pos_integer()
) -> ok.
serve_http_sequence(
    ListenSocket,
    Parent,
    TestRef,
    [ResponseBody | Rest],
    Index
) when is_binary(ResponseBody) ->
    serve_http_sequence(
        ListenSocket,
        Parent,
        TestRef,
        [{200, ResponseBody} | Rest],
        Index
    );
serve_http_sequence(
    ListenSocket,
    Parent,
    TestRef,
    [{Status, ResponseBody} | Rest],
    Index
) ->
    {ok, Socket} = gen_tcp:accept(ListenSocket, 5000),

    {RequestLine, Headers, Body} = read_http_request(Socket),

    Parent ! {
        http_request,
        TestRef,
        RequestLine,
        Headers,
        Body
    },

    Response = <<
        "HTTP/1.1 ",
        (integer_to_binary(Status))/binary,
        " ",
        (status_reason(Status))/binary,
        "\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: ",
        (integer_to_binary(byte_size(ResponseBody)))/binary,
        "\r\nConnection: close\r\n\r\n",
        ResponseBody/binary
    >>,

    ok = gen_tcp:send(Socket, Response),
    gen_tcp:close(Socket),

    serve_http_sequence(
        ListenSocket,
        Parent,
        TestRef,
        Rest,
        Index + 1
    );
serve_http_sequence(ListenSocket, _Parent, _TestRef, [], _Index) ->
    gen_tcp:close(ListenSocket),
    ok.

-spec read_http_request(port()) -> {binary(), binary(), binary()}.
read_http_request(Socket) ->
    {HeaderBlock, InitialBody} = receive_http_headers(Socket, <<>>),
    [RequestLine | _] = binary:split(
        HeaderBlock,
        <<"\r\n">>,
        [global]
    ),

    HeaderLines = binary:split(
        HeaderBlock,
        <<"\r\n">>,
        [global]
    ),

    Headers = iolist_to_binary(
        lists:join(<<"\r\n">>, tl(HeaderLines))
    ),

    ContentLength = request_content_length(HeaderLines),
    Body = receive_http_body(
        Socket,
        InitialBody,
        ContentLength
    ),

    {RequestLine, Headers, Body}.

-spec receive_http_headers(port(), binary()) ->
    {binary(), binary()}.
receive_http_headers(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {Position, 4} ->
            HeaderBlock = binary:part(Acc, 0, Position),
            BodyStart = Position + 4,
            Body = binary:part(
                Acc,
                BodyStart,
                byte_size(Acc) - BodyStart
            ),
            {HeaderBlock, Body};
        nomatch ->
            {ok, Data} = gen_tcp:recv(Socket, 0, 5000),
            receive_http_headers(Socket, <<Acc/binary, Data/binary>>)
    end.

-spec request_content_length([binary()]) -> non_neg_integer().
request_content_length(HeaderLines) ->
    Lengths = [
        list_to_integer(string:trim(binary_to_list(Value)))
        || Line <- HeaderLines,
           binary:match(Line, <<":">>) =/= nomatch,
           {Key, Value} <- [split_header(Line)],
           string:lowercase(binary_to_list(Key)) =:= "content-length"
    ],

    case Lengths of
        [Length | _] -> Length;
        [] -> 0
    end.

-spec split_header(binary()) -> {binary(), binary()}.
split_header(Line) ->
    [Key, Value] = binary:split(Line, <<":">>),
    {Key, Value}.

-spec receive_http_body(port(), binary(), non_neg_integer()) -> binary().
receive_http_body(_Socket, Body, Length)
        when byte_size(Body) >= Length ->
    binary:part(Body, 0, Length);
receive_http_body(Socket, Body, Length) ->
    {ok, Data} = gen_tcp:recv(Socket, 0, 5000),
    receive_http_body(Socket, <<Body/binary, Data/binary>>, Length).

-spec valid_request() -> map().
valid_request() ->
    #{
        model => <<"test-model">>,
        messages => [
            #{
                role => user,
                content => [
                    #{type => text, text => <<"Hello">>}
                ]
            }
        ]
    }.

-spec response_text(map()) -> binary().
response_text(Response) ->
    Message = maps:get(message, Response),
    [Block] = maps:get(content, Message),
    maps:get(text, Block).

-spec status_reason(non_neg_integer()) -> binary().
status_reason(200) -> <<"OK">>;
status_reason(400) -> <<"Bad Request">>;
status_reason(401) -> <<"Unauthorized">>;
status_reason(429) -> <<"Too Many Requests">>;
status_reason(403) -> <<"Forbidden">>;
status_reason(504) -> <<"Gateway Timeout">>;
status_reason(500) -> <<"Internal Server Error">>.
