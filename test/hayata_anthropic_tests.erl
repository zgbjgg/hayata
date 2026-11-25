-module(hayata_anthropic_tests).

-include_lib("eunit/include/eunit.hrl").

capabilities_test() ->
    {ok, Capabilities} = hayata_anthropic:capabilities(#{}),
    Features = maps:get(features, Capabilities),
    ?assertEqual(true, maps:get(tool_calling, Features)),
    ?assertEqual(true, maps:get(streaming, Features)),
    ?assertEqual(false, maps:get(embeddings, Features)).

missing_api_key_test() ->
    ?assertEqual(
        {error, #{code => authentication}},
        hayata_anthropic:generate(valid_request(), #{})
    ).

invalid_configuration_test() ->
    ?assertEqual(
        {error, #{code => invalid_request}},
        hayata_anthropic:generate(valid_request(), #{api_key => <<"key">>, timeout => 0})
    ).

prepare_payload_moves_system_and_developer_to_system_test() ->
    Request = #{
        model => <<"claude-test">>,
        messages => [
            #{role => system, content => [#{type => text, text => <<"system">>}]},
            #{role => developer, content => [#{type => text, text => <<"developer">>}]},
            #{role => user, content => [#{type => text, text => <<"hello">>}]}
        ]
    },
    {ok, Payload} = hayata_anthropic:prepare_payload(Request),
    ?assertEqual(<<"system">>, maps:get(<<"text">>, hd(maps:get(<<"system">>, Payload)))),
    ?assertEqual(<<"developer">>, maps:get(<<"text">>, lists:nth(2, maps:get(<<"system">>, Payload)))),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, hd(maps:get(<<"messages">>, Payload)))).

tool_schema_conversion_test() ->
    Request = (valid_request())#{
        tools => [#{
            name => <<"lookup">>,
            description => <<"Look up a value">>,
            parameters => #{
                type => object,
                properties => #{city => #{type => string}},
                required => [city]
            },
            handler => fun(_) -> ok end
        }]
    },
    {ok, Payload} = hayata_anthropic:prepare_payload(Request),
    [Tool] = maps:get(<<"tools">>, Payload),
    ?assertEqual(<<"lookup">>, maps:get(<<"name">>, Tool)),
    ?assert(maps:is_key(<<"input_schema">>, Tool)),
    ?assertNot(maps:is_key(<<"handler">>, Tool)).

