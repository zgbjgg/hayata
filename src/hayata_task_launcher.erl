-module(hayata_task_launcher).

-behaviour(gen_server).

-export([
    start_link/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    task_key,
    task_fun,
    notify_pid,
    metadata = #{}
}).

-type task_key() :: term().
-type task_result() :: {ok, term()} | {error, term()}.

-doc("Starts a task launcher process.").
-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) when is_map(Config) ->
    gen_server:start_link(?MODULE, Config, []);
start_link(_Config) ->
    {error, invalid_config}.

-doc(false).
-spec init(map()) -> {ok, #state{}} | {stop, term()}.
init(Config) ->
    case validate_config(Config) of
        {ok, TaskKey, TaskFun, NotifyPid, Metadata} ->
            self() ! execute_task,
            {ok, #state{
                task_key = TaskKey,
                task_fun = TaskFun,
                notify_pid = NotifyPid,
                metadata = Metadata
            }};
        {error, Reason} ->
            {stop, Reason}
    end.

-doc(false).
-spec handle_call(term(), gen_server:from(), #state{}) ->
    {reply, term(), #state{}}.
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

-doc(false).
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}}.
handle_cast(_Request, State) ->
    {noreply, State}.

-doc(false).
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.
handle_info(execute_task, State) ->
    execute_task(State);
handle_info(_Info, State) ->
    {noreply, State}.

-doc(false).
-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, _State) ->
    ok.

-doc(false).
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.
code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% Internal functions

-spec validate_config(map()) ->
    {ok, task_key(), fun(() -> term()), pid(), map()}
    | {error, term()}.
validate_config(Config) ->
    case {
        maps:find(task_key, Config),
        maps:find(task_fun, Config),
        maps:find(notify_pid, Config)
    } of
        {{ok, TaskKey}, {ok, TaskFun}, {ok, NotifyPid}}
                when is_function(TaskFun, 0), is_pid(NotifyPid) ->
            Metadata = maps:get(metadata, Config, #{}),
            case is_map(Metadata) of
                true ->
                    {ok, TaskKey, TaskFun, NotifyPid, Metadata};
                false ->
                    {error, invalid_metadata}
            end;
        _ ->
            {error, invalid_task_config}
    end.

-spec execute_task(#state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.
execute_task(State) ->
    case hayata_task_store:claim_task(
        State#state.task_key,
        State#state.metadata
    ) of
        {ok, execute} ->
            run_and_persist(State);
        {ok, {completed, Result}} ->
            notify_result(State, Result),
            {stop, normal, State};
        {error, task_execution_uncertain} ->
            notify_result(
                State,
                {error, task_execution_uncertain}
            ),
            {stop, normal, State};
        {error, Reason} ->
            notify_result(
                State,
                {error, {checkpoint_claim_failed, Reason}}
            ),
            {stop, normal, State}
    end.

-spec run_and_persist(#state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.
run_and_persist(State) ->
    Result = run_task(State#state.task_fun),
    case hayata_task_store:save_task_result(
        State#state.task_key,
        Result
    ) of
        ok ->
            notify_result(State, Result),
            {stop, normal, State};
        {error, Reason} ->
            notify_result(
                State,
                {error, {checkpoint_persist_failed, Reason}}
            ),
            {stop, {checkpoint_persist_failed, Reason}, State}
    end.

-spec run_task(fun(() -> term())) -> task_result().
run_task(TaskFun) ->
    try TaskFun() of
        {ok, _Value} = Result ->
            Result;
        {error, _Reason} = Result ->
            Result;
        Other ->
            {error, {invalid_task_result, Other}}
    catch
        Class:Reason:Stacktrace ->
            {error, {exception, Class, Reason, Stacktrace}}
    end.

-spec notify_result(#state{}, task_result()) -> ok.
notify_result(State, Result) ->
    State#state.notify_pid ! {
        hayata_task_result,
        State#state.task_key,
        Result
    },
    ok.
