# VM Recovery Verification

This document records the local, repeatable checks used to verify
Hayata's durable task and invocation recovery on the
`recovery_checkpoints` branch.

These are manual integration checks, separate from EUnit. Each check
starts a fresh Erlang VM for each phase and uses the same Mnesia
directory across the restart. The first VM ends with `erlang:halt(0)`,
without a graceful application shutdown.

## Requirements

-   Run from the Hayata repository root.
-   Erlang/OTP 29.1.1 and Rebar3, matching the project's target runtime.
-   Dependencies and beams compiled locally.
-   Hayata beams available under `_build/default/lib`.

Prepare the project once:

``` sh
rebar3 compile
```

Each test uses its own directory under `tmp/`. Phase 1 removes that
test's directory to guarantee a clean start. **Do not remove the
directory between phase 1 and phase 2.** Run every command from the
repository root.

The commands use `ERL_LIBS=_build/default/lib` and pass the Mnesia
directory explicitly.

------------------------------------------------------------------------

## Test 1 --- Completed task survives an abrupt VM shutdown

**Purpose:** prove that a completed task result survives a VM restart
and that claiming it after restart returns the persisted result instead
of requesting execution again.

### Phase 1: persist the completed result and stop the VM

``` sh
cd ~/hayata
export MnesiaDir="$PWD/tmp/hayata-vm-task-completed"
rm -rf "$MnesiaDir"
mkdir -p "$MnesiaDir"

ERL_LIBS=_build/default/lib erl -noshell \
  -mnesia dir "\"$MnesiaDir\"" \
  -eval '
    ok = hayata_task_store:ensure_started(),
    Key = {hayata_vm_completed_agent, completed_execution, node_result},
    Result = {ok, #{answer => task_completed, value => 42}},

    ok = hayata_task_store:save_task_result(Key, Result),
    {ok, {completed, Result}} = hayata_task_store:inspect_task(Key),

    io:format("COMPLETED_RESULT_PERSISTED~n"),
    io:format("SIMULATING_ABRUPT_VM_SHUTDOWN~n"),
    erlang:halt(0).
'
```

Expected markers:

``` text
COMPLETED_RESULT_PERSISTED
SIMULATING_ABRUPT_VM_SHUTDOWN
```

### Phase 2: restart the VM and inspect/claim the task

``` sh
cd ~/hayata
export MnesiaDir="$PWD/tmp/hayata-vm-task-completed"

ERL_LIBS=_build/default/lib erl -noshell \
  -mnesia dir "\"$MnesiaDir\"" \
  -eval '
    ok = hayata_task_store:ensure_started(),
    Key = {hayata_vm_completed_agent, completed_execution, node_result},
    Result = {ok, #{answer => task_completed, value => 42}},

    {ok, {completed, Result}} = hayata_task_store:inspect_task(Key),
    {ok, {completed, Result}} =
      hayata_task_store:claim_task(Key, #{source => restart_verification}),

    io:format("COMPLETED_RESULT_RESTORED: ~p~n", [Result]),
    io:format("COMPLETED_TASK_RECOVERY_VERIFIED~n"),
    erlang:halt(0).
'
```

The final marker must be `COMPLETED_TASK_RECOVERY_VERIFIED`. The task
claim returns the stored result; it does not return `{ok, execute}`.

------------------------------------------------------------------------

## Test 2 --- A task left running without a result is marked uncertain

**Purpose:** prove that Hayata does not silently execute a task again
when the durable store says it had started but no terminal result was
saved.

### Phase 1: claim the task, do not save a result, and stop the VM

``` sh
cd ~/hayata
export MnesiaDir="$PWD/tmp/hayata-vm-task-uncertain"
rm -rf "$MnesiaDir"
mkdir -p "$MnesiaDir"

ERL_LIBS=_build/default/lib erl -noshell \
  -mnesia dir "\"$MnesiaDir\"" \
  -eval '
    ok = hayata_task_store:ensure_started(),
    Key = {hayata_vm_uncertain_agent, uncertain_execution, node_result},

    {ok, execute} =
      hayata_task_store:claim_task(Key, #{node_id => uncertain_node}),
    {error, task_execution_uncertain} =
      hayata_task_store:inspect_task(Key),

    io:format("TASK_LEFT_RUNNING_WITHOUT_RESULT~n"),
    io:format("SIMULATING_ABRUPT_VM_SHUTDOWN~n"),
    erlang:halt(0).
'
```

