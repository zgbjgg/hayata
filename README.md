# Hayata

[![Hex.pm](https://img.shields.io/hexpm/v/hayata.svg)](https://hex.pm/packages/hayata)
[![Build Status](https://github.com/zgbjgg/hayata/actions/workflows/erlang.yml/badge.svg)](https://github.com/zgbjgg/hayata/actions/workflows/erlang.yml)
[![Codecov](https://img.shields.io/codecov/c/github/zgbjgg/hayata.svg)](https://codecov.io/gh/zgbjgg/hayata)
[![License: MIT](https://img.shields.io/github/license/zgbjgg/hayata.svg)](https://raw.githubusercontent.com/zgbjgg/hayata/master/LICENSE)
[![Hex.pm](https://img.shields.io/hexpm/dt/hayata.svg)](https://hex.pm/packages/hayata)
[![Hex.pm](https://img.shields.io/hexpm/dw/hayata.svg)](https://hex.pm/packages/hayata)

Hayata is an Erlang/OTP framework for building AI agents around a
graph-based execution model. It uses OTP processes, supervision,
monitoring, and message passing to coordinate agent execution, with
explicit ownership of process state and durable recovery checkpoints.

Hayata is designed to be usable from Erlang and Elixir applications. Its
graph-oriented model is inspired by agent orchestration frameworks such
as LangGraph, while exposing an Erlang/OTP-native runtime rather than a
feature-for-feature clone of another API.

## Highlights

-   Graph-based agent execution with a configurable decision policy.
-   Sequential and parallel node execution.
-   OTP supervision and process monitoring for agents, nodes, edges,
    reducers, and edge watchers.
-   Asynchronous invocation APIs and result notifications.
-   Invocation checkpoints and task-result persistence in Mnesia.
-   Recovery of interrupted invocations, including parallel transitions.
-   Conservative handling of uncertain tasks: a task marked as running
    without a durable result is not silently re-executed.
-   Telemetry lifecycle events for agents, nodes, edges, and reducers.

## Architecture

-   **Agent** --- coordinates invocations, applies the decision policy,
    tracks invocation state, and initiates recovery.
-   **Node** --- a supervised `gen_server` that owns local execution
    state, coordinates outgoing edges, tracks executions, and monitors
    edges and reducers.
-   **Edge** --- an anonymous `gen_server` that runs an edge task and
    reports its terminal result.
-   **Edge watcher** --- monitors the node and its edge. If the node
    terminates unexpectedly, the watcher terminates the edge so it does
    not remain orphaned.
-   **Reducer** --- a temporary process that collects edge results for
    an execution and produces a consolidated outcome.
-   **Task store** --- persists invocation checkpoints and task outcomes
    in Mnesia.
-   **Node supervisor** --- supervises node processes and restarts them
    after abnormal termination.

## Requirements

-   Erlang/OTP 29.1.1 (target runtime)
-   Rebar3

## Build and test

``` sh
rebar3 compile
rebar3 eunit
```

## Quick start

The following example mirrors a basic graph-agent pattern: define a
node, define control flow, start the agent's supervision tree, and
invoke it. This example uses a mock node; it does not call an LLM.

``` erlang
%% hello_hayata.erl
-module(hello_hayata).

-export([run/0]).

run() ->
    AgentId = hello_agent,

    MockNode = fun(State) ->
        Message = maps:get(input, State, <<"Hello">>),
        #{
            messages => [
                #{role => ai, content => <<"Hello, world!">>},
                #{role => user, content => Message}
            ]
        }
    end,

    Nodes = #{mock_node => MockNode},

    DecisionPolicy = fun(Context) ->
        case maps:get(step, Context) of
            0 ->
                {next, mock_node, <<"Hello">>};
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
            case hayata_agent:run(AgentPid, #{input => <<"Hello">>}, self()) of
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

Save the module as `hello_hayata.erl` in a location included in your
Erlang code path, compile it, and call:

``` erlang
hello_hayata:run().
```

## Invocation API

Hayata supports two invocation APIs:

-   `hayata_agent:run(AgentPid, Input)` starts an asynchronous
    invocation and returns `{ok, InvocationId}`. Retrieve the result
    later with `hayata_agent:get_result/1`.
-   `hayata_agent:run(AgentPid, Input, SubscriptionPid)` starts an
    asynchronous invocation and sends the terminal result to the
    subscription process.

The subscription receives one of these messages:

``` erlang
{hayata_agent_result, InvocationId, {ok, Result}}
{hayata_agent_result, InvocationId, {error, Reason}}
```

`InvocationId` correlates the message with its invocation. Success,
execution errors, and timeouts are reported through this message format.
If an invocation is rejected before starting---for example, because the
agent is already running---`run/3` returns an error without sending a
terminal-result notification for that rejected request.

The subscription argument must be a PID; otherwise, `run/3` returns
`{error, invalid_subscription_pid}`.

The decision policy controls execution flow: `{next, NodeId, Input}`
schedules a node, and `{finish, Result}` ends the invocation.

## Parallel node execution

A decision policy can schedule multiple nodes in parallel by returning
`{next, NodeIds, Input}`, where `NodeIds` is a non-empty list of
distinct node identifiers.

All branch nodes receive the same input and current shared agent state.
Their returned maps are collected independently and do not directly
modify the shared state.

When every branch completes successfully, the policy receives the
results through the `parallel_results` field in its context. Results are
a list of maps in the same order as the requested node identifiers,
regardless of completion order.

``` erlang
DecisionPolicy = fun(Context) ->
    case maps:get(step, Context) of
        0 ->
            {next, [customer, orders], undefined};
        2 ->
            [Customer, Orders] = maps:get(parallel_results, Context),
            {next, aggregate, #{
                customer => Customer,
                orders => Orders
            }};
        3 ->
            {finish, maps:get(state, Context)}
    end
end.
```

The `parallel_results` field is `undefined` before a parallel transition
completes. After all branches succeed, it contains their ordered result
maps and remains available to the policy that chooses the next
transition. When the policy schedules another node or parallel
transition, the previous results are cleared. A new invocation starts
with `parallel_results` set to `undefined`.

If a branch fails or the invocation times out, the transition fails and
pending branches are cancelled; incomplete parallel results are not
published as a successful transition result.

## Durable checkpoints and recovery

Hayata uses Mnesia to persist invocation checkpoints and task outcomes.
The task store uses disk-backed Mnesia tables and synchronous
transactions; completed task results and invocation checkpoints are
flushed to the Mnesia log after writes.

A checkpoint captures the information required to identify and resume an
invocation, including the invocation ID, current state and step, active
execution, parallel results, and terminal result/error fields. When an
agent starts and finds an unfinished invocation for its ID, it restores
that invocation and reports `recovery_required` rather than accepting a
new invocation on top of it.

Call `hayata_agent:recover(AgentPid)` to initiate recovery of the
restored invocation.

Recovery classifies each task using its durable record:

-   **Completed:** reuse the persisted task result instead of executing
    that task again.
-   **Not started:** schedule the task for execution during recovery.
-   **Uncertain:** if a task record indicates that execution started but
    no completed result exists, recovery returns
    `{error, task_execution_uncertain}` rather than silently repeating
    the operation.

For parallel execution, Hayata can combine completed branch results with
branches that have not started, execute only the missing branches, and
persist the final invocation result. Results retain the configured node
order.

### Recovery guarantees and limitations

Recovery is designed to avoid silently repeating a task whose completion
is uncertain. It does not provide exactly-once semantics for arbitrary
external side effects. If a node may have called an external service
before the VM stopped but its result was not durably saved, Hayata
cannot know whether that side effect occurred. Applications should use
idempotency keys, external deduplication, or other application-level
safeguards where retry safety matters.

Durable recovery depends on preserving the configured Mnesia data
directory across VM restarts. If that directory is removed or replaced,
the persisted checkpoints are unavailable.

### Reproducing VM restart scenarios

The repository includes [`VM_RECOVERY_TESTS.md`](VM_RECOVERY_TESTS.md),
a step-by-step manual verification guide with complete local commands
for:

1.  A completed task result surviving an abrupt VM shutdown.
2.  A task left running without a result being classified as uncertain
    after restart.
3.  A running invocation checkpoint being restored by a new agent
    process.
4.  A parallel invocation reusing a completed branch and executing a
    not-started branch after an abrupt VM shutdown.

These manual integration checks complement the EUnit suite; run both
against the exact commit intended for release.

## Execution lifecycle

1.  The node validates an execution request, edge tasks, and timeout.
2.  A reducer is started and activated when result consolidation is
    required.
3.  The node starts and monitors edge processes.
4.  Each edge runs its task and sends its result to the reducer and
    node.
5.  The reducer consolidates the edge results and reports the final
    result.
6.  The node updates execution status, notifies any configured
    recipient, and tracks process termination.

Logical edge IDs and execution IDs correlate messages. Stale
notifications must not overwrite terminal execution state or trigger
duplicate notifications.

## Telemetry

Hayata uses [Telemetry](https://hexdocs.pm/telemetry/) to expose
lifecycle events from agents, nodes, edges, and reducers. Applications
can attach handlers to collect metrics, trace execution activity, or
integrate with monitoring systems.

  ----------------------------------------------------------------------------------------------
  Component               Event                                          Meaning
  ----------------------- ---------------------------------------------- -----------------------
  Agent                   `[:hayata, :agent, :invocation, :start]`       An invocation starts.

  Agent                   `[:hayata, :agent, :invocation, :stop]`        An invocation completes
                                                                         or fails normally.

  Agent                   `[:hayata, :agent, :invocation, :exception]`   An invocation
                                                                         encounters a caught
                                                                         policy exception.

  Node                    `[:hayata, :node, :execution, :start]`         A node execution
                                                                         starts.

  Node                    `[:hayata, :node, :execution, :stop]`          A node execution
                                                                         reaches a terminal
                                                                         state, such as
                                                                         completion or
                                                                         cancellation.

  Node                    `[:hayata, :node, :execution, :exception]`     A node execution ends
                                                                         with a reducer recovery
                                                                         failure.

  Edge                    `[:hayata, :edge, :start]`                     An edge task starts.

  Edge                    `[:hayata, :edge, :stop]`                      An edge task ends
                                                                         without a caught task
                                                                         exception.

  Edge                    `[:hayata, :edge, :exception]`                 An edge task raises a
                                                                         caught exception.

  Reducer                 `[:hayata, :reducer, :start]`                  A reducer is activated.

  Reducer                 `[:hayata, :reducer, :stop]`                   A reducer completes or
                                                                         times out.
  ----------------------------------------------------------------------------------------------

A `stop` event indicates a terminal outcome, not necessarily success.
Where present, use the `status` metadata to distinguish completed,
failed, cancelled, and timed-out executions.

Start events include `system_time`. Terminal events include `duration`,
calculated with `erlang:monotonic_time/0`. Both use Erlang native time
units; convert durations when exporting to systems that expect
milliseconds.

Common metadata includes `agent_id`, `node_id`, `execution_id`,
`edge_id`, `status`, and, for caught exceptions, `class`. Reducer events
may also include `expected_edges`, `result_count`, `error_count`, and
`pending_edges`. Available fields vary by event.

Hayata's telemetry metadata avoids including full results, exception
reasons, or stacktraces. Applications should also review their own
handlers and exporters to avoid exposing sensitive inputs, state,
prompts, or outputs.

### Attaching a handler

``` erlang
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

Call `my_hayata_telemetry:attach/0` during application startup and
`my_hayata_telemetry:detach/0` when the handler is no longer needed.
Keep handlers lightweight; forward expensive processing to a dedicated
process or metrics backend.

## Fault handling and process supervision

The edge watcher monitors the node independently. If the node dies,
including through an untrappable `kill`, the watcher terminates its edge
even though the node's `terminate/2` callback cannot run. Node processes
are supervised and restarted after abnormal termination.

**Known limitation:** edge task functions execute synchronously inside
the edge GenServer callback. A blocked task prevents that GenServer from
processing messages until the callback returns. The watcher can
terminate the edge when the node disappears, but cancellation semantics
for blocked tasks and their side effects remain an area for further
review.

## Release scope: 1.0.0

The planned 1.0.0 release brings together the graph-based agent runtime,
sequential and parallel execution, OTP supervision, Telemetry lifecycle
events, durable invocation/task checkpoints, and explicit recovery
handling for completed, not-started, and uncertain tasks.

The release should be considered ready only after the complete EUnit
suite, compilation, package validation, and review of the final release
commit have succeeded. The manual VM recovery procedures are documented
in `VM_RECOVERY_TESTS.md`.

## Design principles

-   Use OTP processes and monitoring for concurrency and failure
    detection.
-   Keep process responsibilities and state ownership explicit.
-   Treat logical IDs separately from process PIDs.
-   Keep cancellation and recovery scoped to the affected execution.
-   Persist task outcomes before treating them as completed.
-   Reject uncertain execution states rather than silently repeating
    potentially non-idempotent work.
-   Validate behavior incrementally with EUnit and explicit VM-restart
    checks.

## License

Apache-2.0. See [LICENSE.md](LICENSE.md) for details.
