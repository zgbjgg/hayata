
-module(hayata_rag_tests).

-include_lib("eunit/include/eunit.hrl").

-export([mfa_retrieve/2]).

new_accepts_anonymous_retriever_test() ->
    Retrieve = fun(_Query, _Options) ->
        {ok, #{documents => []}}
    end,

    ?assertMatch(
        {ok, Rag} when is_function(Rag, 2),
        hayata_rag:new(#{retrieve => Retrieve})
    ).

new_accepts_mfa_retriever_test() ->
    ?assertMatch(
        {ok, Rag} when is_function(Rag, 2),
        hayata_rag:new(#{
            retrieve => {?MODULE, mfa_retrieve}
        })
    ).

new_rejects_missing_retriever_test() ->
    ?assertEqual(
        {error, invalid_config},
        hayata_rag:new(#{})
    ).

new_rejects_invalid_retriever_test() ->
    ?assertEqual(
        {error, invalid_config},
        hayata_rag:new(#{
            retrieve => invalid_retriever
        })
    ).

new_rejects_unavailable_mfa_test() ->
    ?assertEqual(
        {error, invalid_config},
        hayata_rag:new(#{
            retrieve => {non_existing_rag_module, retrieve}
        })
    ).

new_rejects_unexported_mfa_test() ->
    ?assertEqual(
        {error, invalid_config},
        hayata_rag:new(#{
            retrieve => {?MODULE, non_existing_function}
        })
    ).

validate_config_accepts_anonymous_retriever_test() ->
    ?assertEqual(
        ok,
        hayata_rag:validate_config(#{
            retrieve => fun(_Query, _Options) ->
                {ok, #{documents => []}}
            end
        })
    ).

validate_config_rejects_invalid_config_test() ->
    ?assertEqual(
        {error, invalid_config},
        hayata_rag:validate_config(undefined)
    ).

