# Hayata

[![Hex.pm](https://img.shields.io/hexpm/v/hayata.svg)](https://hex.pm/packages/hayata)
[![Build Status](https://github.com/zgbjgg/hayata/actions/workflows/erlang.yml/badge.svg)](https://github.com/zgbjgg/hayata/actions/workflows/erlang.yml)
[![Codecov](https://img.shields.io/codecov/c/github/zgbjgg/hayata.svg)](https://codecov.io/gh/zgbjgg/hayata)
[![License: MIT](https://img.shields.io/github/license/zgbjgg/hayata.svg)](https://raw.githubusercontent.com/zgbjgg/hayata/master/LICENSE)
[![Hex.pm](https://img.shields.io/hexpm/dt/hayata.svg)](https://hex.pm/packages/hayata)
[![Hex.pm](https://img.shields.io/hexpm/dw/hayata.svg)](https://hex.pm/packages/hayata)

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

Save the module as `hello_hayata.erl` in a location included in your Erlang code path, then run it from an Erlang shell after compiling the Hayata application and ensuring its beams are available:

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

Unlike LangGraph's `StateGraph` builder, this example uses Hayata's current agent API; it does not claim feature-for-feature API parity.

## Execution lifecycle

1. The node validates an execution request, edge tasks, and timeout.
2. A reducer is started and activated when result consolidation is required.
3. The node starts and monitors edge processes.
4. Each edge runs its task and sends its result to the reducer and node.
5. The reducer consolidates the edge results and reports the final result.
6. The node updates execution status, notifies any configured recipient, and tracks process termination.

Logical edge IDs and execution IDs correlate messages. Stale notifications must not overwrite terminal execution state or trigger duplicate notifications.

## Telemetry

Hayata uses [Telemetry](https://hexdocs.pm/telemetry/) to expose lifecycle events from agents, nodes, edges, and reducers. Applications can attach handlers to collect metrics, trace execution activity, or integrate with monitoring systems.

### Event conventions

| Component | Event | Meaning |
|---|---|---|
| Agent | `[:hayata, :agent, :invocation, :start]` | An invocation starts. |
| Agent | `[:hayata, :agent, :invocation, :stop]` | An invocation completes or fails normally. |
| Agent | `[:hayata, :agent, :invocation, :exception]` | An invocation encounters a caught policy exception. |
| Node | `[:hayata, :node, :execution, :start]` | A node execution starts. |
| Node | `[:hayata, :node, :execution, :stop]` | A node execution reaches a terminal state, such as completion or cancellation. |
| Node | `[:hayata, :node, :execution, :exception]` | A node execution ends with a reducer recovery failure. |
| Edge | `[:hayata, :edge, :start]` | An edge task starts. |
| Edge | `[:hayata, :edge, :stop]` | An edge task ends without a caught task exception. |
| Edge | `[:hayata, :edge, :exception]` | An edge task raises a caught exception. |
| Reducer | `[:hayata, :reducer, :start]` | A reducer is activated. |
| Reducer | `[:hayata, :reducer, :stop]` | A reducer completes or times out. |

A `stop` event indicates a terminal outcome, not necessarily success. Where present, use the `status` metadata to distinguish completed, failed, cancelled, and timed-out executions.

### Measurements and metadata

Start events include `system_time`. Terminal events include `duration`, calculated with `erlang:monotonic_time/0`. Both use Erlang native time units; convert durations when exporting to systems that expect milliseconds.

Common metadata includes `agent_id`, `node_id`, `execution_id`, `edge_id`, `status`, and, for caught exceptions, `class`. Reducer events may also include `expected_edges`, `result_count`, `error_count`, and `pending_edges`. Available fields vary by event.

Hayata's telemetry metadata avoids including full results, exception reasons, or stacktraces. Applications should also review their own handlers and exporters to avoid exposing sensitive inputs, state, prompts, or outputs.

### Attaching a handler

The following example subscribes to agent invocation events:

```erlang
-module(my_hayata_telemetry).

-export([attach/0, detach/0, handle_event/4]).

-define(HANDLER_ID, {?MODULE, agent_invocations}).

attach() ->
    telemetry:attach_many(
        ?HANDLER_ID,
        [
            [hayata, agent, invocation, start],
            [hayata, agent, invocation, stop],
            [hayata, agent, invocation, exception]
        ],
        fun ?MODULE:handle_event/4,
        #{}
    ).

detach() ->
    telemetry:detach(?HANDLER_ID).

handle_event(Event, Measurements, Metadata, _Config) ->
    logger:info(
        "Hayata telemetry event",
        #{
            event => Event,
            measurements => Measurements,
            metadata => Metadata
        }
    ).
```

Call `my_hayata_telemetry:attach/0` during application startup and `my_hayata_telemetry:detach/0` when the handler is no longer needed. Keep handlers lightweight; forward expensive processing to a dedicated process or metrics backend.

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

Apache-2.0. See [LICENSE](LICENSE.md) for details.
