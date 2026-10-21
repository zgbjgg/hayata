
%%%-------------------------------------------------------------------
%% @doc Coordinates node execution for a Hayata agent.
%% @end
%%%-------------------------------------------------------------------

-module(hayata_agent).

-behaviour(gen_server).

-export([
    start_link/1,
    run/2,
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
    decision_policy,
    max_steps,
    current_step = 0,
    invocation_id = undefined,
    invocation_input = undefined,
    active_execution = undefined,
    result = undefined,
    last_error = undefined
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
    gen_server:call(Agent, {run, Input}, 5000).

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

-doc("Stops the agent and its managed node processes.").
-spec stop(gen_server:server_ref()) -> ok.
stop(Agent) ->
    gen_server:call(Agent, stop, 5000).

-doc(false).
-spec init(config()) -> {ok, #agent_state{}} | {stop, term()}.
init(Config) ->
    case validate_config(Config) of
        ok ->
            InitialState = maps:get(state, Config, #{}),
            {ok, #agent_state{
                id = maps:get(id, Config),
                initial_state = InitialState,
                state = InitialState,
                nodes = maps:get(nodes, Config),
                node_sup_pid = maps:get(node_sup_pid, Config),
                decision_policy = maps:get(
                    decision_policy,
                    Config,
                    fun default_decision_policy/1
                ),
                max_steps = maps:get(max_steps, Config, 10)
            }};
        {error, Reason} ->
            {stop, Reason}
    end.

-doc(false).
-spec handle_call(term(), gen_server:from(), #agent_state{}) ->
    {reply, term(), #agent_state{}} |
    {stop, term(), term(), #agent_state{}}.
handle_call({run, _Input}, _From, #agent_state{status = running} = State) ->
    {reply, {error, already_running}, State};
handle_call({run, Input}, _From, State) ->
    case prepare_invocation(State) of
        ok ->
            InvocationId = make_ref(),
            NewState = State#agent_state{
                status = running,
                state = State#agent_state.initial_state,
                current_step = 0,
                invocation_id = InvocationId,
                invocation_input = Input,
                active_execution = undefined,
                result = undefined,
                last_error = undefined
            },
            case evaluate_policy(NewState) of
                {ok, UpdatedState} ->
                    {reply, {ok, InvocationId}, UpdatedState};
                {error, Reason, UpdatedState} ->
                    {reply, {error, Reason}, UpdatedState}
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

handle_call(stop, _From, State) ->
    case stop_nodes(State) of
        ok ->
            {stop, normal, ok, State#agent_state{
                status = stopped,
                active_execution = undefined
            }};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
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
            node_id := NodeId,
            execution_id := ExecutionId
        }
    } = State
) ->
    case apply_node_result(FinalResult, State) of
        {ok, UpdatedState} ->
            case evaluate_policy(UpdatedState) of
                {ok, NextState} ->
                    {noreply, NextState};
                {error, _Reason, NextState} ->
                    {noreply, NextState}
            end;
        {error, Reason, UpdatedState} ->
            {noreply, fail_invocation(Reason, UpdatedState)}
    end;
handle_info(
    {hayata_node_execution, _NodeId, _ExecutionId, _FinalResult},
    State
) ->
    %% Ignore notifications from old or already completed executions.
    {noreply, State};
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
        maps:find(decision_policy, Config),
        maps:find(max_steps, Config),
        maps:find(state, Config)
    } of
        {{ok, _Id}, {ok, Nodes}, {ok, NodeSupPid},
         {ok, Policy}, {ok, MaxSteps}, {ok, InitialState}}
                when is_map(Nodes),
                     is_pid(NodeSupPid),
                     is_function(Policy, 1),
                     is_integer(MaxSteps),
                     MaxSteps > 0,
                     is_map(InitialState) ->
            validate_node_catalog(Nodes);
        {{ok, _Id}, {ok, Nodes}, {ok, NodeSupPid},
         error, error, error}
                when is_map(Nodes), is_pid(NodeSupPid) ->
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
    reset_nodes(
        State#agent_state.node_sup_pid,
        State#agent_state.id,
        maps:keys(State#agent_state.nodes)
    ).

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
        max_steps => State#agent_state.max_steps
    },
    try (State#agent_state.decision_policy)(Context) of
        {next, NodeId, Input} ->
            start_next_node(NodeId, Input, State);
        {finish, Result} ->
            {ok, State#agent_state{
                status = completed,
                result = Result,
                last_error = undefined,
                active_execution = undefined
            }};
        {error, Reason} ->
            {error, Reason, fail_invocation(Reason, State)};
        Other ->
            Reason = {invalid_policy_decision, Other},
            {error, Reason, fail_invocation(Reason, State)}
    catch
        Class:Reason:Stacktrace ->
            Error = {policy_exception, Class, Reason, Stacktrace},
            {error, Error, fail_invocation(Error, State)}
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
                    start_node_execution(NodePid, NodeId, NodeFun, Input, State)
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
    case hayata_node:start_execution(
        NodePid,
        ExecutionId,
        [{node_result, Task}],
        30000,
        self()
    ) of
        {ok, ExecutionId} ->
            {ok, State#agent_state{
                current_step = State#agent_state.current_step + 1,
                active_execution = #{
                    node_id => NodeId,
                    execution_id => ExecutionId
                }
            }};
        {error, Reason} ->
            Error = {node_execution_start_failed, NodeId, Reason},
            {error, Error, fail_invocation(Error, State)}
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

-spec fail_invocation(term(), #agent_state{}) -> #agent_state{}.
fail_invocation(Reason, State) ->
    State#agent_state{
        status = {error, Reason},
        result = undefined,
        last_error = Reason,
        active_execution = undefined
    }.

-spec stop_nodes(#agent_state{}) -> ok | {error, term()}.
stop_nodes(State) ->
    stop_nodes(
        State#agent_state.node_sup_pid,
        maps:keys(State#agent_state.nodes)
    ).

-spec stop_nodes(pid(), [atom()]) -> ok | {error, term()}.
stop_nodes(_NodeSupPid, []) ->
    ok;
stop_nodes(NodeSupPid, [NodeId | Rest]) ->
    case hayata_node_sup:stop_node(NodeSupPid, NodeId) of
        ok ->
            stop_nodes(NodeSupPid, Rest);
        {error, not_found} ->
            stop_nodes(NodeSupPid, Rest);
        {error, Reason} ->
            {error, {node_stop_failed, NodeId, Reason}}
    end.

-spec default_decision_policy(map()) -> {finish, term()}.
default_decision_policy(Context) ->
    {finish, maps:get(state, Context)}.
