# Hayata LLM Contract

**Status:** Architecture draft — decisions recorded on 2026-10-28\
**Scope:** Provider-agnostic LLM contract for Hayata\
**Goal:** Integrate different LLM providers without changing Hayata's graph runtime when a provider is added.

## Decisions already agreed

1. The provider and model are selected when the agent is created; there is no global default provider and no per-invocation provider selection in v1.
2. All LLM-using nodes inherit the agent's provider/model configuration in v1. The contract should leave room for explicit per-node overrides in a future version.
3. LLM streaming events use Hayata's existing invocation subscription mechanism and public event envelope. No second public subscription API will be introduced.
4. Provider adapters normalize provider-specific payloads. Hayata owns graph orchestration, tool validation/execution, conversation state, recovery, and publication of public stream events.

These decisions are architectural constraints for the first implementation, not claims that an LLM integration is already implemented.

## 1. Design goals

The LLM layer must:

1.  Define one normalized contract for requests, responses, messages,
    tool calls, capabilities, streaming, and errors.
2.  Keep provider-specific HTTP payloads and response formats inside
    provider adapters.
3.  Let Hayata own orchestration, tool authorization and execution,
    graph state, retries, and recovery policy.
4.  Make provider features explicit. Unsupported capabilities must be
    detectable rather than silently approximated.
5.  Support text and multimodal content without requiring every provider
    to support every modality.
6.  Support ordinary generation and native provider streaming from the
    beginning.
7.  Avoid leaking credentials, prompts, or provider payloads through
    logs, telemetry, errors, or checkpoints.
8.  Keep the core dependency-light; provider adapters may be separate
    packages.
9.  Allow a new adapter to be added without modifying `hayata_agent`,
    `hayata_node`, or the graph runtime.

This document is a proposal. The names and Erlang types below are
targets, not claims that the modules already exist.

## 2. Architecture

Three layers:

-   **Public API (`hayata_llm`)** resolves configuration, validates
    requests, checks capabilities where possible, delegates to the
    adapter, and returns normalized results.
-   **Shared contract** defines adapter behavior, normalized types,
    configuration, capability validation, stream events, and potentially
    reusable tool orchestration helpers.
-   **Provider adapters** such as `hayata_openai`, `hayata_anthropic`,
    and `hayata_gemini` translate normalized requests to native APIs and
    normalize responses. They own authentication, HTTP, native response
    parsing, and native stream parsing.

Provider adapters must not own graph routing or execute application
tools. They may use OTP processes internally when useful, but the
contract must not require every adapter to be a process. Adding a
provider must not require changes to the graph runtime.

## 3. Adapter behaviour

Minimum contract:

``` erlang
-callback capabilities(Config :: map()) ->
    {ok, Capabilities :: map()} |
    {error, term()}.

-callback generate(Request :: map(), Config :: map()) ->
    {ok, Response :: map()} |
    {error, NormalizedError :: map()}.
```

Native streaming is optional:

``` erlang
-callback generate_stream(
    Request :: map(),
    Config :: map(),
    Consumer :: fun((Event :: map()) -> ok | {error, term()})
) ->
    {ok, Response :: map()} |
    {error, NormalizedError :: map()}.
```

The consumer is an internal callback supplied by Hayata, not the public
subscriber PID. The adapter calls it synchronously for each normalized
event. The callback returns `ok` or `{error, Reason}`. On callback error,
the adapter must stop producing events and terminate the generation as
soon as the underlying transport permits. This keeps provider adapters
independent of Hayata's public subscription protocol.

The callback must not wait for acknowledgement from the public
subscriber. Hayata's existing public stream sends Erlang messages
asynchronously. Version 1 therefore has no subscriber-driven
backpressure. Events must not be silently dropped to simulate
backpressure; subscribers are expected to consume promptly. A future
bounded or acknowledged stream may be added without changing the
normalized LLM event vocabulary.

The adapter returns the final normalized response on success. If the
stream fails, it returns a normalized error and must not report success
after a terminal failure. Hayata owns the generation deadline and
cancellation intent. The implementation must arrange for the adapter
operation to stop or be isolated when its deadline expires. A transport
that cannot guarantee immediate cancellation must not be allowed to emit
accepted events after Hayata has marked that generation terminal. The
behaviour does not mandate one process per request.

Optional callbacks should use Erlang behaviour conventions, including
`-optional_callbacks([...]).` A provider that lacks streaming or
embeddings can still conform to ordinary generation.

Embeddings can be introduced as an optional operation later; they must
not be mandatory for chat generation.

## 4. Normalized request

