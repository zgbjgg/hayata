-module(hayata_weather_agent_stream_example).

-export([
    run/0,
    get_current_weather/1
]).

-define(AGENT_ID, hayata_weather_agent_stream).
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

    Nodes = #{
        agent => fun agent_node/1,
        tools => fun tools_node/1
    },

    Config = #{
        id => ?AGENT_ID,
        state => #{},
        nodes => Nodes,
        llm => LLM,
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
        "Do I need an umbrella if I am in Buenos Aires today?"
    ),

    io:format("~n[USER] ~ts~n", [Query]),

    case hayata_agent:run(
        AgentPid,
        Query,
        #{
            subscriber => self(),
            stream => true
        }
    ) of
        {ok, InvocationId} ->
            await_result(InvocationId, 120000);
        {error, Reason} ->
            {error, {invocation_start_failed, Reason}}
    end.

-spec await_result(reference(), timeout()) ->
    {ok, map()} | {error, term()}.
await_result(InvocationId, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_result_until(InvocationId, Deadline).

-spec await_result_until(reference(), integer()) ->
    {ok, map()} | {error, term()}.
await_result_until(InvocationId, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),

    case Remaining =< 0 of
        true ->
            {error, invocation_timeout};
        false ->
            receive
                {hayata_agent_event, InvocationId, Event} ->
                    handle_agent_event(Event),
                    await_result_until(InvocationId, Deadline);

                {hayata_agent_result, InvocationId, {ok, Result}} ->
                    io:format("~n[FINAL] Streaming completed successfully.~n"),
                    {ok, Result};

                {hayata_agent_result, InvocationId, {error, Reason}} ->
                    {error, Reason}
            after Remaining ->
                {error, invocation_timeout}
            end
    end.

-spec handle_agent_event(map()) -> ok.
handle_agent_event(#{
    type := llm_content_delta,
    data := #{text := Text}
}) when is_binary(Text) ->
    io:put_chars(Text),
    ok;
handle_agent_event(#{
    type := llm_generation_completed
}) ->
    io:format("~n"),
    ok;
handle_agent_event(#{
    type := llm_generation_failed,
    data := Data
}) ->
    io:format("~n[STREAM ERROR] ~p~n", [Data]),
    ok;
handle_agent_event(_Event) ->
    ok.

%% Hayata injects hayata_llm_stream into the node state.
%% The stream events are forwarded through the agent subscriber.

-spec agent_node(map()) -> map().
agent_node(State) ->
    LLMStream = maps:get(hayata_llm_stream, State),
    Messages = current_messages(State),
    Tools = weather_tools(),

    case hayata_tool:definitions(Tools) of
        {ok, Definitions} ->
            Request = #{
                messages => Messages,
                tools => Definitions
            },

            io:format("[AGENT] Calling the injected streaming function...~n"),

            case LLMStream(Request) of
                {ok, Response} ->
                    handle_llm_response(Response, Messages);
                {error, Reason} ->
                    error({llm_generation_failed, Reason})
            end;
        {error, Reason} ->
            error({invalid_tool_definitions, Reason})
    end.

-spec handle_llm_response(map(), [map()]) -> map().
handle_llm_response(Response, Messages) ->
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
    end.

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

-spec weather_tools() -> [map()].
weather_tools() ->
    [
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
    ].

-spec tools_node(map()) -> map().
tools_node(State) ->
    Calls = maps:get(pending_tool_calls, State, []),
    Messages = maps:get(messages, State),
    Tools = weather_tools(),

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

%% The policy receives the policy context.

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
