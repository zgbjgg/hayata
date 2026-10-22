-module(hayata_test_telemetry).

-export([
    attach/0,
    detach/1,
    events/0,
    clear/0,
    ensure_telemetry_started/0
]).

-define(EVENTS, [
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
    [hayata, reducer, stop],
    [hayata, reducer, exception]
]).

-spec attach() -> {ok, term()} | {error, term()}.
attach() ->
    HandlerId = {?MODULE, make_ref()},
    TestPid = self(),
    Handler = fun(Event, Measurements, Metadata, _Config) ->
        TestPid ! {
            hayata_telemetry_event,
            Event,
            Measurements,
            Metadata
        }
    end,

    case telemetry:attach_many(
        HandlerId,
        ?EVENTS,
        Handler,
        undefined
    ) of
        ok ->
            {ok, HandlerId};
        {error, Reason} ->
            {error, Reason}
    end.

-spec detach(term()) -> ok.
detach(HandlerId) ->
    telemetry:detach(HandlerId).

-spec events() -> [tuple()].
events() ->
    events([]).

-spec clear() -> [tuple()].
clear() ->
    events().

-spec events([tuple()]) -> [tuple()].
events(Acc) ->
    receive
        {
            hayata_telemetry_event,
            Event,
            Measurements,
            Metadata
        } = Message ->
            _ = {Event, Measurements, Metadata},
            events([Message | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

-spec ensure_telemetry_started() -> ok.
ensure_telemetry_started() ->
    case application:ensure_all_started(telemetry) of
        {ok, _Started} ->
            ok;
        {error, {already_started, telemetry}} ->
            ok
    end.