Do not call `save_task_result/2` in this phase. The missing result is
the scenario under test.

### Phase 2: restart the VM and verify that execution is rejected

``` sh
cd ~/hayata
export MnesiaDir="$PWD/tmp/hayata-vm-task-uncertain"

ERL_LIBS=_build/default/lib erl -noshell \
  -mnesia dir "\"$MnesiaDir\"" \
  -eval '
    ok = hayata_task_store:ensure_started(),
    Key = {hayata_vm_uncertain_agent, uncertain_execution, node_result},

    {error, task_execution_uncertain} =
      hayata_task_store:inspect_task(Key),
    {error, task_execution_uncertain} =
      hayata_task_store:claim_task(Key, #{node_id => uncertain_node}),

    io:format("UNCERTAIN_TASK_REJECTED_AFTER_RESTART~n"),
    io:format("UNCERTAIN_TASK_RECOVERY_VERIFIED~n"),
    erlang:halt(0).
'
```

The final marker must be `UNCERTAIN_TASK_RECOVERY_VERIFIED`. This is
deliberate safety behavior: the system cannot know whether the original
operation produced external side effects before the VM stopped.

------------------------------------------------------------------------

## Test 3 --- An invocation checkpoint is restored after an abrupt VM shutdown

**Purpose:** prove that the persisted invocation identity, state, step,
and active node execution are loaded by a newly started agent.

### Phase 1: persist a running invocation checkpoint and stop the VM

``` sh
cd ~/hayata
export MnesiaDir="$PWD/tmp/hayata-vm-invocation-checkpoint"
rm -rf "$MnesiaDir"
mkdir -p "$MnesiaDir"

ERL_LIBS=_build/default/lib erl -noshell \
  -mnesia dir "\"$MnesiaDir\"" \
  -eval '
    ok = hayata_task_store:ensure_started(),

    AgentId = hayata_vm_checkpoint_agent,
    InvocationId = make_ref(),
    ExecutionId = recovery_execution_1,

    ActiveExecution = #{
      node_id => alpha,
      execution_id => ExecutionId,
      node_input => #{input => original_input, progress => 1}
    },

    Checkpoint = #{
      invocation_id => InvocationId,
      status => running,
      input => original_input,
      state => #{progress => 1},
      current_step => 1,
      active_execution => ActiveExecution,
      parallel_results => undefined,
      result => undefined,
      last_error => undefined
    },

    {ok, created} =
      hayata_task_store:create_invocation(AgentId, Checkpoint),
    {ok, Stored} =
      hayata_task_store:get_invocation(AgentId, InvocationId),
    running = maps:get(status, Stored),

    io:format("INVOCATION_CHECKPOINT_PERSISTED~n"),
    io:format("INVOCATION_ID: ~p~n", [InvocationId]),
    io:format("SIMULATING_ABRUPT_VM_SHUTDOWN~n"),
    erlang:halt(0).
'
```

### Phase 2: start a new agent and verify its restored state

