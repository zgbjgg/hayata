-module(hayata_node_sup).

-behaviour(supervisor).

-export([
    start_link/1,
    start_node/5,
    stop_node/2,
    init/1
]).

-type agent_id() :: term().
-type node_id() :: atom() | string().
-type node_state() :: map().

-doc("Starts a node supervisor for an agent.").
-spec start_link(agent_id()) -> supervisor:start_ret().
start_link(AgentId) ->
    supervisor:start_link(?MODULE, AgentId).

-doc("Starts a node process under the agent's node supervisor.").
-spec start_node(
    pid(),
    node_id(),
    node_state(),
    [term()],
    term()
) -> {ok, pid()} | {error, term()}.
start_node(SupPid, NodeId, InitialState, Edges, AgentId)
        when is_pid(SupPid),
             (is_atom(NodeId) orelse is_list(NodeId)),
             is_map(InitialState),
             is_list(Edges) ->
    ChildSpec = #{
        id => {hayata_node, NodeId},
        start => {
            hayata_node,
            start_link,
            [AgentId, NodeId, NodeId, InitialState, Edges]
        },
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [hayata_node]
    },
    supervisor:start_child(SupPid, ChildSpec).

-doc("Stops a node process managed by this supervisor.").
-spec stop_node(pid(), node_id()) -> ok | {error, term()}.
stop_node(SupPid, NodeId) when is_pid(SupPid) ->
    ChildId = {hayata_node, NodeId},
    case supervisor:terminate_child(SupPid, ChildId) of
        ok ->
            supervisor:delete_child(SupPid, ChildId);
        {error, Reason} ->
            {error, Reason}
    end.

-doc(false).
-spec init(agent_id()) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(_AgentId) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    {ok, {SupFlags, []}}.
