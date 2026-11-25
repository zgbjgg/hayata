# Hayata from Elixir

This guide documents the Elixir integration provided by Hayata: the agent API, the declarative DSL, invocation handling, streaming, and the capabilities exposed to node functions.

Hayata's execution engine remains implemented in Erlang/OTP. The Elixir integration is a thin interface over that runtime; it does not introduce a separate execution engine or change the Erlang contracts.

## Requirements

- Elixir 1.11 or later.
- An Erlang/OTP release supported by Hayata.
- Mix.

The Elixir integration uses the same OTP application and runtime as the Erlang API.

## Installation

For local development from a Hayata checkout, add it as a path dependency:

```elixir
defp deps do
  [
    {:hayata, path: "../hayata"}
  ]
end
```

Then run:

```sh
mix deps.get
mix compile
```

## Define an agent

Use `Hayata.Agent` to import the `agent/1` DSL macro into a module:

```elixir
defmodule MyApp.SupportAgent do
  use Hayata.Agent

  agent do
    id "support_agent"

    state %{
      messages: []
    }

    node "answer", context do
      %{
        answer: "Hello from Hayata",
        received_input: context.input
      }
    end

    decision do
      on_step 0, context do
        next "answer", input: context.input
      end

      on_step 1, context do
        finish context.state
      end
    end

    max_steps 10
    execution_timeout 30_000
  end
end
```

The DSL supports:

| Expression | Purpose |
|---|---|
| `id` | Required agent identifier. |
| `state` | Initial shared state; defaults to an empty map. |
| `node` | Declares a node function. At least one node is required. |
| `decision` | Declares the decision policy. Required. |
| `max_steps` | Maximum node executions; runtime default is 10. |
| `execution_timeout` | Invocation timeout in milliseconds; runtime default is 30,000. |
| `llm` | LLM adapter and model configuration. |
| `conversation_memory` | Retains the `messages` state entry between invocations. |
| `rag_config` | Configures the RAG retriever. |

Node identifiers must be string literals in the DSL. They are converted to atoms at compile time; do not construct them from runtime input.

### Node functions

A node receives one context map and must return a map of state updates. The context contains `input`, the current application-defined shared-state fields, and optional capabilities injected by the Erlang runtime.

```elixir
node "answer", context do
  %{
    answer: context.input,
    processed: true
  }
end
```

Nodes do not mutate shared state directly. Hayata merges each successful returned map into shared state: returned values replace matching keys, while omitted keys remain unchanged.

### Decision policy

The decision context contains `agent_id`, `state`, the original invocation `input`, `step`, `max_steps`, and `parallel_results` (which is `undefined` when no parallel results are available).

```elixir
decision do
  on_step 0, context do
    next "answer", input: context.input
  end

  on_step 1, context do
    finish context.state
  end
end
```

Supported decisions mirror the Erlang contract:

- `next "node_id", input: value` schedules one node.
- `parallel ["node_a", "node_b"], input: value` schedules multiple nodes.
- `finish value` completes the invocation and returns the value.

Parallel nodes receive the same input and shared state. Their results remain independent and are exposed through `parallel_results` in the order of the requested node identifiers.

The DSL supports pattern matching on the decision context:

```elixir
decision do
  on_step _, %{state: %{status: :pending}} = context do
    next "process", input: context.input
  end

  on_step _, %{state: %{status: :completed}} = context do
    finish context.state
  end
end
```

Duplicate literal node identifiers and duplicate literal numeric steps are rejected when the DSL is compiled.

## Start and supervise an agent

A DSL module provides an OTP child specification and can be supervised like any other child:

```elixir
children = [MyApp.SupportAgent]

{:ok, supervisor_pid} =
  Supervisor.start_link(children, strategy: :one_for_one)
```

The public `Hayata.Agent` functions accept the PID of the agent supervision tree, not the internal coordinator PID. The API resolves the coordinator through the Erlang supervision tree.

For a standalone agent:

```elixir
{:ok, agent_supervisor_pid} =
  Hayata.Agent.start_link(MyApp.SupportAgent.config())
```

## Agent API

| Function | Description |
|---|---|
| `child_spec(config)` | Builds an OTP child specification. |
| `start_link(config)` | Starts an agent supervision tree. |
| `coordinator(agent_supervisor_pid)` | Returns the internal coordinator PID. |
| `run(agent_supervisor_pid, input, options \\ %{})` | Starts an asynchronous invocation. |
| `result(agent_supervisor_pid)` | Returns the most recent invocation result, if available. |
| `state(agent_supervisor_pid)` | Returns the current shared state. |
| `info(agent_supervisor_pid)` | Returns operational information. |
| `recover(agent_supervisor_pid)` | Attempts recovery of an invocation that requires recovery. |
| `stop(agent_supervisor_pid)` | Stops the agent and its complete supervision tree. |

Start an invocation and subscribe to its terminal result:

```elixir
{:ok, invocation_id} =
  Hayata.Agent.run(agent_supervisor_pid, %{question: "How does Hayata work?"},
    subscriber: self()
  )

receive do
  {:hayata_agent_result, ^invocation_id, {:ok, result}} -> result
  {:hayata_agent_result, ^invocation_id, {:error, reason}} -> {:error, reason}
end
```

Invocations are asynchronous. `Hayata.Agent.result/1` returns `{:error, :no_result}` before a result is available.

## Streaming

Streaming forwards the Erlang runtime's events directly to the subscriber PID. Elixir does not create a receiver process or an intermediate streaming layer.

