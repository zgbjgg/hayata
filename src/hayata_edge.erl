
-module(hayata_edge).
-behaviour(gen_server).

-export([
    start/4,
    start/5,
    start/6,
    execute/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(edge_state, {
    node_pid,
    reducer_pid = undefined,
    edge_id,
    execution_id,
    task,
    metadata = #{},
    started_at = undefined
}).

-type edge_id() :: term().
-type execution_id() :: term().
-type task_result() :: {ok, term()} | {error, term()}.
-type task_fun() :: fun(() -> task_result()).

-doc("Starts an anonymous, linked edge process.").
-spec start(pid(), edge_id(), execution_id(), task_fun()) ->
    gen_server:start_ret().
start(NodePid, EdgeId, ExecutionId, TaskFun)
        when is_pid(NodePid), is_function(TaskFun, 0) ->
    start(NodePid, undefined, EdgeId, ExecutionId, TaskFun).

-doc("Starts an anonymous edge process with a result reducer.").
-spec start(pid(), pid() | undefined, edge_id(), execution_id(), task_fun()) ->
    gen_server:start_ret().
start(NodePid, ReducerPid, EdgeId, ExecutionId, TaskFun)
        when is_pid(NodePid),
             (is_pid(ReducerPid) orelse ReducerPid =:= undefined),
             is_function(TaskFun, 0) ->
    start(
        NodePid,
        ReducerPid,
        EdgeId,
        ExecutionId,
        TaskFun,
        #{}
    ).

-doc("Starts an edge with persistent task metadata.").
-spec start(
    pid(),
    pid() | undefined,
    edge_id(),
    execution_id(),
    task_fun(),
    map()
) -> gen_server:start_ret().
start(NodePid, ReducerPid, EdgeId, ExecutionId, TaskFun, Metadata)
        when is_pid(NodePid),
             (is_pid(ReducerPid) orelse ReducerPid =:= undefined),
             is_function(TaskFun, 0),
             is_map(Metadata) ->
    gen_server:start(
        ?MODULE,
        {
            NodePid,
            ReducerPid,
            EdgeId,
            ExecutionId,
            TaskFun,
            Metadata
        },
        []
    ).

-doc("Starts execution of an edge process.").
-spec execute(pid()) -> ok.
execute(EdgePid) ->
    gen_server:cast(EdgePid, start).


-doc(false).
-spec init({
    pid(),
    pid() | undefined,
    edge_id(),
    execution_id(),
    task_fun(),
    map()
}) -> {ok, #edge_state{}}.
init({NodePid, ReducerPid, EdgeId, ExecutionId, TaskFun, Metadata}) ->
    EdgePid = self(),
    ok = hayata_monitor:start(NodePid, EdgePid),

    {ok, #edge_state{
        node_pid = NodePid,
        reducer_pid = ReducerPid,
        edge_id = EdgeId,
        execution_id = ExecutionId,
        task = TaskFun,
        metadata = Metadata
    }}.

-doc(false).
-spec handle_call(term(), gen_server:from(), #edge_state{}) ->
    {reply, term(), #edge_state{}}.
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

-doc(false).
-spec handle_cast(term(), #edge_state{}) ->
    {noreply, #edge_state{}} | {stop, term(), #edge_state{}}.
handle_cast(start, State) ->
    StartedAt = erlang:monotonic_time(),
    StartedState = State#edge_state{started_at = StartedAt},
    telemetry:execute(
        [hayata, edge, start],
        #{system_time => erlang:system_time()},
        edge_metadata(StartedState)
    ),
    TaskKey = task_key(StartedState),
    execute_persisted_task(
        TaskKey,
        edge_metadata(StartedState),
        StartedState
    );
handle_cast(_Request, State) ->
    {noreply, State}.

-doc(false).
-spec handle_info(term(), #edge_state{}) ->
    {noreply, #edge_state{}} | {stop, term(), #edge_state{}}.
handle_info(_Info, State) ->
    {noreply, State}.

-doc(false).
-spec terminate(term(), #edge_state{}) -> ok.
terminate(_Reason, _State) ->
    ok.

-doc(false).
-spec code_change(term(), #edge_state{}, term()) ->
    {ok, #edge_state{}}.
code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% Internal functions


-spec emit_terminal_event(
    term(),
    map(),
    map()
) -> ok.
emit_terminal_event({error, {exception, Class, _Reason, _Stacktrace}}, Measurements, Metadata) ->
    telemetry:execute(
        [hayata, edge, exception],
        Measurements,
        Metadata#{
            class => Class
        }
    );
emit_terminal_event(_Result, Measurements, Metadata) ->
    telemetry:execute(
        [hayata, edge, stop],
        Measurements,
        Metadata
    ).

-spec execute_persisted_task(tuple(), map(), #edge_state{}) ->
    {noreply, #edge_state{}} | {stop, term(), #edge_state{}}.
execute_persisted_task(TaskKey, Metadata, State) ->
    case hayata_task_store:claim_task(TaskKey, Metadata) of
        {ok, execute} ->
            execute_and_persist(TaskKey, State);
        {ok, {completed, Result}} ->
            finish_edge(Result, State);
        {error, task_execution_uncertain} ->
            finish_edge(
                {error, task_execution_uncertain},
                State
            );
        {error, Reason} ->
            finish_edge(
                {error, {checkpoint_claim_failed, Reason}},
                State
            )
    end.

-spec execute_and_persist(tuple(), #edge_state{}) ->
    {noreply, #edge_state{}} | {stop, term(), #edge_state{}}.
execute_and_persist(TaskKey, State) ->
    Result = run_task(State#edge_state.task),
    case hayata_task_store:save_task_result(TaskKey, Result) of
        ok ->
            finish_edge(Result, State);
        {error, Reason} ->
            finish_edge(
                {error, {checkpoint_persist_failed, Reason}},
                State
            )
    end.

-spec run_task(task_fun()) -> task_result().
run_task(TaskFun) ->
    try TaskFun() of
        {ok, _Value} = Result ->
            Result;
        {error, _Reason} = Result ->
            Result;
        Other ->
            {error, {invalid_task_result, Other}}
    catch
        Class:Reason:Stacktrace ->
            {error, {exception, Class, Reason, Stacktrace}}
    end.

-spec task_key(#edge_state{}) -> tuple().
task_key(State) ->
    Metadata = State#edge_state.metadata,
    AgentId = maps:get(agent_id, Metadata, undefined),
    {
        AgentId,
        State#edge_state.execution_id,
        State#edge_state.edge_id
    }.

-spec edge_metadata(#edge_state{}) -> map().
edge_metadata(State) ->
    (State#edge_state.metadata)#{
        edge_id => State#edge_state.edge_id,
        execution_id => State#edge_state.execution_id
    }.

-spec finish_edge(term(), #edge_state{}) ->
    {noreply, #edge_state{}} | {stop, term(), #edge_state{}}.
finish_edge(Result, State) ->
    Message = normalize_result(Result),
    StopReason = case Message of
        {ok, _Value} ->
            normal;
        {error, ErrorReason} ->
            {edge_failed, ErrorReason}
    end,
    Duration = erlang:monotonic_time() - State#edge_state.started_at,
    emit_terminal_event(
        Message,
        #{duration => Duration},
        edge_metadata(State)
    ),
    case State#edge_state.reducer_pid of
        undefined ->
            ok;
        ReducerPid ->
            ReducerPid ! {
                hayata_reducer_edge_result,
                State#edge_state.edge_id,
                State#edge_state.execution_id,
                Message
            }
    end,
    State#edge_state.node_pid ! {
        hayata_edge_result,
        State#edge_state.edge_id,
        State#edge_state.execution_id,
        Message
    },
    {stop, StopReason, State}.

-spec normalize_result(term()) ->
    {ok, term()} | {error, term()}.
normalize_result({ok, _Value} = Result) ->
    Result;
normalize_result({error, _Reason} = Result) ->
    Result;
normalize_result(Other) ->
    {error, {invalid_task_result, Other}}.
