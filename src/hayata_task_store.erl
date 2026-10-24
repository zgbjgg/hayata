-module(hayata_task_store).

-export([
    ensure_started/0,
    create_invocation/2,
    get_invocation/2,
    save_invocation/1,
    get_task/1,
    save_task_result/2,
    claim_task/2,
    get_active_invocation/1,
    inspect_task/1
]).

-record(hayata_invocation_checkpoint, {
    key,
    checkpoint
}).

-record(hayata_task_checkpoint, {
    key,
    checkpoint
}).

-define(INVOCATION_TABLE, hayata_invocation_checkpoint).
-define(TASK_TABLE, hayata_task_checkpoint).
-define(SCHEMA_VERSION, 1).

-type checkpoint() :: map().
-type task_key() :: term().

-doc("Starts Mnesia and ensures the durable checkpoint tables exist.").
-spec ensure_started() -> ok | {error, term()}.
ensure_started() ->
    case ensure_mnesia_started() of
        ok ->
            case create_tables() of
                ok ->
                    wait_for_tables();
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-doc("Creates an invocation checkpoint if it does not already exist.").
-spec create_invocation(term(), checkpoint()) ->
    {ok, created | existing} | {error, term()}.
create_invocation(AgentId, Checkpoint)
        when is_map(Checkpoint) ->
    case maps:find(invocation_id, Checkpoint) of
        {ok, InvocationId} ->
            Key = {AgentId, InvocationId},
            InitialCheckpoint = Checkpoint#{
                agent_id => AgentId,
                status => running,
                version => ?SCHEMA_VERSION,
                updated_at => erlang:system_time(millisecond)
            },
            transaction_create(
                ?INVOCATION_TABLE,
                Key,
                InitialCheckpoint
            );
        error ->
            {error, missing_invocation_id}
    end;
create_invocation(_AgentId, _Checkpoint) ->
    {error, invalid_checkpoint}.

-doc("Retrieves an invocation checkpoint by agent and invocation ID.").
-spec get_invocation(term(), term()) ->
    {ok, checkpoint()} | {error, term()}.
get_invocation(AgentId, InvocationId) ->
    transaction_get(
        ?INVOCATION_TABLE,
        {AgentId, InvocationId}
    ).

-doc("Persists an updated invocation checkpoint.").
-spec save_invocation(checkpoint()) -> ok | {error, term()}.
save_invocation(Checkpoint) when is_map(Checkpoint) ->
    case {maps:find(agent_id, Checkpoint),
          maps:find(invocation_id, Checkpoint)} of
        {{ok, AgentId}, {ok, InvocationId}} ->
            Key = {AgentId, InvocationId},
            UpdatedCheckpoint = Checkpoint#{
                version => ?SCHEMA_VERSION,
                updated_at => erlang:system_time(millisecond)
            },
            transaction_write(
                ?INVOCATION_TABLE,
                Key,
                UpdatedCheckpoint
            );
        _ ->
            {error, missing_checkpoint_identity}
    end;
save_invocation(_Checkpoint) ->
    {error, invalid_checkpoint}.

-doc("Retrieves a task checkpoint by its stable logical key.").
-spec get_task(task_key()) ->
    {ok, checkpoint()} | {error, term()}.
get_task(Key) ->
    transaction_get(?TASK_TABLE, Key).


-doc("Atomically claims a task or returns its persisted outcome.").
-spec claim_task(term(), map()) ->
    {ok, execute | {completed, term()}}
    | {error, task_execution_uncertain}
    | {error, term()}.
