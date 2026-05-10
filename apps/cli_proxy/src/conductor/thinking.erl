-module(thinking).

%% Thinking normalization module
%% Handles: suffix parsing, budget/level clamping, cross-format conversion
%% Pure functions — no process state

-export([
    parse_suffix/1,
    apply_thinking/5,
    clamp_budget/4,
    level_to_budget/2,
    budget_to_level/2
]).

%%====================================================================
%% Suffix Parsing: "model-name(high)" → {"model-name", "high"}
%%====================================================================

-spec parse_suffix(binary()) -> {binary(), binary()}.
parse_suffix(Model) ->
    case binary:match(Model, <<"(">>) of
        {Pos, _} ->
            Base = binary:part(Model, 0, Pos),
            %% Extract content between ( and )
            Rest = binary:part(Model, Pos + 1, byte_size(Model) - Pos - 1),
            Suffix = case binary:match(Rest, <<")">>) of
                {SPos, _} -> binary:part(Rest, 0, SPos);
                nomatch -> Rest
            end,
            {Base, Suffix};
        nomatch ->
            {Model, <<>>}
    end.

%%====================================================================
%% Apply Thinking: inject thinking config into translated request
%%====================================================================

-spec apply_thinking(map(), binary(), binary(), map() | undefined, atom()) -> map().
apply_thinking(Body, _Model, _Suffix, undefined, _TargetFormat) ->
    %% No thinking config for this model
    Body;
apply_thinking(Body, _Model, <<>>, _ModelInfo, _TargetFormat) ->
    %% No suffix — pass through any existing thinking params
    Body;
apply_thinking(Body, Model, Suffix, ModelInfo, TargetFormat) ->
    ThinkingConfig = maps:get(thinking, ModelInfo, undefined),
    case ThinkingConfig of
        undefined ->
            %% No thinking support — strip suffix silently
            Body;
        Config ->
            apply_suffix(Body, Model, Suffix, Config, TargetFormat)
    end.

%%====================================================================
%% Internal: apply suffix to body based on model config and target format
%%====================================================================

apply_suffix(Body, _Model, Suffix, Config, TargetFormat) ->
    %% Determine if suffix is a level or budget
    case parse_suffix_value(Suffix, Config) of
        {level, Level} ->
            apply_level(Body, Level, Config, TargetFormat);
        {budget, Budget} ->
            apply_budget(Body, Budget, Config, TargetFormat);
        none ->
            Body
    end.

parse_suffix_value(Suffix, Config) ->
    %% Try as integer (budget)
    case catch binary_to_integer(Suffix) of
        N when is_integer(N) ->
            {budget, N};
        _ ->
            %% Try as level name
            Levels = maps:get(levels, Config, []),
            case is_valid_level(Suffix, Levels, Config) of
                true -> {level, Suffix};
                false ->
                    %% Try standard effort names
                    case normalize_level(Suffix) of
                        <<>> -> none;
                        Normalized -> {level, Normalized}
                    end
            end
    end.

is_valid_level(Level, Levels, _Config) when Levels =/= [] ->
    lists:member(Level, Levels);
is_valid_level(_Level, [], _Config) ->
    true.  %% Budget-only model — treat any string as level to convert

normalize_level(<<"none">>) -> <<"none">>;
normalize_level(<<"low">>) -> <<"low">>;
normalize_level(<<"minimal">>) -> <<"minimal">>;
normalize_level(<<"medium">>) -> <<"medium">>;
normalize_level(<<"high">>) -> <<"high">>;
normalize_level(<<"max">>) -> <<"max">>;
normalize_level(<<"auto">>) -> <<"auto">>;
normalize_level(_) -> <<>>.

%%====================================================================
%% Apply level to body for target format
%%====================================================================

apply_level(Body, Level, Config, claude) ->
    %% Claude uses reasoning_effort or thinking.type
    Levels = maps:get(levels, Config, []),
    ClampedLevel = clamp_level(Level, Levels, Config),
    case ClampedLevel of
        <<"none">> ->
            Body;  %% Don't add thinking for "none"
        _ ->
            Body#{<<"reasoning_effort">> => ClampedLevel}
    end;

