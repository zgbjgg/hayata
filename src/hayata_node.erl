
-module(hayata_node).

-behaviour(gen_server).

-export([
    start_link/5,
    whereis/2,
    get_info/1,
    get_state/1,
    replace_state/2,
    update_state/2,
    set_edges/2
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
    edges = []
}).

-type agent_id() :: term().
-type node_id() :: term().
-type node_name() :: atom() | string().
-type local_state() :: map().
-type edge_definitions() :: [term()].

-export_type([
    agent_id/0,
    node_id/0,
    node_name/0,
    local_state/0,
    edge_definitions/0
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

-doc("Returns the node identity, local state, and outgoing edges.").
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
        edges => State#node_state.edges
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
