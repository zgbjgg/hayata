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
        last_edge_event => State#node_state.last_edge_event
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

handle_info(
    {hayata_edge_result, EdgeId, ExecutionId, Result},
    State
) ->
    ResultKey = {EdgeId, ExecutionId},
    EdgeResults = maps:put(
        ResultKey,
        Result,
        State#node_state.edge_results
    ),
    NewState = State#node_state{
        edge_results = EdgeResults
    },
    {noreply, NewState};
handle_info(
    {'DOWN', MonitorRef, process, EdgePid, Reason},
    State
) ->
    ActiveEdges = State#node_state.active_edges,
    case maps:take(MonitorRef, ActiveEdges) of
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
            {noreply, NewState};
        error ->
            {noreply, State}
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
