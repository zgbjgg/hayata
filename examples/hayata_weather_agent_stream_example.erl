
-module(hayata_weather_agent_stream_example).

-export([
    run/0,
    get_current_weather/1
]).

-define(AGENT_ID, hayata_weather_agent_example).
-define(MODEL, <<"gpt-4o-mini">>).

-doc("Runs the streaming weather agent using OpenAI.").
-spec run() -> {ok, map()} | {error, term()}.
run() ->
    case os:getenv("OPENAI_API_KEY") of
        false ->
            {error, missing_openai_api_key};
        ApiKey ->
            case application:ensure_all_started(hayata) of
                {ok, _Started} ->
                    start_weather_agent(list_to_binary(ApiKey));
                {error, Reason} ->
                    {error, {application_start_failed, Reason}}
            end
    end.

-spec start_weather_agent(binary()) ->
    {ok, map()} | {error, term()}.
start_weather_agent(ApiKey) ->
    LLM = #{
        adapter => hayata_openai,
        model => ?MODEL,
        provider_config => #{api_key => ApiKey}
    },

    Tools = [
        #{
            name => <<"get_current_weather">>,
            description => unicode:characters_to_binary(
                "Gets the current weather for a specific location."
            ),
            parameters => #{
                type => object,
                properties => #{
                    location => #{type => string}
                },
                required => [location]
            },
            handler => fun ?MODULE:get_current_weather/1
        }
    ],

    case hayata_tool:definitions(Tools) of
        {ok, Definitions} ->
            start_agent(LLM, Tools, Definitions);
        {error, Reason} ->
            {error, {invalid_tool_definitions, Reason}}
    end.

-spec start_agent(map(), [map()], [map()]) ->
    {ok, map()} | {error, term()}.
start_agent(LLM, Tools, Definitions) ->
    Nodes = #{
        agent => fun(State) ->
            agent_node(State, LLM, Definitions)
        end,
        tools => fun(State) ->
            tools_node(State, Tools)
        end
    },

    Config = #{
        id => ?AGENT_ID,
        state => #{},
        nodes => Nodes,
        decision_policy => fun decision_policy/1,
        max_steps => 10,
        execution_timeout => 60000
    },

    case hayata_sup:start_agent(Config) of
        {ok, AgentSupPid} ->
            try
                case hayata_agent_sup:agent(AgentSupPid) of
                    {ok, AgentPid} ->
                        execute_query(AgentPid);
                    {error, Reason} ->
                        {error, {agent_not_found, Reason}}
                end
            after
                hayata_sup:stop_agent(AgentSupPid)
            end;
        {error, Reason} ->
            {error, {agent_start_failed, Reason}}
    end.

-spec execute_query(pid()) -> {ok, map()} | {error, term()}.
execute_query(AgentPid) ->
    Query = unicode:characters_to_binary(
        "¿Necesito paraguas si estoy en Buenos Aires hoy?"
    ),

    io:format("~n[USER] ~ts~n", [Query]),

    case hayata_agent:run(
        AgentPid,
        Query,
        #{subscriber => self()}
    ) of
        {ok, InvocationId} ->
            await_result(InvocationId, 120000);
        {error, Reason} ->
            {error, {invocation_start_failed, Reason}}
    end.

-spec await_result(reference(), timeout()) ->
    {ok, map()} | {error, term()}.
await_result(InvocationId, Timeout) ->
    receive
        {hayata_agent_result, InvocationId, {ok, Result}} ->
            io:format(
                "~n[FINAL] Streaming completed successfully.~n"
            ),
            {ok, Result};
        {hayata_agent_result, InvocationId, {error, Reason}} ->
            {error, Reason}
    after Timeout ->
        {error, invocation_timeout}
    end.

-spec agent_node(map(), map(), [map()]) -> map().
agent_node(State, LLM, ToolDefinitions) ->
    Messages = current_messages(State),

    io:format("[AGENT] Calling OpenAI with streaming...~n"),

    Request = #{
        messages => Messages,
        tools => ToolDefinitions
    },

    case hayata_llm:generate_stream(
        LLM,
        Request,
        fun stream_consumer/1
    ) of
        {ok, Response} ->
            Message = maps:get(message, Response),
            Calls = maps:get(tool_calls, Message, []),
            UpdatedMessages = Messages ++ [Message],

            case Calls of
                [] ->
                    io:format("[AGENT] No tool calls; finishing.~n"),
                    #{
                        messages => UpdatedMessages,
                        pending_tool_calls => [],
                        last_response => Response,
                        next_action => finish
                    };
                _ ->
                    io:format(
                        "[AGENT] Requested tools: ~p~n",
                        [[maps:get(name, Call) || Call <- Calls]]
                    ),
                    #{
                        messages => UpdatedMessages,
                        pending_tool_calls => Calls,
                        last_response => Response,
                        next_action => tools
                    }
            end;
        {error, Reason} ->
            error({llm_generation_failed, Reason})
    end.

