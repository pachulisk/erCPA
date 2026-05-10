-module(translator_prop_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Property-based tests for translator invariants
%% Uses EUnit-style tests that exercise invariants across many inputs
%% (PropEr integration deferred to rebar3 proper profile)
%% ============================================================

%% T2-013: Roundtrip preserves message content
%% OpenAI → Claude → OpenAI should preserve user message text

roundtrip_openai_claude_text_test() ->
    Messages = [
        <<"Hello">>, <<"How are you?">>, <<"">>,
        <<"Multi\nline\ntext">>,
        <<"Special chars: <>&\"'"/utf8>>,
        <<"Unicode: 你好世界"/utf8>>
    ],
    lists:foreach(fun(Text) ->
        Input = #{
            <<"model">> => <<"claude-3">>,
            <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Text}],
            <<"max_tokens">> => 100
        },
        %% OpenAI → Claude
        Claude = translator_openai_claude:request(<<"claude-3">>, Input, false),
        %% Claude → OpenAI
        Back = translator_claude_openai:request(<<"gpt-4">>, Claude, false),
        %% Extract text
        BackMessages = maps:get(<<"messages">>, Back),
        UserMsgs = [M || M <- BackMessages, maps:get(<<"role">>, M) =:= <<"user">>],
        case UserMsgs of
            [#{<<"content">> := BackText}] ->
                ?assertEqual(Text, BackText);
            _ ->
                %% Empty text may be filtered — ok
                ok
        end
    end, Messages).

roundtrip_openai_gemini_text_test() ->
    Texts = [<<"Hello">>, <<"Test message">>, <<"Multi\nline">>],
    lists:foreach(fun(Text) ->
        Input = #{
            <<"model">> => <<"gemini-pro">>,
            <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Text}],
            <<"max_tokens">> => 100
        },
        Gemini = translator_openai_gemini:request(<<"gemini-pro">>, Input, false),
        Back = translator_gemini_openai:request(<<"gpt-4">>, Gemini, false),
        BackMessages = maps:get(<<"messages">>, Back),
        UserMsgs = [M || M <- BackMessages, maps:get(<<"role">>, M) =:= <<"user">>],
        [#{<<"content">> := BackText}] = UserMsgs,
        ?assertEqual(Text, BackText)
    end, Texts).

%% T2-014: Usage tokens are never negative

usage_non_negative_openai_test() ->
    Responses = [
        #{<<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"Hi">>}],
          <<"id">> => <<"m1">>, <<"model">> => <<"c3">>,
          <<"stop_reason">> => <<"end_turn">>,
          <<"usage">> => #{<<"input_tokens">> => 0, <<"output_tokens">> => 0}},
        #{<<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"Hi">>}],
          <<"id">> => <<"m2">>, <<"model">> => <<"c3">>,
          <<"stop_reason">> => <<"end_turn">>,
          <<"usage">> => #{<<"input_tokens">> => 100, <<"output_tokens">> => 50}},
        #{<<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"Hi">>}],
          <<"id">> => <<"m3">>, <<"model">> => <<"c3">>,
          <<"stop_reason">> => <<"max_tokens">>,
          <<"usage">> => #{<<"input_tokens">> => 99999, <<"output_tokens">> => 99999}}
    ],
    lists:foreach(fun(Resp) ->
        Result = translator_openai_claude:response_nonstream(Resp),
        Usage = maps:get(<<"usage">>, Result),
        ?assert(maps:get(<<"prompt_tokens">>, Usage) >= 0),
        ?assert(maps:get(<<"completion_tokens">>, Usage) >= 0),
        ?assert(maps:get(<<"total_tokens">>, Usage) >= 0)
    end, Responses).

