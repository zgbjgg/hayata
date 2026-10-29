-module(hayata_llm).

-export([
    validate_config/1,
    capabilities/1,
    generate/2,
    generate_stream/3
]).

-export_type([config/0]).

-type config() :: #{
    adapter := module(),
    model := binary(),
    provider_config => map()
}.

-type request_input() :: #{
    messages := [hayata_llm_adapter:message()],
    atom() => term()
}.

-doc("Validates the adapter and model configuration.").
-spec validate_config(term()) -> ok | {error, term()}.
validate_config(Config) when is_map(Config) ->
    case {
        maps:find(adapter, Config),
        maps:find(model, Config),
        maps:find(provider_config, Config)
    } of
        {{ok, Adapter}, {ok, Model}, {ok, ProviderConfig}}
                when is_atom(Adapter),
                     is_binary(Model),
                     byte_size(Model) > 0,
                     is_map(ProviderConfig) ->
            validate_adapter(Adapter);
        {{ok, Adapter}, {ok, Model}, error}
                when is_atom(Adapter),
                     is_binary(Model),
                     byte_size(Model) > 0 ->
            validate_adapter(Adapter);
        _ ->
            {error, invalid_config}
    end;
validate_config(_Config) ->
    {error, invalid_config}.

-doc("Returns the configured adapter's normalized model capabilities.").
-spec capabilities(config()) ->
    {ok, hayata_llm_adapter:capabilities()} |
    {error, hayata_llm_adapter:normalized_error()}.
