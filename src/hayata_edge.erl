
-module(hayata_edge).
-behaviour(gen_server).

-export([
    start/4,
    start/5,
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
    gen_server:start(
        ?MODULE,
        {NodePid, ReducerPid, EdgeId, ExecutionId, TaskFun},
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
    task_fun()
}) -> {ok, #edge_state{}}.
init({NodePid, ReducerPid, EdgeId, ExecutionId, TaskFun}) ->
    EdgePid = self(),
    ok = hayata_monitor:start(NodePid, EdgePid),

    {ok, #edge_state{
        node_pid = NodePid,
        reducer_pid = ReducerPid,
        edge_id = EdgeId,
        execution_id = ExecutionId,
        task = TaskFun
    }}.

-doc(false).
-spec handle_call(term(), gen_server:from(), #edge_state{}) ->
    {reply, term(), #edge_state{}}.
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

-doc(false).
-spec handle_cast(term(), #edge_state{}) ->
    {noreply, #edge_state{}}.
handle_cast(start, State) ->
    StartedAt = erlang:monotonic_time(),
    StartedState = State#edge_state{started_at = StartedAt},
    telemetry:execute(
        [hayata, edge, start],
        #{system_time => erlang:system_time()},
        #{
            edge_id => StartedState#edge_state.edge_id,
            execution_id => StartedState#edge_state.execution_id
        }
    ),

    Result = try
        (StartedState#edge_state.task)()
    catch
        Class:Reason:Stacktrace ->
            {error, {exception, Class, Reason, Stacktrace}}
    end,

    {Message, StopReason} = case Result of
        {ok, Res} ->
            {{ok, Res}, normal};

        {error, ErrorReason} ->
            {{error, ErrorReason}, {edge_failed, ErrorReason}}
    end,

    Duration = erlang:monotonic_time() - StartedState#edge_state.started_at,
    Measurements = #{duration => Duration},
    Metadata = #{
        edge_id => StartedState#edge_state.edge_id,
        execution_id => StartedState#edge_state.execution_id
    },
    emit_terminal_event(Message, Measurements, Metadata),

    ok = case StartedState#edge_state.reducer_pid of
        undefined ->
            ok;

        ReducerPid ->
            ReducerPid ! {
                hayata_reducer_edge_result,
                StartedState#edge_state.edge_id,
                StartedState#edge_state.execution_id,
                Message
            },
            ok
    end,

    StartedState#edge_state.node_pid ! {
        hayata_edge_result,
        StartedState#edge_state.edge_id,
        StartedState#edge_state.execution_id,
        Message
    },

    {stop, StopReason, StartedState};
handle_cast(_Request, State) ->
    {noreply, State}.

-doc(false).
-spec handle_info(term(), #edge_state{}) ->
    {noreply, #edge_state{}}.
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
