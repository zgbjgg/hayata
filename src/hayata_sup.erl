
%%%-------------------------------------------------------------------
%% @doc Top-level supervisor and agent lifecycle API for Hayata.
%% @end
%%%-------------------------------------------------------------------

-module(hayata_sup).

-behaviour(supervisor).

-export([
    start_link/0,
    start_agent/1,
    stop_agent/1,
    agents/0,
    init/1
]).

-define(SERVER, ?MODULE).

-doc("Starts the top-level Hayata supervisor.").
-spec start_link() -> supervisor:start_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-doc("Starts an agent under the top-level supervisor.").
-spec start_agent(map()) -> {ok, pid()} | {error, term()}.
start_agent(Config) when is_map(Config) ->
    case whereis(?SERVER) of
        undefined ->
            {error, not_started};
        SupPid ->
            ChildSpec = #{
                id => make_ref(),
                start => {hayata_agent_sup, start_link, [Config]},
                restart => temporary,
                shutdown => infinity,
                type => supervisor,
                modules => [hayata_agent_sup]
            },
            supervisor:start_child(SupPid, ChildSpec)
    end;
start_agent(_Config) ->
    {error, invalid_config}.

-doc("Stops an agent supervision tree managed by Hayata.").
-spec stop_agent(pid()) -> ok | {error, term()}.
stop_agent(AgentSupPid) when is_pid(AgentSupPid) ->
    case whereis(?SERVER) of
        undefined ->
            {error, not_started};
        SupPid ->
            case lists:keyfind(
                AgentSupPid,
                2,
                supervisor:which_children(SupPid)
            ) of
                {ChildId, AgentSupPid, supervisor, _Modules} ->
                    supervisor:terminate_child(SupPid, ChildId);
                false ->
                    {error, agent_not_found}
            end
    end;
stop_agent(_AgentSupPid) ->
    {error, invalid_agent_supervisor}.

-doc("Returns the agents managed by the top-level supervisor.").
-spec agents() ->
    [{term(), pid() | restarting, supervisor, [module()]}]
    | {error, not_started}.
agents() ->
    case whereis(?SERVER) of
        undefined ->
            {error, not_started};
        SupPid ->
            supervisor:which_children(SupPid)
    end.


-doc(false).
-spec init([]) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}
    | {stop, term()}.
init([]) ->
    case hayata_task_store:ensure_started() of
        ok ->
            SupFlags = #{
                strategy => one_for_one,
                intensity => 5,
                period => 10
            },
            TaskLauncherSup = #{
                id => hayata_task_launcher_sup,
                start => {
                    hayata_task_launcher_sup,
                    start_link,
                    []
                },
                restart => permanent,
                shutdown => infinity,
                type => supervisor,
                modules => [hayata_task_launcher_sup]
            },
            {ok, {SupFlags, [TaskLauncherSup]}};
        {error, Reason} ->
            {stop, {task_store_start_failed, Reason}}
    end.
