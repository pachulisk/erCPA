-module(claude_code_compat_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Claude Code Compatibility Sentinel Tests
%% Ported from test/claude_code_compatibility_sentinel_test.go
%%
%% These validate the JSON shape of Claude Code sentinel messages
%% to ensure proxy translation preserves required fields.
%% ============================================================

fixtures_dir() ->
    filename:join([code:priv_dir(cli_proxy), "..", "test", "fixtures",
                   "claude_code_sentinels"]).

read_fixture(Name) ->
    Path = filename:join(fixtures_dir(), Name),
    {ok, Bin} = file:read_file(Path),
    jiffy:decode(Bin, [return_maps]).

%% T2-007: Claude Code sentinel shape tests

tool_progress_shape_test() ->
    Msg = read_fixture("tool_progress.json"),
    ?assert(maps:is_key(<<"type">>, Msg)),
    ?assert(maps:is_key(<<"tool_use_id">>, Msg)),
    ?assert(maps:is_key(<<"tool_name">>, Msg)),
    ?assert(maps:is_key(<<"session_id">>, Msg)),
    ?assert(maps:is_key(<<"elapsed_time_seconds">>, Msg)),
    ?assertEqual(<<"tool_progress">>, maps:get(<<"type">>, Msg)).

session_state_shape_test() ->
    Msg = read_fixture("session_state_changed.json"),
    ?assertEqual(<<"system">>, maps:get(<<"type">>, Msg)),
    ?assertEqual(<<"session_state_changed">>, maps:get(<<"subtype">>, Msg)),
    State = maps:get(<<"state">>, Msg),
    ?assert(lists:member(State, [<<"idle">>, <<"running">>, <<"requires_action">>])).

tool_use_summary_shape_test() ->
    Msg = read_fixture("tool_use_summary.json"),
    ?assert(maps:is_key(<<"type">>, Msg)),
    ?assert(maps:is_key(<<"summary">>, Msg)),
    Ids = maps:get(<<"preceding_tool_use_ids">>, Msg),
    ?assert(is_list(Ids)).

control_request_can_use_tool_shape_test() ->
    Msg = read_fixture("control_request_can_use_tool.json"),
    ?assertEqual(<<"control_request">>, maps:get(<<"type">>, Msg)),
    ?assert(maps:is_key(<<"request_id">>, Msg)),
    Request = maps:get(<<"request">>, Msg),
    ?assert(maps:is_key(<<"subtype">>, Request)),
    ?assert(maps:is_key(<<"tool_name">>, Request)),
    ?assert(maps:is_key(<<"tool_use_id">>, Request)),
    ?assert(maps:is_key(<<"input">>, Request)).
