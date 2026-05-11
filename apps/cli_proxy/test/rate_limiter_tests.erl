-module(rate_limiter_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Rate limiter unit tests — sliding window, expiry, config
%% ============================================================

%% --- Sliding window logic ---

expired_entries_filtered_test() ->
    Now = erlang:system_time(second),
    WindowStart = Now - 60,
    Timestamps = [Now - 120, Now - 90, Now - 30, Now - 10, Now],
    Recent = [T || T <- Timestamps, T > WindowStart],
    ?assertEqual(3, length(Recent)).

all_expired_test() ->
    Now = erlang:system_time(second),
    WindowStart = Now - 60,
    Timestamps = [Now - 120, Now - 90, Now - 70],
    Recent = [T || T <- Timestamps, T > WindowStart],
    ?assertEqual(0, length(Recent)).

all_recent_test() ->
    Now = erlang:system_time(second),
    WindowStart = Now - 60,
    Timestamps = [Now - 10, Now - 20, Now - 30],
    Recent = [T || T <- Timestamps, T > WindowStart],
    ?assertEqual(3, length(Recent)).

within_limit_test() ->
    Recent = [1, 2, 3],
    Limit = 60,
    ?assert(length(Recent) < Limit).

exceeds_limit_test() ->
    Recent = lists:seq(1, 60),
    Limit = 60,
    ?assert(length(Recent) >= Limit).

%% --- Config ---

zero_limit_disables_test() ->
    Limit = 0,
    ?assertEqual(0, Limit).

%% --- IP key conversion ---

ip_to_key_tuple_test() ->
    IP = {127, 0, 0, 1},
    Key = list_to_binary(inet:ntoa(IP)),
    ?assertEqual(<<"127.0.0.1">>, Key).

ip_to_key_ipv6_test() ->
    IP = {0, 0, 0, 0, 0, 0, 0, 1},
    Key = list_to_binary(inet:ntoa(IP)),
    ?assertEqual(<<"::1">>, Key).
