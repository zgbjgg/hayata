-module(hayata_rag_example).

-export([run/1]).

-doc("Runs the RAG agent with a real OpenAI request.").
-spec run(binary()) -> {ok, map()} | {error, term()}.
run(Question) ->
    case os:getenv("OPENAI_API_KEY") of
        false ->
            {error, missing_openai_api_key};
        ApiKey ->
            case application:ensure_all_started(hayata) of
                {ok, _Started} ->
                    run_agent(list_to_binary(ApiKey), Question);
                {error, Reason} ->
                    {error, {application_start_failed, Reason}}
            end
    end.

run_agent(ApiKey, Question) ->
    Config = #{
        id => hayata_rag_agent,
        state => #{},
        nodes => #{
            agent => fun agent_node/1
        },
        decision_policy => fun decision_policy/1,
        max_steps => 5,
        execution_timeout => 60000,

        llm => #{
            adapter => hayata_openai,
            model => <<"gpt-4o-mini">>,
            provider_config => #{
                api_key => ApiKey
            }
        },

        rag_config => #{
            retrieve => fun retrieve_documents/2
        }
    },

    case hayata_sup:start_agent(Config) of
        {ok, AgentSupPid} ->
            try
                {ok, AgentPid} = hayata_agent_sup:agent(AgentSupPid),

                case hayata_agent:run(
                    AgentPid,
                    Question,
                    #{subscriber => self()}
                ) of
                    {ok, InvocationId} ->
                        await_result(InvocationId);
                    {error, Reason} ->
                        {error, Reason}
                end
            after
                hayata_sup:stop_agent(AgentSupPid)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% 1. RAG retriever.
%% Replace this example with your own vector database.

retrieve_documents(Query, Options) ->
    Documents = knowledge_base(),
    Tokens = query_tokens(Query),

    ScoredDocuments = [
        Document#{
            score => relevance_score(
                Tokens,
                maps:get(content, Document)
            )
        }
        || Document <- Documents
    ],

    RelevantDocuments = [
        Document
        || Document <- ScoredDocuments,
           maps:get(score, Document) > 0
    ],

    SortedDocuments = lists:sort(
        fun(A, B) ->
            ScoreA = maps:get(score, A),
            ScoreB = maps:get(score, B),

            case ScoreA =:= ScoreB of
                true ->
                    maps:get(id, A) =< maps:get(id, B);
                false ->
                    ScoreA > ScoreB
            end
        end,
        RelevantDocuments
    ),

    Limit = maps:get(limit, Options, 5),

    {ok, #{
        documents => lists:sublist(SortedDocuments, Limit)
    }}.

knowledge_base() ->
    [
        #{
            id => <<"hayata-architecture">>,
            content =>
                <<"Hayata is an Erlang/OTP framework for building "
                  "AI agents. Its architecture is based on agents, "
                  "nodes, edges and decision policies. The agent "
                  "coordinates node execution and controls the "
                  "execution flow.">>,
            metadata => #{
                source => <<"hayata-documentation">>,
                topic => <<"architecture">>
            }
        },
        #{
            id => <<"hayata-parallel-execution">>,
            content =>
                <<"Hayata supports parallel node execution. "
                  "An agent can dispatch multiple nodes through "
                  "a parallel transition. Each node executes "
                  "independently and its result is collected "
                  "in parallel_results in the requested order.">>,
            metadata => #{
                source => <<"hayata-documentation">>,
                topic => <<"parallel-execution">>
            }
        },
        #{
            id => <<"hayata-rag">>,
            content =>
                <<"Hayata provides provider-agnostic RAG retrieval "
                  "through hayata_rag. Applications supply their "
                  "own retriever function or MFA. Retrieved "
                  "documents are validated and normalized into "
                  "a common document contract.">>,
            metadata => #{
                source => <<"hayata-documentation">>,
                topic => <<"rag">>
            }
        },
        #{
            id => <<"hayata-llm-tools">>,
            content =>
                <<"Hayata integrates language models through "
                  "hayata_llm and supports tool calling through "
                  "hayata_tool_loop. The tool loop executes "
                  "registered handlers, adds their results to "
                  "the conversation and calls the language "
                  "model again to produce a final response.">>,
            metadata => #{
                source => <<"hayata-documentation">>,
                topic => <<"llm-tools">>
            }
        },
        #{
            id => <<"hayata-checkpoints">>,
            content =>
                <<"Hayata supports execution checkpoints and "
                  "recovery. Checkpoints allow the framework "
                  "to persist execution information and recover "
                  "interrupted node executions.">>,
            metadata => #{
                source => <<"hayata-documentation">>,
                topic => <<"recovery">>
            }
        }
    ].

