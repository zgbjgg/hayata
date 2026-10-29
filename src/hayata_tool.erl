
-module(hayata_tool).

-export([
    validate_registry/1,
    definitions/1,
    resolve/2,
    execute/3
]).

-doc("Validates a registry of tools and rejects invalid or duplicate definitions.").
-spec validate_registry(term()) -> ok | {error, term()}.
validate_registry([]) ->
    {error, empty_registry};
validate_registry(Tools) when is_list(Tools) ->
    validate_tools(Tools, []);
validate_registry(_Tools) ->
    {error, invalid_registry}.

-doc("Returns the validated tool definitions without their handlers.").
-spec definitions(term()) -> {ok, [map()]} | {error, term()}.
definitions(Tools) ->
    case validate_registry(Tools) of
        ok ->
            {ok, [tool_definition(Tool) || Tool <- Tools]};
        {error, Reason} ->
            {error, Reason}
    end.

-doc("Resolves a tool by name from a validated registry.").
-spec resolve(binary(), term()) -> {ok, map()} | {error, term()}.
resolve(Name, Tools) when is_binary(Name), byte_size(Name) > 0 ->
    case validate_registry(Tools) of
        ok ->
            resolve_tool(Name, Tools);
        {error, Reason} ->
            {error, Reason}
    end;
resolve(_Name, _Tools) ->
    {error, invalid_tool_name}.