-spec stream_consumer(map()) -> ok | {error, term()}.
stream_consumer(#{
    type := content_delta,
    data := #{text := Text}
}) when is_binary(Text) ->
    io:put_chars(Text),
    ok;
stream_consumer(#{
    type := generation_failed,
    data := #{error := Error}
}) ->
    io:format("~n[STREAM ERROR] ~p~n", [Error]),
    ok;
stream_consumer(#{type := generation_completed}) ->
    io:format("~n"),
    ok;
stream_consumer(_Event) ->
    ok.

-spec current_messages(map()) -> [map()].
current_messages(#{messages := Messages}) ->
    Messages;
current_messages(#{input := Input}) ->
    [
        #{
            role => user,
            content => [
                #{type => text, text => Input}
            ]
        }
    ].

-spec tools_node(map(), [map()]) -> map().
tools_node(State, Tools) ->
    Calls = maps:get(pending_tool_calls, State, []),
    Messages = maps:get(messages, State),

    io:format(
        "[TOOLS] Executing ~p tool call(s).~n",
        [length(Calls)]
    ),

    ToolMessages = execute_tool_calls(Calls, Tools, []),

    #{
        messages => Messages ++ ToolMessages,
        pending_tool_calls => [],
        next_action => agent
    }.

-spec execute_tool_calls([map()], [map()], [map()]) -> [map()].
execute_tool_calls([Call | Rest], Tools, Acc) ->
    Id = maps:get(id, Call),
    Name = maps:get(name, Call),
    Arguments = maps:get(arguments, Call),

    io:format("[TOOLS] ~ts(~p)~n", [Name, Arguments]),

    Result = hayata_tool:execute(Name, Arguments, Tools),

    ToolMessage = #{
        role => tool,
        tool_call_id => Id,
        name => Name,
        content => [
            #{
                type => text,
                text => tool_result_text(Result)
            }
        ]
    },

    execute_tool_calls(
        Rest,
        Tools,
        [ToolMessage | Acc]
    );
execute_tool_calls([], _Tools, Acc) ->
    lists:reverse(Acc).

-spec tool_result_text(term()) -> binary().
tool_result_text(Result) when is_binary(Result) ->
    Result;
tool_result_text({error, _Reason}) ->
    <<"{\"error\":\"tool_execution_failed\"}">>;
tool_result_text(Result) ->
    try iolist_to_binary(json:encode(Result)) of
        Encoded ->
            Encoded
    catch
        _:_ ->
            <<"{\"error\":\"tool_result_not_serializable\"}">>
    end.

-spec decision_policy(map()) -> tuple().
decision_policy(#{step := 0, input := Input}) ->
    {next, agent, Input};
decision_policy(#{state := State}) ->
    case maps:get(next_action, State, undefined) of
        tools ->
            {next, tools, maps:get(pending_tool_calls, State)};
        agent ->
            {next, agent, maps:get(messages, State)};
        finish ->
            Response = maps:get(last_response, State),
            {
                finish,
                #{
                    answer => response_text(Response),
                    messages => maps:get(messages, State)
                }
            };
        Other ->
            {error, {unexpected_next_action, Other}}
    end.

-spec response_text(map()) -> binary().
response_text(Response) ->
    Message = maps:get(message, Response),
    Content = maps:get(content, Message, []),

    TextParts = [
        maps:get(text, Block, <<>>)
        || Block <- Content,
           maps:get(type, Block, undefined) =:= text
    ],

    iolist_to_binary(TextParts).

-doc("Returns simulated weather for a supported location.").
-spec get_current_weather(map()) -> binary().
get_current_weather(#{<<"location">> := Location}) ->
    get_current_weather(#{location => Location});
get_current_weather(#{location := Location})
        when is_binary(Location) ->
    LowerLocation = unicode:characters_to_binary(
        string:lowercase(Location)
    ),

    case {
        binary:match(LowerLocation, <<"madrid">>),
        binary:match(LowerLocation, <<"buenos aires">>),
        binary:match(
            LowerLocation,
            unicode:characters_to_binary("ciudad de méxico")
        ),
        binary:match(LowerLocation, <<"cdmx">>)
    } of
        {{_, _}, _, _, _} ->
            unicode:characters_to_binary(
                "The weather in Madrid is sunny, 22°C."
            );
        {_, {_, _}, _, _} ->
            unicode:characters_to_binary(
                "The weather in Buenos Aires is rainy, 15°C."
            );
        {_, _, {_, _}, _} ->
            unicode:characters_to_binary(
                "The weather in Mexico City is cloudy, 19°C."
            );
        {_, _, _, {_, _}} ->
            unicode:characters_to_binary(
                "The weather in Mexico City is cloudy, 19°C."
            );
        _ ->
            iolist_to_binary([
                <<"No weather data found for ">>,
                Location,
                <<".">>
            ])
    end.
