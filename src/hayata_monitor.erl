-module(hayata_monitor).

-export([start/2]).

-doc("Start monitor node and edge processes to check if terminate.").
-spec start(pid(), pid()) -> ok.
start(NodePid, EdgePid) ->
    spawn(fun() -> monitor_processes(NodePid, EdgePid) end),
    ok.

-spec monitor_processes(pid(), pid()) -> ok.
monitor_processes(NodePid, EdgePid) ->
    NodeMonitor = erlang:monitor(process, NodePid),
    EdgeMonitor = erlang:monitor(process, EdgePid),

    receive
        {'DOWN', NodeMonitor, process, NodePid, _Reason} ->
            exit(EdgePid, kill),
            ok;

        {'DOWN', EdgeMonitor, process, EdgePid, _Reason} ->
            erlang:demonitor(NodeMonitor, [flush]),
            ok
    end.