``` erlang
#{
    model => <<"model-name">>,
    messages => [
        #{
            role => user,
            content => [
                #{type => text, text => <<"Hello">>}
            ]
        }
    ],
    tools => [],
    tool_choice => auto,
    response_format => #{type => text},
    options => #{
        temperature => 0.2,
        max_output_tokens => 2048
    },
    provider_options => #{},
    metadata => #{}
}
```

`model` and `messages` are required. Other fields are optional where the
operation permits them.

-   `tools`: normalized tool definitions available to the model.
-   `tool_choice`: initially `auto`, `none`, `required`, or a documented
    named-tool selection.
-   `response_format`: text or a declared structured schema.
-   `options`: provider-neutral generation options.
-   `provider_options`: explicitly provider-scoped options.
-   `metadata`: safe correlation data, not secrets.

The facade must reject malformed required fields with `invalid_request`.
It must not silently drop a requested feature when that would materially
change the request's meaning.

Provider-specific options must be isolated from provider-neutral
options. An adapter may reject unknown provider options or pass through
documented options, but must never interpret another provider's options
as its own.

## 5. Messages and multimodal content

A message has an ordered list of content parts and a normalized role.
Initial roles:

-   `system`
-   `developer`
-   `user`
-   `assistant`
-   `tool`

Text example:

``` erlang
#{role => user, content => [
    #{type => text, text => <<"What is the weather?">>}
]}
```

Image example:

``` erlang
#{
    type => image,
    source => #{
        type => url,
        url => <<"https://example.com/image.png">>
    }
}
```

The contract should allow sources such as URLs, binaries, data URIs, or
managed file references without requiring large binaries to be embedded
in conversation history. Exact source forms and size limits must be
defined and validated.

Reserve extensible content types for `audio`, `video`, `file`, and
`structured`. Audio may need task/format metadata; video must preserve
frame order and timestamps; files should support references; structured
content should represent typed data where needed. The first
implementation need not implement every modality, but must report
unsupported content explicitly. Content order and semantically relevant
metadata must be preserved.

## 6. Tools and tool calls

A normalized tool definition:

``` erlang
#{
    name => <<"get_weather">>,
    description => <<"Returns current weather for a city.">>,
    parameters => #{
        type => object,
        properties => #{
            city => #{type => string}
        },
        required => [city]
    }
}
```

The schema representation must be consistent. A documented JSON Schema
subset is acceptable for the first implementation; adapters translate it
to native schemas.

A normalized tool call:

``` erlang
#{
    id => <<"call-123">>,
    name => <<"get_weather">>,
    arguments => #{city => <<"Mexico City">>}
}
```

The adapter normalizes tool requests; **Hayata owns the tool cycle**:

1.  Send message history and allowed tool schemas to the model.
2.  Normalize the response and tool calls.
3.  Validate each call against the tools permitted for the invocation.
4.  Apply authorization and argument validation.
5.  Execute approved tools.
6.  Append tool-result messages associated with the original call IDs.
7.  Invoke the model again, subject to iteration and execution limits.
8.  Finish when the model returns a final answer or the policy stops the
    cycle.

A normalized tool result is appended as a `tool` message correlated with
the original call ID, for example:

``` erlang
#{
    role => tool,
    tool_call_id => <<"call-123">>,
    content => [#{type => text, text => <<"Sunny, 22 C">>}],
    is_error => false
}
```

`is_error` is optional when false and set to `true` for a tool failure that
is returned to the model. Tool output may be text or supported typed
content; adapters translate it to the provider's tool-result format.

A model response does not authorize arbitrary code execution. Unknown
tools, invalid arguments, missing/duplicate call IDs, execution
failures, multiple tool calls, and tool-loop limits require defined
behavior. Unknown tools must not be executed silently. Hayata validates
the complete argument map against the declared schema before execution;
partial streamed arguments are never executable tool calls.

## 7. Normalized response

``` erlang
#{
    message => #{
        role => assistant,
        content => [
            #{type => text, text => <<"Hello!">>}
        ],
        tool_calls => []
    },
    finish_reason => stop,
    usage => #{
        input_tokens => 12,
        output_tokens => 4,
        total_tokens => 16
    },
    provider_metadata => #{}
}
```

Initial normalized `finish_reason` values:

-   `stop`: ordinary completion.
-   `tool_calls`: one or more tool calls were requested.
-   `length`: generation stopped at an output limit.
-   `content_filter`: a safety/content filter stopped or altered
    generation.
-   `other`: no portable category fits.

The native reason may be preserved in `provider_metadata`. Do not treat
`length` or `content_filter` as an ordinary successful stop.

