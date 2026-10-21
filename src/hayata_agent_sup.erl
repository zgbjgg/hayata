
%%%-------------------------------------------------------------------
%% @doc Supervises the infrastructure belonging to one Hayata agent.
%% @end
%%%-------------------------------------------------------------------

-module(hayata_agent_sup).

-behaviour(supervisor).

-export([
    start_link/1,
    init/1,
    node_supervisor/1
]).

-type config() :: #{
    id := term(),
    nodes := #{term() => function()}
}.

-doc("Starts the supervision tree for one agent.").
-spec start_link(config()) -> supervisor:startchild_ret().
start_link(Config) ->
    case validate_config(Config) of
        ok ->
            case supervisor:start_link(?MODULE, Config) of
                {ok, SupPid} ->
                    case start_nodes(SupPid, Config) of
                        ok ->
                            {ok, SupPid};
                        {error, Reason} ->
                            exit(SupPid, shutdown),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-doc("Returns the PID of the agent's node supervisor.").
-spec node_supervisor(pid()) -> {ok, pid()} | {error, term()}.
node_supervisor(SupPid) ->
    case lists:keyfind(
        hayata_node_sup,
        1,
        supervisor:which_children(SupPid)
    ) of
        {hayata_node_sup, NodeSupPid, supervisor, _Modules}
                when is_pid(NodeSupPid) ->
            {ok, NodeSupPid};
        _ ->
            {error, node_supervisor_not_found}
    end.

-doc(false).
-spec init(config()) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(Config) ->
    AgentId = maps:get(id, Config),
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    ChildSpecs = [
        #{
            id => hayata_node_sup,
            start => {hayata_node_sup, start_link, [AgentId]},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [hayata_node_sup]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.

-spec validate_config(term()) -> ok | {error, term()}.
validate_config(Config) when is_map(Config) ->
    case {maps:find(id, Config), maps:find(nodes, Config)} of
        {{ok, AgentId}, {ok, Nodes}}
                when is_map(Nodes), map_size(Nodes) > 0 ->
            validate_nodes(AgentId, maps:to_list(Nodes));
        {{ok, _AgentId}, {ok, Nodes}} when is_map(Nodes) ->
            {error, empty_node_catalog};
        _ ->
            {error, invalid_config}
    end;
validate_config(_Config) ->
    {error, invalid_config}.

-spec validate_nodes(term(), [{term(), term()}]) ->
    ok | {error, term()}.
validate_nodes(_AgentId, []) ->
    ok;
validate_nodes(AgentId, [{NodeId, NodeFun} | Rest])
        when (is_atom(NodeId) orelse is_list(NodeId)),
             is_function(NodeFun, 1) ->
    case hayata_node:whereis(AgentId, NodeId) of
        undefined ->
            validate_nodes(AgentId, Rest);
        _Pid ->
            {error, {node_already_registered, NodeId}}
    end;
validate_nodes(_AgentId, [{NodeId, _NodeFun} | _Rest]) ->
    {error, {invalid_node_definition, NodeId}}.

-spec start_nodes(pid(), config()) -> ok | {error, term()}.
start_nodes(SupPid, Config) ->
    AgentId = maps:get(id, Config),
    Nodes = maps:get(nodes, Config),
    case node_supervisor(SupPid) of
        {ok, NodeSupPid} ->
            start_nodes(NodeSupPid, AgentId, maps:to_list(Nodes));
        {error, Reason} ->
            {error, Reason}
    end.

-spec start_nodes(pid(), term(), [{term(), function()}]) ->
    ok | {error, term()}.
start_nodes(_NodeSupPid, _AgentId, []) ->
    ok;
start_nodes(NodeSupPid, AgentId, [{NodeId, _NodeFun} | Rest]) ->
    case hayata_node_sup:start_node(
        NodeSupPid,
        NodeId,
        #{},
        [],
        AgentId
    ) of
        {ok, _NodePid} ->
            start_nodes(NodeSupPid, AgentId, Rest);
        {error, Reason} ->
            {error, {node_start_failed, NodeId, Reason}}
    end.