claim_task(Key, Metadata) when is_map(Metadata) ->
    Timestamp = erlang:system_time(millisecond),
    Transaction = fun() ->
        case mnesia:read(?TASK_TABLE, Key, write) of
            [] ->
                Checkpoint = Metadata#{
                    status => running,
                    started_at => Timestamp,
                    updated_at => Timestamp,
                    version => ?SCHEMA_VERSION
                },
                mnesia:write({
                    ?TASK_TABLE,
                    Key,
                    Checkpoint
                }),
                execute;
            [{?TASK_TABLE, Key, Checkpoint}] ->
                case maps:find(status, Checkpoint) of
                    {ok, completed} ->
                        case maps:find(result, Checkpoint) of
                            {ok, Result} ->
                                {completed, Result};
                            error ->
                                task_execution_uncertain
                        end;
                    _ ->
                        task_execution_uncertain
                end
        end
    end,
    ResultTrx = mnesia:sync_transaction(Transaction),
    mnesia:dump_log(),
    case ResultTrx of
        {atomic, execute} ->
            {ok, execute};
        {atomic, {completed, Result}} ->
            {ok, {completed, Result}};
        {atomic, task_execution_uncertain} ->
            {error, task_execution_uncertain};
        {aborted, Reason} ->
            {error, Reason}
    end;
claim_task(_Key, _Metadata) ->
    {error, invalid_metadata}.

-doc("Persists a completed task result before notifying other processes.").
-spec save_task_result(task_key(), term()) -> ok | {error, term()}.
save_task_result(Key, Result) ->
    Timestamp = erlang:system_time(millisecond),
    Transaction = fun() ->
        Existing = case mnesia:read(?TASK_TABLE, Key, write) of
            [{?TASK_TABLE, Key, Current}] ->
                Current;
            [] ->
                #{}
        end,
        Checkpoint = maps:merge(
            Existing,
            #{
                status => completed,
                result => Result,
                completed_at => Timestamp,
                updated_at => Timestamp,
                version => ?SCHEMA_VERSION
            }
        ),
        mnesia:write({
            ?TASK_TABLE,
            Key,
            Checkpoint
        })
    end,
    ResultTrx = transaction_result(mnesia:sync_transaction(Transaction)),
    mnesia:dump_log(),
    ResultTrx.

-doc("Retrieves the most recently updated running invocation for an agent.").
-spec get_active_invocation(term()) ->
    {ok, checkpoint()} | {error, term()}.
get_active_invocation(AgentId) ->
    Transaction = fun() ->
        mnesia:foldl(
            fun
                ({?INVOCATION_TABLE, {StoredAgentId, _InvocationId}, Checkpoint}, Acc)
                        when StoredAgentId =:= AgentId ->
                    case maps:get(status, Checkpoint, undefined) of
                        running ->
                            select_latest_invocation(Checkpoint, Acc);
                        _ ->
                            Acc
                    end;
                (_Record, Acc) ->
                    Acc
            end,
            none,
            ?INVOCATION_TABLE
        )
    end,
    case mnesia:transaction(Transaction) of
        {atomic, {ok, Checkpoint}} ->
            {ok, Checkpoint};
        {atomic, none} ->
            {error, not_found};
        {aborted, Reason} ->
            {error, Reason}
    end.

-doc("Classifies a persisted task without executing or modifying it.").
-spec inspect_task(task_key()) ->
    {ok, not_started | {completed, term()}}
    | {error, term()}.
inspect_task(Key) ->
    case get_task(Key) of
        {ok, Checkpoint} ->
            case maps:get(status, Checkpoint, undefined) of
                completed ->
                    case maps:find(result, Checkpoint) of
                        {ok, Result} ->
                            {ok, {completed, Result}};
                        error ->
                            {error, task_execution_uncertain}
                    end;
                running ->
                    {error, task_execution_uncertain};
                _Status ->
                    {error, task_execution_uncertain}
            end;
        {error, not_found} ->
            {ok, not_started};
        {error, Reason} ->
            {error, Reason}
    end.

%% Internal functions

