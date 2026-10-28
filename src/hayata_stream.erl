-module(hayata_stream).

-export([flush/5]).

-doc("Sends a stream event to the invocation subscriber.").
-spec flush(pid(), reference(), atom(), pos_integer(), map()) -> ok.
flush(Subscriber, InvocationId, Type, Sequence, Data) ->
    Event = #{
        type => Type,
        sequence => Sequence,
        data => Data
    },
    Subscriber ! {hayata_agent_event, InvocationId, Event},
    ok.