capabilities(Config) ->
    case validate_config(Config) of
        ok ->
            Adapter = maps:get(adapter, Config),
            ProviderConfig = provider_config(Config),
            case safe_adapter_call(
                Adapter,
                capabilities,
                [ProviderConfig]
            ) of
                {ok, Capabilities} when is_map(Capabilities) ->
                    {ok, Capabilities};
                {error, Reason} ->
                    normalize_error(Reason);
                _ ->
                    {error, #{code => invalid_response}}
            end;
        {error, Reason} ->
            {error, #{code => invalid_request, reason => Reason}}
    end.

-doc("Generates a normalized response using the configured model.").
-spec generate(config(), request_input()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
generate(Config, Request) ->
    case prepare_request(Config, Request) of
        {ok, Adapter, ProviderConfig, NormalizedRequest} ->
            case safe_adapter_call(
                Adapter,
                generate,
                [NormalizedRequest, ProviderConfig]
            ) of
                {ok, Response} ->
                    validate_response(Response);
                {error, Reason} ->
                    normalize_error(Reason);
                _ ->
                    {error, #{code => invalid_response}}
            end;
        {error, Reason} ->
            {error, #{code => invalid_request, reason => Reason}}
    end.

-doc("Generates a normalized response and forwards validated stream events.").
-spec generate_stream(config(), request_input(),
    hayata_llm_adapter:consumer()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
generate_stream(Config, Request, Consumer)
        when is_function(Consumer, 1) ->
    case prepare_request(Config, Request) of
        {ok, Adapter, ProviderConfig, NormalizedRequest} ->
            case erlang:function_exported(
                Adapter,
                generate_stream,
                3
            ) of
                true ->
                    run_stream(
                        Adapter,
                        ProviderConfig,
                        NormalizedRequest,
                        Consumer
                    );
                false ->
                    {error, #{code => unsupported_capability,
                        capability => streaming}}
            end;
        {error, Reason} ->
            {error, #{code => invalid_request, reason => Reason}}
    end;
generate_stream(_Config, _Request, _Consumer) ->
    {error, #{code => invalid_request}}.

-spec validate_adapter(module()) -> ok | {error, term()}.
validate_adapter(Adapter) ->
    case code:ensure_loaded(Adapter) of
        {module, Adapter} ->
            case {
                erlang:function_exported(Adapter, capabilities, 1),
                erlang:function_exported(Adapter, generate, 2)
            } of
                {true, true} ->
                    ok;
                _ ->
                    {error, invalid_adapter}
            end;
        {error, _Reason} ->
            {error, adapter_not_available}
    end.

-spec prepare_request(term(), term()) ->
    {ok, module(), map(), map()} | {error, term()}.
prepare_request(Config, Request) when is_map(Request) ->
    case validate_config(Config) of
        ok ->
            case maps:find(messages, Request) of
                {ok, Messages} when is_list(Messages) ->
                    Model = maps:get(model, Config),
                    case maps:find(model, Request) of
                        {ok, Model} ->
                            prepare_normalized_request(
                                Config,
                                Request,
                                Model
                            );
                        {ok, _OtherModel} ->
                            {error, model_mismatch};
                        error ->
                            prepare_normalized_request(
                                Config,
                                Request,
                                Model
                            )
                    end;
                _ ->
                    {error, invalid_messages}
            end;
        {error, Reason} ->
            {error, Reason}
    end;
prepare_request(_Config, _Request) ->
    {error, invalid_request}.

-spec prepare_normalized_request(config(), map(), binary()) ->
    {ok, module(), map(), map()}.
prepare_normalized_request(Config, Request, Model) ->
    Adapter = maps:get(adapter, Config),
    ProviderConfig = provider_config(Config),
    NormalizedRequest = Request#{model => Model},
    {ok, Adapter, ProviderConfig, NormalizedRequest}.

-spec provider_config(config()) -> map().
provider_config(Config) ->
    maps:get(provider_config, Config, #{}).

-spec safe_adapter_call(module(), atom(), [term()]) -> term().
safe_adapter_call(Adapter, Function, Arguments) ->
    try apply(Adapter, Function, Arguments) of
        Result ->
            Result
    catch
        _Class:_Reason ->
            {error, #{code => provider_error,
                reason => adapter_call_failed}}
    end.

-spec validate_response(term()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
validate_response(
    #{
        message := Message,
        finish_reason := FinishReason
    } = Response
) when is_map(Message), is_atom(FinishReason) ->
    case {
        maps:get(role, Message, undefined),
        maps:get(content, Message, undefined),
        valid_finish_reason(FinishReason)
    } of
        {assistant, Content, true} when is_list(Content) ->
            case validate_tool_calls(Message) of
                ok ->
                    case validate_finish_reason(FinishReason, Message) of
                        ok ->
                            {ok, Response};
                        {error, _Reason} ->
                            {error, #{code => invalid_response}}
                    end;
               {error, _Reason} ->
                   {error, #{code => invalid_response}}
           end;
        _ ->
            {error, #{code => invalid_response}}
    end;
validate_response(_Response) ->
    {error, #{code => invalid_response}}.

-spec valid_finish_reason(atom()) -> boolean().
valid_finish_reason(FinishReason) ->
    lists:member(
        FinishReason,
        [
            stop,
            length,
            tool_calls,
            content_filter
        ]
    ).

-spec validate_finish_reason(atom(), map()) ->
    ok | {error, invalid_finish_reason}.
validate_finish_reason(tool_calls, Message) ->
    case maps:get(tool_calls, Message, []) of
        [_First | _Rest] ->
            ok;
        _ ->
            {error, invalid_finish_reason}
    end;
validate_finish_reason(_FinishReason, Message) ->
    case maps:get(tool_calls, Message, []) of
        [] ->
            ok;
        _ ->
            {error, invalid_finish_reason}
    end.

-spec validate_tool_calls(map()) -> ok | {error, invalid_tool_calls}.
validate_tool_calls(Message) ->
    case maps:find(tool_calls, Message) of
        error ->
            ok;
        {ok, ToolCalls} when is_list(ToolCalls) ->
            validate_tool_calls_list(ToolCalls);
        {ok, _ToolCalls} ->
            {error, invalid_tool_calls}
    end.

-spec validate_tool_calls_list([map()]) -> ok | {error, invalid_tool_calls}.
validate_tool_calls_list([]) ->
    ok;
validate_tool_calls_list([
    #{
        id := Id,
        name := Name,
        arguments := Arguments
    } | Rest
]) when is_binary(Id), byte_size(Id) > 0,
         is_binary(Name), byte_size(Name) > 0,
         is_map(Arguments) ->
    validate_tool_calls_list(Rest);
validate_tool_calls_list(_ToolCalls) ->
    {error, invalid_tool_call}.

-spec forward_stream_event(
    term(),
    hayata_llm_adapter:consumer(),
    map()
) -> ok | {error, term()}.
forward_stream_event(Event, Consumer, State) ->
    case atomics:get(maps:get(closed, State), 1) of
        1 ->
            {error, stream_closed};
        0 ->
            forward_open_stream_event(Event, Consumer, State)
    end.

-spec forward_open_stream_event(
    term(),
    hayata_llm_adapter:consumer(),
    map()
) -> ok | {error, term()}.
forward_open_stream_event(Event, Consumer, State) ->
    Cancellation = maps:get(cancellation, State),

    case ets:lookup(Cancellation, cancellation) of
        [{cancellation, Reason}] ->
            {error, Reason};
        [] ->
            validate_stream_event(Event, Consumer, State)
    end.

-spec validate_stream_event(
    term(),
    hayata_llm_adapter:consumer(),
    ets:tid()
) -> ok | {error, term()}.
validate_stream_event(
    #{type := Type, generation_id := _GenerationId, data := Data} = Event,
    Consumer,
    State
) when is_atom(Type), is_map(Data) ->
    case lists:member(
        Type,
        [
            message_started,
            content_delta,
            tool_call_started,
            tool_call_delta,
            tool_call_completed,
            message_completed,
            generation_completed,
            generation_failed
        ]
    ) of
        true ->
            call_stream_consumer(Event, Consumer, State);
        false ->
            {error, invalid_stream_event}
    end;
validate_stream_event(_Event, _Consumer, _State) ->
    {error, invalid_stream_event}.

-spec call_stream_consumer(
    map(),
    hayata_llm_adapter:consumer(),
    ets:tid()
) -> ok | {error, term()}.
call_stream_consumer(Event, Consumer, State) ->
    try Consumer(Event) of
        ok ->
            ok;
        {error, Reason} = Error ->
            record_stream_cancellation(maps:get(cancellation, State), Reason),
            Error;
        _Other ->
            record_stream_cancellation(
                maps:get(cancellation, State),
                invalid_consumer_result
            ),
            {error, invalid_consumer_result}
    catch
        _Class:_Reason ->
            record_stream_cancellation(maps:get(cancellation, State), consumer_failed),
            {error, consumer_failed}
    end.

-spec record_stream_cancellation(ets:tid(), term()) -> true | false.
record_stream_cancellation(State, Reason) ->
    ets:insert_new(State, {cancellation, Reason}).

-spec normalize_error(term()) ->
    {error, hayata_llm_adapter:normalized_error()}.
normalize_error(#{code := Code} = Error) ->
    case lists:member(
        Code,
        [
            invalid_request,
            unsupported_capability,
            authentication,
            rate_limited,
            timeout,
            cancelled,
            provider_error,
            invalid_response
        ]
    ) of
        true ->
            {error, Error};
        false ->
            {error, #{code => provider_error}}
    end;
normalize_error(_Reason) ->
    {error, #{code => provider_error}}.

-spec run_stream(module(), map(), map(),
    hayata_llm_adapter:consumer()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
run_stream(Adapter, ProviderConfig, Request, Consumer) ->
    State = #{
        cancellation => ets:new(
            hayata_llm_stream_state,
            [set, public]
        ),
        closed => atomics:new(1, [])
    },

    try
        StreamConsumer = fun(Event) ->
            forward_stream_event(Event, Consumer, State)
        end,

        AdapterResult = safe_adapter_call(
            Adapter,
            generate_stream,
            [Request, ProviderConfig, StreamConsumer]
        ),

        case ets:lookup(maps:get(cancellation, State), cancellation) of
            [{cancellation, Reason}] ->
                {error, #{
                    code => cancelled,
                    reason => {consumer_rejected_event, Reason}
                }};
            [] ->
                normalize_stream_result(AdapterResult)
        end
    after
        atomics:put(maps:get(closed, State), 1, 1),
        ets:delete(maps:get(cancellation, State))
    end.

-spec normalize_stream_result(term()) ->
    {ok, hayata_llm_adapter:response()} |
    {error, hayata_llm_adapter:normalized_error()}.
normalize_stream_result({ok, Response}) ->
    validate_response(Response);
normalize_stream_result({error, Reason}) ->
    normalize_error(Reason);
normalize_stream_result(_Result) ->
    {error, #{code => invalid_response}}.