``` sh
cd ~/hayata
export MnesiaDir="$PWD/tmp/hayata-vm-invocation-checkpoint"

ERL_LIBS=_build/default/lib erl -noshell \
  -mnesia dir "\"$MnesiaDir\"" \
  -eval '
    Config = #{
      id => hayata_vm_checkpoint_agent,
      state => #{progress => 0},
      nodes => #{
        alpha => fun(_Input) -> #{alpha => recovered} end
      },
      decision_policy => fun(Context) ->
        {finish, maps:get(state, Context)}
      end,
      max_steps => 3
    },

    {ok, SupPid} = hayata_agent_sup:start_link(Config),
    unlink(SupPid),

    try
      {ok, AgentPid} = hayata_agent_sup:agent(SupPid),
      Info = hayata_agent:get_info(AgentPid),

      recovery_required = maps:get(status, Info),
      #{node_id := alpha,
        execution_id := recovery_execution_1} =
        maps:get(active_execution, Info),
      #{progress := 1} = hayata_agent:get_state(AgentPid),

      {error, recovery_required} =
        hayata_agent:run(AgentPid, #{input => should_wait_for_recovery}),

      io:format("RESTORED_AGENT_INFO: ~p~n", [Info]),
      io:format("INVOCATION_CHECKPOINT_RESTORED~n")
    after
      exit(SupPid, shutdown)
    end,

    erlang:halt(0).
'
```

The final marker must be `INVOCATION_CHECKPOINT_RESTORED`. The restored
invocation must not accept a new run until recovery has been explicitly
handled.

------------------------------------------------------------------------

## Test 4 --- Parallel execution recovers across an abrupt VM shutdown

**Purpose:** verify a complete recovery flow across two separate VMs.
Branch `alpha` has a durable result; branch `beta` has never been
started. After restart, Hayata must reuse `alpha`, execute `beta`, and
persist the combined result.

### Phase 1: persist the parallel checkpoint and only alpha's result

``` sh
cd ~/hayata
export MnesiaDir="$PWD/tmp/hayata-parallel-crash-recovery"
rm -rf "$MnesiaDir"
mkdir -p "$MnesiaDir"

ERL_LIBS=_build/default/lib erl -noshell \
  -mnesia dir "\"$MnesiaDir\"" \
  -eval '
    ok = hayata_task_store:ensure_started(),

    AgentId = hayata_parallel_crash_recovery_agent,
    InvocationId = make_ref(),
    AlphaExecutionId = make_ref(),
    BetaExecutionId = make_ref(),

    NodeInput = #{progress => 1, input => original_input},

    ActiveExecution = #{
      type => parallel,
      node_ids => [alpha, beta],
      node_input => NodeInput,
      pending => #{
        alpha => AlphaExecutionId,
        beta => BetaExecutionId
      },
      results => #{}
    },

    Checkpoint = #{
      invocation_id => InvocationId,
      status => running,
      input => original_input,
      state => #{progress => 1},
      current_step => 1,
      active_execution => ActiveExecution,
      parallel_results => undefined,
      result => undefined,
      last_error => undefined
    },

    {ok, created} =
      hayata_task_store:create_invocation(AgentId, Checkpoint),

    AlphaResult = {ok, #{alpha => recovered}},
    ok = hayata_task_store:save_task_result(
      {AgentId, AlphaExecutionId, node_result},
      AlphaResult
    ),

    {ok, {completed, AlphaResult}} =
      hayata_task_store:inspect_task(
        {AgentId, AlphaExecutionId, node_result}
      ),
    {ok, not_started} =
      hayata_task_store:inspect_task(
        {AgentId, BetaExecutionId, node_result}
      ),

    io:format("CHECKPOINT_PERSISTED~n"),
    io:format("ALPHA_RESULT_PERSISTED~n"),
    io:format("BETA_NOT_STARTED~n"),
    io:format("AGENT_ID: ~p~n", [AgentId]),
    io:format("INVOCATION_ID: ~p~n", [InvocationId]),
    io:format("SIMULATING_ABRUPT_VM_SHUTDOWN~n"),
    erlang:halt(0).
'
```

Do not delete or modify the Mnesia directory before phase 2.

### Phase 2: restart the VM, recover the agent, and verify the result

