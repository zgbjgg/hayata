# Adding an LLM provider to Hayata

This guide is intended for contributors and coding agents implementing a new LLM provider. Treat the existing OpenAI adapter and its tests as the reference implementation, but keep provider-specific HTTP payloads out of Hayata's shared contract.

## Goals

A new provider adapter must:

1. Implement the shared Hayata LLM adapter contract.
2. Translate Hayata's normalized request into the provider's request format.
3. Normalize successful responses, tool calls, streaming events, and errors back into Hayata's contract.
4. Reject malformed or unsupported data explicitly rather than silently losing it.
5. Include deterministic tests for success, failure, serialization, tools, and streaming.
6. Keep the tool loop provider-agnostic.

Reference files:

- Contract: [`src/hayata_llm_adapter.erl`](../../src/hayata_llm_adapter.erl)
- Reference provider: [OpenAI adapter guide](openai.md)
- Reference implementation: [`src/hayata_openai.erl`](../../src/hayata_openai.erl)
- Reference tests: [`test/hayata_openai_tests.erl`](../../test/hayata_openai_tests.erl)
- Tool execution loop: [`src/hayata_tool_loop.erl`](../../src/hayata_tool_loop.erl)
- Tool validation and execution: [`src/hayata_tool.erl`](../../src/hayata_tool.erl)
- Tool-loop tests: [`test/hayata_tool_loop_tests.erl`](../../test/hayata_tool_loop_tests.erl)

## 1. Implement the adapter contract

Create a provider module, for example `hayata_example_provider.erl`, and declare the behavior:

```erlang
-module(hayata_example_provider).
-behaviour(hayata_llm_adapter).

-export([capabilities/1, generate/2, generate_stream/3]).
```

Implement the callbacks defined in `hayata_llm_adapter.erl`:

- `capabilities(Config)`: return `{ok, Capabilities}` or a normalized error. Report only capabilities the adapter actually implements.
- `generate(Request, Config)`: perform one non-streaming generation and return a normalized response or normalized error.
- `generate_stream(Request, Config, Consumer)`: if streaming is supported, emit normalized events and return the final normalized response. Streaming is an optional callback in the behavior, but export it if your provider supports it.

Use the types from `hayata_llm_adapter` in public specs. Follow the repository's public API documentation conventions and add `-doc` and `-spec` annotations to public functions.

## 2. Keep the request and response format provider-neutral

The normalized request requires:

```erlang
#{
    model => ModelBinary,
    messages => [
        #{
            role => system | developer | user | assistant | tool,
            content => [ContentBlock]
        }
    ]
}
```

Text content blocks use `#{type => text, text => Binary}`. Tool definitions are added to the request by `hayata_tool_loop`; they contain `name`, `description`, and `parameters`, with the handler removed before they are sent to a provider.

A normalized successful response must have this shape:

```erlang
{ok, #{
    message => #{
        role => assistant,
        content => [#{type => text, text => TextBinary}]
        %% Include tool_calls when the model requests tools
    },
    finish_reason => stop | length | tool_calls | content_filter,
    id => ProviderResponseId
}}
```

A normalized tool call must contain a non-empty binary `id`, a non-empty binary `name`, and a map of decoded `arguments`. If the provider returns both text and tool calls in one response, preserve both. Do not execute tools inside the adapter; `hayata_tool_loop` validates and executes them.

## 3. Normalize errors

Use the shared error codes declared in `hayata_llm_adapter`:

- `invalid_request`
- `unsupported_capability`
- `authentication`
- `rate_limited`
- `timeout`
- `cancelled`
- `provider_error`
- `invalid_response`

Provider-specific status codes and response formats must be translated into this shared vocabulary. Add extra fields such as `reason` when they are stable and useful. Do not expose credentials or sensitive request data in errors or logs.

At minimum, handle invalid configuration, missing credentials, malformed JSON, provider authentication errors, rate limiting, timeouts, server errors, incomplete responses, and unexpected response shapes.

## 4. Implement tool calling end to end

When the provider supports tool calling:

1. Convert Hayata tool definitions into the provider's schema format.
2. Convert assistant tool calls into normalized maps with `id`, `name`, and `arguments`.
3. Validate every call in a response before returning success. If any call is malformed, reject the whole response so the tool loop cannot partially execute a valid subset.
4. Preserve the association between each tool call and its result using the call ID.
5. Serialize assistant tool calls and tool results in the provider's required conversation-history format.
6. Preserve Unicode, empty strings, lists, booleans, nested maps, and JSON-compatible values.
7. Reject invalid JSON arguments and arguments that are not objects.
8. Do not execute handlers in the adapter; execution and recovery are the tool loop's responsibility.

