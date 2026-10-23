%% hayata_simple_example.erl
-module(hayata_simple_example).

-export([run/0]).

run() ->
    AgentId = hello_agent,

    MockLlm = fun(State) ->
        Message = maps:get(input, State, <<"Hola">>),
        #{
            messages => [
                #{role => ai, content => <<"¡Hola mundo!">>},
                #{role => user, content => Message}
            ]
        }
    end,

    Nodes = #{mock_llm => MockLlm},

    DecisionPolicy = fun(Context) ->
        case maps:get(step, Context) of
            0 ->
                {next, mock_llm, <<"Hola">>};
            1 ->
                {finish, maps:get(state, Context)}
        end
    end,

    Config = #{
        id => AgentId,
        state => #{},
        nodes => Nodes,
        decision_policy => DecisionPolicy,
        max_steps => 3,
        execution_timeout => 5000
    },

    case hayata_sup:start_agent(Config) of
        {ok, AgentSupPid} ->
            try
                run_agent(AgentSupPid)
            after
                hayata_sup:stop_agent(AgentSupPid)
            end;
        {error, Reason} ->
            {error, {agent_start_failed, Reason}}
    end.

run_agent(AgentSupPid) ->
    case hayata_agent_sup:agent(AgentSupPid) of
        {ok, AgentPid} ->
            case hayata_agent:run(
                AgentPid,
                #{input => <<"Hola">>},
                self()
            ) of
                {ok, InvocationId} ->
                    await_result(InvocationId, 100);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

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
