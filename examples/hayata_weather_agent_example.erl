-module(hayata_weather_agent_example).

-export([
    run/0,
    get_current_weather/1
]).

-define(AGENT_ID, weather_agent).
-define(MODEL, <<"gpt-4o-mini">>).

-doc("Runs the weather agent with a real OpenAI request.").
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
        agent => fun agent_node/1
    },

    Config = #{
        id => ?AGENT_ID,
        state => #{},
        nodes => Nodes,
        llm => LLM,
        decision_policy => fun decision_policy/1,
        max_steps => 5,
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
                "~n[FINAL] ~ts~n",
                [maps:get(answer, Result, <<"(no text response)">>)]
            ),
            {ok, Result};
        {hayata_agent_result, InvocationId, {error, Reason}} ->
            {error, Reason}
    after Timeout ->
        {error, invocation_timeout}
    end.

%% The node receives the state map directly.
%% Hayata injects hayata_tool_loop when llm is configured.

-spec agent_node(map()) -> map().
agent_node(State) ->
    ToolLoop = maps:get(hayata_tool_loop, State),
    Messages = current_messages(State),
    Tools = weather_tools(),

    Request = #{
        messages => Messages
    },

    io:format("~n[AGENT] Running the LLM tool loop...~n"),

    case ToolLoop(Request, Tools, 5) of
        {ok, LoopResult} ->
            Response = maps:get(response, LoopResult),
            UpdatedMessages = maps:get(messages, LoopResult),

            io:format(
                "[AGENT] Tool loop completed after ~p iteration(s).~n",
                [maps:get(iterations, LoopResult)]
            ),

            #{
                messages => UpdatedMessages,
                last_response => Response
            };
        {error, Reason} ->
            error({tool_loop_failed, Reason})
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

%% The policy receives the policy context, not the node state.

-spec decision_policy(map()) -> tuple().
decision_policy(#{step := 0, input := Input}) ->
    {next, agent, Input};
decision_policy(#{state := State}) ->
    Response = maps:get(last_response, State),
    {finish, #{
        answer => response_text(Response),
        messages => maps:get(messages, State)
    }}.

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

%% This is deterministic demo data, not a live weather service.

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
