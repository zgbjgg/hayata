
-module(hayata_test_telemetry_tests).

-include_lib("eunit/include/eunit.hrl").

captures_and_detaches_handler_test() ->
    ok = hayata_test_telemetry:ensure_telemetry_started(),
    {ok, HandlerId} = hayata_test_telemetry:attach(),

    try
        Event = [hayata, agent, invocation, start],
        Measurements = #{system_time => erlang:system_time()},
        Metadata = #{
            agent_id => test_agent,
            invocation_id => make_ref()
        },

        telemetry:execute(Event, Measurements, Metadata),

        ?assertMatch(
            [{
                hayata_telemetry_event,
                Event,
                Measurements,
                Metadata
            }],
            hayata_test_telemetry:events()
        )
    after
        ok = hayata_test_telemetry:detach(HandlerId)
    end.
