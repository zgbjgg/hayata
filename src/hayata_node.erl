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
    start_execution/4,
    start_execution/5,
    cancel_execution/2
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

-doc("Starts an asynchronous execution and notifies a recipient when it terminates.").
-spec start_execution(
    gen_server:server_ref(),
    term(),
    [edge_task()],
    non_neg_integer(),
    pid()
) -> {ok, term()} | {error, term()}.
start_execution(Node, ExecutionId, EdgeTasks, TimeoutMs, RecipientPid)
        when is_pid(RecipientPid) ->
    gen_server:call(
        Node,
        {start_execution, ExecutionId, EdgeTasks, TimeoutMs, RecipientPid}
    ).

-doc("Cancels an active execution and its associated processes.").
-spec cancel_execution(gen_server:server_ref(), term()) ->
    ok | {error, term()}.
cancel_execution(Node, ExecutionId) ->
    gen_server:call(Node, {cancel_execution, ExecutionId}).

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
    start_execution_request(
        ExecutionId,
        EdgeTasks,
        TimeoutMs,
        undefined,
        State
    );
handle_call({start_execution, ExecutionId, EdgeTasks, TimeoutMs, RecipientPid}, _From, State) when is_pid(RecipientPid) ->
    start_execution_request(
        ExecutionId,
        EdgeTasks,
        TimeoutMs,
        RecipientPid,
        State
    );
