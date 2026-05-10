-module(translator_openai_gemini_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% OpenAI → Gemini Request Tests
%% ============================================================

basic_request_test() ->
    Input = #{
        <<"model">> => <<"gemini-pro">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>}
        ],
        <<"max_tokens">> => 1024,
        <<"temperature">> => 0.7
    },
    Result = translator_openai_gemini:request(<<"gemini-pro">>, Input, false),
    ?assert(maps:is_key(<<"contents">>, Result)),
    [Content] = maps:get(<<"contents">>, Result),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, Content)),
    Parts = maps:get(<<"parts">>, Content),
    [#{<<"text">> := <<"Hello">>}] = Parts,
    %% Generation config
    GenConfig = maps:get(<<"generationConfig">>, Result),
    ?assertEqual(1024, maps:get(<<"maxOutputTokens">>, GenConfig)),
    ?assertEqual(0.7, maps:get(<<"temperature">>, GenConfig)).

system_instruction_extracted_test() ->
    Input = #{
        <<"model">> => <<"gemini-pro">>,
        <<"messages">> => [
            #{<<"role">> => <<"system">>, <<"content">> => <<"You are helpful">>},
            #{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}
        ]
    },
    Result = translator_openai_gemini:request(<<"gemini-pro">>, Input, true),
    %% System extracted
    SysInst = maps:get(<<"systemInstruction">>, Result),
    [#{<<"text">> := <<"You are helpful">>}] = maps:get(<<"parts">>, SysInst),
    %% Only user message in contents
    [Content] = maps:get(<<"contents">>, Result),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, Content)).

assistant_role_mapped_to_model_test() ->
    Input = #{
        <<"model">> => <<"gemini-pro">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>},
            #{<<"role">> => <<"assistant">>, <<"content">> => <<"Hello!">>}
        ]
    },
    Result = translator_openai_gemini:request(<<"gemini-pro">>, Input, false),
    Contents = maps:get(<<"contents">>, Result),
    ?assertEqual(2, length(Contents)),
    [_, AssistantContent] = Contents,
    ?assertEqual(<<"model">>, maps:get(<<"role">>, AssistantContent)).

safety_settings_included_test() ->
    Input = #{
        <<"model">> => <<"gemini-pro">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}]
    },
    Result = translator_openai_gemini:request(<<"gemini-pro">>, Input, false),
    Safety = maps:get(<<"safetySettings">>, Result),
    ?assertEqual(4, length(Safety)),
    [First | _] = Safety,
    ?assertEqual(<<"BLOCK_NONE">>, maps:get(<<"threshold">>, First)).

tools_translated_test() ->
    Input = #{
        <<"model">> => <<"gemini-pro">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"tools">> => [
            #{<<"type">> => <<"function">>,
              <<"function">> => #{
                  <<"name">> => <<"search">>,
                  <<"description">> => <<"Search web">>,
                  <<"parameters">> => #{<<"type">> => <<"object">>}
              }}
        ]
    },
    Result = translator_openai_gemini:request(<<"gemini-pro">>, Input, false),
    [ToolsObj] = maps:get(<<"tools">>, Result),
    [Decl] = maps:get(<<"functionDeclarations">>, ToolsObj),
    ?assertEqual(<<"search">>, maps:get(<<"name">>, Decl)),
    ?assertEqual(<<"Search web">>, maps:get(<<"description">>, Decl)).

image_to_inline_data_test() ->
    Input = #{
        <<"model">> => <<"gemini-pro-vision">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>,
              <<"content">> => [
                  #{<<"type">> => <<"text">>, <<"text">> => <<"Describe">>},
                  #{<<"type">> => <<"image_url">>,
                    <<"image_url">> => #{<<"url">> => <<"data:image/png;base64,iVBOR">>}}
              ]}
        ]
    },
    Result = translator_openai_gemini:request(<<"gemini-pro-vision">>, Input, false),
    [Content] = maps:get(<<"contents">>, Result),
    Parts = maps:get(<<"parts">>, Content),
    ?assertEqual(2, length(Parts)),
    [TextPart, ImgPart] = Parts,
    ?assertEqual(<<"Describe">>, maps:get(<<"text">>, TextPart)),
    InlineData = maps:get(<<"inlineData">>, ImgPart),
    ?assertEqual(<<"image/png">>, maps:get(<<"mimeType">>, InlineData)),
    ?assertEqual(<<"iVBOR">>, maps:get(<<"data">>, InlineData)).

%% ============================================================
%% Gemini → OpenAI Non-streaming Response Tests
%% ============================================================

nonstream_response_test() ->
    GeminiResp = #{
        <<"candidates">> => [#{
            <<"content">> => #{
                <<"role">> => <<"model">>,
                <<"parts">> => [#{<<"text">> => <<"Hello there!">>}]
            },
            <<"finishReason">> => <<"STOP">>
        }],
        <<"usageMetadata">> => #{
            <<"promptTokenCount">> => 10,
            <<"candidatesTokenCount">> => 5
        },
        <<"modelVersion">> => <<"gemini-pro">>
    },
    Result = translator_openai_gemini:response_nonstream(GeminiResp),
    ?assertEqual(<<"chat.completion">>, maps:get(<<"object">>, Result)),
    [Choice] = maps:get(<<"choices">>, Result),
    ?assertEqual(<<"stop">>, maps:get(<<"finish_reason">>, Choice)),
    Msg = maps:get(<<"message">>, Choice),
    ?assertEqual(<<"Hello there!">>, maps:get(<<"content">>, Msg)),
    Usage = maps:get(<<"usage">>, Result),
    ?assertEqual(10, maps:get(<<"prompt_tokens">>, Usage)),
    ?assertEqual(5, maps:get(<<"completion_tokens">>, Usage)).

nonstream_function_call_response_test() ->
    GeminiResp = #{
        <<"candidates">> => [#{
            <<"content">> => #{
                <<"role">> => <<"model">>,
                <<"parts">> => [#{
                    <<"functionCall">> => #{
                        <<"name">> => <<"search">>,
                        <<"args">> => #{<<"q">> => <<"erlang">>}
                    }
                }]
            },
            <<"finishReason">> => <<"STOP">>
        }],
        <<"usageMetadata">> => #{
            <<"promptTokenCount">> => 15,
            <<"candidatesTokenCount">> => 8
        },
        <<"modelVersion">> => <<"gemini-pro">>
    },
    Result = translator_openai_gemini:response_nonstream(GeminiResp),
    [Choice] = maps:get(<<"choices">>, Result),
    Msg = maps:get(<<"message">>, Choice),
    [TC] = maps:get(<<"tool_calls">>, Msg),
    Func = maps:get(<<"function">>, TC),
    ?assertEqual(<<"search">>, maps:get(<<"name">>, Func)).
