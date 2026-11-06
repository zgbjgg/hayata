
-module(hayata_rag).

-export([
    new/1,
    validate_config/1,
    validate_result/1
]).

-export_type([
    config/0,
    document/0,
    options/0,
    result/0,
    retriever/0
]).

-type options() :: map().

-type document() :: #{
    id := binary(),
    content := binary(),
    metadata := map(),
    score => number()
}.

-type result() ::
    {ok, #{documents := [document()]}} |
    {error, term()}.

-type retriever() ::
    fun((binary(), options()) -> term()) |
    {module(), atom()}.

-type config() :: #{
    retrieve := retriever()
}.

-type rag_function() :: fun((binary(), options()) -> result()).

-doc("Creates a RAG retrieval function from the supplied retriever configuration.").
-spec new(term()) -> {ok, rag_function()} | {error, invalid_config}.
new(Config) ->
    case validate_config(Config) of
        ok ->
            Retrieve = maps:get(retrieve, Config),
            Rag = fun(Query, Options) ->
                run_retriever(Retrieve, Query, Options)
            end,
            {ok, Rag};
        {error, _Reason} ->
            {error, invalid_config}
    end.

-doc("Validates a RAG retriever configuration.").
-spec validate_config(term()) -> ok | {error, invalid_config}.
validate_config(#{retrieve := Retrieve}) ->
    case validate_retriever(Retrieve) of
        ok ->
            ok;
        {error, _Reason} ->
            {error, invalid_config}
    end;
validate_config(_Config) ->
    {error, invalid_config}.

-doc("Validates and normalizes a retriever result.").
-spec validate_result(term()) -> result().
validate_result({ok, #{documents := Documents}})
        when is_list(Documents) ->
    case validate_documents(Documents) of
        ok ->
            {ok, #{documents => Documents}};
        {error, _Reason} ->
            {error, #{code => invalid_response}}
    end;
validate_result({error, _Reason} = Error) ->
    Error;
validate_result(_Result) ->
    {error, #{code => invalid_response}}.

-spec validate_retriever(term()) -> ok | {error, invalid_retriever}.
validate_retriever(Retrieve) when is_function(Retrieve, 2) ->
    ok;
validate_retriever({Module, Function})
        when is_atom(Module), is_atom(Function) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, Function, 2) of
                true ->
                    ok;
                false ->
                    {error, invalid_retriever}
            end;
        {error, _Reason} ->
            {error, invalid_retriever}
    end;
validate_retriever(_Retrieve) ->
    {error, invalid_retriever}.

-spec run_retriever(term(), term(), term()) -> result().
run_retriever(Retrieve, Query, Options)
        when is_binary(Query), byte_size(Query) > 0,
             is_map(Options) ->
    try invoke_retriever(Retrieve, Query, Options) of
        Result ->
            validate_result(Result)
    catch
        _Class:_Reason ->
            {error, #{
                code => provider_error,
                reason => retriever_call_failed
            }}
    end;
run_retriever(_Retrieve, _Query, _Options) ->
    {error, #{code => invalid_request}}.

-spec invoke_retriever(term(), binary(), options()) -> term().
invoke_retriever(Retrieve, Query, Options)
        when is_function(Retrieve, 2) ->
    Retrieve(Query, Options);
invoke_retriever({Module, Function}, Query, Options) ->
    apply(Module, Function, [Query, Options]).

-spec validate_documents([term()]) -> ok | {error, invalid_documents}.
validate_documents([Document | Rest]) ->
    case validate_document(Document) of
        ok ->
            validate_documents(Rest);
        {error, _Reason} ->
            {error, invalid_documents}
    end;
validate_documents([]) ->
    ok.

-spec validate_document(term()) -> ok | {error, invalid_document}.
validate_document(#{
    id := Id,
    content := Content,
    metadata := Metadata
} = Document)
        when is_binary(Id), byte_size(Id) > 0,
             is_binary(Content),
             is_map(Metadata) ->
    case maps:find(score, Document) of
        error ->
            ok;
        {ok, Score} when is_number(Score) ->
            ok;
        {ok, _Score} ->
            {error, invalid_document}
    end;
validate_document(_Document) ->
    {error, invalid_document}.
