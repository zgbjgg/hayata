
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
