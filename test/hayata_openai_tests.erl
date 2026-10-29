
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
