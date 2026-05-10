-module(thinking_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Thinking Module Tests (subset of T1-014/T1-015 matrix)
%% ============================================================

%% --- Suffix parsing ---

parse_suffix_basic_test() ->
    ?assertEqual({<<"model">>, <<"high">>}, thinking:parse_suffix(<<"model(high)">>)).

parse_suffix_budget_test() ->
    ?assertEqual({<<"model">>, <<"8192">>}, thinking:parse_suffix(<<"model(8192)">>)).

parse_suffix_no_suffix_test() ->
    ?assertEqual({<<"model-name">>, <<>>}, thinking:parse_suffix(<<"model-name">>)).

parse_suffix_empty_test() ->
    ?assertEqual({<<"m">>, <<>>}, thinking:parse_suffix(<<"m()">>)).

%% --- Budget clamping ---

clamp_budget_within_range_test() ->
    Config = #{min => 128, max => 20000, zero_allowed => false, dynamic_allowed => false},
    ?assertEqual(5000, thinking:clamp_budget(5000, 128, 20000, Config)).

clamp_budget_exceeds_max_test() ->
    Config = #{min => 128, max => 20000, zero_allowed => false, dynamic_allowed => false},
    ?assertEqual(20000, thinking:clamp_budget(99999, 128, 20000, Config)).

clamp_budget_below_min_test() ->
    Config = #{min => 128, max => 20000, zero_allowed => false, dynamic_allowed => false},
    ?assertEqual(128, thinking:clamp_budget(50, 128, 20000, Config)).

clamp_budget_zero_allowed_test() ->
    Config = #{min => 1024, max => 128000, zero_allowed => true, dynamic_allowed => false},
    ?assertEqual(0, thinking:clamp_budget(0, 1024, 128000, Config)).

clamp_budget_zero_not_allowed_test() ->
    Config = #{min => 128, max => 20000, zero_allowed => false, dynamic_allowed => false},
    ?assertEqual(128, thinking:clamp_budget(0, 128, 20000, Config)).

clamp_budget_dynamic_allowed_test() ->
    Config = #{min => 128, max => 20000, zero_allowed => false, dynamic_allowed => true},
    ?assertEqual(-1, thinking:clamp_budget(-1, 128, 20000, Config)).

clamp_budget_dynamic_not_allowed_test() ->
    Config = #{min => 1024, max => 128000, zero_allowed => false, dynamic_allowed => false},
    %% Should return midpoint
    ?assertEqual(64512, thinking:clamp_budget(-1, 1024, 128000, Config)).

%% --- Level to budget conversion ---

level_to_budget_high_test() ->
    Config = #{min => 128, max => 20000},
    ?assertEqual(20000, thinking:level_to_budget(<<"high">>, Config)).

level_to_budget_low_test() ->
    Config = #{min => 128, max => 20000},
    Expected = 128 + (20000 - 128) div 4,
    ?assertEqual(Expected, thinking:level_to_budget(<<"low">>, Config)).

level_to_budget_medium_test() ->
    Config = #{min => 128, max => 20000},
    ?assertEqual(10064, thinking:level_to_budget(<<"medium">>, Config)).

level_to_budget_none_zero_allowed_test() ->
    Config = #{min => 128, max => 20000, zero_allowed => true},
    ?assertEqual(0, thinking:level_to_budget(<<"none">>, Config)).

level_to_budget_none_not_allowed_test() ->
    Config = #{min => 128, max => 20000, zero_allowed => false},
    ?assertEqual(128, thinking:level_to_budget(<<"none">>, Config)).

%% --- Budget to level conversion ---

budget_to_level_zero_test() ->
    Config = #{min => 1024, max => 128000},
    ?assertEqual(<<"none">>, thinking:budget_to_level(0, Config)).

budget_to_level_low_test() ->
    Config = #{min => 1024, max => 128000},
    ?assertEqual(<<"low">>, thinking:budget_to_level(10000, Config)).

budget_to_level_high_test() ->
    Config = #{min => 1024, max => 128000},
    ?assertEqual(<<"high">>, thinking:budget_to_level(100000, Config)).

budget_to_level_dynamic_test() ->
    Config = #{min => 1024, max => 128000},
    ?assertEqual(<<"auto">>, thinking:budget_to_level(-1, Config)).

%% --- Apply thinking (integration) ---

apply_thinking_no_config_test() ->
    Body = #{<<"model">> => <<"test">>},
    Result = thinking:apply_thinking(Body, <<"test">>, <<"high">>, undefined, claude),
    ?assertEqual(Body, Result).

apply_thinking_no_suffix_test() ->
    Body = #{<<"model">> => <<"test">>},
    Config = #{thinking => #{levels => [<<"low">>, <<"high">>], min => 0, max => 0,
                             zero_allowed => false, dynamic_allowed => false}},
    Result = thinking:apply_thinking(Body, <<"test">>, <<>>, Config, claude),
    ?assertEqual(Body, Result).

apply_thinking_level_to_claude_test() ->
    Body = #{<<"model">> => <<"test">>},
    Config = #{thinking => #{levels => [<<"low">>, <<"medium">>, <<"high">>],
                             min => 0, max => 0,
                             zero_allowed => false, dynamic_allowed => false}},
    Result = thinking:apply_thinking(Body, <<"test">>, <<"high">>, Config, claude),
    ?assertEqual(<<"high">>, maps:get(<<"reasoning_effort">>, Result)).

apply_thinking_budget_to_gemini_test() ->
    Body = #{<<"model">> => <<"test">>, <<"generationConfig">> => #{}},
    Config = #{thinking => #{levels => [], min => 128, max => 20000,
                             zero_allowed => false, dynamic_allowed => true}},
    Result = thinking:apply_thinking(Body, <<"test">>, <<"8192">>, Config, gemini),
    GenConfig = maps:get(<<"generationConfig">>, Result),
    ThinkConfig = maps:get(<<"thinkingConfig">>, GenConfig),
    ?assertEqual(8192, maps:get(<<"thinkingBudget">>, ThinkConfig)),
    ?assertEqual(true, maps:get(<<"includeThoughts">>, ThinkConfig)).

apply_thinking_budget_zero_gemini_test() ->
    Body = #{<<"model">> => <<"test">>, <<"generationConfig">> => #{}},
    Config = #{thinking => #{levels => [], min => 128, max => 20000,
                             zero_allowed => true, dynamic_allowed => true}},
    Result = thinking:apply_thinking(Body, <<"test">>, <<"0">>, Config, gemini),
    GenConfig = maps:get(<<"generationConfig">>, Result),
    ThinkConfig = maps:get(<<"thinkingConfig">>, GenConfig),
    ?assertEqual(0, maps:get(<<"thinkingBudget">>, ThinkConfig)),
    ?assertEqual(false, maps:get(<<"includeThoughts">>, ThinkConfig)).