Usage is optional. Missing usage must be represented as absent or
unknown; adapters must not invent counts. `provider_metadata` is
explicitly non-portable and must not be required by generic
orchestration.

## 8. Capabilities

Capabilities describe the selected model under effective configuration,
not just a provider brand.

``` erlang
#{
    input_modalities => [text, image],
    output_modalities => [text],
    features => #{
        tool_calling => true,
        structured_output => true,
        streaming => true,
        embeddings => false
    },
    limits => #{
        max_context_tokens => 128000,
        max_output_tokens => 8192
    }
}
```

Unknown limits must be omitted, not guessed. The final contract must
distinguish unsupported from unknown/not reported consistently.
Capabilities may include input/output modalities, tool calling,
structured output, native streaming, embeddings, and known model limits.

A request requiring a known unsupported feature must fail with
`unsupported_capability`. The facade calls `capabilities/1` during agent
initialization and retains the result alongside that agent's effective
LLM configuration. The call should be local and deterministic by default;
it must not require a network request just to start an agent. An adapter
may report a capability as unknown when it cannot establish support.
Unknown is not the same as supported: known-unsupported requests fail
before generation, while unknown features are passed to the adapter for
request-level validation and may be rejected there. If capabilities are
cached, the cache key must account for adapter, model, and relevant
configuration. An adapter must not claim a feature merely because
another model from the same provider supports it.

## 9. Streaming

Keep two layers distinct:

1. **LLM generation stream:** normalized events emitted by a provider
   adapter during one generation.
2. **Hayata agent stream:** the existing invocation/graph events,
   including node lifecycle and partial results.

### 9.1 Adapter-internal events

The adapter uses these normalized event types:

- `message_started`
- `content_delta`
- `tool_call_started`
- `tool_call_delta`
- `tool_call_completed`
- `message_completed`
- `generation_completed`
- `generation_failed`

Every event is a map with `type` and `data`. Content deltas include a
stable message/content index; tool events include a stable `tool_call_id`
(or an adapter-neutral call index until an ID is available). These
identifiers are required to reconstruct interleaved text and tool calls.
`tool_call_completed` carries the complete normalized call with parsed
arguments. Partial tool arguments are never executable.

The adapter emits events in provider order and emits at most one terminal
generation event. `generate_stream/3` also returns the canonical final
normalized response on success. That response must agree with the events
emitted. On failure it returns a normalized error. No event may be
accepted after `generation_completed` or `generation_failed`.

### 9.2 Public Hayata events

Hayata bridges adapter events to the existing public envelope:

```erlang
{hayata_agent_event, InvocationId, #{
    type => EventType,
    sequence => Sequence,
    data => EventData
}}
```

The existing `hayata_stream:flush/5` sends this message, while
`hayata_agent` owns the monotonically increasing sequence for the entire
invocation. The sequence must not reset between model generations.

To prevent collisions with existing graph event names, public LLM event
types are prefixed:

- `llm_message_started`
- `llm_content_delta`
- `llm_tool_call_started`
- `llm_tool_call_delta`
- `llm_tool_call_completed`
- `llm_message_completed`
- `llm_generation_completed`
- `llm_generation_failed`

Every public LLM event's `data` includes `node_id` and `generation_id`,
and may include `message_index`, `content_index`, or `tool_call_id` as
appropriate. The outer `InvocationId` remains the invocation correlation
ID. The public event sequence is assigned by Hayata at publication time,
not by the adapter.

The initial integration should add a distinct internal callback to the
node execution context (proposed key: `hayata_llm_streamer`). This
callback sends the normalized event to `hayata_agent` with the current
invocation, node, execution, and generation identifiers. The agent
validates that the invocation and node execution are still active, then
uses its existing `emit_stream_event` path to assign the public sequence
and publish via `hayata_stream:flush/5`. Do not call `hayata_stream:flush/5`
directly from a provider adapter, because that would bypass sequence
ownership and stale-execution validation. This is an internal bridge,
not a second public subscription API.

The adapter does not emit graph lifecycle events. The agent continues to
own `invocation_started`, `invocation_completed`, `invocation_failed`,
node lifecycle, and node partial-result events. A successful LLM
generation does not mean the agent invocation has completed; the node
may still execute tools or perform another generation.

### 9.3 Event ordering and terminal semantics

- The first accepted event for a generation is `llm_message_started`
  when the provider exposes that boundary; if not, the adapter documents
  the limitation and emits the earliest meaningful event.
- Content and tool-call events preserve provider order.
- `llm_generation_completed` or `llm_generation_failed` is terminal for
  that generation and occurs at most once.
- The agent invocation's existing terminal event remains owned by
  `hayata_agent` and occurs at most once under the existing lifecycle
  rules.
