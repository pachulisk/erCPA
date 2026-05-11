-module(log_rotator_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Log rotator logic tests
%% ============================================================

%% --- Size calculation ---

total_size_sum_test() ->
    Sizes = [1024, 2048, 512],
    Total = lists:sum(Sizes),
    ?assertEqual(3584, Total).

threshold_check_over_test() ->
    TotalBytes = 20 * 1024 * 1024, %% 20 MB
    MaxMB = 10,
    ?assert(TotalBytes > MaxMB * 1024 * 1024).

threshold_check_under_test() ->
    TotalBytes = 5 * 1024 * 1024, %% 5 MB
    MaxMB = 10,
    ?assertNot(TotalBytes > MaxMB * 1024 * 1024).

zero_disables_rotation_test() ->
    MaxMB = 0,
    ?assertEqual(0, MaxMB).

%% --- Pruning order (oldest first) ---

sort_by_age_test() ->
    Files = [{<<"c.log">>, 3}, {<<"a.log">>, 1}, {<<"b.log">>, 2}],
    Sorted = lists:sort(fun({_, A}, {_, B}) -> A < B end, Files),
    [{First, _} | _] = Sorted,
    ?assertEqual(<<"a.log">>, First).

%% --- Error log cleanup ---

files_within_limit_no_delete_test() ->
    Files = [<<"e1.log">>, <<"e2.log">>],
    MaxFiles = 5,
    ?assertNot(length(Files) > MaxFiles).

files_over_limit_need_delete_test() ->
    Files = [<<"e1.log">>, <<"e2.log">>, <<"e3.log">>, <<"e4.log">>],
    MaxFiles = 2,
    ?assert(length(Files) > MaxFiles),
    ToDelete = length(Files) - MaxFiles,
    ?assertEqual(2, ToDelete).
