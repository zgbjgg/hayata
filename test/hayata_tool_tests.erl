
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

resolve_finds_tool_by_name_test() ->
    {ok, Tool} = hayata_tool:resolve(
        <<"get_weather">>,
        [weather_tool()]
    ),

    ?assertEqual(<<"get_weather">>, maps:get(name, Tool)).

resolve_rejects_unknown_tool_test() ->
    ?assertEqual(
        {error, {unknown_tool, <<"get_forecast">>}},
        hayata_tool:resolve(
            <<"get_forecast">>,
            [weather_tool()]
        )
    ).

execute_returns_handler_result_test() ->
    ?assertEqual(
        {ok, #{temperature => 22}},
        hayata_tool:execute(
            <<"get_weather">>,
            #{city => <<"Mexico City">>},
            [weather_tool()]
        )
    ).

execute_rejects_missing_required_argument_test() ->
    ?assertEqual(
        {error, {invalid_arguments, {missing_required, <<"city">>}}},
        hayata_tool:execute(
            <<"get_weather">>,
            #{},
            [weather_tool()]
        )
    ).

execute_rejects_unknown_argument_test() ->
    ?assertEqual(
        {error, {invalid_arguments, {unknown_property, <<"country">>}}},
        hayata_tool:execute(
            <<"get_weather">>,
            #{
                city => <<"Mexico City">>,
                country => <<"Mexico">>
            },
            [weather_tool()]
        )
    ).

execute_rejects_wrong_argument_type_test() ->
    ?assertEqual(
        {error, {invalid_arguments, {invalid_type, <<"city">>, string}}},
        hayata_tool:execute(
            <<"get_weather">>,
            #{city => 123},
            [weather_tool()]
        )
    ).

execute_normalizes_handler_exception_test() ->
    Tool = (weather_tool())#{
        handler => fun(_Arguments) ->
            erlang:error(weather_service_failed)
        end
    },

    ?assertEqual(
        {error, {handler_failed, <<"get_weather">>}},
        hayata_tool:execute(
            <<"get_weather">>,
            #{city => <<"Mexico City">>},
            [Tool]
        )
    ).


validate_registry_rejects_invalid_parameter_type_test() ->
    Tool = (weather_tool())#{
        parameters => #{
            type => object,
            properties => #{
                city => #{type => unsupported_type}
            }
        }
    },

    ?assertEqual(
        {error, {invalid_tool, invalid_property_schema}},
        hayata_tool:validate_registry([Tool])
    ).

validate_registry_rejects_invalid_parameter_root_test() ->
    Tool = (weather_tool())#{
        parameters => #{
            type => string,
            properties => #{}
        }
    },

    ?assertEqual(
        {error, {invalid_tool, invalid_parameters_schema}},
        hayata_tool:validate_registry([Tool])
    ).

validate_registry_rejects_invalid_properties_test() ->
    Tool = (weather_tool())#{
        parameters => #{
            type => object,
            properties => []
        }
    },

    ?assertEqual(
        {error, {invalid_tool, invalid_parameters_schema}},
        hayata_tool:validate_registry([Tool])
    ).

validate_registry_rejects_unknown_required_property_test() ->
    Tool = (weather_tool())#{
        parameters => #{
            type => object,
            properties => #{
                city => #{type => string}
            },
            required => [<<"country">>]
        }
    },

    ?assertEqual(
        {error, {
            invalid_tool,
            {unknown_required_property, <<"country">>}
        }},
        hayata_tool:validate_registry([Tool])
    ).

validate_registry_rejects_invalid_required_list_test() ->
    Tool = (weather_tool())#{
        parameters => #{
            type => object,
            properties => #{
                city => #{type => string}
            },
            required => <<"city">>
        }
    },

    ?assertEqual(
        {error, {invalid_tool, invalid_required_properties}},
        hayata_tool:validate_registry([Tool])
    ).

validate_registry_rejects_duplicate_required_property_test() ->
    Tool = (weather_tool())#{
        parameters => #{
            type => object,
            properties => #{
                city => #{type => string}
            },
            required => [<<"city">>, city]
        }
    },

    ?assertEqual(
        {error, {
            invalid_tool,
            {duplicate_required_property, <<"city">>}
        }},
        hayata_tool:validate_registry([Tool])
    ).

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