apply_level(Body, Level, Config, gemini) ->
    %% Gemini uses generationConfig.thinkingConfig
    Budget = level_to_budget(Level, Config),
    apply_gemini_thinking(Body, Budget, Config);

apply_level(Body, Level, Config, antigravity) ->
    Budget = level_to_budget(Level, Config),
    apply_antigravity_thinking(Body, Budget, Config);

apply_level(Body, Level, _Config, openai) ->
    Body#{<<"reasoning_effort">> => Level};

apply_level(Body, Level, _Config, codex) ->
    Body#{<<"reasoning">> => #{<<"effort">> => Level}};

apply_level(Body, Level, Config, _) ->
    %% Default: try reasoning_effort
    Levels = maps:get(levels, Config, []),
    ClampedLevel = clamp_level(Level, Levels, Config),
    Body#{<<"reasoning_effort">> => ClampedLevel}.

%%====================================================================
%% Apply budget to body for target format
%%====================================================================

apply_budget(Body, Budget, Config, claude) ->
    Clamped = clamp_budget(Budget, maps:get(min, Config, 0),
                           maps:get(max, Config, 128000), Config),
    case Clamped of
        0 ->
            case maps:get(zero_allowed, Config, false) of
                true -> Body#{<<"thinking">> => #{<<"type">> => <<"enabled">>,
                                                  <<"budget_tokens">> => 0}};
                false -> Body
            end;
        _ ->
            Body#{<<"thinking">> => #{<<"type">> => <<"enabled">>,
                                      <<"budget_tokens">> => Clamped}}
    end;

apply_budget(Body, Budget, Config, gemini) ->
    Clamped = clamp_budget(Budget, maps:get(min, Config, 0),
                           maps:get(max, Config, 20000), Config),
    apply_gemini_thinking(Body, Clamped, Config);

apply_budget(Body, Budget, Config, antigravity) ->
    Clamped = clamp_budget(Budget, maps:get(min, Config, 0),
                           maps:get(max, Config, 20000), Config),
    apply_antigravity_thinking(Body, Clamped, Config);

apply_budget(Body, Budget, Config, openai) ->
    %% OpenAI uses reasoning_effort levels
    Level = budget_to_level(Budget, Config),
    Body#{<<"reasoning_effort">> => Level};

apply_budget(Body, Budget, Config, _) ->
    Clamped = clamp_budget(Budget, maps:get(min, Config, 0),
                           maps:get(max, Config, 128000), Config),
    Body#{<<"thinking">> => #{<<"type">> => <<"enabled">>,
                              <<"budget_tokens">> => Clamped}}.

%%====================================================================
%% Budget clamping
%%====================================================================

-spec clamp_budget(integer(), integer(), integer(), map()) -> integer().
clamp_budget(0, _Min, _Max, Config) ->
    case maps:get(zero_allowed, Config, false) of
        true -> 0;
        false -> maps:get(min, Config, 0)
    end;
clamp_budget(-1, _Min, _Max, Config) ->
    case maps:get(dynamic_allowed, Config, false) of
        true -> -1;
        false ->
            %% Use midpoint
            Min = maps:get(min, Config, 0),
            Max = maps:get(max, Config, 128000),
            (Min + Max) div 2
    end;
clamp_budget(Budget, Min, Max, _Config) when Budget > Max ->
    Max;
clamp_budget(Budget, Min, _Max, _Config) when Budget > 0, Budget < Min ->
    Min;
clamp_budget(Budget, _Min, _Max, _Config) ->
    Budget.

%%====================================================================
%% Level ↔ Budget conversion
%%====================================================================

-spec level_to_budget(binary(), map()) -> integer().
level_to_budget(<<"none">>, Config) ->
    case maps:get(zero_allowed, Config, false) of
        true -> 0;
        false -> maps:get(min, Config, 128)
    end;
level_to_budget(<<"minimal">>, Config) -> maps:get(min, Config, 128);
level_to_budget(<<"low">>, Config) ->
    Min = maps:get(min, Config, 128),
    Max = maps:get(max, Config, 20000),
    Min + (Max - Min) div 4;
level_to_budget(<<"medium">>, Config) ->
    Min = maps:get(min, Config, 128),
    Max = maps:get(max, Config, 20000),
    (Min + Max) div 2;
