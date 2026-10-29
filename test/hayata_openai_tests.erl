
-module(hayata_openai_tests).

-include_lib("eunit/include/eunit.hrl").

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

    {Port, ServerPid} = start_http_server(ResponseBody),

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
            {http_request, RequestLine, Headers, Body} ->
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

    {Port, ServerPid} = start_http_server(
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

    {Port, ServerPid} = start_http_server(ResponseBody),
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

    {Port, ServerPid} = start_http_server(<<"not-json">>),
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

    {Port, ServerPid} = start_http_server(
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

    {Port, ServerPid} = start_http_server(ResponseBody),
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

    {Port, ServerPid} = start_http_server(ResponseBody),
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

    {Port, ServerPid} = start_http_server(
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

    {Port, ServerPid} = start_http_server(
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

    {Port, ServerPid} = start_http_server(
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

    {Port, ServerPid} = start_http_server(
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

    Consumer = fun(Event) ->
        Parent ! {stream_event, Event},
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
            {stream_event, Event} ->
                ?assertEqual(
                    message_started,
                    maps:get(type, Event)
                )
        after 5000 ->
            error(message_started_event_not_received)
        end,

        receive
            {stream_event, Event2} ->
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

    Consumer = fun(Event) ->
        Parent ! {stream_event, Event},
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

        EventTypes = receive_stream_event_types(4, []),

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

-spec receive_stream_event_types(non_neg_integer(), [atom()]) -> [atom()].
receive_stream_event_types(0, Acc) ->
    lists:reverse(Acc);
receive_stream_event_types(Count, Acc) ->
    receive
        {stream_event, Event} ->
            receive_stream_event_types(
                Count - 1,
                [maps:get(type, Event) | Acc]
            )
    after 5000 ->
        error(stream_event_not_received)
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

    ServerPid = spawn(fun() ->
        try
            {ok, Socket} = gen_tcp:accept(ListenSocket, 5000),
            {RequestLine, Headers, Body} = read_http_request(Socket),
            Parent ! {http_request, RequestLine, Headers, Body},

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

    {Port, ServerPid}.

-spec start_http_stream_server(binary()) ->
    {inet:port_number(), pid()}.
start_http_stream_server(ResponseBody) ->
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
                "Content-Type: text/event-stream\r\n",
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

-spec status_reason(non_neg_integer()) -> binary().
status_reason(200) -> <<"OK">>;
status_reason(400) -> <<"Bad Request">>;
status_reason(401) -> <<"Unauthorized">>;
status_reason(429) -> <<"Too Many Requests">>;
status_reason(403) -> <<"Forbidden">>;
status_reason(504) -> <<"Gateway Timeout">>;
status_reason(500) -> <<"Internal Server Error">>.
