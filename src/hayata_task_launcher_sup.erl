-module(hayata_task_launcher_sup).

-behaviour(supervisor).

-export([
    start_link/0,
    start_task/1,
    init/1
]).

-doc("Starts the task launcher supervisor.").
-spec start_link() -> supervisor:start_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc("Starts a task launcher under this supervisor.").
-spec start_task(map()) -> supervisor:startchild_ret().
start_task(Config) when is_map(Config) ->
    ChildSpec = #{
        id => make_ref(),
        start => {hayata_task_launcher, start_link, [Config]},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [hayata_task_launcher]
    },
    case whereis(?MODULE) of
        undefined ->
            {error, not_started};
        _Pid ->
            supervisor:start_child(?MODULE, ChildSpec)
    end;
start_task(_Config) ->
    {error, invalid_config}.

-doc(false).
-spec init([]) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    Flags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    {ok, {Flags, []}}.