-doc("Validates arguments and executes the selected tool handler.").
-spec execute(binary(), term(), term()) -> term().
execute(Name, Arguments, Tools) ->
    case resolve(Name, Tools) of
        {ok, Tool} ->
            case validate_arguments(Arguments, maps:get(parameters, Tool)) of
                ok ->
                    execute_handler(Name, Arguments, maps:get(handler, Tool));
                {error, Reason} ->
                    {error, {invalid_arguments, Reason}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec resolve_tool(binary(), [map()]) -> {ok, map()} | {error, term()}.
resolve_tool(Name, [Tool | Rest]) ->
    case maps:get(name, Tool) of
        Name ->
            {ok, Tool};
        _Other ->
            resolve_tool(Name, Rest)
    end;
resolve_tool(Name, []) ->
    {error, {unknown_tool, Name}}.

-spec execute_handler(binary(), map(), function()) -> term().
execute_handler(Name, Arguments, Handler) ->
    try Handler(Arguments) of
        Result ->
            Result
    catch
        _Class:_Reason ->
            {error, {handler_failed, Name}}
    end.

-spec validate_arguments(term(), map()) -> ok | {error, term()}.
validate_arguments(Arguments, Schema) when is_map(Arguments) ->
    case maps:get(type, Schema, undefined) of
        object ->
            case maps:get(properties, Schema, undefined) of
                Properties when is_map(Properties) ->
                    case validate_required(
                        Arguments,
                        maps:get(required, Schema, [])
                    ) of
                        ok ->
                            case validate_known_arguments(
                                maps:to_list(Arguments),
                                Properties
                            ) of
                                ok ->
                                    validate_argument_types(
                                        maps:to_list(Arguments),
                                        Properties
                                    );
                                {error, Reason} ->
                                    {error, Reason}
                            end;
                        {error, Reason} ->
                            {error, Reason}
                    end;
                _Other ->
                    {error, invalid_schema}
            end;
        _Other ->
            {error, invalid_schema}
    end;
validate_arguments(_Arguments, _Schema) ->
    {error, expected_object}.

-spec validate_required(map(), term()) -> ok | {error, term()}.
validate_required(_Arguments, Required) when not is_list(Required) ->
    {error, invalid_schema};
validate_required(Arguments, [Name | Rest]) ->
    case normalize_key(Name) of
        {ok, NormalizedName} ->
            case find_key(NormalizedName, Arguments) of
                {ok, _Value} ->
                    validate_required(Arguments, Rest);
                error ->
                    {error, {missing_required, NormalizedName}}
            end;
        error ->
            {error, invalid_schema}
    end;
validate_required(_Arguments, []) ->
    ok.

-spec validate_known_arguments([{term(), term()}], map()) ->
    ok | {error, term()}.
validate_known_arguments([{Key, _Value} | Rest], Properties) ->
    case normalize_key(Key) of
        {ok, NormalizedKey} ->
            case find_key(NormalizedKey, Properties) of
                {ok, _PropertySchema} ->
                    validate_known_arguments(Rest, Properties);
                error ->
                    {error, {unknown_property, NormalizedKey}}
            end;
        error ->
            {error, invalid_property_name}
    end;
validate_known_arguments([], _Properties) ->
    ok.

-spec validate_argument_types([{term(), term()}], map()) ->
    ok | {error, term()}.
validate_argument_types([{Key, Value} | Rest], Properties) ->
    case normalize_key(Key) of
        {ok, NormalizedKey} ->
            case find_key(NormalizedKey, Properties) of
                {ok, PropertySchema} when is_map(PropertySchema) ->
                    ExpectedType = maps:get(type, PropertySchema, undefined),
                    case validate_argument_type(
                        NormalizedKey,
                        Value,
                        ExpectedType
                    ) of
                        ok ->
                            validate_argument_types(Rest, Properties);
                        {error, Reason} ->
                            {error, Reason}
                    end;
                _Other ->
                    {error, invalid_schema}
            end;
        error ->
            {error, invalid_property_name}
    end;
validate_argument_types([], _Properties) ->
    ok.

-spec validate_argument_type(binary(), term(), term()) ->
    ok | {error, term()}.
validate_argument_type(_Name, Value, string) when is_binary(Value) ->
    ok;
validate_argument_type(_Name, Value, number) when is_number(Value) ->
    ok;
validate_argument_type(_Name, Value, integer) when is_integer(Value) ->
    ok;
validate_argument_type(_Name, Value, boolean) when is_boolean(Value) ->
    ok;
validate_argument_type(_Name, Value, object) when is_map(Value) ->
    ok;
validate_argument_type(_Name, _Value, Type)
        when Type =:= string;
             Type =:= number;
             Type =:= integer;
             Type =:= boolean;
             Type =:= object ->
    {error, {invalid_type, _Name, Type}};
validate_argument_type(_Name, _Value, _Type) ->
    {error, invalid_schema}.

-spec find_key(binary(), map()) -> {ok, term()} | error.
find_key(Name, Map) ->
    find_key_in_list(Name, maps:to_list(Map)).

-spec find_key_in_list(binary(), [{term(), term()}]) ->
    {ok, term()} | error.
find_key_in_list(Name, [{Key, Value} | Rest]) ->
    case normalize_key(Key) of
        {ok, Name} ->
            {ok, Value};
        _Other ->
            find_key_in_list(Name, Rest)
    end;
find_key_in_list(_Name, []) ->
    error.

-spec normalize_key(term()) -> {ok, binary()} | error.
normalize_key(Key) when is_binary(Key), byte_size(Key) > 0 ->
    {ok, Key};
normalize_key(Key) when is_atom(Key) ->
    {ok, atom_to_binary(Key, utf8)};
normalize_key(_Key) ->
    error.

-spec validate_tools([term()], [binary()]) -> ok | {error, term()}.
validate_tools([], _Names) ->
    ok;
validate_tools([Tool | Rest], Names) when is_map(Tool) ->
    case validate_tool(Tool) of
        ok ->
            Name = maps:get(name, Tool),
            case lists:member(Name, Names) of
                true ->
                    {error, {duplicate_tool_name, Name}};
                false ->
                    validate_tools(Rest, [Name | Names])
            end;
        {error, Reason} ->
            {error, {invalid_tool, Reason}}
    end;
validate_tools([_Tool | _Rest], _Names) ->
    {error, {invalid_tool, invalid_definition}}.

-spec validate_tool(map()) -> ok | {error, term()}.
validate_tool(Tool) ->
    case maps:find(name, Tool) of
        error ->
            {error, missing_name};
        {ok, Name} ->
            case validate_name(Name) of
                ok ->
                    validate_description(Tool);
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-spec validate_name(term()) -> ok | {error, invalid_name}.
validate_name(Name) when is_binary(Name), byte_size(Name) > 0 ->
    ok;
validate_name(_Name) ->
    {error, invalid_name}.

-spec validate_description(map()) -> ok | {error, term()}.
validate_description(Tool) ->
    case maps:find(description, Tool) of
        error ->
            {error, missing_description};
        {ok, Description}
                when is_binary(Description),
                     byte_size(Description) > 0 ->
            validate_parameters(Tool);
        {ok, _Description} ->
            {error, invalid_description}
    end.

-spec validate_parameters(map()) -> ok | {error, term()}.
validate_parameters(Tool) ->
    case maps:find(parameters, Tool) of
        error ->
            {error, missing_parameters};
        {ok, Parameters} when is_map(Parameters) ->
            case validate_parameter_schema(Parameters) of
                ok ->
                    validate_handler(Tool);
                {error, Reason} ->
                    {error, Reason}
            end;
        {ok, _Parameters} ->
            {error, invalid_parameters}
    end.

-spec validate_parameter_schema(map()) -> ok | {error, term()}.
validate_parameter_schema(#{type := object, properties := Properties} = Schema)
        when is_map(Properties) ->
    case validate_properties(maps:to_list(Properties)) of
        ok ->
            validate_required_schema(
                maps:get(required, Schema, []),
                Properties
            );
        {error, Reason} ->
            {error, Reason}
    end;
validate_parameter_schema(_Schema) ->
    {error, invalid_parameters_schema}.


-spec validate_properties([{term(), term()}]) -> ok | {error, term()}.
validate_properties(Properties) ->
    validate_properties(Properties, []).

-spec validate_properties(
    [{term(), term()}],
    [binary()]
) -> ok | {error, term()}.
validate_properties([{Name, Schema} | Rest], Seen) when is_map(Schema) ->
    case normalize_key(Name) of
        {ok, NormalizedName} ->
            case lists:member(NormalizedName, Seen) of
                true ->
                    {error, {duplicate_property, NormalizedName}};
                false ->
                    case maps:get(type, Schema, undefined) of
                        Type
                                when Type =:= string;
                                     Type =:= number;
                                     Type =:= integer;
                                     Type =:= boolean;
                                     Type =:= object ->
                            validate_properties(
                                Rest,
                                [NormalizedName | Seen]
                            );
                        _Other ->
                            {error, invalid_property_schema}
                    end
            end;
        error ->
            {error, invalid_property_name}
    end;
validate_properties([{_Name, _Schema} | _Rest], _Seen) ->
    {error, invalid_property_schema};
validate_properties([], _Seen) ->
    ok.

-spec validate_required_schema(term(), map()) -> ok | {error, term()}.
validate_required_schema(Required, Properties) when is_list(Required) ->
    validate_required_properties(Required, Properties, []);
validate_required_schema(_Required, _Properties) ->
    {error, invalid_required_properties}.

-spec validate_required_properties(
    [term()],
    map(),
    [binary()]
) -> ok | {error, term()}.
validate_required_properties([Name | Rest], Properties, Seen) ->
    case normalize_key(Name) of
        {ok, NormalizedName} ->
            case lists:member(NormalizedName, Seen) of
                true ->
                    {error, {duplicate_required_property, NormalizedName}};
                false ->
                    case find_key(NormalizedName, Properties) of
                        {ok, _PropertySchema} ->
                            validate_required_properties(
                                Rest,
                                Properties,
                                [NormalizedName | Seen]
                            );
                        error ->
                            {error, {unknown_required_property, NormalizedName}}
                    end
            end;
        error ->
            {error, invalid_required_property}
    end;
validate_required_properties([], _Properties, _Seen) ->
    ok.

-spec validate_handler(map()) -> ok | {error, term()}.
validate_handler(Tool) ->
    case maps:find(handler, Tool) of
        error ->
            {error, missing_handler};
        {ok, Handler} when is_function(Handler, 1) ->
            ok;
        {ok, _Handler} ->
            {error, invalid_handler}
    end.

-spec tool_definition(map()) -> map().
tool_definition(Tool) ->
    maps:with(
        [name, description, parameters],
        Tool
    ).
