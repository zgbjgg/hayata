-module(hayata_router_decision_example).

-export([run/1]).

-spec run(binary()) -> {ok, term()} | {error, term()}.
run(Message) when is_binary(Message) ->
    Nodes = #{
        router => fun router_node/1,
        greeting_processor => fun greeting_node/1,
        math_processor => fun math_node/1
    },

    Config = #{
        id => router_decision_agent,
        nodes => Nodes,
        decision_policy => fun decision_policy/1,
        max_steps => 5
    },

    case hayata_sup:start_agent(Config) of
        {ok, AgentSupPid} ->
            try
                run_agent(AgentSupPid, Message)
            after
                hayata_sup:stop_agent(AgentSupPid)
            end;
        {error, Reason} ->
            {error, {agent_start_failed, Reason}}
    end.

-spec router_node(map()) -> map().
router_node(State) ->
    Message = maps:get(input, State, <<>>),
    Normalized = string:lowercase(binary_to_list(Message)),
    Route = case contains_greeting(Normalized) of
        true ->
            go_to_greeting;
        false ->
            go_to_math
    end,
    #{route => Route}.

-spec greeting_node(map()) -> map().
greeting_node(State) ->
    append_ai_message(
        State,
        <<"¡Hola! ¿En qué puedo ayudarte hoy?">>
    ).

-spec math_node(map()) -> map().
math_node(State) ->
    append_ai_message(
        State,
        <<"El resultado de 2 + 2 es 4.">>
    ).

-spec decision_policy(map()) -> tuple().
decision_policy(Context) ->
    Step = maps:get(step, Context),
    State = maps:get(state, Context),
    Input = maps:get(input, Context),

    case Step of
        0 ->
            {next, router, Input};
        1 ->
            case maps:get(route, State, go_to_math) of
                go_to_greeting ->
                    {next, greeting_processor, Input};
                go_to_math ->
                    {next, math_processor, Input}
            end;
        _ ->
            {finish, State}
    end.

-spec append_ai_message(map(), binary()) -> map().
append_ai_message(State, Content) ->
    Messages = maps:get(messages, State, []),
    UserMessage = #{role => user, content => maps:get(input, State, <<>>)},
    AiMessage = #{role => ai, content => Content},
    #{messages => Messages ++ [UserMessage, AiMessage]}.

-spec contains_greeting(string()) -> boolean().
contains_greeting(Message) ->
    string:find(Message, "hola") =/= nomatch
        orelse string:find(Message, "saludo") =/= nomatch.

-spec run_agent(pid(), binary()) -> {ok, map()} | {error, term()}.
run_agent(AgentSupPid, Message) ->
    case hayata_agent_sup:agent(AgentSupPid) of
        {ok, AgentPid} ->
            case hayata_agent:run(AgentPid, Message, self()) of
                {ok, InvocationId} ->
                    await_result(InvocationId, 100);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec await_result(reference(), non_neg_integer()) ->
    {ok, map()} | {error, term()}.
await_result(_InvocationId, 0) ->
    {error, notification_timeout};
await_result(InvocationId, Attempts) ->
    receive
        {hayata_agent_result, InvocationId, {ok, Result}} ->
            {ok, Result};
        {hayata_agent_result, InvocationId, {error, Reason}} ->
            {error, Reason}
    after 100 ->
        await_result(InvocationId, Attempts - 1)
    end.