-spec ensure_mnesia_started() -> ok | {error, term()}.
ensure_mnesia_started() ->
    case lists:keymember(
        mnesia,
        1,
        application:which_applications()
    ) of
        true ->
            ok;
        false ->
            case ensure_schema() of
                ok ->
                    case application:ensure_all_started(mnesia) of
                        {ok, _Started} -> ok;
                        {error, Reason} -> {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-spec ensure_schema() -> ok | {error, term()}.
ensure_schema() ->
    normalize_schema_result(mnesia:create_schema([node()])).

-spec normalize_schema_result(term()) -> ok | {error, term()}.
normalize_schema_result(ok) ->
    ok;
normalize_schema_result({error, {already_exists, _Node}}) ->
    ok;
normalize_schema_result({error, {_, {already_exists, _Node}}}) ->
    ok;
normalize_schema_result({error, Reason}) ->
    {error, Reason};
normalize_schema_result(Other) ->
    {error, Other}.

-spec select_latest_invocation(checkpoint(), term()) ->
    {ok, checkpoint()}.
select_latest_invocation(Checkpoint, none) ->
    {ok, Checkpoint};
select_latest_invocation(Checkpoint, {ok, Existing}) ->
    NewTimestamp = maps:get(updated_at, Checkpoint, 0),
    ExistingTimestamp = maps:get(updated_at, Existing, 0),
    case NewTimestamp > ExistingTimestamp of
        true ->
            {ok, Checkpoint};
        false ->
            {ok, Existing}
    end.

-spec create_tables() -> ok | {error, term()}.
create_tables() ->
    case create_table(
        ?INVOCATION_TABLE,
        record_info(fields, hayata_invocation_checkpoint)
    ) of
        ok ->
            create_table(
                ?TASK_TABLE,
                record_info(fields, hayata_task_checkpoint)
            );
        {error, Reason} ->
            {error, Reason}
    end.

-spec create_table(atom(), [atom()]) -> ok | {error, term()}.
create_table(Table, Attributes) ->
    Options = [
        {attributes, Attributes},
        {type, set},
        {disc_copies, [node()]}
    ],
    case mnesia:create_table(Table, Options) of
        {atomic, ok} ->
            ok;
        {aborted, {already_exists, Table}} ->
            ok;
        {aborted, Reason} ->
            {error, {table_creation_failed, Table, Reason}}
    end.

-spec wait_for_tables() -> ok | {error, term()}.
wait_for_tables() ->
    Tables = [?INVOCATION_TABLE, ?TASK_TABLE],
    case mnesia:wait_for_tables(Tables, 5000) of
        ok ->
            ok;
        {timeout, Remaining} ->
            {error, {table_wait_timeout, Remaining}};
        {error, Reason} ->
            {error, {table_wait_failed, Reason}}
    end.

-spec transaction_create(atom(), term(), checkpoint()) ->
    {ok, created | existing} | {error, term()}.
transaction_create(Table, Key, Checkpoint) ->
    Transaction = fun() ->
        case mnesia:read(Table, Key, write) of
            [] ->
                mnesia:write({Table, Key, Checkpoint}),
                created;
            [_Existing] ->
                existing
        end
    end,
    ResultTrx = mnesia:sync_transaction(Transaction),
    mnesia:dump_log(),
    case ResultTrx of
        {atomic, Outcome} ->
            {ok, Outcome};
        {aborted, Reason} ->
            {error, Reason}
    end.

-spec transaction_get(atom(), term()) ->
    {ok, checkpoint()} | {error, term()}.
transaction_get(Table, Key) ->
    Transaction = fun() ->
        mnesia:read(Table, Key, read)
    end,
    case mnesia:transaction(Transaction) of
        {atomic, [{Table, Key, Checkpoint}]} ->
            {ok, Checkpoint};
        {atomic, []} ->
            {error, not_found};
        {aborted, Reason} ->
            {error, Reason}
    end.

-spec transaction_write(atom(), term(), checkpoint()) ->
    ok | {error, term()}.
transaction_write(Table, Key, Checkpoint) ->
    Transaction = fun() ->
        mnesia:write({Table, Key, Checkpoint})
    end,
    ResultTrx = transaction_result(mnesia:sync_transaction(Transaction)),
    mnesia:dump_log(),
    ResultTrx.

-spec transaction_result(term()) -> ok | {error, term()}.
transaction_result({atomic, _Result}) ->
    ok;
transaction_result({aborted, Reason}) ->
    {error, Reason}.