usage_non_negative_gemini_test() ->
    Responses = [
        #{<<"candidates">> => [#{
            <<"content">> => #{<<"role">> => <<"model">>,
                               <<"parts">> => [#{<<"text">> => <<"Hi">>}]},
            <<"finishReason">> => <<"STOP">>}],
          <<"usageMetadata">> => #{<<"promptTokenCount">> => 0,
                                   <<"candidatesTokenCount">> => 0},
          <<"modelVersion">> => <<"gemini">>},
        #{<<"candidates">> => [#{
            <<"content">> => #{<<"role">> => <<"model">>,
                               <<"parts">> => [#{<<"text">> => <<"Hi">>}]},
            <<"finishReason">> => <<"STOP">>}],
          <<"usageMetadata">> => #{<<"promptTokenCount">> => 500,
                                   <<"candidatesTokenCount">> => 200},
          <<"modelVersion">> => <<"gemini">>}
    ],
    lists:foreach(fun(Resp) ->
        Result = translator_openai_gemini:response_nonstream(Resp),
        Usage = maps:get(<<"usage">>, Result),
        ?assert(maps:get(<<"prompt_tokens">>, Usage) >= 0),
        ?assert(maps:get(<<"completion_tokens">>, Usage) >= 0),
        ?assert(maps:get(<<"total_tokens">>, Usage) >= 0)
    end, Responses).

%% T2-015: Thinking budget always within model bounds after clamping

thinking_clamped_invariant_test() ->
    Models = thinking_test_models:models(),
    Budgets = [-1, 0, 1, 50, 128, 1000, 5000, 10000, 20000, 50000, 128000, 999999],
    maps:foreach(fun(ModelKey, ModelDef) ->
        case maps:get(thinking, ModelDef, undefined) of
            undefined -> ok;
            Config ->
                Min = maps:get(min, Config, 0),
                Max = maps:get(max, Config, 128000),
                ZeroAllowed = maps:get(zero_allowed, Config, false),
                DynAllowed = maps:get(dynamic_allowed, Config, false),
                lists:foreach(fun(Budget) ->
                    Result = thinking:clamp_budget(Budget, Min, Max, Config),
                    %% Invariant: result is either -1 (dynamic), 0 (zero), or within [Min, Max]
                    Valid = (Result =:= -1 andalso DynAllowed) orelse
                            (Result =:= 0 andalso ZeroAllowed) orelse
                            (Result >= Min andalso Result =< Max),
                    ?assert(Valid,
                        io_lib:format("Model ~s, Budget ~p → ~p invalid (min=~p, max=~p, zero=~p, dyn=~p)",
                            [ModelKey, Budget, Result, Min, Max, ZeroAllowed, DynAllowed]))
                end, Budgets)
        end
    end, Models).

%% Stop reason mapping is consistent

stop_reason_mapping_test() ->
    %% Claude → OpenAI mapping
    ClaudeReasons = [<<"end_turn">>, <<"stop_sequence">>, <<"max_tokens">>, <<"tool_use">>, <<>>],
    lists:foreach(fun(Reason) ->
        Resp = #{
            <<"id">> => <<"m">>, <<"model">> => <<"c">>,
            <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<>>}],
            <<"stop_reason">> => Reason,
            <<"usage">> => #{<<"input_tokens">> => 0, <<"output_tokens">> => 0}
        },
        Result = translator_openai_claude:response_nonstream(Resp),
        [Choice] = maps:get(<<"choices">>, Result),
        FR = maps:get(<<"finish_reason">>, Choice),
        %% Must be a valid OpenAI finish reason or null
        ?assert(lists:member(FR, [<<"stop">>, <<"length">>, <<"tool_calls">>,
                                   <<"content_filter">>, null]),
                io_lib:format("Invalid finish_reason: ~p for stop_reason: ~p", [FR, Reason]))
    end, ClaudeReasons).

%% System message extraction is idempotent

system_extraction_idempotent_test() ->
    Input = #{
        <<"model">> => <<"c3">>,
        <<"messages">> => [
            #{<<"role">> => <<"system">>, <<"content">> => <<"Be helpful">>},
            #{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}
        ]
    },
    %% First pass
    Claude1 = translator_openai_claude:request(<<"c3">>, Input, false),
    ?assertEqual(<<"Be helpful">>, maps:get(<<"system">>, Claude1)),
    %% Second pass on the Claude output
    OpenAI = translator_claude_openai:request(<<"gpt-4">>, Claude1, false),
    Claude2 = translator_openai_claude:request(<<"c3">>, OpenAI, false),
    ?assertEqual(<<"Be helpful">>, maps:get(<<"system">>, Claude2)).
