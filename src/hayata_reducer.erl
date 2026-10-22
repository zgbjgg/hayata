-module(hayata_reducer).

-behaviour(gen_server).

-export([
    start/1,
    activate/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(reducer_state, {
    node_pid,
    execution_id,
    expected_edges = [],
    results = #{},
    errors = #{},
    timeout_ms,
    timeout_ref = undefined,
    activated = false,
    started_at = undefined
}).

-type edge_id() :: term().
-type execution_id() :: term().
-type config() :: #{
    node_pid := pid(),
    execution_id := execution_id(),
    expected_edges := [edge_id()],
    timeout_ms := non_neg_integer(),
    results => map(),
    errors => map()
}.

-doc("Starts an unlinked reducer for a single execution.").
-spec start(config()) -> gen_server:start_ret().
start(Config) when is_map(Config) ->
    gen_server:start(?MODULE, Config, []).

-doc("Activates the reducer and confirms that it is ready.").
-spec activate(gen_server:server_ref()) -> ok.
activate(Reducer) ->
    gen_server:call(Reducer, activate).

-doc(false).
-spec init(config()) ->
    {ok, #reducer_state{}, {continue, evaluate}} |
    {stop, term()}.
init(Config) ->
    case validate_config(Config) of
        {ok, NodePid, ExecutionId, ExpectedEdges,
         Results, Errors, TimeoutMs} ->
            {ok, #reducer_state{
                node_pid = NodePid,
                execution_id = ExecutionId,
                expected_edges = ExpectedEdges,
                results = Results,
                errors = Errors,
                timeout_ms = TimeoutMs,
                timeout_ref = undefined,
                activated = false
            }};
        {error, Reason} ->
            {stop, Reason}
    end.

-doc(false).
-spec handle_call(term(), gen_server:from(), #reducer_state{}) ->
    {reply, {error, unsupported_request}, #reducer_state{}}.
handle_call(activate, _From, State = #reducer_state{execution_id = ExecutionId, activated = false, timeout_ms = TimeoutMs}) ->
    StartedAt = erlang:monotonic_time(),
    TimeoutRef = erlang:send_after(
        TimeoutMs,
        self(),
        {reducer_timeout, ExecutionId}
    ),
    NewState = State#reducer_state{
        activated = true,
        timeout_ref = TimeoutRef,
        started_at = StartedAt
    },
    telemetry:execute(
        [hayata, reducer, start],
        #{system_time => erlang:system_time()},
        #{execution_id => State#reducer_state.execution_id}
    ),
    self() ! {hayata_reducer_evaluate, ExecutionId},
    {reply, ok, NewState};
handle_call(activate, _From, State) ->
    {reply, {error, already_activated}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

-doc(false).
-spec handle_cast(term(), #reducer_state{}) ->
    {noreply, #reducer_state{}}.
handle_cast(_Request, State) ->
    {noreply, State}.

-doc(false).
-spec handle_info(term(), #reducer_state{}) ->
    {noreply, #reducer_state{}} |
    {stop, normal, #reducer_state{}}.
handle_info({hayata_reducer_edge_result, EdgeId, ExecutionId, Result}, State = #reducer_state{execution_id = ExecutionId, activated = true}) ->
    NewState = record_result(EdgeId, Result, State),
    evaluate_completion(NewState);
handle_info({hayata_reducer_edge_down, EdgeId, ExecutionId, Reason}, State = #reducer_state{execution_id = ExecutionId, activated = true}) ->
    NewState = record_error(EdgeId, Reason, State),
    evaluate_completion(NewState);
handle_info({reducer_timeout, ExecutionId}, State = #reducer_state{execution_id = ExecutionId}) ->
    finish(timed_out, State);
handle_info({hayata_reducer_evaluate, ExecutionId}, State = #reducer_state{execution_id = ExecutionId, activated = true}) ->
    evaluate_completion(State);
handle_info({hayata_reducer_activate, ExecutionId}, State = #reducer_state{execution_id = ExecutionId, activated = false, timeout_ms = TimeoutMs}) ->
    StartedAt = erlang:monotonic_time(),
    TimeoutRef = erlang:send_after(
        TimeoutMs,
        self(),
        {reducer_timeout, ExecutionId}
    ),
    NewState = State#reducer_state{
        activated = true,
        timeout_ref = TimeoutRef,
        started_at = StartedAt
    },
    telemetry:execute(
        [hayata, reducer, start],
        #{system_time => erlang:system_time()},
        #{execution_id => State#reducer_state.execution_id}
    ),
    evaluate_completion(NewState);
handle_info(_Info, State) ->
    {noreply, State}.

-doc(false).
-spec terminate(term(), #reducer_state{}) -> ok.
terminate(_Reason, _State) ->
    ok.

-doc(false).
-spec code_change(term(), #reducer_state{}, term()) ->
    {ok, #reducer_state{}}.
code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% Internal functions

-spec validate_config(map()) ->
    {ok, pid(), execution_id(), [edge_id()], map(), map(),
     non_neg_integer()} |
    {error, term()}.
validate_config(Config) ->
    case {
        maps:get(node_pid, Config, undefined),
        maps:get(execution_id, Config, undefined),
        maps:get(expected_edges, Config, undefined),
        maps:get(timeout_ms, Config, undefined),
        maps:get(results, Config, #{}),
        maps:get(errors, Config, #{})
    } of
        {NodePid, ExecutionId, ExpectedEdges, TimeoutMs, Results, Errors}
                when is_pid(NodePid),
                     is_list(ExpectedEdges),
                     is_integer(TimeoutMs),
                     TimeoutMs >= 0,
                     is_map(Results),
                     is_map(Errors) ->
            {ok, NodePid, ExecutionId, lists:usort(ExpectedEdges),
             Results, Errors, TimeoutMs};
        _ ->
            {error, invalid_reducer_config}
    end.

-spec record_result(edge_id(), term(), #reducer_state{}) ->
    #reducer_state{}.
record_result(EdgeId, Result, State) ->
    case is_expected(EdgeId, State) andalso
         not is_recorded(EdgeId, State) of
        true ->
            store_result(EdgeId, Result, State);
        false ->
            State
    end.

-spec store_result(edge_id(), term(), #reducer_state{}) ->
    #reducer_state{}.
store_result(EdgeId, {ok, _Value} = Result, State) ->
    Results = maps:put(EdgeId, Result, State#reducer_state.results),
    State#reducer_state{results = Results};
store_result(EdgeId, {error, Reason}, State) ->
    Errors = maps:put(EdgeId, Reason, State#reducer_state.errors),
    State#reducer_state{errors = Errors};
store_result(EdgeId, Result, State) ->
    Errors = maps:put(
        EdgeId,
        {invalid_edge_result, Result},
        State#reducer_state.errors
    ),
    State#reducer_state{errors = Errors}.

-spec record_error(edge_id(), term(), #reducer_state{}) ->
    #reducer_state{}.
record_error(EdgeId, Reason, State) ->
    case is_expected(EdgeId, State) andalso
         not is_recorded(EdgeId, State) of
        true ->
            Errors = maps:put(EdgeId, Reason, State#reducer_state.errors),
            State#reducer_state{errors = Errors};
        false ->
            State
    end.

-spec is_expected(edge_id(), #reducer_state{}) -> boolean().
is_expected(EdgeId, State) ->
    lists:member(EdgeId, State#reducer_state.expected_edges).

-spec is_recorded(edge_id(), #reducer_state{}) -> boolean().
is_recorded(EdgeId, State) ->
    maps:is_key(EdgeId, State#reducer_state.results) orelse
    maps:is_key(EdgeId, State#reducer_state.errors).

-spec evaluate_completion(#reducer_state{}) ->
    {noreply, #reducer_state{}} |
    {stop, normal, #reducer_state{}}.
evaluate_completion(State) ->
    case pending_edges(State) of
        [] ->
            finish(completed, State);
        _PendingEdges ->
            {noreply, State}
    end.

-spec pending_edges(#reducer_state{}) -> [edge_id()].
pending_edges(State) ->
    [
        EdgeId
     || EdgeId <- State#reducer_state.expected_edges,
        not is_recorded(EdgeId, State)
    ].

-spec finish(completed | timed_out, #reducer_state{}) ->
    {stop, normal, #reducer_state{}}.
finish(Status, State) ->
    cancel_timeout(State#reducer_state.timeout_ref),
    PendingEdges = pending_edges(State),
    FinalResult = #{
        status => Status,
        execution_id => State#reducer_state.execution_id,
        results => State#reducer_state.results,
        errors => State#reducer_state.errors,
        pending_edges => PendingEdges
    },
    telemetry:execute(
        [hayata, reducer, stop],
        #{
           duration => erlang:monotonic_time() - State#reducer_state.started_at
        },
        #{
            execution_id => State#reducer_state.execution_id,
            status => Status,
            expected_edges => length(State#reducer_state.expected_edges),
            result_count => map_size(State#reducer_state.results),
            error_count => map_size(State#reducer_state.errors),
            pending_edges => length(PendingEdges)
        }
    ),
    State#reducer_state.node_pid !
        {
            hayata_reducer_result,
            self(),
            State#reducer_state.execution_id,
            FinalResult
        },
    {stop, normal, State}.

-spec cancel_timeout(reference() | undefined) -> ok.
cancel_timeout(undefined) ->
    ok;
cancel_timeout(TimeoutRef) ->
    _ = erlang:cancel_timer(TimeoutRef),
    ok.