normalizes_text_response_test() ->
    Response = #{
        <<"id">> => <<"msg_1">>,
        <<"type">> => <<"message">>,
        <<"role">> => <<"assistant">>,
        <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"Hello">>}],
        <<"stop_reason">> => <<"end_turn">>
    },
    {ok, Normalized} = hayata_anthropic:normalize_response(Response),
    ?assertEqual(stop, maps:get(finish_reason, Normalized)),
    ?assertEqual(<<"msg_1">>, maps:get(id, Normalized)),
    ?assertEqual([#{type => text, text => <<"Hello">>}],
                 maps:get(content, maps:get(message, Normalized))).

normalizes_tool_call_test() ->
    Response = #{
        <<"type">> => <<"message">>,
        <<"role">> => <<"assistant">>,
        <<"content">> => [
            #{<<"type">> => <<"text">>, <<"text">> => <<"Need a lookup">>},
            #{<<"type">> => <<"tool_use">>, <<"id">> => <<"toolu_1">>,
              <<"name">> => <<"lookup">>, <<"input">> => #{<<"city">> => <<"Puebla">>}}
        ],
        <<"stop_reason">> => <<"tool_use">>
    },
    {ok, Normalized} = hayata_anthropic:normalize_response(Response),
    ?assertEqual(tool_calls, maps:get(finish_reason, Normalized)),
    Message = maps:get(message, Normalized),
    [Call] = maps:get(tool_calls, Message),
    ?assertEqual(<<"toolu_1">>, maps:get(id, Call)),
    ?assertEqual(<<"lookup">>, maps:get(name, Call)),
    ?assertEqual(#{city => <<"Puebla">>}, maps:get(arguments, Call)),
    ?assertEqual(<<"Need a lookup">>, maps:get(text, hd(maps:get(content, Message)))).

rejects_malformed_tool_call_test() ->
    Response = #{
        <<"type">> => <<"message">>,
        <<"role">> => <<"assistant">>,
        <<"content">> => [#{<<"type">> => <<"tool_use">>,
            <<"id">> => <<"">>, <<"name">> => <<"lookup">>, <<"input">> => #{}}],
        <<"stop_reason">> => <<"tool_use">>
    },
    ?assertEqual({error, #{code => invalid_response}},
                 hayata_anthropic:normalize_response(Response)).

rejects_unknown_stop_reason_test() ->
    Response = #{
        <<"type">> => <<"message">>, <<"role">> => <<"assistant">>,
        <<"content">> => [], <<"stop_reason">> => <<"something_new">>
    },
    ?assertEqual({error, #{code => invalid_response}},
                 hayata_anthropic:normalize_response(Response)).

http_error_mapping_test() ->
    ?assertEqual({error, #{code => authentication}},
                 hayata_anthropic:normalize_http_error(401, <<>>)),
    ?assertEqual({error, #{code => rate_limited}},
                 hayata_anthropic:normalize_http_error(429, <<>>)),
    ?assertEqual({error, #{code => provider_error}},
                 hayata_anthropic:normalize_http_error(503, <<>>)).

sse_parser_handles_split_chunk_test() ->
    {ok, [], State1} = hayata_anthropic:parse_sse_chunk(
        <<"event: content_block_delta\ndata: {\"delta\":" >>,
        #{buffer => <<>>, event => undefined, data => []}
    ),
    {ok, [Event], _State2} = hayata_anthropic:parse_sse_chunk(
        <<"{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n">>,
        State1
    ),
    ?assertEqual(<<"content_block_delta">>, maps:get(event, Event)).

normalizes_stream_text_delta_test() ->
    Raw = #{event => <<"content_block_delta">>, data => #{
        <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => <<"hello">>}
    }},
    {ok, Event, State} = hayata_anthropic:normalize_sse_event(Raw, #{}),
    ?assertEqual(content_delta, maps:get(type, Event)),
    ?assertEqual(<<"hello">>, maps:get(text, maps:get(data, Event))),
    ?assert(maps:is_key(generation_id, State)).

normalize_stream_stop_reason_test() ->
    Raw = #{event => <<"message_delta">>, data => #{
        <<"delta">> => #{<<"stop_reason">> => <<"max_tokens">>}
    }},
    {ok, undefined, State} = hayata_anthropic:normalize_sse_event(Raw, #{}),
    ?assertEqual(<<"max_tokens">>, maps:get(stop_reason, State)).

valid_request() ->
    #{
        model => <<"claude-test">>,
        messages => [#{role => user, content => [#{type => text, text => <<"hello">>}]}]
    }.

tool_history_converts_without_handler_test() ->
    Request = #{
        model => <<"claude-test">>,
        messages => [
            #{role => assistant, content => [#{type => text, text => <<"I'll check">>}],
              tool_calls => [#{id => <<"toolu_1">>, name => <<"lookup">>,
                               arguments => #{city => <<"Puebla">>}}]},
            #{role => tool, tool_call_id => <<"toolu_1">>,
              content => [#{type => text, text => <<"Found it">>}]}
        ]
    },
    {ok, Payload} = hayata_anthropic:prepare_payload(Request),
    [Assistant, ToolResult] = maps:get(<<"messages">>, Payload),
    ?assertEqual(<<"tool_use">>, maps:get(<<"type">>, lists:nth(2, maps:get(<<"content">>, Assistant)))),
    ?assertEqual(<<"tool_result">>, maps:get(<<"type">>, hd(maps:get(<<"content">>, ToolResult)))).
