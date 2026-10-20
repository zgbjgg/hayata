-module(hayata_node).

-behaviour(gen_server).

-export([
    start_link/5,
    whereis/2,
    get_info/1,
    get_state/1,
    replace_state/2,
    update_state/2,
    set_edges/2,
    track_edge/3,
    start_edge/4,
    start_execution/4
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(node_state, {
    agent_id,
    node_id,
    name,
    local_state = #{},
    edges = [],
    active_edges = #{},
    edge_results = #{},
    last_edge_event = undefined,
    executions = #{},
    active_reducers = #{}
}).

-type agent_id() :: term().
-type node_id() :: term().
-type node_name() :: atom() | string().
-type local_state() :: map().
-type edge_definitions() :: [term()].
-type edge_id() :: term().
-type edge_task() :: {edge_id(), fun(() -> term())}.

-export_type([
    agent_id/0,
    node_id/0,
    node_name/0,
    local_state/0,
    edge_definitions/0,
    edge_id/0
]).

%% Public API

-doc("Starts a globally registered node within an agent namespace.").
-spec start_link(
    agent_id(),
    node_id(),
    node_name(),
    local_state(),
    edge_definitions()
) -> gen_server:start_ret().
start_link(AgentId, NodeId, Name, InitialState, Edges)
        when is_map(InitialState), is_list(Edges) ->
    RegisteredName = registered_name(AgentId, Name),
    gen_server:start_link(
        {global, RegisteredName},
        ?MODULE,
        {AgentId, NodeId, Name, InitialState, Edges},
        []
    ).

-doc("Finds a node by agent ID and registered name.").
-spec whereis(agent_id(), node_name()) -> pid() | undefined.
whereis(AgentId, Name) ->
    global:whereis_name(registered_name(AgentId, Name)).

-doc("Returns node metadata and active edge processes.").
-spec get_info(gen_server:server_ref()) -> map().
get_info(Server) ->
    gen_server:call(Server, get_info).

-doc("Returns the node's local state.").
-spec get_state(gen_server:server_ref()) -> local_state().
get_state(Server) ->
    gen_server:call(Server, get_state).

-doc("Replaces the node's complete local state.").
-spec replace_state(gen_server:server_ref(), local_state()) -> ok.
replace_state(Server, NewState) when is_map(NewState) ->
    gen_server:call(Server, {replace_state, NewState}).

-doc("Merges updates into the node's local state.").
-spec update_state(gen_server:server_ref(), local_state()) -> ok.
update_state(Server, Updates) when is_map(Updates) ->
    gen_server:call(Server, {update_state, Updates}).

-doc("Replaces the node's outgoing edge definitions.").
-spec set_edges(gen_server:server_ref(), edge_definitions()) -> ok.
set_edges(Server, Edges) when is_list(Edges) ->
    gen_server:call(Server, {set_edges, Edges}).

-doc("Registers and monitors an active edge process.").
-spec track_edge(gen_server:server_ref(), edge_id(), pid()) ->
    {ok, reference()} | {error, term()}.
track_edge(Server, EdgeId, EdgePid) when is_pid(EdgePid) ->
    gen_server:call(Server, {track_edge, EdgeId, EdgePid}).

-doc("Starts, monitors, registers, and asynchronously executes an edge.").
-spec start_edge(
    gen_server:server_ref(),
    edge_id(),
    term(),
    fun(() -> term())
) -> {ok, pid()} | {error, term()}.
start_edge(Node, EdgeId, ExecutionId, TaskFun) ->
    gen_server:call(
        Node,
        {start_edge, EdgeId, ExecutionId, TaskFun}
    ).

-doc("Starts an asynchronous execution across multiple edges.").
-spec start_execution(
    gen_server:server_ref(),
    term(),
    [edge_task()],
    non_neg_integer()
) -> {ok, term()} | {error, term()}.
start_execution(Node, ExecutionId, EdgeTasks, TimeoutMs) ->
    gen_server:call(
        Node,
        {start_execution, ExecutionId, EdgeTasks, TimeoutMs}
    ).

%% gen_server callbacks

-doc(false).
-spec init({
    agent_id(),
    node_id(),
    node_name(),
    local_state(),
    edge_definitions()
}) -> {ok, #node_state{}}.
init({AgentId, NodeId, Name, InitialState, Edges}) ->
    {ok, #node_state{
        agent_id = AgentId,
        node_id = NodeId,
        name = Name,
        local_state = InitialState,
        edges = Edges
    }}.

-doc(false).
-spec handle_call(term(), gen_server:from(), #node_state{}) ->
    {reply, term(), #node_state{}}.
handle_call(get_info, _From, State) ->
    Info = #{
        agent_id => State#node_state.agent_id,
        node_id => State#node_state.node_id,
        name => State#node_state.name,
        local_state => State#node_state.local_state,
        edges => State#node_state.edges,
        active_edges => State#node_state.active_edges,
        edge_results => State#node_state.edge_results,
        last_edge_event => State#node_state.last_edge_event,
        executions => State#node_state.executions,
        active_reducers => State#node_state.active_reducers
    },
    {reply, Info, State};
handle_call(get_state, _From, State) ->
    {reply, State#node_state.local_state, State};
handle_call({replace_state, NewState}, _From, State) ->
    NewNodeState = State#node_state{local_state = NewState},
    {reply, ok, NewNodeState};
handle_call({update_state, Updates}, _From, State) ->
    CurrentState = State#node_state.local_state,
    NewState = maps:merge(CurrentState, Updates),
    NewNodeState = State#node_state{local_state = NewState},
    {reply, ok, NewNodeState};
handle_call({set_edges, Edges}, _From, State) ->
    NewNodeState = State#node_state{edges = Edges},
    {reply, ok, NewNodeState};
handle_call({track_edge, EdgeId, EdgePid}, _From, State) ->
    MonitorRef = erlang:monitor(process, EdgePid),
    Edge = #{
        edge_id => EdgeId,
        execution_id => undefined,
        pid => EdgePid
    },
    ActiveEdges = maps:put(
        MonitorRef,
        Edge,
        State#node_state.active_edges
    ),
    NewNodeState = State#node_state{active_edges = ActiveEdges},
    {reply, {ok, MonitorRef}, NewNodeState};
handle_call({start_edge, EdgeId, ExecutionId, TaskFun}, _From, State) ->
    case hayata_edge:start(
        self(),
        EdgeId,
        ExecutionId,
        TaskFun
    ) of
        {ok, EdgePid} ->
            MonitorRef = erlang:monitor(process, EdgePid),
            Edge = #{
                edge_id => EdgeId,
                execution_id => ExecutionId,
                pid => EdgePid
            },
            ActiveEdges = maps:put(
                MonitorRef,
                Edge,
                State#node_state.active_edges
            ),
            NewState = State#node_state{
                active_edges = ActiveEdges
            },
            ok = hayata_edge:execute(EdgePid),
            {reply, {ok, EdgePid}, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call({start_execution, ExecutionId, EdgeTasks, TimeoutMs}, _From, State) ->
    case validate_execution(ExecutionId, EdgeTasks, TimeoutMs) of
        ok ->
            case maps:is_key(
                ExecutionId,
                State#node_state.executions
            ) of
                true ->
                    {reply, {error, execution_already_exists}, State};

                false ->
                    start_execution_processes(
                        ExecutionId,
                        EdgeTasks,
                        TimeoutMs,
                        State
                    )
            end;

        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

-doc(false).
-spec handle_cast(term(), #node_state{}) ->
    {noreply, #node_state{}}.
handle_cast(_Request, State) ->
    {noreply, State}.

-doc(false).
-spec handle_info(term(), #node_state{}) ->
    {noreply, #node_state{}}.
handle_info({hayata_edge_result, EdgeId, ExecutionId, Result}, State) ->
    ResultKey = {EdgeId, ExecutionId},
    EdgeResults = maps:put(
        ResultKey,
        Result,
        State#node_state.edge_results
    ),
    NewState = update_execution_edge_result(
        ExecutionId,
        EdgeId,
        Result,
        State#node_state{edge_results = EdgeResults}
    ),
    {noreply, forward_recovered_edge_result(
        ExecutionId,
        EdgeId,
        Result,
        NewState
    )};
handle_info({hayata_reducer_result, ExecutionId, FinalResult}, State) ->
    {noreply, complete_execution(ExecutionId, FinalResult, State)};
handle_info({'DOWN', MonitorRef, process, EdgePid, Reason}, State) ->
    case maps:take(MonitorRef, State#node_state.active_edges) of
        {#{pid := EdgePid, edge_id := EdgeId,
           execution_id := ExecutionId}, RemainingEdges} ->
            Event = #{
                edge_id => EdgeId,
                execution_id => ExecutionId,
                pid => EdgePid,
                reason => Reason
            },
            NewState = State#node_state{
                active_edges = RemainingEdges,
                last_edge_event = Event
            },
            notify_reducer_edge_down(
                EdgeId,
                ExecutionId,
                Reason,
                NewState
            );

        error ->
            {noreply, handle_reducer_down(MonitorRef, Reason, State)}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

-doc(false).
-spec terminate(term(), #node_state{}) -> ok.
terminate(_Reason, _State) ->
    ok.

-doc(false).
-spec code_change(term(), #node_state{}, term()) ->
    {ok, #node_state{}}.
code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% Internal functions

-spec registered_name(agent_id(), node_name()) -> tuple().
registered_name(AgentId, Name) ->
    {hayata_node, AgentId, Name}.

-spec validate_execution(term(), term(), term()) ->
    ok | {error, term()}.
validate_execution(_ExecutionId, EdgeTasks, _TimeoutMs)
        when not is_list(EdgeTasks) ->
    {error, invalid_edge_tasks};
validate_execution(_ExecutionId, _EdgeTasks, TimeoutMs)
        when not is_integer(TimeoutMs); TimeoutMs < 0 ->
    {error, invalid_timeout};
validate_execution(_ExecutionId, EdgeTasks, _TimeoutMs) ->
    case validate_edge_tasks(EdgeTasks, [], []) of
        {ok, _EdgeIds} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

-spec validate_edge_tasks([term()], [term()], [term()]) ->
    {ok, [term()]} | {error, term()}.
validate_edge_tasks([], _Seen, EdgeIds) ->
    {ok, lists:reverse(EdgeIds)};
validate_edge_tasks([{EdgeId, TaskFun} | Rest], Seen, EdgeIds)
        when is_function(TaskFun, 0) ->
    case lists:member(EdgeId, Seen) of
        true ->
            {error, duplicate_edge_id};
        false ->
            validate_edge_tasks(
                Rest,
                [EdgeId | Seen],
                [EdgeId | EdgeIds]
            )
    end;
validate_edge_tasks(_EdgeTasks, _Seen, _EdgeIds) ->
    {error, invalid_edge_task}.

-spec edge_ids([{term(), fun(() -> term())}]) -> [term()].
edge_ids(EdgeTasks) ->
    [EdgeId || {EdgeId, _TaskFun} <- EdgeTasks].

-spec start_execution_processes(
    term(),
    [edge_task()],
    non_neg_integer(),
    #node_state{}
) -> {reply, {ok, term()} | {error, term()}, #node_state{}}.
start_execution_processes(ExecutionId, EdgeTasks, TimeoutMs, State) ->
    EdgeIds = edge_ids(EdgeTasks),
    Config = #{
        node_pid => self(),
        execution_id => ExecutionId,
        expected_edges => EdgeIds,
        timeout_ms => TimeoutMs
    },

    case hayata_reducer:start(Config) of
        {ok, ReducerPid} ->
            start_execution_reducer(
                ExecutionId,
                EdgeTasks,
                TimeoutMs,
                ReducerPid,
                State
            );

        {error, Reason} ->
            {reply, {error, {reducer_start_failed, Reason}}, State}
    end.

-spec start_execution_reducer(
    term(),
    [edge_task()],
    non_neg_integer(),
    pid(),
    #node_state{}
) -> {reply, {ok, term()} | {error, term()}, #node_state{}}.
start_execution_reducer(
    ExecutionId,
    EdgeTasks,
    TimeoutMs,
    ReducerPid,
    State
) ->
    MonitorRef = erlang:monitor(process, ReducerPid),
    Reducer = #{
        pid => ReducerPid,
        monitor_ref => MonitorRef
    },
    ActiveReducers = maps:put(
        ExecutionId,
        Reducer,
        State#node_state.active_reducers
    ),
    Execution = #{
        execution_id => ExecutionId,
        status => starting,
        edge_ids => edge_ids(EdgeTasks),
        timeout_ms => TimeoutMs,
        deadline => erlang:monotonic_time(millisecond) + TimeoutMs,
        results => #{},
        errors => #{}
    },
    Executions = maps:put(
        ExecutionId,
        Execution,
        State#node_state.executions
    ),
    NewState = State#node_state{
        active_reducers = ActiveReducers,
        executions = Executions
    },

    case activate_execution_reducer(ReducerPid) of
        ok ->
            start_execution_edges(
                ExecutionId,
                EdgeTasks,
                ReducerPid,
                NewState

            );
        {error, Reason} ->
            erlang:demonitor(MonitorRef, [flush]),
            {reply, {error, {reducer_activation_failed, Reason}}, State}
    end.

-spec activate_execution_reducer(pid()) -> ok | {error, term()}.
activate_execution_reducer(ReducerPid) ->
    try hayata_reducer:activate(ReducerPid) of
        ok ->
            ok;
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, {unexpected_activation_result, Other}}
    catch
        exit:Reason ->
            {error, {reducer_activation_exit, Reason}}
    end.

-spec start_execution_edges(
    term(),
    [edge_task()],
    pid(),
    #node_state{}
) -> {reply, {ok, term()}, #node_state{}}.
start_execution_edges(ExecutionId, EdgeTasks, ReducerPid, State) ->
    {NewState, _Started, _Failed} = lists:foldl(
        fun(Task, Acc) ->
            start_execution_edge(Task, ExecutionId, ReducerPid, Acc)
        end,
        {State, [], []},
        EdgeTasks
    ),
    Execution = maps:get(ExecutionId, NewState#node_state.executions),
    UpdatedExecution = Execution#{status => running},
    Executions = maps:put(
        ExecutionId,
        UpdatedExecution,
        NewState#node_state.executions
    ),
    FinalState = NewState#node_state{executions = Executions},
    {reply, {ok, ExecutionId}, FinalState}.

-spec start_execution_edge(
    edge_task(),
    term(),
    pid(),
    {#node_state{}, [term()], [term()]}
) -> {#node_state{}, [term()], [term()]}.
start_execution_edge(
    {EdgeId, TaskFun},
    ExecutionId,
    ReducerPid,
    {State, Started, Failed}
) ->
    case hayata_edge:start(
        self(),
        ReducerPid,
        EdgeId,
        ExecutionId,
        TaskFun
    ) of
        {ok, EdgePid} ->
            MonitorRef = erlang:monitor(process, EdgePid),
            Edge = #{
                edge_id => EdgeId,
                execution_id => ExecutionId,
                pid => EdgePid
            },
            ActiveEdges = maps:put(
                MonitorRef,
                Edge,
                State#node_state.active_edges
            ),
            NewState = State#node_state{
                active_edges = ActiveEdges
            },
            ok = hayata_edge:execute(EdgePid),
            {NewState, [EdgeId | Started], Failed};

        {error, Reason} ->
            ReducerPid ! {
                hayata_reducer_edge_down,
                EdgeId,
                ExecutionId,
                {edge_start_failed, Reason}
            },
            {record_execution_error(
                ExecutionId,
                EdgeId,
                {edge_start_failed, Reason},
                State
            ), Started, [EdgeId | Failed]}
    end.

-spec record_execution_error(term(), term(), term(), #node_state{}) ->
    #node_state{}.
record_execution_error(ExecutionId, EdgeId, Reason, State) ->
    Execution = maps:get(ExecutionId, State#node_state.executions),
    Errors = maps:put(EdgeId, Reason, maps:get(errors, Execution)),
    UpdatedExecution = Execution#{errors => Errors},
    Executions = maps:put(
        ExecutionId,
        UpdatedExecution,
        State#node_state.executions
    ),
    State#node_state{executions = Executions}.

-spec update_execution_edge_result(
    term(),
    term(),
    term(),
    #node_state{}
) -> #node_state{}.
update_execution_edge_result(ExecutionId, EdgeId, Result, State) ->
    case maps:find(ExecutionId, State#node_state.executions) of
        {ok, Execution} ->
            update_execution_result(Execution, EdgeId, Result, State);
        error ->
            State
    end.

-spec update_execution_result(
    map(),
    term(),
    term(),
    #node_state{}
) -> #node_state{}.
update_execution_result(Execution, EdgeId, {ok, _Value} = Result, State) ->
    Results = maps:put(EdgeId, Result, maps:get(results, Execution)),
    Errors = maps:remove(EdgeId, maps:get(errors, Execution)),
    save_execution(
        Execution#{results => Results, errors => Errors},
        State
    );
update_execution_result(Execution, EdgeId, {error, Reason}, State) ->
    Results = maps:remove(EdgeId, maps:get(results, Execution)),
    Errors = maps:put(EdgeId, Reason, maps:get(errors, Execution)),
    save_execution(
        Execution#{results => Results, errors => Errors},
        State
    );
update_execution_result(Execution, EdgeId, Result, State) ->
    update_execution_result(
        Execution,
        EdgeId,
        {error, {invalid_edge_result, Result}},
        State
    ).

-spec save_execution(map(), #node_state{}) -> #node_state{}.
save_execution(Execution, State) ->
    ExecutionId = maps:get(execution_id, Execution),
    Executions = maps:put(
        ExecutionId,
        Execution,
        State#node_state.executions
    ),
    State#node_state{executions = Executions}.

-spec complete_execution(term(), map(), #node_state{}) -> #node_state{}.
complete_execution(ExecutionId, FinalResult, State) ->
    case maps:find(ExecutionId, State#node_state.executions) of
        {ok, Execution} ->
            UpdatedExecution = Execution#{
                status => maps:get(status, FinalResult),
                results => maps:get(results, FinalResult),
                errors => maps:get(errors, FinalResult),
                pending_edges => maps:get(pending_edges, FinalResult)
            },
            NewState = save_execution(UpdatedExecution, State),
            remove_active_reducer(ExecutionId, NewState);
        error ->
            State
    end.

-spec remove_active_reducer(term(), #node_state{}) -> #node_state{}.
remove_active_reducer(ExecutionId, State) ->
    case maps:take(ExecutionId, State#node_state.active_reducers) of
        {#{monitor_ref := MonitorRef}, ActiveReducers} ->
            erlang:demonitor(MonitorRef, [flush]),
            State#node_state{active_reducers = ActiveReducers};
        error ->
            State
    end.


-spec handle_reducer_down(reference(), term(), #node_state{}) ->
    #node_state{}.
handle_reducer_down(MonitorRef, Reason, State) ->
    case find_reducer_execution(
        MonitorRef,
        maps:to_list(State#node_state.active_reducers)
    ) of
        {ok, ExecutionId} ->
            case maps:find(ExecutionId, State#node_state.active_reducers) of
                {ok, #{recovered := true}} ->
                    mark_reducer_recovery_failed(
                        ExecutionId,
                        {repeated_reducer_failure, Reason},
                        State#node_state{
                            active_reducers = maps:remove(
                                ExecutionId,
                                State#node_state.active_reducers
                            )
                        }
                    );

                {ok, _Reducer} ->
                    recover_execution_reducer(ExecutionId, Reason, State);

                error ->
                    State
            end;

        error ->
            State
    end.

-spec find_reducer_execution(
    reference(),
    [{term(), map()}]
) -> {ok, term()} | error.
find_reducer_execution(_MonitorRef, []) ->
    error;
find_reducer_execution(MonitorRef, [{ExecutionId, Reducer} | Rest]) ->
    case maps:get(monitor_ref, Reducer) of
        MonitorRef ->
            {ok, ExecutionId};
        _ ->
            find_reducer_execution(MonitorRef, Rest)
    end.


-spec recover_execution_reducer(term(), term(), #node_state{}) ->
    #node_state{}.
recover_execution_reducer(ExecutionId, Reason, State) ->
    Execution = maps:get(
        ExecutionId,
        State#node_state.executions
    ),
    ActiveReducers = maps:remove(
        ExecutionId,
        State#node_state.active_reducers
    ),
    BaseState = State#node_state{
        active_reducers = ActiveReducers
    },
    Deadline = maps:get(deadline, Execution),
    RemainingMs = max(0, Deadline - erlang:monotonic_time(millisecond)),
    Config = #{
        node_pid => self(),
        execution_id => ExecutionId,
        expected_edges => maps:get(edge_ids, Execution),
        timeout_ms => RemainingMs,
        results => maps:get(results, Execution),
        errors => maps:get(errors, Execution)
    },
    case hayata_reducer:start(Config) of
        {ok, ReducerPid} ->
            activate_recovered_reducer(
                ExecutionId,
                ReducerPid,
                BaseState
            );

        {error, StartReason} ->
            mark_reducer_recovery_failed(
                ExecutionId,
                {start_failed, Reason, StartReason},
                BaseState
            )
    end.

-spec activate_recovered_reducer(term(), pid(), #node_state{}) ->
    #node_state{}.
activate_recovered_reducer(ExecutionId, ReducerPid, State) ->
    MonitorRef = erlang:monitor(process, ReducerPid),
    case activate_execution_reducer(ReducerPid) of
        ok ->
            Reducer = #{
                pid => ReducerPid,
                monitor_ref => MonitorRef,
                recovered => true
            },
            ActiveReducers = maps:put(
                ExecutionId,
                Reducer,
                State#node_state.active_reducers
            ),
            Execution = maps:get(
                ExecutionId,
                State#node_state.executions
            ),
            UpdatedExecution = Execution#{status => recovering},
            Executions = maps:put(
                ExecutionId,
                UpdatedExecution,
                State#node_state.executions
            ),
            State#node_state{
                active_reducers = ActiveReducers,
                executions = Executions
            };

        {error, ActivationReason} ->
            erlang:demonitor(MonitorRef, [flush]),
            exit(ReducerPid, shutdown),
            mark_reducer_recovery_failed(
                ExecutionId,
                {activation_failed, ActivationReason},
                State
            )
    end.

-spec mark_reducer_recovery_failed(term(), term(), #node_state{}) ->
    #node_state{}.
mark_reducer_recovery_failed(ExecutionId, Reason, State) ->
    case maps:find(ExecutionId, State#node_state.executions) of
        {ok, Execution} ->
            UpdatedExecution = Execution#{
                status => {reducer_recovery_failed, Reason}
            },
            save_execution(UpdatedExecution, State);
        error ->
            State
    end.


-spec forward_recovered_edge_result(
    term(),
    term(),
    term(),
    #node_state{}
) -> #node_state{}.
forward_recovered_edge_result(ExecutionId, EdgeId, Result, State) ->
    case maps:find(ExecutionId, State#node_state.active_reducers) of
        {ok, #{pid := ReducerPid, recovered := true}} ->
            ReducerPid ! {
                hayata_reducer_edge_result,
                EdgeId,
                ExecutionId,
                Result
            },
            State;
        _ ->
            State
    end.


-spec notify_reducer_edge_down(
    term(),
    term(),
    term(),
    #node_state{}
) -> {noreply, #node_state{}}.
notify_reducer_edge_down(_EdgeId, undefined, _Reason, State) ->
    {noreply, State};
notify_reducer_edge_down(EdgeId, ExecutionId, Reason, State) ->
    case maps:find(ExecutionId, State#node_state.active_reducers) of
        {ok, #{pid := ReducerPid}} ->
            ReducerPid ! {
                hayata_reducer_edge_down,
                EdgeId,
                ExecutionId,
                Reason
            },
            {noreply, State};
        error ->
            {noreply, State}
    end.