- A timed-out or cancelled generation cannot later publish accepted
  deltas or a success event. Late transport messages must be ignored
  using the generation's correlation identity.
- A stream failure must be reflected in the returned generation result;
  it must not be converted into a successful final response.

### 9.4 Cancellation, deadlines, and slow subscribers

The generation inherits the remaining execution deadline from Hayata;
provider-specific request timeouts must not extend beyond that deadline.
Cancellation and timeout must terminate or isolate the adapter operation,
release transport resources where supported, and prevent late events from
being accepted. The adapter must map a known cancellation to the
normalized `cancelled` error and a deadline expiry to `timeout`.

The current public stream uses asynchronous Erlang message delivery and
has no acknowledgement-based backpressure. Version 1 does not promise
that a slow subscriber can slow down the provider. Events must not be
dropped silently; subscriber mailbox growth is a known limitation and
must be documented. Do not add an unbounded intermediate queue. A future
bounded/acknowledged stream can be considered separately.

An adapter without native streaming must report that capability
accurately. Hayata must not pretend that ordinary generation is token
streaming. The public subscription mechanism remains the only public
streaming interface.

## 10. Agent-scoped configuration

The provider and model are selected when creating the agent. There is no
global provider default and no provider selection on each invocation.
All LLM-using nodes inherit the agent's LLM configuration in v1.

Illustrative configuration (to be adapted to the actual agent API):

``` erlang
#{
    llm => #{
        adapter => hayata_openai,
        model => <<"gpt-4o">>,
        options => #{temperature => 0.0},
        credentials => #{
            source => environment,
            key => <<"OPENAI_API_KEY">>
        }
    }
}
```

The configuration is owned by the agent. Per-node provider/model
overrides are explicitly out of scope for v1, but the internal contract
should not make them impossible in a later version. No global registry or
global provider config is required.

Credential resolution must not put secret values in ordinary
configuration dumps. Credentials must never be included in logs,
telemetry, errors, or durable checkpoints. Prompts, multimodal payloads,
and tool arguments must not be logged by default.

Common options have explicit semantics: the facade validates and
normalizes known provider-neutral keys, and adapters handle only their
own `provider_options`. Unknown common keys are rejected rather than
silently ignored. Maps are not merged across global/provider/agent/node/
invocation layers because those layers do not exist in v1; the agent's
configuration is the effective configuration for all its LLM nodes.

## 11. Normalized errors

Initial categories:

-   `invalid_request`
-   `unsupported_capability`
-   `authentication`
-   `rate_limited`
-   `timeout`
-   `cancelled`
-   `provider_error`
-   `invalid_response`

Example:

``` erlang
{error, #{
    category => rate_limited,
    message => <<"Provider rate limit exceeded">>,
    retryable => true,
    provider => openai,
    details => #{}
}}
```

Details must be sanitized. Safe status codes or provider request IDs may
be retained, but raw request/response bodies, credentials, authorization
headers, and sensitive user content must not be included by default.

Adapters normalize native errors. Hayata owns retry policy, taking error
category, attempt budget, deadlines, and operation semantics into
account. Do not automatically retry every error. Retrying a model
request differs from re-executing a tool that may have external side
effects.

## 12. Timeouts, cancellation, and concurrency

The remaining execution deadline is passed from Hayata's node execution
to the LLM operation. A provider timeout may be shorter, but must not
extend the remaining deadline. The adapter call returns a normalized
result or error; the stream callback is synchronous and its return value
is used to stop generation when the callback rejects an event.

The integration must define a concrete cancellation path when implemented:
Hayata marks the generation as terminal, requests adapter/transport
cancellation where available, and rejects any late events for that
`generation_id`. Killing a process alone must not be assumed to cancel an
external HTTP request unless the selected client guarantees that cleanup.
The API must not force every adapter to use a process, but the integration
may isolate a blocking provider operation when required to enforce a
deadline.

Concurrent invocations must not share mutable conversation history or
request state unless an explicitly configured provider session is
supported. A generation ID is unique within an invocation; events from a
stale generation cannot be forwarded into a later generation or invocation.

## 13. Adapter conformance suite

An adapter is conformant when tests verify:

### Request and response

-   Valid requests are accepted; invalid required fields are rejected.
-   Messages and content parts are translated correctly.
-   Assistant text, tool calls, finish reasons, and usage are
    normalized.
-   Multiple tool calls and call IDs are preserved.
-   Missing optional fields do not lead to invented values.
-   Errors are sanitized and credentials are not exposed.

### Capabilities

