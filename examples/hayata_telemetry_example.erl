-module(hayata_telemetry_example).

-export([attach/0, detach/0, handle_event/4]).

-define(HANDLER_ID, {?MODULE, agent_invocations}).

attach() ->
    logger:set_primary_config(level, info),
    
    telemetry:attach_many(
        ?HANDLER_ID,
        [
            [hayata, agent, invocation, start],
            [hayata, agent, invocation, stop],
            [hayata, agent, invocation, exception],
            [hayata, node, execution, start],
            [hayata, node, execution, stop],
            [hayata, node, execution, exception],
            [hayata, edge, start],
            [hayata, edge, stop],
            [hayata, edge, exception],
            [hayata, reducer, start],
            [hayata, reducer, stop]
        ],
        fun ?MODULE:handle_event/4,
        #{}
    ).

detach() ->
    telemetry:detach(?HANDLER_ID).

handle_event(Event, Measurements, Metadata, _Config) ->
    logger:info(
        "Hayata telemetry event ~n~p",
        [
            #{
                event => Event,
                measurements => Measurements,
                metadata => Metadata
            }
        ]
    ).