If tool calling is not supported, report `tool_calling => false` in capabilities and do not claim that it works.

## 5. Implement streaming safely (if supported)

Use the normalized `stream_event/0` contract. Each event must include:

```erlang
#{
    type => EventType,
    generation_id => StableGenerationId,
    data => EventData
}
```

Keep the same `generation_id` for the entire generation. Respect the consumer contract: `ok` continues; `{error, Reason}` cancels. Stop emitting when the consumer fails, reject malformed event payloads, reject events after terminal completion, and return an error if the stream ends without a valid terminal response.

If streaming is not supported, do not advertise it. Keep non-streaming generation functional independently.

## 6. Build a deterministic test suite

Use `test/hayata_openai_tests.erl` as a coverage checklist, adapting cases to the new provider protocol. Prefer a local HTTP server or injected transport over live API calls. Tests must not require paid requests, real credentials, or external network access.

### Capabilities and configuration

- [ ] Capabilities accurately describe tool calling, streaming, structured output, embeddings, and modalities.
- [ ] Capabilities are stable for equivalent configurations.
- [ ] Missing credentials and empty credentials are rejected.
- [ ] Invalid base URL, timeout, and malformed configuration are rejected.
- [ ] Request shape validation covers missing model/messages, invalid roles, and unsupported content.

### Non-streaming response normalization

- [ ] Basic text response maps to `finish_reason => stop`.
- [ ] Empty or malformed response is rejected.
- [ ] Invalid JSON and unexpected status/finish reasons are rejected.
- [ ] Incomplete responses and provider-specific failure states are normalized.
- [ ] HTTP authentication, forbidden, rate-limit, timeout, client-error, and server-error statuses are mapped consistently.
- [ ] Provider response ID is preserved when available.

### Tool calling and conversation history

- [ ] One tool call is normalized correctly.
- [ ] Multiple tool calls preserve their order.
- [ ] Text plus tool calls in the same response preserves both.
- [ ] Missing/empty call ID, missing/empty name, invalid JSON arguments, and non-object arguments are rejected.
- [ ] A response with valid and malformed calls mixed together is rejected as a whole.
- [ ] Tool definitions are converted correctly; handler functions never appear in provider payloads.
- [ ] No empty `tools` property is sent if the contract expects omission.
- [ ] Assistant tool calls and tool results are serialized into subsequent history with matching call IDs.
- [ ] Unicode, empty strings, nested maps, arrays/lists, numbers, and booleans round-trip correctly.
- [ ] Multiple tool rounds preserve message order and call/result association.

### Streaming

- [ ] Fragmented and multi-event transport chunks are parsed correctly.
- [ ] Comments and multiline event data are handled according to the provider's SSE protocol.
- [ ] Text deltas are normalized.
- [ ] Every event in a generation uses one stable generation ID.
- [ ] Completion produces the same normalized final response contract as non-streaming generation.
- [ ] Failure before start, malformed events, inconsistent IDs, events after terminal completion, timeout, and missing completion are rejected.
- [ ] Consumer cancellation, invalid return values, and exceptions stop the stream safely.

### Tool-loop integration

- [ ] The provider callback works with `hayata_tool_loop:run/4`.
- [ ] Provider errors are propagated as `{error, {llm_failed, Reason}}`.
- [ ] Malformed tool calls never result in partial execution.
- [ ] Tool execution errors are handled by the shared loop, not duplicated in the adapter.
- [ ] Iteration limits prevent another tool batch from executing.

Run the suite:

```sh
rebar3 eunit
```

If the new provider has its own test module, follow the repository's naming convention, for example `test/hayata_example_provider_tests.erl`.

## 7. Keep the implementation maintainable

- Keep provider-specific payload conversion inside the provider module.
- Keep shared tool validation and execution in `hayata_tool` and `hayata_tool_loop`.
- Do not add provider-specific branches to the generic tool loop unless a provider-neutral contract genuinely needs to change.
- Add regression tests for every bug fixed.
- Update the LLM section in the README with a link to the provider's adapter documentation once it is supported.
- Do not advertise unsupported features in capabilities or documentation.

A provider is ready to be listed as available only when its implementation, tests, normalized errors, and documentation agree.
