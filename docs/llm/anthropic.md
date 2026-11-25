# Anthropic Claude adapter

Hayata's `hayata_anthropic` adapter integrates the Anthropic Messages API while keeping provider-specific payloads, HTTP headers, response normalization, and SSE parsing out of the shared LLM contract.

## Configuration

```erlang
LlmConfig = #{
    adapter => hayata_anthropic,
    model => <<"claude-sonnet-4-5">>,
    provider_config => #{
        api_key => list_to_binary(os:getenv("ANTHROPIC_API_KEY")),
        max_tokens => 2048,
        timeout => 30000
    }
}.
```

`api_key` is required. Optional provider settings are `base_url` (defaults to `https://api.anthropic.com/v1`), `api_version` (defaults to `2023-06-01`), `timeout` (milliseconds, defaults to `30000`), and request-level `max_tokens` (defaults to `1024`). Do not commit API keys or include them in logs.

The adapter sends `x-api-key` and `anthropic-version` headers and posts to `/messages`.

## Normalized request mapping

Hayata `system` and `developer` messages are concatenated into Anthropic's top-level `system` text blocks. `user` and `assistant` messages map to the corresponding Messages API roles. Tool definitions map from Hayata's `name`, `description`, and `parameters` to Anthropic's `name`, `description`, and `input_schema` fields. Hayata tool outputs are sent as `tool_result` blocks linked by `tool_use_id`.

Anthropic tool-use blocks are normalized to Hayata tool calls (`id`, `name`, and `arguments`). The adapter never invokes tool handlers; `hayata_tool_loop` owns execution and subsequent turns.

## Streaming

The adapter supports Anthropic's Messages SSE stream and normalizes text deltas to Hayata `content_delta` events. It preserves a stable generation ID per invocation and maps the final stop reason to the shared finish reason. Consumer errors cancel the HTTP request.

## Capabilities and limitations

- Text input and output.
- Tool calling.
- Streaming text deltas.
- No embeddings or structured-output capability advertised.
- The adapter currently accepts text content blocks only; multimodal image/audio blocks are rejected explicitly.

## Tests

Run the deterministic suite with:

```sh
rebar3 eunit --module=hayata_anthropic_tests
```

The tests do not use Anthropic credentials or make live API calls.
