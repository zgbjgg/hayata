-module(hayata_tool).

-export([
    validate_registry/1,
    definitions/1
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
            validate_handler(Tool);
        {ok, _Parameters} ->
            {error, invalid_parameters}
    end.

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
