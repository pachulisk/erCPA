-module(stream_keepalive).

%% Sends periodic keepalive signals during long streaming requests

-export([start/1, start/2, stop/1]).

-spec start(pid()) -> pid().
start(CallerPid) ->
    Interval = config_loader:get(keepalive_seconds, 30) * 1000,
    start(CallerPid, Interval).

-spec start(pid(), pos_integer()) -> pid().
start(CallerPid, Interval) ->
    spawn_link(fun() -> keepalive_loop(CallerPid, Interval) end).

-spec stop(pid()) -> ok.
stop(Pid) ->
    Pid ! stop,
    ok.

keepalive_loop(CallerPid, Interval) ->
    receive
        stop -> ok
    after Interval ->
        CallerPid ! {keepalive, <<": keepalive\n\n">>},
        keepalive_loop(CallerPid, Interval)
    end.
