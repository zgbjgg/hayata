-module(hayata_agent).

-behaviour(gen_server).

-export([
    start_link/1,
    run/2,
    run/3,
    get_state/1,
    get_info/1,
    get_result/1,
    stop/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(agent_state, {
    id,
    status = ready,
    initial_state = #{},
    state = #{},
    nodes = #{},
    node_sup_pid,
    supervisor_pid,
    decision_policy,
    max_steps,
    current_step = 0,
    invocation_id = undefined,
    subscription_pid = undefined,
    invocation_input = undefined,
    active_execution = undefined,
    result = undefined,
    last_error = undefined,
    execution_timeout = 30000,
    timeout_ref = undefined,
    invocation_start_time = undefined,
    parallel_results = undefined,
    execution_starter = fun hayata_node:start_execution/6
}).

-type config() :: #{
    id := term(),
    nodes := #{atom() => function()},
    node_sup_pid := pid(),
    decision_policy => function(),
    state => map(),
    max_steps => pos_integer()
}.

-doc("Starts an agent coordinator.").
-spec start_link(config()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

-doc("Starts an asynchronous agent invocation.").
-spec run(gen_server:server_ref(), term()) ->
    {ok, reference()} | {error, term()}.
run(Agent, Input) ->
    gen_server:call(Agent, {run, Input, undefined}, 5000).

-doc("Starts an asynchronous agent invocation and sends its terminal result to a subscription process.").
-spec run(gen_server:server_ref(), term(), pid()) ->
    {ok, reference()} | {error, term()}.
run(Agent, Input, SubscriptionPid) when is_pid(SubscriptionPid) ->
    gen_server:call(Agent, {run, Input, SubscriptionPid}, 5000);
run(_Agent, _Input, _SubscriptionPid) ->
    {error, invalid_subscription_pid}.

-doc("Returns the current agent context.").
-spec get_state(gen_server:server_ref()) -> map().
get_state(Agent) ->
    gen_server:call(Agent, get_state).

-doc("Returns operational information about the agent.").
-spec get_info(gen_server:server_ref()) -> map().
get_info(Agent) ->
    gen_server:call(Agent, get_info).

-doc("Returns the final result, if available.").
-spec get_result(gen_server:server_ref()) ->
    {ok, term()} | {error, term()}.
get_result(Agent) ->
    gen_server:call(Agent, get_result).

-doc("Stops the agent and its complete supervision tree.").
-spec stop(gen_server:server_ref()) -> ok | {error, term()}.
stop(Agent) ->
    case gen_server:call(Agent, get_supervisor_pid) of
        {ok, SupPid} ->
            gen_server:stop(SupPid, normal, 5000);
        {error, Reason} ->
            {error, Reason}
    end.

-doc(false).
-spec init(config()) -> {ok, #agent_state{}} | {stop, term()}.
init(Config) ->
    case validate_config(Config) of
        ok ->
            InitialState = maps:get(state, Config, #{}),
            State = #agent_state{
                id = maps:get(id, Config),
                initial_state = InitialState,
                state = InitialState,
                nodes = maps:get(nodes, Config),
                node_sup_pid = maps:get(node_sup_pid, Config),
                supervisor_pid = maps:get(supervisor_pid, Config),
                decision_policy = maps:get(
                    decision_policy,
                    Config,
                    fun default_decision_policy/1
                ),
                max_steps = maps:get(max_steps, Config, 10),
                execution_timeout = maps:get(execution_timeout, Config, 30000),
                execution_starter = maps:get(
                    execution_starter,
                    Config,
                    fun hayata_node:start_execution/6
                )
            },
            {ok, restore_invocation_state(State)};
        {error, Reason} ->
            {stop, Reason}
    end.

-doc(false).
-spec handle_call(term(), gen_server:from(), #agent_state{}) ->
    {reply, term(), #agent_state{}} |
    {stop, term(), term(), #agent_state{}}.
handle_call({run, _Input, _SubscriptionPid}, _From, #agent_state{status = running} = State) ->
    {reply, {error, already_running}, State};
handle_call({run, _Input, _SubscriptionPid}, _From, #agent_state{status = recovery_required} = State) ->
    {reply, {error, recovery_required}, State};
handle_call({run, Input, SubscriptionPid}, _From, State) ->
    case prepare_invocation(State) of
        ok ->
            InvocationId = make_ref(),
            InvocationStartTime = erlang:monotonic_time(),
            NewState = State#agent_state{
                status = running,
                state = State#agent_state.initial_state,
                current_step = 0,
                invocation_id = InvocationId,
                subscription_pid = SubscriptionPid,
                invocation_input = Input,
                active_execution = undefined,
                result = undefined,
                last_error = undefined,
                timeout_ref = undefined,
                invocation_start_time = InvocationStartTime,
                parallel_results = undefined
            },
            case create_invocation_checkpoint(NewState) of
                ok ->
                    start_persisted_invocation(NewState);
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(get_state, _From, State) ->
    {reply, State#agent_state.state, State};
handle_call(get_info, _From, State) ->
    Info = #{
        id => State#agent_state.id,
        status => State#agent_state.status,
        current_step => State#agent_state.current_step,
        max_steps => State#agent_state.max_steps,
        invocation_id => State#agent_state.invocation_id,
        active_execution => State#agent_state.active_execution,
        last_error => State#agent_state.last_error
    },
    {reply, Info, State};

handle_call(get_result, _From, #agent_state{status = completed, result = Result} = State) ->
    {reply, {ok, Result}, State};
handle_call(get_result, _From, #agent_state{status = {error, Reason}} = State) ->
    {reply, {error, Reason}, State};
handle_call(get_result, _From, State) ->
    {reply, {error, no_result}, State};
handle_call(get_supervisor_pid, _From, State) ->
    {reply, {ok, State#agent_state.supervisor_pid}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

-doc(false).
-spec handle_cast(term(), #agent_state{}) -> {noreply, #agent_state{}}.
handle_cast(_Request, State) ->
    {noreply, State}.

-doc(false).
-spec handle_info(term(), #agent_state{}) ->
    {noreply, #agent_state{}}.
handle_info(
    {hayata_node_execution, NodeId, ExecutionId, FinalResult},
    #agent_state{
        status = running,
        active_execution = #{
            type := parallel,
            pending := Pending
        } = Transition
    } = State
) ->
    case maps:find(NodeId, Pending) of
        {ok, ExecutionId} ->
            case extract_node_updates(FinalResult) of
                {ok, Updates} ->
                    Remaining = maps:remove(NodeId, Pending),
                    Results = maps:put(
                        NodeId,
                        Updates,
                        maps:get(results, Transition)
                    ),
                    UpdatedTransition = Transition#{
                        pending => Remaining,
                        results => Results
                    },
                    persist_parallel_result(
                        UpdatedTransition,
                        Remaining,
                        Results,
                        Transition,
                        State
                    );
                {error, Reason} ->
                    FailedState = fail_invocation(Reason, State),
                    _ = persist_invocation_checkpoint(FailedState),
                    {noreply, FailedState}
            end;
        _ ->
            %% Ignore stale or unrelated execution notifications.
            {noreply, State}
    end;
handle_info(
    {hayata_node_execution, NodeId, ExecutionId, FinalResult},
    #agent_state{
        status = running,
        active_execution = #{
            node_id := NodeId,
            execution_id := ExecutionId
        }
    } = State
) ->
    case apply_node_result(FinalResult, State) of
        {ok, UpdatedState} ->
            case persist_invocation_checkpoint(UpdatedState) of
                ok ->
                    case evaluate_policy(UpdatedState) of
                        {ok, NextState} ->
                            {noreply, NextState};
                        {error, _Reason, NextState} ->
                            {noreply, NextState}
                    end;
                {error, Reason} ->
                    FailedState = fail_invocation(Reason, UpdatedState),
                    _ = persist_invocation_checkpoint(FailedState),
                    {noreply, FailedState}
            end;
        {error, Reason, UpdatedState} ->
            FailedState = fail_invocation(Reason, UpdatedState),
            _ = persist_invocation_checkpoint(FailedState),
            {noreply, FailedState}
    end;
handle_info(
    {hayata_node_execution, _NodeId, _ExecutionId, _FinalResult},
    State
) ->
    %% Ignore notifications from old or already completed executions.
    {noreply, State};
handle_info({invocation_timeout, InvocationId}, #agent_state{status = running, invocation_id = InvocationId} = State) ->
    Reason = timeout,
    TimedOutState = State#agent_state{
        timeout_ref = undefined
    },
    CancelledState = cancel_active_execution(TimedOutState),
    {noreply, fail_invocation(Reason, CancelledState)};
handle_info(_Info, State) ->
    {noreply, State}.

-doc(false).
-spec terminate(term(), #agent_state{}) -> ok.
terminate(_Reason, _State) ->
    ok.

-doc(false).
-spec code_change(term(), #agent_state{}, term()) ->
    {ok, #agent_state{}}.
code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

-spec validate_config(term()) -> ok | {error, term()}.
validate_config(Config) when is_map(Config) ->
    case {
        maps:find(id, Config),
        maps:find(nodes, Config),
        maps:find(node_sup_pid, Config),
        maps:find(supervisor_pid, Config),
        maps:find(decision_policy, Config),
        maps:find(max_steps, Config),
        maps:find(state, Config),
        maps:find(execution_timeout, Config)
    } of
        {{ok, _Id}, {ok, Nodes}, {ok, NodeSupPid}, {ok, SupervisorPid},
         {ok, Policy}, {ok, MaxSteps}, {ok, InitialState}, {ok, ExecutionTime}}
                when is_map(Nodes),
                     is_pid(NodeSupPid),
                     is_pid(SupervisorPid),
                     is_function(Policy, 1),
                     is_integer(MaxSteps),
                     MaxSteps > 0,
                     is_map(InitialState),
                     ExecutionTime > 0 ->
            validate_node_catalog(Nodes);
        {{ok, _Id}, {ok, Nodes}, {ok, NodeSupPid}, {ok, SupervisorPid},
         error, error, error, error}
                when is_map(Nodes), is_pid(NodeSupPid), is_pid(SupervisorPid) ->
            validate_node_catalog(Nodes);
        _ ->
            {error, invalid_config}
    end;
validate_config(_Config) ->
    {error, invalid_config}.

-spec validate_node_catalog(map() | [{term(), term()}]) ->
    ok | {error, term()}.
validate_node_catalog(Nodes) when is_map(Nodes), map_size(Nodes) > 0 ->
    validate_node_catalog(maps:to_list(Nodes));
validate_node_catalog(Nodes) when is_map(Nodes) ->
    {error, empty_node_catalog};
validate_node_catalog([]) ->
    ok;
validate_node_catalog([{NodeId, NodeFun} | Rest])
        when is_atom(NodeId), is_function(NodeFun, 1) ->
    validate_node_catalog(Rest);
validate_node_catalog([{NodeId, _NodeFun} | _Rest]) ->
    {error, {invalid_node_definition, NodeId}}.

-spec prepare_invocation(#agent_state{}) -> ok | {error, term()}.
prepare_invocation(#agent_state{status = ready}) ->
    ok;
prepare_invocation(#agent_state{status = completed} = State) ->
    reset_nodes(State);
prepare_invocation(#agent_state{status = {error, _Reason}} = State) ->
    reset_nodes(State);
prepare_invocation(#agent_state{status = stopped}) ->
    {error, agent_stopped};
prepare_invocation(_State) ->
    ok.

-spec reset_nodes(#agent_state{}) -> ok | {error, term()}.
reset_nodes(State) ->
    case hayata_agent_sup:node_supervisor(
        State#agent_state.supervisor_pid
    ) of
        {ok, NodeSupPid} ->
            reset_nodes(
                NodeSupPid,
                State#agent_state.id,
                maps:keys(State#agent_state.nodes)
            );
        {error, Reason} ->
            {error, {node_supervisor_unavailable, Reason}}
    end.

-spec reset_nodes(pid(), term(), [atom()]) -> ok | {error, term()}.
reset_nodes(_NodeSupPid, _AgentId, []) ->
    ok;
reset_nodes(NodeSupPid, AgentId, [NodeId | Rest]) ->
    case hayata_node_sup:stop_node(NodeSupPid, NodeId) of
        ok ->
            start_reset_node(NodeSupPid, AgentId, NodeId, Rest);
        {error, not_found} ->
            start_reset_node(NodeSupPid, AgentId, NodeId, Rest);
        {error, Reason} ->
            {error, {node_reset_failed, NodeId, Reason}}
    end.

-spec start_reset_node(pid(), term(), atom(), [atom()]) ->
    ok | {error, term()}.
start_reset_node(NodeSupPid, AgentId, NodeId, Rest) ->
    case hayata_node_sup:start_node(
        NodeSupPid,
        NodeId,
        #{},
        [],
        AgentId
    ) of
        {ok, _Pid} ->
            reset_nodes(NodeSupPid, AgentId, Rest);
        {error, Reason} ->
            {error, {node_restart_failed, NodeId, Reason}}
    end.

-spec evaluate_policy(#agent_state{}) ->
    {ok, #agent_state{}} | {error, term(), #agent_state{}}.
evaluate_policy(State) ->
    Context = #{
        agent_id => State#agent_state.id,
        state => State#agent_state.state,
        input => State#agent_state.invocation_input,
        step => State#agent_state.current_step,
        max_steps => State#agent_state.max_steps,
        parallel_results => State#agent_state.parallel_results
    },
    try (State#agent_state.decision_policy)(Context) of
        {next, NodeId, Input} when is_atom(NodeId) ->
            start_next_node(NodeId, Input, State);
        {next, NodeIds, Input} when is_list(NodeIds) ->
            start_parallel_nodes(NodeIds, Input, State);

        {finish, Result} ->
            CancelledState = cancel_invocation_timeout(State),
            CompletedState = CancelledState#agent_state{
                status = completed,
                result = Result,
                last_error = undefined,
                active_execution = undefined
            },
            case persist_invocation_checkpoint(CompletedState) of
                ok ->
                    telemetry_stop(
                        CompletedState#agent_state.id,
                        CompletedState#agent_state.invocation_id,
                        CompletedState#agent_state.invocation_start_time
                    ),
                    {ok, notify_invocation_result(
                        CompletedState,
                        {ok, Result}
                    )};
                {error, Reason} ->
                    FailedState = fail_invocation_state(
                        Reason,
                        CompletedState
                    ),
                    case persist_invocation_checkpoint(FailedState) of
                        ok ->
                            telemetry_stop(
                                FailedState#agent_state.id,
                                FailedState#agent_state.invocation_id,
                                FailedState#agent_state.invocation_start_time
                            ),
                            {error, Reason, notify_invocation_result(
                                FailedState,
                                {error, Reason}
                            )};
                        {error, PersistReason} ->
                            {error, PersistReason, FailedState}
                    end
            end;
        {error, Reason} ->
            {error, Reason, fail_invocation(Reason, State)};
        Other ->
            Reason = {invalid_policy_decision, Other},
            {error, Reason, fail_invocation(Reason, State)}
    catch
        Class:Reason:Stacktrace ->
            Error = {policy_exception, Class, Reason, Stacktrace},
            FailedState = fail_invocation_exception(Class, Error, State),
            {error, Error, FailedState}
    end.

-spec start_next_node(term(), term(), #agent_state{}) ->
    {ok, #agent_state{}} | {error, term(), #agent_state{}}.
start_next_node(NodeId, Input, State) ->
    case maps:find(NodeId, State#agent_state.nodes) of
        error ->
            Reason = {unknown_node, NodeId},
            {error, Reason, fail_invocation(Reason, State)};
        {ok, _NodeFun} when State#agent_state.current_step >=
                            State#agent_state.max_steps ->
            Reason = max_steps_exceeded,
            {error, Reason, fail_invocation(Reason, State)};
        {ok, NodeFun} ->
            case hayata_node:whereis(State#agent_state.id, NodeId) of
                undefined ->
                    Reason = {node_not_running, NodeId},
                    {error, Reason, fail_invocation(Reason, State)};
                NodePid ->
                    start_node_execution(NodePid, NodeId, NodeFun, Input, State#agent_state{parallel_results = undefined})
            end
    end.

-spec start_node_execution(
    pid(),
    atom(),
    function(),
    term(),
    #agent_state{}
) -> {ok, #agent_state{}} | {error, term(), #agent_state{}}.
start_node_execution(NodePid, NodeId, NodeFun, Input, State) ->
    ExecutionId = make_ref(),
    NodeInput = maps:put(input, Input, State#agent_state.state),
    Task = fun() -> execute_node(NodeFun, NodeInput) end,
    PlannedState = State#agent_state{
        current_step = State#agent_state.current_step + 1,
        active_execution = #{
            node_id => NodeId,
            execution_id => ExecutionId
        }
    },
    case persist_invocation_checkpoint(PlannedState) of
        ok ->
            start_checkpointed_node_execution(
                NodePid,
                NodeId,
                ExecutionId,
                Task,
                PlannedState
            );
        {error, Reason} ->
            FailedState = fail_invocation(Reason, State),
            {error, Reason, FailedState}
    end.

-spec start_checkpointed_node_execution(
    pid(),
    atom(),
    reference(),
    function(),
    #agent_state{}
) -> {ok, #agent_state{}} | {error, term(), #agent_state{}}.
start_checkpointed_node_execution(NodePid, NodeId, ExecutionId, Task, PlannedState) ->
    case hayata_node:start_execution(
        NodePid,
        ExecutionId,
        [{node_result, Task}],
        30000,
        isolated,
        self()
    ) of
        {ok, ExecutionId} ->
            {ok, PlannedState};
        {error, Reason} ->
            Error = {node_execution_start_failed, NodeId, Reason},
            FailedState = fail_invocation(Error, PlannedState),
            {error, Error, FailedState}
    end.

-spec execute_node(function(), map()) -> {ok, map()} | {error, term()}.
execute_node(NodeFun, NodeInput) ->
    try NodeFun(NodeInput) of
        UpdateMap when is_map(UpdateMap) ->
            {ok, UpdateMap};
        Other ->
            {error, {invalid_node_result, Other}}
    catch
        Class:Reason:Stacktrace ->
            {error, {node_exception, Class, Reason, Stacktrace}}
    end.

-spec apply_node_result(map(), #agent_state{}) ->
    {ok, #agent_state{}} | {error, term(), #agent_state{}}.
apply_node_result(FinalResult, State) ->
    case {
        maps:get(status, FinalResult, undefined),
        maps:get(errors, FinalResult, #{}),
        maps:get(results, FinalResult, #{})
    } of
        {completed, Errors, _Results} when map_size(Errors) > 0 ->
            {error, {node_execution_failed, Errors}, State};
        {completed, _Errors, Results} ->
            case maps:find(node_result, Results) of
                {ok, {ok, Updates}} when is_map(Updates) ->
                    NewContext = maps:merge(State#agent_state.state, Updates),
                    {ok, State#agent_state{
                        state = NewContext,
                        active_execution = undefined
                    }};
                {ok, Other} ->
                    {error, {invalid_node_result, Other}, State};
                error ->
                    {error, missing_node_result, State}
            end;
        {Status, _Errors, _Results} ->
            {error, {node_execution_failed, Status}, State}
    end.

-spec extract_node_updates(map()) ->
    {ok, map()} | {error, term()}.
extract_node_updates(FinalResult) ->
    case {
        maps:get(status, FinalResult, undefined),
        maps:get(errors, FinalResult, #{}),
        maps:get(results, FinalResult, #{})
    } of
        {completed, Errors, _Results} when map_size(Errors) > 0 ->
            {error, {node_execution_failed, Errors}};
        {completed, _Errors, Results} ->
            case maps:find(node_result, Results) of
                {ok, {ok, Updates}} when is_map(Updates) ->
                    {ok, Updates};
                {ok, Other} ->
                    {error, {invalid_node_result, Other}};
                error ->
                    {error, missing_node_result}
            end;
        {Status, _Errors, _Results} ->
            {error, {node_execution_failed, Status}}
    end.

-spec fail_invocation(term(), #agent_state{}) -> #agent_state{}.
fail_invocation(Reason, State) ->
    fail_invocation_terminal(Reason, State, failed).

-spec fail_invocation_exception(
    term(),
    term(),
    #agent_state{}
) -> #agent_state{}.
fail_invocation_exception(Class, Reason, State) ->
    FailedState = fail_invocation_state(Reason, State),
    case persist_invocation_checkpoint(FailedState) of
        ok ->
            notify_failed_invocation_exception(
                FailedState,
                Class,
                Reason
            );
        {error, PersistReason} ->
            notify_failed_invocation_exception(
                FailedState,
                Class,
                {terminal_checkpoint_save_failed, Reason, PersistReason}
            )
    end.

-spec notify_failed_invocation_exception(
    #agent_state{},
    term(),
    term()
) -> #agent_state{}.
notify_failed_invocation_exception(FailedState, Class, Reason) ->
    telemetry_exception(
        FailedState#agent_state.id,
        FailedState#agent_state.invocation_id,
        FailedState#agent_state.invocation_start_time,
        Class
    ),
    notify_invocation_result(FailedState, {error, Reason}).

-spec fail_invocation_terminal(
    term(),
    #agent_state{},
    failed
) -> #agent_state{}.
fail_invocation_terminal(Reason, State, failed) ->
    FailedState = fail_invocation_state(Reason, State),
    case persist_invocation_checkpoint(FailedState) of
        ok ->
            notify_failed_invocation(FailedState, Reason);
        {error, PersistReason} ->
            notify_failed_invocation(
                FailedState,
                {terminal_checkpoint_save_failed, Reason, PersistReason}
            )
    end.

-spec notify_failed_invocation(#agent_state{}, term()) ->
    #agent_state{}.
notify_failed_invocation(FailedState, Reason) ->
    telemetry:execute(
        [hayata, agent, invocation, stop],
        #{
            duration =>
                erlang:monotonic_time() -
                FailedState#agent_state.invocation_start_time
        },
        #{
            agent_id => FailedState#agent_state.id,
            invocation_id => FailedState#agent_state.invocation_id,
            status => failed
        }
    ),
    notify_invocation_result(FailedState, {error, Reason}).

-spec fail_invocation_state(term(), #agent_state{}) -> #agent_state{}.
fail_invocation_state(Reason, State) ->
    ExecutionCancelledState = cancel_active_execution(State),
    CancelledState = cancel_invocation_timeout(ExecutionCancelledState),
    CancelledState#agent_state{
        status = {error, Reason},
        result = undefined,
        last_error = Reason,
        active_execution = undefined
    }.

-spec default_decision_policy(map()) -> {finish, term()}.
default_decision_policy(Context) ->
    {finish, maps:get(state, Context)}.

-spec cancel_invocation_timeout(#agent_state{}) -> #agent_state{}.
cancel_invocation_timeout(#agent_state{timeout_ref = undefined} = State) ->
    State;
cancel_invocation_timeout(#agent_state{timeout_ref = TimeoutRef} = State) ->
    _ = erlang:cancel_timer(TimeoutRef),
    State#agent_state{timeout_ref = undefined}.

-spec cancel_active_execution(#agent_state{}) -> #agent_state{}.
cancel_active_execution(
    #agent_state{
        id = AgentId,
        active_execution = #{
            type := parallel,
            pending := Pending
        }
    } = State
) ->
    cancel_parallel_executions(
        AgentId,
        maps:to_list(Pending),
        State
    );
cancel_active_execution(
    #agent_state{
        id = AgentId,
        active_execution = #{
            node_id := NodeId,
            execution_id := ExecutionId
        }
    } = State
) ->
    case hayata_node:whereis(AgentId, NodeId) of
        undefined ->
            State;
        NodePid ->
            case hayata_node:cancel_execution(NodePid, ExecutionId) of
                ok ->
                    State;
                {error, _Reason} ->
                    State
            end
    end;
cancel_active_execution(State) ->
    State.

-spec cancel_parallel_executions(
    term(),
    [{atom(), reference()}],
    #agent_state{}
) -> #agent_state{}.
cancel_parallel_executions(_AgentId, [], State) ->
    State;
cancel_parallel_executions(AgentId, [{NodeId, ExecutionId} | Rest], State) ->
    case hayata_node:whereis(AgentId, NodeId) of
        undefined ->
            cancel_parallel_executions(AgentId, Rest, State);
        NodePid ->
            _ = hayata_node:cancel_execution(NodePid, ExecutionId),
            cancel_parallel_executions(AgentId, Rest, State)
    end.

-spec notify_invocation_result(#agent_state{}, term()) ->
    #agent_state{}.
notify_invocation_result(#agent_state{invocation_id = InvocationId, subscription_pid = SubscriptionPid} = State, Outcome) when is_pid(SubscriptionPid) ->
    SubscriptionPid ! {hayata_agent_result, InvocationId, Outcome},
    State#agent_state{subscription_pid = undefined};
notify_invocation_result(State, _Outcome) ->
    State.


-spec telemetry_start(term(), reference()) -> ok.
telemetry_start(AgentId, InvocationId) ->
    telemetry:execute(
        [hayata, agent, invocation, start],
        #{system_time => erlang:system_time()},
        #{
            agent_id => AgentId,
            invocation_id => InvocationId
        }
    ).

-spec telemetry_stop(term(), reference(), integer()) -> ok.
telemetry_stop(AgentId, InvocationId, StartTime) ->
    telemetry:execute(
        [hayata, agent, invocation, stop],
        #{
            duration => erlang:monotonic_time() - StartTime
        },
        #{
            agent_id => AgentId,
            invocation_id => InvocationId,
            status => completed
        }
    ).

-spec telemetry_exception(
    term(),
    reference(),
    integer(),
    term()
) -> ok.
telemetry_exception(AgentId, InvocationId, StartTime, Class) ->
    telemetry:execute(
        [hayata, agent, invocation, exception],
        #{
            duration => erlang:monotonic_time() - StartTime
        },
        #{
            agent_id => AgentId,
            invocation_id => InvocationId,
            class => Class
        }
    ).

-spec start_parallel_nodes([atom()], term(), #agent_state{}) ->
    {ok, #agent_state{}} | {error, term(), #agent_state{}}.
start_parallel_nodes([], _Input, State) ->
    Reason = {invalid_parallel_nodes, empty_list},
    {error, Reason, fail_invocation(Reason, State)};
start_parallel_nodes(NodeIds, Input, State) ->
    case validate_parallel_nodes(NodeIds, State) of
        ok ->
            RemainingSteps =
                State#agent_state.max_steps -
                State#agent_state.current_step,
            case length(NodeIds) =< RemainingSteps of
                true ->
                    start_parallel_node_executions(
                        NodeIds,
                        Input,
                        State#agent_state{parallel_results = undefined}
                    );
                false ->
                    Reason = max_steps_exceeded,
                    {error, Reason, fail_invocation(Reason, State)}
            end;
        {error, Reason} ->
            {error, Reason, fail_invocation(Reason, State)}
    end.

-spec validate_parallel_nodes([atom()], #agent_state{}) ->
    ok | {error, term()}.
validate_parallel_nodes(NodeIds, State) ->
    case length(NodeIds) =:= length(lists:usort(NodeIds)) of
        false ->
            {error, {invalid_parallel_nodes, duplicate_node_ids}};
        true ->
            validate_parallel_node_ids(NodeIds, State)
    end.

-spec validate_parallel_node_ids([atom()], #agent_state{}) ->
    ok | {error, term()}.
validate_parallel_node_ids([], _State) ->
    ok;
validate_parallel_node_ids([NodeId | Rest], State) ->
    case maps:find(NodeId, State#agent_state.nodes) of
        error ->
            {error, {unknown_node, NodeId}};
        {ok, _NodeFun} ->
            case hayata_node:whereis(State#agent_state.id, NodeId) of
                undefined ->
                    {error, {node_not_running, NodeId}};
                _NodePid ->
                    validate_parallel_node_ids(Rest, State)
            end
    end.

-spec start_parallel_node_executions(
    [atom()],
    term(),
    #agent_state{}
) -> {ok, #agent_state{}} | {error, term(), #agent_state{}}.
start_parallel_node_executions(NodeIds, Input, State) ->
    Transition = #{
        type => parallel,
        node_ids => NodeIds,
        pending => #{},
        results => #{}
    },
    start_parallel_node_executions(
        NodeIds,
        Input,
        Transition,
        State
    ).


-spec start_parallel_node_executions(
    [atom()],
    term(),
    map(),
    #agent_state{}
) -> {ok, #agent_state{}} | {error, term(), #agent_state{}}.
start_parallel_node_executions([], _Input, Transition, State) ->
    UpdatedState = State#agent_state{
        active_execution = Transition
    },
    case persist_invocation_checkpoint(UpdatedState) of
        ok ->
            {ok, UpdatedState};
        {error, Reason} ->
            FailedState = fail_invocation(Reason, UpdatedState),
            {error, Reason, FailedState}
    end;
start_parallel_node_executions([NodeId | Rest], Input, Transition, State) ->
    NodeFun = maps:get(NodeId, State#agent_state.nodes),
    NodePid = hayata_node:whereis(State#agent_state.id, NodeId),
    ExecutionId = make_ref(),
    NodeInput = maps:put(input, Input, State#agent_state.state),
    Task = fun() -> execute_node(NodeFun, NodeInput) end,
    StartExecution = State#agent_state.execution_starter,

    Pending = maps:put(
        NodeId,
        ExecutionId,
        maps:get(pending, Transition)
    ),
    UpdatedTransition = Transition#{pending => Pending},
    PlannedState = State#agent_state{
        current_step = State#agent_state.current_step + 1,
        active_execution = UpdatedTransition
    },

    case persist_invocation_checkpoint(PlannedState) of
        ok ->
            case StartExecution(
                NodePid,
                ExecutionId,
                [{node_result, Task}],
                30000,
                parallel,
                self()
            ) of
                {ok, ExecutionId} ->
                    start_parallel_node_executions(
                        Rest,
                        Input,
                        UpdatedTransition,
                        PlannedState
                    );
                {error, Reason} ->
                    Error = {node_execution_start_failed, NodeId, Reason},
                    FailedState = fail_invocation(Error, PlannedState),
                    {error, Error, FailedState}
            end;
        {error, Reason} ->
            FailedState = fail_invocation(Reason, PlannedState),
            {error, Reason, FailedState}
    end.

-spec create_invocation_checkpoint(#agent_state{}) ->
    ok | {error, term()}.
create_invocation_checkpoint(State) ->
    Checkpoint = #{
        invocation_id => State#agent_state.invocation_id,
        input => State#agent_state.invocation_input,
        state => State#agent_state.state,
        current_step => State#agent_state.current_step,
        active_execution => State#agent_state.active_execution,
        parallel_results => State#agent_state.parallel_results,
        result => State#agent_state.result,
        last_error => State#agent_state.last_error,
        status => running
    },
    case hayata_task_store:create_invocation(
        State#agent_state.id,
        Checkpoint
    ) of
        {ok, created} ->
            ok;
        {ok, existing} ->
            {error, invocation_already_exists};
        {error, Reason} ->
            {error, {invocation_checkpoint_create_failed, Reason}}
    end.

-spec start_persisted_invocation(#agent_state{}) ->
    {reply, term(), #agent_state{}}.
start_persisted_invocation(State) ->
    InvocationId = State#agent_state.invocation_id,
    TimeoutRef = erlang:send_after(
        State#agent_state.execution_timeout,
        self(),
        {invocation_timeout, InvocationId}
    ),
    TimedState = State#agent_state{
        timeout_ref = TimeoutRef
    },
    case persist_invocation_checkpoint(TimedState) of
        ok ->
            telemetry_start(
                TimedState#agent_state.id,
                InvocationId
            ),
            evaluate_persisted_invocation(TimedState);
        {error, Reason} ->
            _ = erlang:cancel_timer(TimeoutRef),
            {reply, {error, Reason}, State}
    end.

-spec evaluate_persisted_invocation(#agent_state{}) ->
    {reply, term(), #agent_state{}}.
evaluate_persisted_invocation(State) ->
    case evaluate_policy(State) of
        {ok, UpdatedState} ->
            case persist_invocation_checkpoint(UpdatedState) of
                ok ->
                    {reply, {ok, UpdatedState#agent_state.invocation_id},
                     UpdatedState};
                {error, Reason} ->
                    {reply, {error, Reason}, UpdatedState}
            end;
        {error, Reason, UpdatedState} ->
            case persist_invocation_checkpoint(UpdatedState) of
                ok ->
                    {reply, {error, Reason}, UpdatedState};
                {error, PersistReason} ->
                    {reply, {error, PersistReason}, UpdatedState}
            end
    end.

-spec persist_invocation_checkpoint(#agent_state{}) ->
    ok | {error, term()}.
persist_invocation_checkpoint(State) ->
    Checkpoint = #{
        agent_id => State#agent_state.id,
        invocation_id => State#agent_state.invocation_id,
        input => State#agent_state.invocation_input,
        state => State#agent_state.state,
        current_step => State#agent_state.current_step,
        active_execution => State#agent_state.active_execution,
        parallel_results => State#agent_state.parallel_results,
        result => State#agent_state.result,
        last_error => State#agent_state.last_error,
        status => checkpoint_status(State#agent_state.status)
    },
    case hayata_task_store:save_invocation(Checkpoint) of
        ok ->
            ok;
        {error, Reason} ->
            {error, {invocation_checkpoint_save_failed, Reason}}
    end.

-spec checkpoint_status(term()) -> running | completed | failed.
checkpoint_status(running) ->
    running;
checkpoint_status(completed) ->
    completed;
checkpoint_status({error, _Reason}) ->
    failed;
checkpoint_status(_Status) ->
    failed.

-spec persist_parallel_result(
    map(),
    map(),
    map(),
    map(),
    #agent_state{}
) -> {noreply, #agent_state{}}.
persist_parallel_result(UpdatedTransition, Remaining, Results, Transition, State) ->
    case map_size(Remaining) of
        0 ->
            OrderedResults = [
                maps:get(ResultNodeId, Results)
             || ResultNodeId <- maps:get(node_ids, Transition)
            ],
            UpdatedState = State#agent_state{
                active_execution = undefined,
                parallel_results = OrderedResults
            },
            case persist_invocation_checkpoint(UpdatedState) of
                ok ->
                    case evaluate_policy(UpdatedState) of
                        {ok, NextState} ->
                            {noreply, NextState};
                        {error, _Reason, NextState} ->
                            _ = persist_invocation_checkpoint(NextState),
                            {noreply, NextState}
                    end;
                {error, Reason} ->
                    FailedState = fail_invocation(Reason, UpdatedState),
                    _ = persist_invocation_checkpoint(FailedState),
                    {noreply, FailedState}
            end;
        _ ->
            UpdatedState = State#agent_state{
                active_execution = UpdatedTransition
            },
            case persist_invocation_checkpoint(UpdatedState) of
                ok ->
                    {noreply, UpdatedState};
                {error, Reason} ->
                    FailedState = fail_invocation(Reason, UpdatedState),
                    _ = persist_invocation_checkpoint(FailedState),
                    {noreply, FailedState}
            end
    end.

-spec restore_invocation_state(#agent_state{}) -> #agent_state{}.
restore_invocation_state(State) ->
    case hayata_task_store:get_active_invocation(
        State#agent_state.id
    ) of
        {ok, Checkpoint} ->
            State#agent_state{
                status = recovery_required,
                state = maps:get(
                    state,
                    Checkpoint,
                    State#agent_state.initial_state
                ),
                current_step = maps:get(
                    current_step,
                    Checkpoint,
                    0
                ),
                invocation_id = maps:get(
                    invocation_id,
                    Checkpoint
                ),
                invocation_input = maps:get(input, Checkpoint, undefined),
                active_execution = maps:get(
                    active_execution,
                    Checkpoint,
                    undefined
                ),
                parallel_results = maps:get(
                    parallel_results,
                    Checkpoint,
                    undefined
                ),
                result = maps:get(result, Checkpoint, undefined),
                last_error = maps:get(last_error, Checkpoint, undefined)
            };
        {error, not_found} ->
            State;
        {error, _Reason} ->
            State
    end.
