# OpenAI LLM adapter

This document describes Hayata's OpenAI adapter, `hayata_openai`, implemented against the OpenAI Responses API.

- Source: [`src/hayata_openai.erl`](../../src/hayata_openai.erl)
- Adapter contract: [`src/hayata_llm_adapter.erl`](../../src/hayata_llm_adapter.erl)
- Adapter tests: [`test/hayata_openai_tests.erl`](../../test/hayata_openai_tests.erl)
- Tool execution loop: [`src/hayata_tool_loop.erl`](../../src/hayata_tool_loop.erl)

## Scope and current capabilities

The adapter reports these capabilities from `hayata_openai:capabilities/1`:

| Capability | Current value |
| --- | --- |
| Tool calling | Supported |
| Streaming | Supported |
| Structured output | Not advertised |
| Embeddings | Not supported |
| Input modality | Text |
| Output modality | Text |

These are adapter-level capabilities. They do not mean every OpenAI model supports every operation; callers should select a compatible model and handle provider errors.

## Configuration

Pass a configuration map to `generate/2` or `generate_stream/3`.

| Key | Required | Description |
| --- | --- | --- |
| `api_key` | Yes | Non-empty binary containing the API key |
| `base_url` | No | Non-empty binary; defaults to `https://api.openai.com/v1` |
| `timeout` | No | Positive integer in milliseconds; defaults to `30000` |

The adapter posts to `<base_url>/responses`, authenticates with a Bearer token, and uses Erlang's `httpc`. Do not commit API keys to source control.

Example:

```erlang
Config = #{
    api_key => <<"YOUR_API_KEY">>,
    base_url => <<"https://api.openai.com/v1">>,
    timeout => 30000
}.
```

## Normalized request format

The adapter accepts Hayata's provider-neutral request map. A request must contain a binary `model` and a list of `messages`.

```erlang
Request = #{
    model => <<"gpt-4.1-mini">>,
    messages => [
        #{
            role => user,
            content => [
                #{type => text, text => <<"What is the weather in Puebla?">>}
            ]
        }
    ]
}.
```

Supported message roles are `system`, `developer`, `user`, `assistant`, and `tool`. Text content blocks use `#{type => text, text => Binary}`. Unsupported roles or content shapes are rejected instead of being silently converted.

The adapter converts this normalized format to the Responses API's `input` structure. When no tools are supplied, it omits the `tools` property from the outgoing request.

## Tool calling

A tool definition has a name, description, JSON-like parameter schema, and a handler. The handler is used by `hayata_tool` and is not sent to OpenAI.

```erlang
WeatherTool = #{
    name => <<"get_weather">>,
    description => <<"Gets the current weather for a city.">>,
    parameters => #{
        type => object,
        properties => #{
            city => #{
                type => string,
                description => <<"City to look up.">>
            }
        },
        required => [<<"city">>]
    },
    handler => fun(Arguments) ->
        City = maps:get(<<"city">>, Arguments),
        {ok, #{city => City, temperature => 22}}
    end
}.
```

The JSON Schema subset currently converted by the adapter includes object, string, number, integer, and boolean types, nested properties, required fields, descriptions, enums, and `additionalProperties`. Validate actual schemas against the implementation and tests before relying on less common schema features.

Use the tool loop to let Hayata execute tool calls and send the results back to the model:

```erlang
LLM = fun(LLMRequest) ->
    hayata_openai:generate(LLMRequest, Config)
end,

Result = hayata_tool_loop:run(
    LLM,
    Request,
    [WeatherTool],
    5
).
```

The loop validates the assistant response and tool-call shape before executing calls. Tool calls are executed in order. A tool's `{error, Reason}` result or a caught handler exception is converted to a generic JSON error result, allowing the model to decide how to continue. The loop stops with `{error, max_iterations_reached}` rather than executing another batch once the configured iteration limit is reached.

## Normalized responses

A successful generation returns `{ok, Response}`. The response includes:

- `message`: an assistant message with normalized text content and, when requested, `tool_calls`.
- `finish_reason`: `stop` for a text response or `tool_calls` when function calls are present.
- `id`: the provider response ID when available.

Each normalized tool call has `id`, `name`, and `arguments`. Arguments must decode to a JSON object. Missing/empty call IDs, missing names, invalid JSON, or non-object arguments cause the response to be rejected. If a response includes both text and tool calls, both are preserved.

When serializing conversation history, Hayata converts assistant tool calls to Responses API `function_call` input items and tool results to `function_call_output` items. Call IDs are preserved to associate each result with the corresponding call. Nested maps, lists, empty strings, and UTF-8 strings should remain intact through JSON serialization.

## Streaming

Call `hayata_openai:generate_stream(Request, Config, Consumer)` with a one-argument consumer function. The adapter parses Server-Sent Events and emits normalized Hayata stream events. Each event includes `type`, `generation_id`, and `data`.

The adapter currently normalizes these event types:

- `message_started`
- `content_delta`
- `tool_call_started`
- `tool_call_delta`
- `tool_call_completed`
- `message_completed`
- `generation_completed`
- `generation_failed`

Every event in one stream must retain the same generation ID. The consumer must return `ok` to continue. Returning `{error, Reason}` stops the stream and produces a normalized cancellation error; an invalid return or a consumer exception is handled as an error. A stream that ends without a valid completion, contains malformed events, or changes generation ID is rejected.

Example:

```erlang
Consumer = fun(Event) ->
    io:format("LLM event: ~p~n", [Event]),
    ok
end,

Result = hayata_openai:generate_stream(Request, Config, Consumer).
```

## Normalized errors

The adapter returns `{error, #{code => Code}}` (some errors include a `reason` field). Current mappings include:

| Condition | Normalized code / reason |
| --- | --- |
| Missing or empty API key | `authentication` |
| HTTP 401 or 403 | `authentication` |
| HTTP 429 | `rate_limited` |
| Request timeout / HTTP 408 or 504 | `timeout` |
| Invalid request configuration or request shape | `invalid_request` |
| Malformed provider response, invalid tool call, malformed stream | `invalid_response` |
| Other HTTP/provider failures, including HTTP 5xx | `provider_error` |
| Incomplete response due to output-token limit | `provider_error`, reason `max_output_tokens` |
| Incomplete response due to content filtering | `provider_error`, reason `content_filter` |
| Consumer stops streaming | `cancelled` |

Do not rely on undocumented provider error-body fields being preserved; callers should branch on the normalized error contract.

## Tests and local verification

Run the repository's full test suite:

```sh
rebar3 eunit
```

The OpenAI tests exercise response normalization, HTTP status mapping, tool definitions and tool history, multi-round tool execution, malformed tool calls, mixed text and tool-call responses, Unicode/nested JSON serialization, and streaming event parsing and failure handling. Tests use a local HTTP server; they should not require a real API key or live network access.

When changing this adapter, add regression tests for both successful and malformed inputs. Keep the normalized contract provider-neutral so the tool loop does not need to understand OpenAI-specific payloads.
