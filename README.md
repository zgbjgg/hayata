# Hayata

Hayata is an Erlang/OTP framework for building AI agents around a graph-based execution model.

The runtime uses OTP processes, monitoring, and message passing to coordinate agent execution while keeping process responsibilities and state ownership explicit. It is intended to be usable from Erlang and Elixir applications.

## Architecture

- **Agent** — coordinates agent invocations and handles node-related failures and execution outcomes.
- **Node** — a supervised `gen_server` that owns local state, coordinates outgoing edges, tracks executions, and monitors edges and reducers.
- **Edge** — an anonymous `gen_server` that runs an edge task and reports its terminal result.
- **Edge watcher** — monitors the node and its edge. If the node terminates unexpectedly, the watcher terminates the edge so it does not remain orphaned.
- **Reducer** — a temporary process that collects edge results for an execution and produces a consolidated outcome.
- **Node supervisor** — supervises node processes and restarts them after abnormal termination.

## How to use Hayata

The following example mirrors the basic LangGraph pattern: define a node, define the control flow, compile the graph, and invoke it with input. In Hayata's current API, the equivalent is to define a node function and a `decision_policy`, then start the agent's supervision tree.

This example uses a mock node that adds a greeting to the state; it does not call an LLM.

```erlang
%% hello_hayata.erl
-module(hello_hayata).

-export([run/0]).

run() ->
    AgentId = hello_agent,

    %% 1. Define a node function. It receives the current state.
    MockLlm = fun(State) ->
        Message = maps:get(input, State, <<"Hola">>),
        #{messages => [
            #{role => ai, content => <<"¡Hola mundo!">>},
            #{role => user, content => Message}
        ]}
    end,

    %% 2. Define the node catalog and control flow.
    %% First visit the mock_llm node; on the next policy evaluation, finish.
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

    %% 3. Start the supervision tree and get the agent process.
    {ok, SupPid} = hayata_agent_sup:start_link(Config),
    {ok, AgentPid} = hayata_agent_sup:agent(SupPid),

    try
        %% 4. Invoke the agent with input.
        {ok, _InvocationId} = hayata_agent:run(
            AgentPid,
            #{input => <<"Hola">>}
        ),

        %% 5. Wait for the asynchronous invocation to finish.
        Result = await_result(AgentPid, 100),
        Result
    after
        %% Stop the agent and its supervised processes.
        ok = hayata_agent:stop(AgentPid)
    end.

await_result(_AgentPid, 0) ->
    {error, timeout};
await_result(AgentPid, Attempts) ->
    case hayata_agent:get_result(AgentPid) of
        {error, no_result} ->
            timer:sleep(10),
            await_result(AgentPid, Attempts - 1);
        Result ->
            Result
    end.
```

Save the module as `hello_hayata.erl` in a location included in your Erlang code path, then run it from an Erlang shell after compiling the Hayata application and ensuring its beams are available:

```erlang
hello_hayata:run().
```

The invocation is asynchronous: `hayata_agent:run/2` returns an invocation ID, while `hayata_agent:get_result/1` returns the final result after the agent completes. The decision policy controls the flow: `{next, NodeId, Input}` schedules a node, and `{finish, Result}` ends the invocation.

Unlike LangGraph's `StateGraph` builder, this example uses Hayata's current agent API; it does not claim feature-for-feature API parity.

## Execution lifecycle

1. The node validates an execution request, edge tasks, and timeout.
2. A reducer is started and activated when result consolidation is required.
3. The node starts and monitors edge processes.
4. Each edge runs its task and sends its result to the reducer and node.
5. The reducer consolidates the edge results and reports the final result.
6. The node updates execution status, notifies any configured recipient, and tracks process termination.

Logical edge IDs and execution IDs correlate messages. Stale notifications must not overwrite terminal execution state or trigger duplicate notifications.

## Fault handling and recovery

EUnit tests cover node restart and invocation failure, stale notifications, reducer recovery, execution cancellation, and edge cleanup after node failure.

The edge watcher monitors the node independently. If the node dies, including through an untrappable `kill`, the watcher terminates its edge even though the node's `terminate/2` callback cannot run.

**Current limitation:** edge task functions execute synchronously inside the edge GenServer callback. A blocked task prevents that GenServer from processing messages until the callback returns. The watcher can terminate the edge when the node disappears, but cancellation semantics for blocked tasks and their side effects remain an area for further review.

## Requirements

- Erlang/OTP 29.1.1 (target runtime)
- Rebar3

## Build and test

```sh
rebar3 compile
rebar3 eunit
```

## Design principles

- Use OTP processes and monitoring for concurrency and failure detection.
- Keep process responsibilities and state ownership explicit.
- Treat logical IDs separately from process PIDs.
- Keep cancellation and recovery scoped to the affected execution.
- Validate behavior incrementally with EUnit tests.

## Project status

Hayata is under active development. The graph-based agent runtime, node/edge/reducer execution flow, and recovery behavior are being developed and validated incrementally. Upcoming work includes reviewing the interactions among execution cancellation, invocation timeouts, blocked tasks, and recovery.

## License

Apache-2.0. See [LICENSE](LICENSE) for details.
