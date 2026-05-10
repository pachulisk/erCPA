-module(thinking_test_models).
-export([models/0, get/1]).

%% ============================================================
%% Test Model Definitions for Thinking Normalization Tests
%% Ported from test/thinking_conversion_test.go getTestModels()
%% ============================================================

-spec models() -> #{binary() => map()}.
models() ->
    #{
        <<"level-model">> => #{
            thinking => #{
                levels => [<<"minimal">>, <<"low">>, <<"medium">>, <<"high">>],
                min => 0, max => 0,
                zero_allowed => false,
                dynamic_allowed => false
            }
        },
        <<"level-subset-model">> => #{
            thinking => #{
                levels => [<<"low">>, <<"high">>],
                min => 0, max => 0,
                zero_allowed => false,
                dynamic_allowed => false
            }
        },
        <<"gemini-budget-model">> => #{
            thinking => #{
                levels => [],
                min => 128, max => 20000,
                zero_allowed => false,
                dynamic_allowed => true
            }
        },
        <<"gemini-mixed-model">> => #{
            thinking => #{
                levels => [<<"low">>, <<"high">>],
                min => 128, max => 32768,
                zero_allowed => false,
                dynamic_allowed => true
            }
        },
        <<"claude-budget-model">> => #{
            thinking => #{
                levels => [],
                min => 1024, max => 128000,
                zero_allowed => true,
                dynamic_allowed => false
            }
        },
        <<"claude-sonnet-4-6-model">> => #{
            thinking => #{
                levels => [<<"low">>, <<"medium">>, <<"high">>],
                min => 1024, max => 128000,
                zero_allowed => false,
                dynamic_allowed => false
            }
        },
        <<"claude-opus-4-6-model">> => #{
            thinking => #{
                levels => [<<"low">>, <<"medium">>, <<"high">>, <<"max">>],
                min => 1024, max => 128000,
                zero_allowed => false,
                dynamic_allowed => false
            }
        },
        <<"antigravity-budget-model">> => #{
            thinking => #{
                levels => [],
                min => 128, max => 20000,
                zero_allowed => true,
                dynamic_allowed => true
            }
        },
        <<"no-thinking-model">> => #{
            thinking => undefined
        },
        <<"user-defined-model">> => #{
            thinking => undefined,
            user_defined => true
        }
    }.

-spec get(binary()) -> map() | undefined.
get(ModelName) ->
    maps:get(ModelName, models(), undefined).