```elixir
{:ok, invocation_id} =
  Hayata.Agent.run(
    agent_supervisor_pid,
    %{question: "Explain the execution model"},
    stream: true,
    subscriber: self()
  )
```

The subscriber receives:

```elixir
{:hayata_agent_event, invocation_id, event}
```

Each event is a map containing `type`, `sequence` (monotonically increasing within the invocation), and `data`. Lifecycle event types include `invocation_started`, `node_started`, `node_partial_result`, `node_completed`, `invocation_completed`, and `invocation_failed`.

Streaming requires `subscriber` and is disabled by default. Stream events do not replace the terminal `hayata_agent_result` notification; both are delivered. Events from parallel nodes may interleave, so use `node_id` and `execution_id` in event data to associate them with an execution.

## Node capabilities

The Erlang runtime injects capabilities into a node's context when the relevant agent configuration or invocation option is enabled. A node uses a capability by accessing the function in `context` and calling it with the arguments defined by its Erlang contract.

No additional Elixir registry, wrapper module, or agent-level tool configuration is required.

### LLM generation

Configure an adapter and model in the DSL:

```elixir
llm %{
  adapter: MyApp.LLMAdapter,
  model: "my-model"
}
```

When configured, `context.hayata_llm` is a function that accepts one normalized request map and returns the normalized result tuple. The request must contain a `messages` list.

```elixir
node "generate", context do
  request = %{
    messages: [
      %{role: :user, content: [%{type: :text, text: "Summarize the report"}]}
    ]
  }

  case context.hayata_llm.(request) do
    {:ok, response} -> %{response: response}
    {:error, reason} -> %{llm_error: reason}
  end
end
```

The configured model and provider adapter are selected by the agent's `llm` configuration. Provider-specific request formats belong in the adapter, not in the Elixir DSL.

### LLM streaming

When an LLM is configured, `context.hayata_llm_stream` is also available. It accepts a normalized request and uses the invocation's streaming configuration. Invocation streaming must be enabled and a subscriber must be supplied. Otherwise the capability returns an `unsupported_capability` error for streaming. LLM stream events use the same invocation subscriber.

### Tool-calling loop

When an LLM is configured, `context.hayata_tool_loop` is a function with three arguments:

```elixir
context.hayata_tool_loop.(request, tools, max_iterations)
```

The node supplies the tools for that call. Each tool map contains `name` (non-empty binary), `description`, `parameters` (object schema), and `handler` (function receiving the validated argument map).

```elixir
node "assistant", context do
  search_tool = %{
    name: "search_products",
    description: "Search the product catalog",
    parameters: %{
      type: :object,
      properties: %{query: %{type: :string}},
      required: ["query"]
    },
    handler: fn arguments ->
      MyApp.Products.search(Map.fetch!(arguments, "query"))
    end
  }

  request = %{
    messages: [
      %{role: :user, content: [%{type: :text, text: "Find vintage robot toys"}]}
    ]
  }

  case context.hayata_tool_loop.(request, [search_tool], 5) do
    {:ok, result} -> %{response: result.response, messages: result.messages}
    {:error, reason} -> %{tool_error: reason}
  end
end
```

The tool loop validates definitions and arguments, calls the LLM, executes requested handlers, adds tool results to the conversation, and continues until a final response or the iteration limit. Tools are supplied by the node for each call; Hayata does not register them globally on the agent.

### RAG retrieval

Configure a retriever function of arity two, or a `{Module, Function}` pair that exports an arity-two function:

```elixir
rag_config %{
  retrieve: fn query, options ->
    MyApp.KnowledgeBase.search(query, options)
  end
}
```

The retriever receives a non-empty binary query and an options map. It must return `{:ok, %{documents: documents}}` or `{:error, reason}`. Each document requires a non-empty binary `id`, binary `content`, and map `metadata`; an optional `score` must be numeric.

```elixir
{:ok,
 %{
   documents: [
     %{
       id: "document-1",
       content: "Relevant document content",
       metadata: %{source: "knowledge-base"},
       score: 0.92
     }
   ]
 }}
```

When `rag_config` is provided, `context.hayata_rag` is a function with two arguments:

```elixir
context.hayata_rag.("How does recovery work?", %{limit: 5})
```

It returns the normalized document result or an error tuple. The application owns indexing, embeddings, storage, and retrieval; Hayata validates the retriever configuration and its results.

## Conversation memory

Enable conversation memory in the DSL:

```elixir
conversation_memory true
```

When enabled, Hayata carries the `messages` entry from the current shared state into the next invocation. Other state entries are reset to their configured initial values. This is not a vector or semantic memory system and does not independently guarantee persistence across agent or VM restarts. The application remains responsible for building and updating `messages` in the format expected by its LLM adapter.

## Build and test

Run the Elixir checks with Mix:

```sh
mix compile
mix test
```

The Erlang test suite remains independently available:

```sh
rebar3 compile
rebar3 eunit
```

Mix and Rebar3 both use `_build`. Remove the shared build directory when switching between the two build systems:

```sh
rm -rf _build
```

## Scope of the Elixir integration

The Elixir integration provides an OTP-compatible agent API, a declarative DSL, invocation and recovery functions, direct event delivery to subscriber PIDs, and access to the LLM, LLM streaming, tool-loop, and RAG capabilities through the node context.

Execution, supervision, persistence, recovery, validation, LLM adapters, tool execution, and RAG result normalization remain responsibilities of the Erlang/OTP core.
