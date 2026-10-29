
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

-spec start_http_server(binary()) -> {inet:port_number(), pid()}.
start_http_server(ResponseBody) ->
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
                "HTTP/1.1 200 OK\r\n",
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
