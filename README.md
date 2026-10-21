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

The following example demonstrates Hayata's graph-based agent API: define a node, define the control flow, start the agent's supervision tree, and invoke it asynchronously.

This example uses a mock node; it does not call an LLM.

```erlang
%% hello_hayata.erl
-module(hello_hayata).

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
```

Save the module as `hello_hayata.erl` in a location included in your Erlang code path. After compiling Hayata and ensuring its beams are available, run it from an Erlang shell:

```erlang
hello_hayata:run().
```

### Invocation API

Hayata supports two invocation APIs:

- `hayata_agent:run(AgentPid, Input)` starts an asynchronous invocation and returns `{ok, InvocationId}`. Retrieve the result later using `hayata_agent:get_result/1`.
- `hayata_agent:run(AgentPid, Input, SubscriptionPid)` starts an asynchronous invocation and sends the terminal result to the subscription process.

The subscription receives one of these messages:

```erlang
{hayata_agent_result, InvocationId, {ok, Result}}
{hayata_agent_result, InvocationId, {error, Reason}}
```

The `InvocationId` correlates the message with its invocation. Success, execution errors, and timeouts are reported through this message format. If an invocation is rejected before starting, for example because the agent is already running, `run/3` returns an error without sending a terminal-result notification for that rejected request.

The subscription argument must be a PID; otherwise, `run/3` returns `{error, invalid_subscription_pid}`.

The decision policy controls execution flow: `{next, NodeId, Input}` schedules a node, and `{finish, Result}` ends the invocation.

Unlike LangGraph's `StateGraph` builder, this example uses Hayata's current API and does not claim feature-for-feature API parity.

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

## Decision policy contract

The decision policy is a synchronous, deterministic control-flow function. Its
responsibility is to decide whether the agent should execute another node or
finish the current invocation.

A decision policy receives the current agent context and returns one of the
supported decisions:

- `{next, NodeId, Input}` — schedule the specified node with the given input.
- `{finish, Result}` — finish the invocation with the provided result.
- `{error, Reason}` — fail the invocation with the specified reason.

Decision policies should be fast and should not perform long-running operations,
blocking waits, or external I/O. They are evaluated synchronously by the agent
coordinator, so a blocked policy prevents the coordinator from processing other
messages, including invocation timeout messages.

Long-running work belongs in node functions. Nodes can perform operations such
as LLM requests, HTTP calls, database access, and computationally intensive
tasks without placing that work directly in the decision policy.

The agent coordinator owns the invocation lifecycle and enforces the global
invocation timeout. Node execution has its own timeout configuration. Users
should configure appropriate limits for their workloads while keeping the
global invocation timeout in mind.

This separation keeps control-flow decisions simple and makes long-running
work easier to isolate, monitor, cancel, and recover.

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

Apache-2.0. See [LICENSE](LICENSE.md) for details.
