-module(hayata_task_store_tests).

-include_lib("eunit/include/eunit.hrl").

create_and_get_invocation_test() ->
    ok = hayata_task_store:ensure_started(),

    AgentId = make_ref(),
    InvocationId = make_ref(),
    Input = #{prompt => <<"hello">>},
    Checkpoint = #{
        invocation_id => InvocationId,
        input => Input,
        state => #{},
        current_step => 0
    },

    ?assertEqual(
        {ok, created},
        hayata_task_store:create_invocation(AgentId, Checkpoint)
    ),

    {ok, StoredCheckpoint} = hayata_task_store:get_invocation(
        AgentId,
        InvocationId
    ),

    ?assertEqual(
        #{
            agent_id => AgentId,
            invocation_id => InvocationId,
            input => Input,
            state => #{},
            current_step => 0,
            status => running,
            version => 1
        },
        maps:without([updated_at], StoredCheckpoint)
    ).

duplicate_invocation_preserves_checkpoint_test() ->
    ok = hayata_task_store:ensure_started(),

    AgentId = make_ref(),
    InvocationId = make_ref(),

    InitialCheckpoint = #{
        invocation_id => InvocationId,
        input => first_input,
        state => #{counter => 1}
    },

    DuplicateCheckpoint = #{
        invocation_id => InvocationId,
        input => replacement_input,
        state => #{counter => 99}
    },

    ?assertEqual(
        {ok, created},
        hayata_task_store:create_invocation(
            AgentId,
            InitialCheckpoint
        )
    ),

    ?assertEqual(
        {ok, existing},
        hayata_task_store:create_invocation(
            AgentId,
            DuplicateCheckpoint
        )
    ),

    {ok, StoredCheckpoint} = hayata_task_store:get_invocation(
        AgentId,
        InvocationId
    ),

    ?assertEqual(first_input, maps:get(input, StoredCheckpoint)),
    ?assertEqual(
        #{counter => 1},
        maps:get(state, StoredCheckpoint)
    ).

missing_invocation_id_test() ->
    ok = hayata_task_store:ensure_started(),

    ?assertEqual(
        {error, missing_invocation_id},
        hayata_task_store:create_invocation(
            make_ref(),
            #{input => hello}
        )
    ).

invalid_invocation_checkpoint_test() ->
    ok = hayata_task_store:ensure_started(),

    ?assertEqual(
        {error, invalid_checkpoint},
        hayata_task_store:create_invocation(
            make_ref(),
            not_a_map
        )
    ).

get_missing_invocation_test() ->
    ok = hayata_task_store:ensure_started(),

    ?assertEqual(
        {error, not_found},
        hayata_task_store:get_invocation(
            make_ref(),
            make_ref()
        )
    ).

save_and_get_invocation_test() ->
    ok = hayata_task_store:ensure_started(),

    AgentId = make_ref(),
    InvocationId = make_ref(),

    InitialCheckpoint = #{
        invocation_id => InvocationId,
        input => hello,
        state => #{counter => 0}
    },

    ?assertEqual(
        {ok, created},
        hayata_task_store:create_invocation(
            AgentId,
            InitialCheckpoint
        )
    ),

    UpdatedCheckpoint = #{
        agent_id => AgentId,
        invocation_id => InvocationId,
        input => hello,
        state => #{counter => 1},
        current_step => 1,
        status => running
    },

    ?assertEqual(
        ok,
        hayata_task_store:save_invocation(UpdatedCheckpoint)
    ),

    {ok, StoredCheckpoint} = hayata_task_store:get_invocation(
        AgentId,
        InvocationId
    ),

    ?assertEqual(#{counter => 1}, maps:get(state, StoredCheckpoint)),
    ?assertEqual(1, maps:get(current_step, StoredCheckpoint)),
    ?assertEqual(running, maps:get(status, StoredCheckpoint)),
    ?assertEqual(1, maps:get(version, StoredCheckpoint)),
    ?assert(maps:is_key(updated_at, StoredCheckpoint)).

save_invocation_requires_identity_test() ->
    ok = hayata_task_store:ensure_started(),

    ?assertEqual(
        {error, missing_checkpoint_identity},
        hayata_task_store:save_invocation(#{state => #{}})
    ).

save_invocation_rejects_non_map_test() ->
    ok = hayata_task_store:ensure_started(),

    ?assertEqual(
        {error, invalid_checkpoint},
        hayata_task_store:save_invocation(invalid_checkpoint)
    ).

save_and_get_task_result_test() ->
    ok = hayata_task_store:ensure_started(),

    TaskKey = {
        make_ref(),
        make_ref(),
        process_data,
        1
    },
    Result = {ok, #{processed => true}},

    ?assertEqual(
        ok,
        hayata_task_store:save_task_result(TaskKey, Result)
    ),

    {ok, Checkpoint} = hayata_task_store:get_task(TaskKey),

    ?assertEqual(completed, maps:get(status, Checkpoint)),
    ?assertEqual(Result, maps:get(result, Checkpoint)),
    ?assert(maps:is_key(completed_at, Checkpoint)),
    ?assert(maps:is_key(updated_at, Checkpoint)),
    ?assertEqual(1, maps:get(version, Checkpoint)).

save_task_result_preserves_existing_fields_test() ->
    ok = hayata_task_store:ensure_started(),

    AgentId = make_ref(),
    InvocationId = make_ref(),
    NodeId = process_data,
    Step = 2,
    TaskKey = {AgentId, InvocationId, NodeId, Step},
    StartedAt = erlang:system_time(millisecond),

    ExistingCheckpoint = #{
        agent_id => AgentId,
        invocation_id => InvocationId,
        node_id => NodeId,
        step => Step,
        status => running,
        input => #{value => 42},
        started_at => StartedAt,
        custom_metadata => preserved
    },

    {atomic, ok} = mnesia:transaction(fun() ->
        mnesia:write({
            hayata_task_checkpoint,
            TaskKey,
            ExistingCheckpoint
        })
    end),

    Result = {ok, #{value => 84}},

    ?assertEqual(
        ok,
        hayata_task_store:save_task_result(TaskKey, Result)
    ),

    {ok, Checkpoint} = hayata_task_store:get_task(TaskKey),

    ?assertEqual(AgentId, maps:get(agent_id, Checkpoint)),
    ?assertEqual(InvocationId, maps:get(invocation_id, Checkpoint)),
    ?assertEqual(NodeId, maps:get(node_id, Checkpoint)),
    ?assertEqual(Step, maps:get(step, Checkpoint)),
    ?assertEqual(#{value => 42}, maps:get(input, Checkpoint)),
    ?assertEqual(StartedAt, maps:get(started_at, Checkpoint)),
    ?assertEqual(preserved, maps:get(custom_metadata, Checkpoint)),
    ?assertEqual(completed, maps:get(status, Checkpoint)),
    ?assertEqual(Result, maps:get(result, Checkpoint)).

get_missing_task_test() ->
    ok = hayata_task_store:ensure_started(),

    ?assertEqual(
        {error, not_found},
        hayata_task_store:get_task({
            make_ref(),
            make_ref(),
            missing_node,
            1
        })
    ).