handle_call({cancel_execution, ExecutionId}, _From, State) ->
    case cancel_execution_internal(ExecutionId, State) of
        {ok, NewState} ->
            {reply, ok, NewState};
        {error, Reason, NewState} ->
            {reply, {error, Reason}, NewState}
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
    case maps:find(ExecutionId, State#node_state.executions) of
        {ok, Execution} ->
            case is_terminal_status(maps:get(status, Execution)) of
                true ->
                    {noreply, State};
                false ->
                    handle_active_edge_result(
                        EdgeId,
                        ExecutionId,
                        Result,
                        State
                    )
            end;
        error ->
            handle_active_edge_result(
                EdgeId,
                ExecutionId,
                Result,
                State
            )
    end;
handle_info({hayata_reducer_result, ReducerPid, ExecutionId, FinalResult}, State) ->
    case maps:find(ExecutionId, State#node_state.active_reducers) of
        {ok, #{pid := ReducerPid}} ->
            {noreply, complete_execution(
                ExecutionId,
                FinalResult,
                State
            )};

        _ ->
            {noreply, State}
    end;
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
terminate(_Reason, State) ->
    stop_active_processes(
        maps:values(State#node_state.active_edges)
    ),
    stop_active_processes(
        maps:values(State#node_state.active_reducers)
    ),
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
        errors => #{},
        started_at => erlang:monotonic_time()
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
    telemetry:execute(
        [hayata, node, execution, start],
        #{system_time => erlang:system_time()},
        #{
            agent_id => State#node_state.agent_id,
            node_id => State#node_state.node_id,
            execution_id => ExecutionId
        }
    ),

    case activate_execution_reducer(ReducerPid) of
        ok ->
            start_execution_edges(
                ExecutionId,
                EdgeTasks,
                ReducerPid,
                NewState

            );
        {error, Reason} ->
            Execution = maps:get(
                ExecutionId,
                NewState#node_state.executions
            ),
            FailedExecution = Execution#{
                status => {reducer_recovery_failed, {activation_failed, Reason}}
            },
            emit_execution_terminal(FailedExecution, State),
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
            case is_terminal_status(maps:get(status, Execution)) of
                true ->
                    State;
                false ->
                    update_execution_result(
                        Execution,
                        EdgeId,
                        Result,
                        State
                    )
            end;
        error ->
            State
    end.

-spec update_execution_result(map(), term(), term(), #node_state{}) ->
    #node_state{}.
update_execution_result(Execution, EdgeId, Result, State) ->
    Results = maps:get(results, Execution),
    Errors = maps:get(errors, Execution),
    case maps:is_key(EdgeId, Results) orelse maps:is_key(EdgeId, Errors) of
        true ->
            State;
        false ->
            update_new_execution_result(Execution, EdgeId, Result, State)
    end.

-spec update_new_execution_result(map(), term(), term(), #node_state{}) ->
    #node_state{}.
update_new_execution_result(Execution, EdgeId, {ok, _Value} = Result, State) ->
    Results = maps:put(EdgeId, Result, maps:get(results, Execution)),
    Errors = maps:remove(EdgeId, maps:get(errors, Execution)),
    save_execution(
        Execution#{results => Results, errors => Errors},
        State
    );
update_new_execution_result(Execution, EdgeId, {error, Reason}, State) ->
    Results = maps:remove(EdgeId, maps:get(results, Execution)),
    Errors = maps:put(EdgeId, Reason, maps:get(errors, Execution)),
    save_execution(
        Execution#{results => Results, errors => Errors},
        State
    );
update_new_execution_result(Execution, EdgeId, Result, State) ->
    update_new_execution_result(
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
            case is_terminal_status(maps:get(status, Execution)) of
                true ->
                    State;
                false ->
                    complete_execution_result(
                        ExecutionId,
                        Execution,
                        FinalResult,
                        State
                    )
            end;
        error ->
            State
    end.

-spec complete_execution_result(
    term(),
    map(),
    map(),
    #node_state{}
) -> #node_state{}.
complete_execution_result(ExecutionId, Execution, FinalResult, State) ->
    Results = maps:get(results, FinalResult, #{}),
    Errors = maps:get(errors, FinalResult, #{}),
    {FinalResults, FinalErrors} = case map_size(Results) of
        0 ->
            recover_execution_results(
                ExecutionId,
                State#node_state.edge_results,
                Results,
                Errors
            );
        _ ->
            {Results, Errors}
    end,
    UpdatedExecution = Execution#{
        status => maps:get(status, FinalResult),
        results => FinalResults,
        errors => FinalErrors,
        pending_edges => maps:get(pending_edges, FinalResult, [])
    },
    emit_execution_terminal(UpdatedExecution, State),
    NewState = save_execution(UpdatedExecution, State),
    notify_execution_recipient(
        ExecutionId,
        UpdatedExecution,
        NewState
    ),
    remove_active_reducer(ExecutionId, NewState).

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
    case maps:find(ExecutionId, State#node_state.executions) of
        {ok, Execution} ->
            case is_terminal_status(maps:get(status, Execution)) of
                true ->
                    State;
                false ->
                    start_recovered_execution_reducer(
                        ExecutionId,
                        Execution,
                        Reason,
                        State
                    )
            end;
        error ->
            State
    end.

-spec start_recovered_execution_reducer(
    term(),
    map(),
    term(),
    #node_state{}
) -> #node_state{}.
start_recovered_execution_reducer(ExecutionId, Execution, Reason, State) ->
    ActiveReducers = maps:remove(
        ExecutionId,
        State#node_state.active_reducers
    ),
    BaseState = State#node_state{
        active_reducers = ActiveReducers
    },
    Deadline = maps:get(deadline, Execution),
    RemainingMs = max(
        0,
        Deadline - erlang:monotonic_time(millisecond)
    ),
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
            case is_terminal_status(maps:get(status, Execution)) of
                true ->
                    State;
                false ->
                    UpdatedExecution = Execution#{
                        status => {reducer_recovery_failed, Reason}
                    },
                    emit_execution_terminal(UpdatedExecution, State),
                    NewState = save_execution(UpdatedExecution, State),
                    notify_execution_recipient(
                        ExecutionId,
                        UpdatedExecution,
                        NewState
                    ),
                    NewState
            end;
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

-spec recover_execution_results(term(), map(), map(), map()) ->
    {map(), map()}.
recover_execution_results(ExecutionId, EdgeResults, Results, Errors) ->
    ExecutionEdgeResults = maps:fold(
        fun
            ({EdgeId, ResultExecutionId}, Result, Acc)
                    when ResultExecutionId =:= ExecutionId ->
                maps:put(EdgeId, Result, Acc);
            (_Key, _Result, Acc) ->
                Acc
        end,
        #{},
        EdgeResults
    ),
    maps:fold(
        fun
            (EdgeId, {ok, _Value} = Result, {RecoveredResults, RecoveredErrors}) ->
                {
                    maps:put(EdgeId, Result, RecoveredResults),
                    maps:remove(EdgeId, RecoveredErrors)
                };
            (EdgeId, {error, Reason}, {RecoveredResults, RecoveredErrors}) ->
                {
                    maps:remove(EdgeId, RecoveredResults),
                    maps:put(EdgeId, Reason, RecoveredErrors)
                };
            (EdgeId, Result, Acc) ->
                recover_invalid_edge_result(EdgeId, Result, Acc)
        end,
        {Results, Errors},
        ExecutionEdgeResults
    ).

-spec recover_invalid_edge_result(term(), term(), {map(), map()}) ->
    {map(), map()}.
recover_invalid_edge_result(EdgeId, Result, {Results, Errors}) ->
    {
        maps:remove(EdgeId, Results),
        maps:put(EdgeId, {invalid_edge_result, Result}, Errors)
    }.

-spec is_terminal_status(term()) -> boolean().
is_terminal_status(completed) ->
    true;
is_terminal_status(timed_out) ->
    true;
is_terminal_status({reducer_recovery_failed, _Reason}) ->
    true;
is_terminal_status(cancelled) ->
    true;
is_terminal_status(_Status) ->
    false.

-spec handle_active_edge_result(
    term(),
    term(),
    term(),
    #node_state{}
) -> {noreply, #node_state{}}.
handle_active_edge_result(EdgeId, ExecutionId, Result, State) ->
    ResultKey = {EdgeId, ExecutionId},
    EdgeResults = case maps:is_key(
        ResultKey,
        State#node_state.edge_results
    ) of
        true ->
            State#node_state.edge_results;
        false ->
            maps:put(
                ResultKey,
                Result,
                State#node_state.edge_results
            )
    end,
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
    )}.

-spec start_execution_request(
    term(),
    [edge_task()],
    non_neg_integer(),
    pid() | undefined,
    #node_state{}
) -> {reply, term(), #node_state{}}.
start_execution_request(
    ExecutionId,
    EdgeTasks,
    TimeoutMs,
    RecipientPid,
    State
) ->
    case validate_execution(ExecutionId, EdgeTasks, TimeoutMs) of
        ok ->
            case maps:is_key(
                ExecutionId,
                State#node_state.executions
            ) of
                true ->
                    {reply, {error, execution_already_exists}, State};
                false ->
                    start_execution_with_recipient(
                        ExecutionId,
                        EdgeTasks,
                        TimeoutMs,
                        RecipientPid,
                        State
                    )
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

-spec start_execution_with_recipient(
    term(),
    [edge_task()],
    non_neg_integer(),
    pid() | undefined,
    #node_state{}
) -> {reply, term(), #node_state{}}.
start_execution_with_recipient(
    ExecutionId,
    EdgeTasks,
    TimeoutMs,
    RecipientPid,
    State
) ->
    case start_execution_processes(
        ExecutionId,
        EdgeTasks,
        TimeoutMs,
        State
    ) of
        {reply, {ok, ExecutionId}, NewState} ->
            Execution = maps:get(
                ExecutionId,
                NewState#node_state.executions
            ),
            UpdatedExecution = Execution#{
                notify_to => RecipientPid
            },
            Executions = maps:put(
                ExecutionId,
                UpdatedExecution,
                NewState#node_state.executions
            ),
            {reply, {ok, ExecutionId},
             NewState#node_state{executions = Executions}};
        {reply, Error, NewState} ->
            {reply, Error, NewState}
    end.

-spec notify_execution_recipient(
    term(),
    map(),
    #node_state{}
) -> ok.
notify_execution_recipient(ExecutionId, Execution, State) ->
    case maps:get(notify_to, Execution, undefined) of
        RecipientPid when is_pid(RecipientPid) ->
            RecipientPid ! {
                hayata_node_execution,
                State#node_state.node_id,
                ExecutionId,
                Execution
            },
            ok;
        undefined ->
            ok
    end.

-spec stop_active_processes([map()]) -> ok.
stop_active_processes([]) ->
    ok;
stop_active_processes([#{pid := Pid} | Rest]) ->
    exit(Pid, shutdown),
    stop_active_processes(Rest);
stop_active_processes([_Process | Rest]) ->
    stop_active_processes(Rest).

-spec cancel_execution_internal(term(), #node_state{}) ->
    {ok, #node_state{}} | {error, term(), #node_state{}}.
cancel_execution_internal(ExecutionId, State) ->
    case maps:find(ExecutionId, State#node_state.executions) of
        {ok, Execution} ->
            case is_terminal_status(maps:get(status, Execution)) of
                true ->
                    {error, execution_not_active, State};
                false ->
                    cancel_active_execution(ExecutionId, Execution, State)
            end;
        error ->
            {error, execution_not_found, State}
    end.

-spec cancel_active_execution(term(), map(), #node_state{}) ->
    {ok, #node_state{}}.
cancel_active_execution(ExecutionId, Execution, State) ->
    UpdatedExecution = Execution#{status => cancelled},
    Executions = maps:put(
        ExecutionId,
        UpdatedExecution,
        State#node_state.executions
    ),
    CancelledState = State#node_state{executions = Executions},
    ReducerState = cancel_execution_reducer(
        ExecutionId,
        CancelledState
    ),
    EdgeState = cancel_execution_edges(
        ExecutionId,
        ReducerState
    ),
    emit_execution_terminal(UpdatedExecution, State),
    notify_execution_recipient(
        ExecutionId,
        UpdatedExecution,
        EdgeState
    ),
    {ok, EdgeState}.

-spec cancel_execution_reducer(term(), #node_state{}) -> #node_state{}.
cancel_execution_reducer(ExecutionId, State) ->
    case maps:take(ExecutionId, State#node_state.active_reducers) of
        {#{pid := Pid, monitor_ref := MonitorRef}, ActiveReducers} ->
            erlang:demonitor(MonitorRef, [flush]),
            stop_process(Pid),
            State#node_state{active_reducers = ActiveReducers};
        error ->
            State
    end.


-spec cancel_execution_edges(term(), #node_state{}) -> #node_state{}.
cancel_execution_edges(ExecutionId, State) ->
    {CancelledEdges, RemainingEdges} = maps:fold(
        fun(MonitorRef, Edge, {Cancelled, Remaining}) ->
            case maps:get(execution_id, Edge) of
                ExecutionId ->
                    { [{MonitorRef, Edge} | Cancelled], Remaining };
                _OtherExecutionId ->
                    { Cancelled, maps:put(MonitorRef, Edge, Remaining) }
            end
        end,
        {[], #{}},
        State#node_state.active_edges
    ),
    stop_execution_edges(CancelledEdges),
    State#node_state{active_edges = RemainingEdges}.


-spec stop_execution_edges([{reference(), map()}]) -> ok.
stop_execution_edges([]) ->
    ok;
stop_execution_edges([{MonitorRef, #{pid := Pid}} | Rest]) ->
    erlang:demonitor(MonitorRef, [flush]),
    stop_process(Pid),
    stop_execution_edges(Rest).


-spec stop_process(pid()) -> ok.
stop_process(Pid) ->
    case is_process_alive(Pid) of
        true ->
            MonitorRef = erlang:monitor(process, Pid),
            exit(Pid, kill),
            receive
                {'DOWN', MonitorRef, process, Pid, _Reason} ->
                    ok
            after 5000 ->
                erlang:demonitor(MonitorRef, [flush]),
                ok
            end;
        false ->
            ok
    end.

-spec emit_execution_terminal(map(), #node_state{}) -> ok.
emit_execution_terminal(Execution, State) ->
    Status = maps:get(status, Execution),
    StartedAt = maps:get(started_at, Execution),
    Duration = erlang:monotonic_time() - StartedAt,
    Measurements = #{duration => Duration},
    Metadata = #{
        agent_id => State#node_state.agent_id,
        node_id => State#node_state.node_id,
        execution_id => maps:get(execution_id, Execution),
        status => Status
    },
    emit_execution_terminal_event(Status, Measurements, Metadata).

-spec emit_execution_terminal_event(
    term(),
    map(),
    map()
) -> ok.
emit_execution_terminal_event({reducer_recovery_failed, _Reason},Measurements, Metadata) ->
    telemetry:execute(
        [hayata, node, execution, exception],
        Measurements,
        Metadata
    );
emit_execution_terminal_event(_Status, Measurements, Metadata) ->
    telemetry:execute(
        [hayata, node, execution, stop],
        Measurements,
        Metadata
    ).