-   Capabilities are accurate for the selected model/configuration.
-   Unsupported features are reported rather than silently discarded.
-   Limits and usage are never invented.

### Streaming, if supported

-   Normalized events are valid and correctly ordered.
-   Partial text and partial tool arguments are handled.
-   The final response agrees with the stream.
-   Success, failure, cancellation, and timeout each have a single
    terminal outcome.
-   Provider resources are cleaned up when the consumer fails or the
    request is cancelled.

### Integration

-   The adapter never executes application tools.
-   It does not depend on internal graph-state representation.
-   It can be tested using a fake transport or fixtures.
-   It can be added without modifying `hayata_agent` or `hayata_node`.

Hayata core should provide reusable conformance tests for external
adapters.

## 14. Security

-   Resolve credentials from secure, explicit sources; never hard-code
    secrets.
-   Redact secrets from logs, telemetry, exceptions, and checkpoints.
-   Treat model-generated tool calls as untrusted input.
-   Validate tool names, schemas, permissions, and execution limits.
-   Keep provider metadata separate from portable contract fields.
-   Define persistence and retention before storing prompts or generated
    content in checkpoints.

## 15. Integration with Hayata's graph

The LLM contract sits above the existing graph runtime. A typical
tool-using agent has these logical nodes:

1.  `model_node`: call the configured model with the current message
    history.
2.  `tool_node`: validate and execute tool calls, then append
    tool-result messages.
3.  A decision policy routes to `tool_node` when tool calls are present,
    or finishes when the assistant returns a final answer.
4.  `tool_node` routes back to `model_node` after tool results have been
    appended.
5.  Native LLM stream events are bridged to Hayata's existing invocation
    stream.

Message history belongs to agent/application state, not hidden mutable
state in a provider adapter. This supports recovery and keeps a graph
compatible with different providers.

The first reference example should reproduce the weather-tool flow:
request weather, receive a normalized tool call, execute the weather
function in Hayata, send its result back as a tool message, and return
the final assistant response. Build the Erlang example first, then an
Elixir-facing example.

## 16. Implementation sequence

1.  Review and approve this contract.
2.  Define public Erlang types, adapter behaviour, request validation,
    and normalized errors.
3.  Implement `hayata_llm` with a deterministic fake adapter.
4.  Add contract tests that require no network access.
5.  Finalize native streaming semantics and test them with a fake
    stream.
6.  Implement the first real provider adapter (OpenAI is the proposed
    reference).
7.  Implement Hayata-owned tool-call orchestration and limits.
8.  Build and test the Erlang weather-agent example.
9.  Add an Elixir-facing example.
10. Implement further adapters such as Gemini and Anthropic using the
    same conformance suite.
11. Design conversational memory as a separate capability integrated
    with graph state and message history, not as a provider-adapter
    responsibility.

## 17. Decisions to finalize before freezing the API

The following points are now decided for v1:

1. Provider/model selection happens when the agent is created; no global
   provider default and no per-invocation selection.
2. All LLM nodes inherit the agent's provider/model configuration. Per-node
   overrides remain a future extension.
3. LLM stream events use the existing `hayata_agent_event` envelope and
   subscriber PID; no separate public subscription API.
4. Native stream callbacks synchronously deliver normalized events to an
   internal Hayata callback. Public subscriber delivery remains
   asynchronous in v1, with no acknowledgement-based backpressure.
5. `capabilities/1` is queried at agent initialization and should be local
   and deterministic by default; unknown capabilities are represented as
   unknown, not guessed.
6. Tool parameters use a documented JSON Schema subset in v1.
7. Hayata validates and executes tools; adapters only normalize tool calls.

Remaining points to settle in the implementation design:

1. Exact event data fields for `content_delta`, tool-call deltas, and
   message/content correlation IDs.
2. Exact cancellation/deadline mechanism for adapters that cannot cancel
   an in-flight HTTP request natively.
3. Which initial multimodal source forms are supported (text is mandatory;
   image source forms can be added explicitly).
4. Exact structured-output schema and validation responsibility.
5. The tagged error-map fields and retryable classification rules.
6. Adapter packaging/versioning: separate Hex packages versus separate
   repositories.
7. Public compatibility guarantees for messages, events, errors, and
   capabilities.

Do not freeze the public API until the remaining points are represented
in executable conformance tests.

## 18. Initial non-goals

The first implementation does not need every modality for every
provider, a universal vector-store API, automatic long-term memory, full
feature parity across providers, automatic retries for arbitrary tool
side effects, or a guarantee that all native streaming behavior can be
represented without loss.

The goal is a small, robust, extensible core contract with explicit
capability boundaries---not a lowest-common-denominator API that hides
provider differences.
