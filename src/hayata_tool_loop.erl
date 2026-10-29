-module(hayata_tool_loop).

-export([
    run/4
]).

-doc("Runs an LLM interaction loop with controlled tool execution.").
-spec run(function(), map(), list(), pos_integer()) ->
    {ok, map()} | {error, term()}.
run(_LLM, _Request, _Tools, MaxIterations)
        when not is_integer(MaxIterations);
             MaxIterations =< 0 ->
    {error, invalid_max_iterations};
run(LLM, Request, Tools, MaxIterations)
        when is_function(LLM, 1),
             is_map(Request),
             is_list(Tools) ->
    case maps:get(messages, Request, undefined) of
        Messages when is_list(Messages) ->
            case prepare_tools(Tools) of
                {ok, Definitions} ->
                    loop(
                        LLM,
                        Request,
                        Tools,
                        Definitions,
                        MaxIterations,
                        0
                    );
                {error, Reason} ->
                    {error, {invalid_tools, Reason}}
            end;
        _Other ->
            {error, invalid_request}
    end;
run(_LLM, _Request, _Tools, _MaxIterations) ->
    {error, invalid_request}.

-spec prepare_tools(list()) -> {ok, [map()]} | {error, term()}.
prepare_tools([]) ->
    {ok, []};
prepare_tools(Tools) ->
    hayata_tool:definitions(Tools).

-spec loop(
    function(),
    map(),
    list(),
    [map()],
    pos_integer(),
    non_neg_integer()
) -> {ok, map()} | {error, term()}.
loop(LLM, Request, Tools, Definitions, MaxIterations, Iterations) ->
    LLMRequest = add_tool_definitions(Request, Definitions),
    CurrentIteration = Iterations + 1,

    case call_llm(LLM, LLMRequest) of
        {ok, Response} ->
            case response_tool_calls(Response) of
                {ok, []} ->
                    finish(Response, Request, CurrentIteration);
                {ok, ToolCalls} when CurrentIteration >= MaxIterations ->
                    _ = ToolCalls,
                    {error, max_iterations_reached};
                {ok, ToolCalls} ->
                    continue_with_tools(
                        LLM,
                        Request,
                        Tools,
                        Definitions,
                        MaxIterations,
                        CurrentIteration,
                        Response,
                        ToolCalls
                    );
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, {llm_failed, Reason}}
    end.

-spec add_tool_definitions(map(), [map()]) -> map().
add_tool_definitions(Request, []) ->
    maps:remove(tools, Request);
add_tool_definitions(Request, Definitions) ->
    maps:put(tools, Definitions, Request).

-spec call_llm(function(), map()) ->
    {ok, map()} | {error, term()}.
call_llm(LLM, Request) ->
    try LLM(Request) of
        {ok, Response} when is_map(Response) ->
            validate_response_shape(Response);
        {error, Reason} ->
            {error, Reason};
        _Other ->
            {error, invalid_llm_response}
    catch
        _Class:_Reason ->
            {error, llm_call_failed}
    end.

-spec validate_response_shape(map()) ->
    {ok, map()} | {error, invalid_llm_response}.
validate_response_shape(
    #{
        message := #{role := assistant, content := Content},
        finish_reason := FinishReason
    } = Response
) when is_list(Content), is_atom(FinishReason) ->
    case valid_finish_reason(FinishReason) of
        true ->
            case response_tool_calls(Response) of
                {ok, _ToolCalls} ->
                    {ok, Response};
                {error, _Reason} ->
                    {error, invalid_llm_response}
            end;
        false ->
            {error, invalid_llm_response}
    end;
validate_response_shape(_Response) ->
    {error, invalid_llm_response}.

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

-spec response_tool_calls(map()) ->
    {ok, [map()]} | {error, invalid_tool_calls}.
response_tool_calls(#{message := Message}) ->
    case maps:find(tool_calls, Message) of
        error ->
            {ok, []};
        {ok, ToolCalls} when is_list(ToolCalls) ->
            validate_tool_calls(ToolCalls);
        {ok, _Other} ->
            {error, invalid_tool_calls}
    end.

-spec validate_tool_calls(list()) ->
    {ok, [map()]} | {error, invalid_tool_calls}.
validate_tool_calls([]) ->
    {ok, []};
validate_tool_calls([
    #{
        id := Id,
        name := Name,
        arguments := Arguments
    } = ToolCall | Rest
]) when is_binary(Id), byte_size(Id) > 0,
       is_binary(Name), byte_size(Name) > 0,
       is_map(Arguments) ->
    case validate_tool_calls(Rest) of
        {ok, ValidRest} ->
            {ok, [ToolCall | ValidRest]};
        {error, Reason} ->
            {error, Reason}
    end;
validate_tool_calls(_ToolCalls) ->
    {error, invalid_tool_calls}.

-spec finish(map(), map(), pos_integer()) -> {ok, map()}.
finish(Response, Request, Iterations) ->
    Messages = maps:get(messages, Request),
    Message = maps:get(message, Response),
    UpdatedMessages = Messages ++ [Message],

    {ok, #{
        response => Response,
        messages => UpdatedMessages,
        iterations => Iterations
    }}.

-spec continue_with_tools(
    function(),
    map(),
    list(),
    [map()],
    pos_integer(),
    pos_integer(),
    map(),
    [map()]
) -> {ok, map()} | {error, term()}.
continue_with_tools(
    LLM,
    Request,
    Tools,
    Definitions,
    MaxIterations,
    Iterations,
    Response,
    ToolCalls
) ->
    Messages = maps:get(messages, Request),
    AssistantMessage = maps:get(message, Response),

    case execute_calls(ToolCalls, Tools, []) of
        {ok, ToolMessages} ->
            UpdatedMessages =
                Messages ++ [AssistantMessage] ++ ToolMessages,
            UpdatedRequest = maps:put(
                messages,
                UpdatedMessages,
                Request
            ),
            loop(
                LLM,
                UpdatedRequest,
                Tools,
                Definitions,
                MaxIterations,
                Iterations
            );
        {error, Reason} ->
            {error, Reason}
    end.

-spec execute_calls([map()], list(), [map()]) ->
    {ok, [map()]} | {error, term()}.
execute_calls([ToolCall | Rest], Tools, Acc) ->
    Id = maps:get(id, ToolCall),
    Name = maps:get(name, ToolCall),
    Arguments = maps:get(arguments, ToolCall),

    Result = hayata_tool:execute(Name, Arguments, Tools),
    Message = tool_result_message(Id, Name, Result),

    execute_calls(Rest, Tools, [Message | Acc]);
execute_calls([], _Tools, Acc) ->
    {ok, lists:reverse(Acc)}.

-spec tool_result_message(binary(), binary(), term()) -> map().
tool_result_message(Id, Name, Result) ->
    #{
        role => tool,
        tool_call_id => Id,
        name => Name,
        content => [
            #{
                type => text,
                text => encode_tool_result(Result)
            }
        ]
    }.

-spec encode_tool_result(term()) -> binary().
encode_tool_result({ok, Result}) ->
    encode_json(Result);
encode_tool_result({error, _Reason}) ->
    encode_json(#{error => <<"tool_execution_failed">>});
encode_tool_result(Result) ->
    encode_json(Result).

-spec encode_json(term()) -> binary().
encode_json(Term) ->
    try iolist_to_binary(json:encode(Term)) of
        JSON ->
            JSON
    catch
        _:_ ->
            <<"{\"error\":\"tool_result_not_serializable\"}">>
    end.
