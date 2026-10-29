-module(hayata_llm_adapter).

-export_type([
    request/0,
    response/0,
    message/0,
    content_block/0,
    tool_call/0,
    capabilities/0,
    normalized_error/0,
    stream_event/0,
    consumer/0,
    finish_reason/0
]).

-type role() ::
    system |
    developer |
    user |
    assistant |
    tool.

-type content_block() :: map().

-type message() :: #{
    role := role(),
    content := [content_block()],
    atom() => term()
}.

-type tool_call() :: #{
    id := binary(),
    name := binary(),
    arguments := map()
}.

-type request() :: #{
    model := binary(),
    messages := [message()],
    atom() => term()
}.

-type response() :: #{
    message := message(),
    finish_reason := finish_reason(),
    atom() => term()
}.

-type capabilities() :: #{
    atom() => term()
}.

-type error_code() ::
    invalid_request |
    unsupported_capability |
    authentication |
    rate_limited |
    timeout |
    cancelled |
    provider_error |
    invalid_response.

-type normalized_error() :: #{
    code := error_code(),
    atom() => term()
}.

-type stream_event_type() ::
    message_started |
    content_delta |
    tool_call_started |
    tool_call_delta |
    tool_call_completed |
    message_completed |
    generation_completed |
    generation_failed.

%% A normalized event emitted during a single generation.
%%
%% All events emitted by the same generate_stream/3 invocation
%% must use the same generation_id. Changing the identifier
%% causes Hayata to reject the stream with:
%% #{code => invalid_response, reason => inconsistent_generation_id}.
-type stream_event() :: #{
    type := stream_event_type(),
    generation_id := term(),
    data := map()
}.

-type consumer() ::
    fun((stream_event()) -> ok | {error, term()}).

-type finish_reason() ::
    stop |
    length |
    tool_calls |
    content_filter.

-export_type([
    role/0,
    error_code/0,
    stream_event_type/0
]).

%% Returns the capabilities supported by the configured model.
-callback capabilities(Config :: map()) ->
    {ok, Capabilities :: capabilities()} |
    {error, NormalizedError :: normalized_error()}.

%% Generates a normalized response without streaming events.
-callback generate(Request :: request(), Config :: map()) ->
    {ok, Response :: response()} |
    {error, NormalizedError :: normalized_error()}.

%% Generates a normalized response and emits intermediate events.
%%
%% Every event emitted during this invocation must use the same
%% generation_id. Events must comply with the stream_event/0
%% contract.
%%
%% The consumer must return ok to continue or {error, Reason}
%% to stop. The adapter must stop emitting events when the
%% consumer returns an error.
%%
%% If generation_id changes during the stream, Hayata rejects
%% the stream with invalid_response and reason
%% inconsistent_generation_id.
-callback generate_stream(
    Request :: request(),
    Config :: map(),
    Consumer :: consumer()
) ->
    {ok, Response :: response()} |
    {error, NormalizedError :: normalized_error()}.

-optional_callbacks([
    generate_stream/3
]).
