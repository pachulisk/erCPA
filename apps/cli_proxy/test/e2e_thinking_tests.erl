-module(e2e_thinking_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% E2E-006: Thinking suffix normalization end-to-end
%% Tests the full thinking pipeline: suffix → parse → clamp → apply
%% ============================================================

%% Claude budget model with suffix

claude_budget_suffix_pipeline_test() ->
    Model = <<"claude-budget-model(8192)">>,
    {Base, Suffix} = thinking:parse_suffix(Model),
    ?assertEqual(<<"claude-budget-model">>, Base),
    ?assertEqual(<<"8192">>, Suffix),
    ModelDef = thinking_test_models:get(Base),
    Body = #{<<"model">> => Base, <<"messages">> => []},
    Result = thinking:apply_thinking(Body, Base, Suffix, ModelDef, claude),
    Thinking = maps:get(<<"thinking">>, Result),
    ?assertEqual(<<"enabled">>, maps:get(<<"type">>, Thinking)),
    ?assertEqual(8192, maps:get(<<"budget_tokens">>, Thinking)).

%% Claude budget model — over max clamped

claude_budget_over_max_test() ->
    Model = <<"claude-budget-model(999999)">>,
    {Base, Suffix} = thinking:parse_suffix(Model),
    ModelDef = thinking_test_models:get(Base),
    Body = #{<<"model">> => Base},
    Result = thinking:apply_thinking(Body, Base, Suffix, ModelDef, claude),
    Thinking = maps:get(<<"thinking">>, Result),
    ?assertEqual(128000, maps:get(<<"budget_tokens">>, Thinking)).

%% Claude budget model — zero allowed

claude_budget_zero_test() ->
    Model = <<"claude-budget-model(0)">>,
    {Base, Suffix} = thinking:parse_suffix(Model),
    ModelDef = thinking_test_models:get(Base),
    Body = #{<<"model">> => Base},
    Result = thinking:apply_thinking(Body, Base, Suffix, ModelDef, claude),
    Thinking = maps:get(<<"thinking">>, Result),
    ?assertEqual(0, maps:get(<<"budget_tokens">>, Thinking)).

%% Level model with level suffix → claude

level_to_claude_test() ->
    Model = <<"level-model(high)">>,
    {Base, Suffix} = thinking:parse_suffix(Model),
    ModelDef = thinking_test_models:get(Base),
    Body = #{<<"model">> => Base},
    Result = thinking:apply_thinking(Body, Base, Suffix, ModelDef, claude),
    ?assertEqual(<<"high">>, maps:get(<<"reasoning_effort">>, Result)).

%% Level model — none → clamp to minimal (ZeroAllowed=false)

level_none_clamps_to_minimal_test() ->
    Model = <<"level-model(none)">>,
    {Base, Suffix} = thinking:parse_suffix(Model),
    ModelDef = thinking_test_models:get(Base),
    Body = #{<<"model">> => Base},
    Result = thinking:apply_thinking(Body, Base, Suffix, ModelDef, claude),
    ?assertEqual(<<"minimal">>, maps:get(<<"reasoning_effort">>, Result)).

%% Gemini budget model with suffix → gemini format

gemini_budget_suffix_test() ->
    Model = <<"gemini-budget-model(5000)">>,
    {Base, Suffix} = thinking:parse_suffix(Model),
    ModelDef = thinking_test_models:get(Base),
    Body = #{<<"model">> => Base, <<"generationConfig">> => #{}},
    Result = thinking:apply_thinking(Body, Base, Suffix, ModelDef, gemini),
    GenConfig = maps:get(<<"generationConfig">>, Result),
    ThinkConfig = maps:get(<<"thinkingConfig">>, GenConfig),
    ?assertEqual(5000, maps:get(<<"thinkingBudget">>, ThinkConfig)),
    ?assertEqual(true, maps:get(<<"includeThoughts">>, ThinkConfig)).

%% Gemini budget model — below min clamped

gemini_budget_below_min_test() ->
    Model = <<"gemini-budget-model(50)">>,
    {Base, Suffix} = thinking:parse_suffix(Model),
    ModelDef = thinking_test_models:get(Base),
    Body = #{<<"model">> => Base, <<"generationConfig">> => #{}},
    Result = thinking:apply_thinking(Body, Base, Suffix, ModelDef, gemini),
    GenConfig = maps:get(<<"generationConfig">>, Result),
    ThinkConfig = maps:get(<<"thinkingConfig">>, GenConfig),
    ?assertEqual(128, maps:get(<<"thinkingBudget">>, ThinkConfig)).

%% Antigravity budget model — zero → includeThoughts=false

antigravity_budget_zero_test() ->
    Model = <<"antigravity-budget-model(0)">>,
    {Base, Suffix} = thinking:parse_suffix(Model),
    ModelDef = thinking_test_models:get(Base),
    Body = #{<<"model">> => Base, <<"request">> => #{<<"generationConfig">> => #{}}},
    Result = thinking:apply_thinking(Body, Base, Suffix, ModelDef, antigravity),
    Request = maps:get(<<"request">>, Result),
    GenConfig = maps:get(<<"generationConfig">>, Request),
    ThinkConfig = maps:get(<<"thinkingConfig">>, GenConfig),
    ?assertEqual(0, maps:get(<<"thinkingBudget">>, ThinkConfig)),
    ?assertEqual(false, maps:get(<<"includeThoughts">>, ThinkConfig)).

%% No-thinking model — suffix stripped silently

no_thinking_model_suffix_stripped_test() ->
    Model = <<"no-thinking-model(high)">>,
    {Base, Suffix} = thinking:parse_suffix(Model),
    ModelDef = thinking_test_models:get(Base),
    Body = #{<<"model">> => Base},
    Result = thinking:apply_thinking(Body, Base, Suffix, ModelDef, claude),
    %% Should not have any thinking-related fields
    ?assertNot(maps:is_key(<<"thinking">>, Result)),
    ?assertNot(maps:is_key(<<"reasoning_effort">>, Result)).

%% User-defined model — suffix → standard effort passthrough

user_defined_model_test() ->
    Model = <<"user-defined-model(high)">>,
    {Base, Suffix} = thinking:parse_suffix(Model),
    ModelDef = thinking_test_models:get(Base),
    Body = #{<<"model">> => Base},
    Result = thinking:apply_thinking(Body, Base, Suffix, ModelDef, claude),
    %% User-defined with no thinking config → no changes
    ?assertNot(maps:is_key(<<"thinking">>, Result)).

%% Dynamic allowed (-1 passthrough)

dynamic_budget_passthrough_test() ->
    Model = <<"gemini-budget-model(-1)">>,
    {Base, Suffix} = thinking:parse_suffix(Model),
    ModelDef = thinking_test_models:get(Base),
    Body = #{<<"model">> => Base, <<"generationConfig">> => #{}},
    Result = thinking:apply_thinking(Body, Base, Suffix, ModelDef, gemini),
    GenConfig = maps:get(<<"generationConfig">>, Result),
    ThinkConfig = maps:get(<<"thinkingConfig">>, GenConfig),
    ?assertEqual(-1, maps:get(<<"thinkingBudget">>, ThinkConfig)).

%% Level to budget conversion for budget-only model

level_to_budget_only_model_test() ->
    Model = <<"gemini-budget-model">>,
    ModelDef = thinking_test_models:get(Model),
    Config = maps:get(thinking, ModelDef),
    %% "high" should map to max for budget-only model
    Budget = thinking:level_to_budget(<<"high">>, Config),
    ?assertEqual(20000, Budget),
    %% "low" should be quarter of range
    BudgetLow = thinking:level_to_budget(<<"low">>, Config),
    Expected = 128 + (20000 - 128) div 4,
    ?assertEqual(Expected, BudgetLow).
