
-module(hayata_edge).
-behaviour(gen_server).

-export([
    start/4,
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
    edge_id,
    execution_id,
    task
}).

-type edge_id() :: term().
-type execution_id() :: term().
-type task_result() :: {ok, term()} | {error, term()}.
-type task_fun() :: fun(() -> task_result()).

-doc("Starts an anonymous, unlinked edge process.").
-spec start(pid(), edge_id(), execution_id(), task_fun()) ->
    gen_server:start_ret().
start(NodePid, EdgeId, ExecutionId, TaskFun)
        when is_pid(NodePid), is_function(TaskFun, 0) ->
    gen_server:start(
        ?MODULE,
        {NodePid, EdgeId, ExecutionId, TaskFun},
        []
    ).

-doc("Starts execution of an edge process.").
-spec execute(pid()) -> ok.
execute(EdgePid) ->
    gen_server:cast(EdgePid, start).

-doc(false).
-spec init({pid(), edge_id(), execution_id(), task_fun()}) ->
    {ok, #edge_state{}, {continue, execute}}.
init({NodePid, EdgeId, ExecutionId, TaskFun}) ->
    {ok, #edge_state{
        node_pid = NodePid,
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
    Result = try
        (State#edge_state.task)()
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

    State#edge_state.node_pid ! {
        hayata_edge_result,
        State#edge_state.edge_id,
        State#edge_state.execution_id,
        Message
    },

    {stop, StopReason, State};
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