retrieve_with_anonymous_function_test() ->
    ExpectedDocuments = [valid_document()],

    {ok, Rag} = hayata_rag:new(#{
        retrieve => fun(Query, Options) ->
            ?assertEqual(<<"Erlang OTP">>, Query),
            ?assertEqual(5, maps:get(limit, Options)),
            {ok, #{documents => ExpectedDocuments}}
        end
    }),

    ?assertEqual(
        {ok, #{documents => ExpectedDocuments}},
        Rag(<<"Erlang OTP">>, #{limit => 5})
    ).

retrieve_with_mfa_test() ->
    {ok, Rag} = hayata_rag:new(#{
        retrieve => {?MODULE, mfa_retrieve}
    }),

    ?assertEqual(
        {ok, #{documents => [valid_document()]}},
        Rag(<<"Erlang OTP">>, #{})
    ).

retrieve_accepts_empty_documents_test() ->
    {ok, Rag} = hayata_rag:new(#{
        retrieve => fun(_Query, _Options) ->
            {ok, #{documents => []}}
        end
    }),

    ?assertEqual(
        {ok, #{documents => []}},
        Rag(<<"unknown topic">>, #{})
    ).

retrieve_preserves_provider_error_test() ->
    ExpectedError = {
        error,
        #{code => provider_error, reason => unavailable}
    },

    {ok, Rag} = hayata_rag:new(#{
        retrieve => fun(_Query, _Options) ->
            ExpectedError
        end
    }),

    ?assertEqual(
        ExpectedError,
        Rag(<<"Erlang OTP">>, #{})
    ).

retrieve_normalizes_provider_exception_test() ->
    {ok, Rag} = hayata_rag:new(#{
        retrieve => fun(_Query, _Options) ->
            erlang:error(provider_crashed)
        end
    }),

    ?assertEqual(
        {error, #{
            code => provider_error,
            reason => retriever_call_failed
        }},
        Rag(<<"Erlang OTP">>, #{})
    ).

retrieve_rejects_empty_query_test() ->
    {ok, Rag} = hayata_rag:new(#{
        retrieve => fun(_Query, _Options) ->
            {ok, #{documents => []}}
        end
    }),

    ?assertEqual(
        {error, #{code => invalid_request}},
        Rag(<<>>, #{})
    ).

retrieve_rejects_non_binary_query_test() ->
    {ok, Rag} = hayata_rag:new(#{
        retrieve => fun(_Query, _Options) ->
            {ok, #{documents => []}}
        end
    }),

    ?assertEqual(
        {error, #{code => invalid_request}},
        Rag(not_a_binary, #{})
    ).

retrieve_rejects_non_map_options_test() ->
    {ok, Rag} = hayata_rag:new(#{
        retrieve => fun(_Query, _Options) ->
            {ok, #{documents => []}}
        end
    }),

    ?assertEqual(
        {error, #{code => invalid_request}},
        Rag(<<"Erlang OTP">>, invalid_options)
    ).

validate_result_accepts_valid_document_test() ->
    ?assertEqual(
        {ok, #{documents => [valid_document()]}},
        hayata_rag:validate_result(
            {ok, #{documents => [valid_document()]}}
        )
    ).

validate_result_accepts_document_without_score_test() ->
    Document = maps:remove(score, valid_document()),

    ?assertEqual(
        {ok, #{documents => [Document]}},
        hayata_rag:validate_result(
            {ok, #{documents => [Document]}}
        )
    ).

validate_result_accepts_empty_documents_test() ->
    ?assertEqual(
        {ok, #{documents => []}},
        hayata_rag:validate_result(
            {ok, #{documents => []}}
        )
    ).

validate_result_rejects_missing_documents_test() ->
    ?assertEqual(
        {error, #{code => invalid_response}},
        hayata_rag:validate_result({ok, #{}})
    ).

validate_result_rejects_non_list_documents_test() ->
    ?assertEqual(
        {error, #{code => invalid_response}},
        hayata_rag:validate_result(
            {ok, #{documents => not_a_list}}
        )
    ).

validate_result_rejects_invalid_document_test() ->
    ?assertEqual(
        {error, #{code => invalid_response}},
        hayata_rag:validate_result(
            {ok, #{documents => [#{content => <<"Missing id">>}]}}
        )
    ).

validate_result_rejects_empty_document_id_test() ->
    Document = (valid_document())#{id => <<>>},

    ?assertEqual(
        {error, #{code => invalid_response}},
        hayata_rag:validate_result(
            {ok, #{documents => [Document]}}
        )
    ).

validate_result_rejects_non_binary_content_test() ->
    Document = (valid_document())#{content => invalid_content},

    ?assertEqual(
        {error, #{code => invalid_response}},
        hayata_rag:validate_result(
            {ok, #{documents => [Document]}}
        )
    ).

validate_result_rejects_non_map_metadata_test() ->
    Document = (valid_document())#{metadata => invalid_metadata},

    ?assertEqual(
        {error, #{code => invalid_response}},
        hayata_rag:validate_result(
            {ok, #{documents => [Document]}}
        )
    ).

validate_result_rejects_non_numeric_score_test() ->
    Document = (valid_document())#{score => invalid_score},

    ?assertEqual(
        {error, #{code => invalid_response}},
        hayata_rag:validate_result(
            {ok, #{documents => [Document]}}
        )
    ).

validate_result_preserves_provider_error_test() ->
    Error = {error, #{code => timeout}},

    ?assertEqual(
        Error,
        hayata_rag:validate_result(Error)
    ).

validate_result_rejects_invalid_response_test() ->
    ?assertEqual(
        {error, #{code => invalid_response}},
        hayata_rag:validate_result(unexpected_response)
    ).

-spec mfa_retrieve(binary(), map()) -> term().
mfa_retrieve(_Query, _Options) ->
    {ok, #{documents => [valid_document()]}}.

-spec valid_document() -> hayata_rag:document().
valid_document() ->
    #{
        id => <<"chunk-001">>,
        content => <<"Erlang is a concurrent functional language.">>,
        metadata => #{
            source => <<"erlang-guide.pdf">>
        },
        score => 0.95
    }.