query_tokens(Query) ->
    Lowercase = string:lowercase(
        unicode:characters_to_list(Query)
    ),
    Tokens = re:split(
        Lowercase,
        "[^[:alnum:]]+",
        [unicode, {return, binary}, trim]
    ),
    lists:usort([
        Token
        || Token <- Tokens,
           byte_size(Token) >= 3
    ]).

relevance_score(Tokens, Content) ->
    Lowercase = string:lowercase(
        unicode:characters_to_list(Content)
    ),
    ContentBinary = unicode:characters_to_binary(Lowercase),

    length([
        Token
        || Token <- Tokens,
           binary:match(ContentBinary, Token) =/= nomatch
    ]).

%% 2. Agent node.
%% The LLM decides when to call the retrieval tool.

agent_node(Context) ->
    ToolLoop = maps:get(hayata_tool_loop, Context),
    Rag = maps:get(hayata_rag, Context),

    SearchTool = #{
        name => <<"search_knowledge">>,
        description =>
            <<"Searches the Hayata documentation knowledge base. "
              "Use this tool whenever the user asks about Hayata's "
              "architecture, features, execution model, RAG, LLM "
              "integration, tools, or recovery. "
              "Search for the specific subject asked by the user. "
              "Use the returned documents as the primary source "
              "when generating the answer. Do not invent implementation "
              "details that are not supported by the retrieved documents.">>,
        parameters => #{
            type => object,
            properties => #{
                query => #{
                    type => string,
                    description =>
                        <<"A concise search query describing the specific "
                          "Hayata concept or functionality being asked about.">>
                }
            },
            required => [<<"query">>]
        },
        handler => fun(Arguments) ->
            Rag(
                maps:get(<<"query">>, Arguments),
                #{limit => 5}
            )
        end
    },

    Request = #{
        messages => [
            #{
                role => user,
                content => [
                    #{
                        type => text,
                        text => maps:get(input, Context)
                    }
                ]
            }
        ]
    },

    case ToolLoop(Request, [SearchTool], 5) of
        {ok, Result} ->
            #{
                answer => maps:get(response, Result)
            };
        {error, Reason} ->
            #{
                error => Reason
            }
    end.

%% 3. Agent control flow.

decision_policy(Context) ->
    case maps:get(step, Context) of
        0 ->
            {next, agent, maps:get(input, Context)};
        1 ->
            {finish, maps:get(state, Context)}
    end.

%% 4. Receive the final result.

await_result(InvocationId) ->
    receive
        {hayata_agent_result, InvocationId, {ok, Result}} ->
            print_answer(Result),
            {ok, Result};

        {hayata_agent_result, InvocationId, {error, Reason}} ->
            {error, Reason}
    after 60000 ->
        {error, invocation_timeout}
    end.

print_answer(Result) ->
    case maps:find(answer, Result) of
        {ok, Response} ->
            Message = maps:get(message, Response),
            Content = maps:get(content, Message, []),

            lists:foreach(
                fun
                    (#{type := text, text := Text}) ->
                        io:format("~ts~n", [Text]);
                    (_) ->
                        ok
                end,
                Content
            );
        error ->
            io:format("Agent result: ~p~n", [Result])
    end.
