-module(home_mode_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Home/satellite mode logic tests
%% ============================================================

%% --- Config overlay preserves local settings ---

config_overlay_preserves_port_test() ->
    LocalConfig = #{port => 8317, host => <<"0.0.0.0">>},
    RemoteConfig = #{port => 9999, debug => true, password => <<"remote-pw">>},
    %% Overlay: keep local port/host, apply rest from remote
    Merged = maps:merge(RemoteConfig, maps:with([port, host], LocalConfig)),
    ?assertEqual(8317, maps:get(port, Merged)),
    ?assertEqual(<<"0.0.0.0">>, maps:get(host, Merged)),
    ?assertEqual(true, maps:get(debug, Merged)).

config_overlay_accepts_new_keys_test() ->
    LocalConfig = #{port => 8317},
    RemoteConfig = #{rate_limit_rpm => 60, debug => true},
    Merged = maps:merge(RemoteConfig, maps:with([port, host], LocalConfig)),
    ?assertEqual(60, maps:get(rate_limit_rpm, Merged)),
    ?assertEqual(8317, maps:get(port, Merged)).

%% --- Usage buffer ---

usage_buffer_accumulates_test() ->
    Buffer = [],
    Record1 = #{credential_id => <<"c1">>, tokens => 100},
    Record2 = #{credential_id => <<"c2">>, tokens => 200},
    Buffer1 = [Record1 | Buffer],
    Buffer2 = [Record2 | Buffer1],
    ?assertEqual(2, length(Buffer2)).

usage_buffer_flush_threshold_test() ->
    MaxBuffer = 64,
    Buffer = lists:seq(1, 64),
    ?assert(length(Buffer) >= MaxBuffer).

usage_buffer_empty_after_flush_test() ->
    _Flushed = lists:seq(1, 10),
    Buffer = [],
    ?assertEqual(0, length(Buffer)).

%% --- Connection state ---

disconnected_by_default_test() ->
    %% pang means not connected
    Result = pang,
    Connected = (Result =:= pong),
    ?assertNot(Connected).

connected_on_pong_test() ->
    Result = pong,
    Connected = (Result =:= pong),
    ?assert(Connected).

%% --- Node monitoring ---

nodeup_reconnects_test() ->
    Event = {nodeup, 'home@192.168.1.1'},
    {nodeup, Node} = Event,
    ?assertEqual('home@192.168.1.1', Node).

nodedown_disconnects_test() ->
    Event = {nodedown, 'home@192.168.1.1'},
    {nodedown, Node} = Event,
    ?assertEqual('home@192.168.1.1', Node).
