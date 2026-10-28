
-module(hayata_tool_tests).

-include_lib("eunit/include/eunit.hrl").

validate_registry_accepts_valid_tools_test() ->
    ?assertEqual(
        ok,
        hayata_tool:validate_registry([weather_tool()])
    ).

validate_registry_rejects_empty_registry_test() ->
    ?assertEqual(
        {error, empty_registry},
        hayata_tool:validate_registry([])
    ).

validate_registry_rejects_missing_name_test() ->
    Tool = maps:remove(name, weather_tool()),

    ?assertEqual(
        {error, {invalid_tool, missing_name}},
        hayata_tool:validate_registry([Tool])
    ).

validate_registry_rejects_empty_name_test() ->
    Tool = (weather_tool())#{name => <<>>},

    ?assertEqual(
        {error, {invalid_tool, invalid_name}},
        hayata_tool:validate_registry([Tool])
    ).

validate_registry_rejects_missing_description_test() ->
    Tool = maps:remove(description, weather_tool()),

    ?assertEqual(
        {error, {invalid_tool, missing_description}},
        hayata_tool:validate_registry([Tool])
    ).

validate_registry_rejects_missing_parameters_test() ->
    Tool = maps:remove(parameters, weather_tool()),

    ?assertEqual(
        {error, {invalid_tool, missing_parameters}},
        hayata_tool:validate_registry([Tool])
    ).

validate_registry_rejects_missing_handler_test() ->
    Tool = maps:remove(handler, weather_tool()),

    ?assertEqual(
        {error, {invalid_tool, missing_handler}},
        hayata_tool:validate_registry([Tool])
    ).

validate_registry_rejects_invalid_handler_test() ->
    Tool = (weather_tool())#{handler => not_a_function},

    ?assertEqual(
        {error, {invalid_tool, invalid_handler}},
        hayata_tool:validate_registry([Tool])
    ).

validate_registry_rejects_duplicate_names_test() ->
    First = weather_tool(),
    Second = (weather_tool())#{
        description => <<"Another weather tool.">>
    },

    ?assertEqual(
        {error, {duplicate_tool_name, <<"get_weather">>}},
        hayata_tool:validate_registry([First, Second])
    ).

definitions_exclude_handler_test() ->
    {ok, Definitions} = hayata_tool:definitions([weather_tool()]),

    ?assertEqual(
        [
            #{
                name => <<"get_weather">>,
                description => <<"Gets the current weather for a city.">>,
                parameters => #{
                    type => object,
                    properties => #{
                        city => #{
                            type => string,
                            description => <<"City to look up.">>
                        }
                    },
                    required => [<<"city">>]
                }
            }
        ],
        Definitions
    ),

    [Definition] = Definitions,
    ?assertEqual(false, maps:is_key(handler, Definition)).

-spec weather_tool() -> map().
weather_tool() ->
    #{
        name => <<"get_weather">>,
        description => <<"Gets the current weather for a city.">>,
        parameters => #{
            type => object,
            properties => #{
                city => #{
                    type => string,
                    description => <<"City to look up.">>
                }
            },
            required => [<<"city">>]
        },
        handler => fun(_Arguments) ->
            {ok, #{temperature => 22}}
        end
    }.