``` sh
cd ~/hayata
export MnesiaDir="$PWD/tmp/hayata-parallel-crash-recovery"

ERL_LIBS=_build/default/lib erl -noshell \
  -mnesia dir "\"$MnesiaDir\"" \
  -eval '
    ok = hayata_task_store:ensure_started(),

    AgentId = hayata_parallel_crash_recovery_agent,
    Parent = self(),

    Config = #{
      id => AgentId,
      state => #{progress => 0},
      nodes => #{
        alpha => fun(_Input) ->
          Parent ! alpha_must_not_execute_again,
          error(alpha_was_reexecuted_after_crash)
        end,
        beta => fun(_Input) ->
          Parent ! beta_executed_after_restart,
          #{beta => recovered}
        end
      },
      decision_policy => fun(Context) ->
        {finish, maps:get(parallel_results, Context)}
      end,
      max_steps => 3
    },

    {ok, SupPid} = hayata_agent_sup:start_link(Config),
    unlink(SupPid),

    try
      {ok, AgentPid} = hayata_agent_sup:agent(SupPid),
      InitialInfo = hayata_agent:get_info(AgentPid),
      recovery_required = maps:get(status, InitialInfo),

      #{
        alpha := {completed, {ok, #{alpha := recovered}}},
        beta := not_started
      } = maps:get(recovery_tasks, InitialInfo),

      io:format("PERSISTED_STATE_RESTORED~n"),

      {ok, _ExecutionId} = hayata_agent:recover(AgentPid),
      io:format("RECOVERY_STARTED~n"),

      receive
        beta_executed_after_restart ->
          io:format("BETA_EXECUTED_AFTER_RESTART~n")
      after 5000 ->
        erlang:error(beta_recovery_timeout)
      end,

      Wait = fun Loop(0) ->
        erlang:error({recovery_timeout, hayata_agent:get_info(AgentPid)});
      Loop(N) ->
        Info = hayata_agent:get_info(AgentPid),
        case maps:get(status, Info) of
          completed -> Info;
          {error, Reason} ->
            erlang:error({parallel_recovery_failed, Reason, Info});
          _ ->
            timer:sleep(20),
            Loop(N - 1)
        end
      end,

      FinalInfo = Wait(300),
      Expected = [
        #{alpha => recovered},
        #{beta => recovered}
      ],
      {ok, Expected} = hayata_agent:get_result(AgentPid),

      receive
        alpha_must_not_execute_again ->
          erlang:error(alpha_was_reexecuted_after_crash)
      after 200 ->
        ok
      end,

      {ok, Persisted} = hayata_task_store:get_invocation(
        AgentId,
        maps:get(invocation_id, FinalInfo)
      ),
      completed = maps:get(status, Persisted),

      io:format("FINAL_AGENT_INFO: ~p~n", [FinalInfo]),
      io:format("FINAL_AGENT_RESULT: ~p~n", [
        hayata_agent:get_result(AgentPid)
      ]),
      io:format("FINAL_PERSISTED_CHECKPOINT: ~p~n", [Persisted]),
      io:format("PARALLEL_CRASH_RECOVERY_VERIFIED~n")
    after
      exit(SupPid, shutdown)
    end,

    erlang:halt(0).
'
```

The final marker must be `PARALLEL_CRASH_RECOVERY_VERIFIED`. The final
result must be:

``` erlang
{ok, [
  #{alpha => recovered},
  #{beta => recovered}
]}
```

This check proves that the completed branch is not re-executed and the
not-started branch runs after restart.

------------------------------------------------------------------------

## Interpretation and limits

The checks above verify durable storage and recovery classification for
these tested states:

  --------------------------------------------------------------------------
  Persisted state                     Expected behavior after restart
  ----------------------------------- --------------------------------------
  Task has a completed result         Return/reuse the stored result

  Task is marked running but has no   Return
  terminal result                     `{error, task_execution_uncertain}`;
                                      do not silently rerun it

  Invocation checkpoint is running    Restore it and place the agent in
                                      `recovery_required`

  Parallel transition has one         Reuse the completed result, run the
  completed branch and one            missing branch, then persist
  not-started branch                  completion
  --------------------------------------------------------------------------

The uncertain-task behavior is intentionally conservative. If an
operation may have performed an external side effect before the VM
stopped, Hayata cannot infer whether retrying it is safe. Applications
should design node/edge operations with idempotency or external
deduplication where necessary.

These are manual verification procedures and recorded results for the
scenarios above; they are not a substitute for running the complete
EUnit suite on the exact commit being released.