level_to_budget(<<"high">>, Config) -> maps:get(max, Config, 20000);
level_to_budget(<<"max">>, Config) -> maps:get(max, Config, 128000);
level_to_budget(<<"auto">>, Config) ->
    case maps:get(dynamic_allowed, Config, false) of
        true -> -1;
        false ->
            Min = maps:get(min, Config, 128),
            Max = maps:get(max, Config, 20000),
            (Min + Max) div 2
    end;
level_to_budget(_, Config) ->
    %% Unknown level — use midpoint
    Min = maps:get(min, Config, 128),
    Max = maps:get(max, Config, 20000),
    (Min + Max) div 2.

-spec budget_to_level(integer(), map()) -> binary().
budget_to_level(0, _Config) -> <<"none">>;
budget_to_level(-1, _Config) -> <<"auto">>;
budget_to_level(Budget, Config) ->
    Max = maps:get(max, Config, 128000),
    Min = maps:get(min, Config, 1024),
    Range = Max - Min,
    case Range of
        0 -> <<"medium">>;
        _ ->
            Ratio = (Budget - Min) / Range,
            if
                Ratio =< 0.25 -> <<"low">>;
                Ratio =< 0.6 -> <<"medium">>;
                Ratio =< 0.9 -> <<"high">>;
                true -> <<"max">>
            end
    end.

%%====================================================================
%% Level clamping
%%====================================================================

clamp_level(<<"none">>, _Levels, Config) ->
    case maps:get(zero_allowed, Config, false) of
        true -> <<"none">>;
        false ->
            %% Clamp to lowest available level
            Levels = maps:get(levels, Config, []),
            case Levels of
                [] -> <<"low">>;
                [First | _] -> First
            end
    end;
clamp_level(Level, [], _Config) ->
    Level;  %% No level constraints
clamp_level(Level, Levels, _Config) ->
    case lists:member(Level, Levels) of
        true -> Level;
        false ->
            %% Find nearest level
            clamp_to_nearest(Level, Levels)
    end.

clamp_to_nearest(Level, Levels) ->
    %% Map levels to numeric positions for comparison
    LevelOrder = [<<"minimal">>, <<"low">>, <<"medium">>, <<"high">>, <<"max">>],
    TargetPos = level_position(Level, LevelOrder),
    %% Find closest available
    WithPos = [{L, level_position(L, LevelOrder)} || L <- Levels],
    Sorted = lists:sort(fun({_, P1}, {_, P2}) ->
        abs(P1 - TargetPos) =< abs(P2 - TargetPos)
    end, WithPos),
    case Sorted of
        [{Closest, _} | _] -> Closest;
        [] -> Level
    end.

level_position(Level, Order) ->
    level_position(Level, Order, 0).

level_position(_Level, [], _N) -> 2;  %% default to medium position
level_position(Level, [Level | _], N) -> N;
level_position(Level, [_ | Rest], N) -> level_position(Level, Rest, N + 1).

%%====================================================================
%% Gemini thinking helpers
%%====================================================================

apply_gemini_thinking(Body, Budget, _Config) ->
    GenConfig = maps:get(<<"generationConfig">>, Body, #{}),
    ThinkConfig = #{<<"thinkingBudget">> => Budget},
    IncludeThoughts = Budget =/= 0,
    ThinkConfig1 = ThinkConfig#{<<"includeThoughts">> => IncludeThoughts},
    GenConfig1 = GenConfig#{<<"thinkingConfig">> => ThinkConfig1},
    Body#{<<"generationConfig">> => GenConfig1}.

apply_antigravity_thinking(Body, Budget, _Config) ->
    Request = maps:get(<<"request">>, Body, #{}),
    GenConfig = maps:get(<<"generationConfig">>, Request, #{}),
    ThinkConfig = #{<<"thinkingBudget">> => Budget,
                    <<"includeThoughts">> => Budget =/= 0},
    GenConfig1 = GenConfig#{<<"thinkingConfig">> => ThinkConfig},
    Request1 = Request#{<<"generationConfig">> => GenConfig1},
    Body#{<<"request">> => Request1}.

