-module(translator_gemini_claude_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Gemini → Claude Request Translation Tests (T2-009)
%% ============================================================

basic_request_test() ->
    Input = #{
        <<"contents">> => [
            #{<<"role">> => <<"user">>,
              <<"parts">> => [#{<<"text">> => <<"Hello">>}]}
        ],
        <<"generationConfig">> => #{
            <<"maxOutputTokens">> => 2048,
            <<"temperature">> => 0.8
        }
    },
    Result = translator_gemini_claude:request(<<"claude-3">>, Input, false),
    ?assertEqual(<<"claude-3">>, maps:get(<<"model">>, Result)),
    [Msg] = maps:get(<<"messages">>, Result),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, Msg)),
    ?assertEqual(2048, maps:get(<<"max_tokens">>, Result)),
    ?assertEqual(0.8, maps:get(<<"temperature">>, Result)).

system_instruction_test() ->
    Input = #{
        <<"systemInstruction">> => #{
            <<"parts">> => [#{<<"text">> => <<"Be concise">>}]
        },
        <<"contents">> => [
            #{<<"role">> => <<"user">>,
              <<"parts">> => [#{<<"text">> => <<"Hi">>}]}
        ]
    },
    Result = translator_gemini_claude:request(<<"claude-3">>, Input, true),
    ?assertEqual(<<"Be concise">>, maps:get(<<"system">>, Result)),
    ?assertEqual(true, maps:get(<<"stream">>, Result)).

model_role_to_assistant_test() ->
    Input = #{
        <<"contents">> => [
            #{<<"role">> => <<"user">>,
              <<"parts">> => [#{<<"text">> => <<"Hi">>}]},
            #{<<"role">> => <<"model">>,
              <<"parts">> => [#{<<"text">> => <<"Hello!">>}]}
        ]
    },
    Result = translator_gemini_claude:request(<<"claude-3">>, Input, false),
    [_UserMsg, AssistantMsg] = maps:get(<<"messages">>, Result),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, AssistantMsg)).

function_call_to_tool_use_test() ->
    Input = #{
        <<"contents">> => [
            #{<<"role">> => <<"model">>,
              <<"parts">> => [#{
                  <<"functionCall">> => #{
                      <<"name">> => <<"get_weather">>,
                      <<"args">> => #{<<"city">> => <<"Tokyo">>}
                  }
              }]}
        ]
    },
    Result = translator_gemini_claude:request(<<"claude-3">>, Input, false),
    [Msg] = maps:get(<<"messages">>, Result),
    [Content] = maps:get(<<"content">>, Msg),
    ?assertEqual(<<"tool_use">>, maps:get(<<"type">>, Content)),
    ?assertEqual(<<"get_weather">>, maps:get(<<"name">>, Content)),
    ?assertEqual(#{<<"city">> => <<"Tokyo">>}, maps:get(<<"input">>, Content)).

inline_data_to_image_test() ->
    Input = #{
        <<"contents">> => [
            #{<<"role">> => <<"user">>,
              <<"parts">> => [
                  #{<<"text">> => <<"Describe this">>},
                  #{<<"inlineData">> => #{
                      <<"mimeType">> => <<"image/jpeg">>,
                      <<"data">> => <<"base64data">>
                  }}
              ]}
        ]
    },
    Result = translator_gemini_claude:request(<<"claude-3">>, Input, false),
    [Msg] = maps:get(<<"messages">>, Result),
    Content = maps:get(<<"content">>, Msg),
    ?assertEqual(2, length(Content)),
    [_Text, ImgBlock] = Content,
    ?assertEqual(<<"image">>, maps:get(<<"type">>, ImgBlock)),
    Source = maps:get(<<"source">>, ImgBlock),
    ?assertEqual(<<"base64">>, maps:get(<<"type">>, Source)),
    ?assertEqual(<<"image/jpeg">>, maps:get(<<"media_type">>, Source)).

tools_translation_test() ->
    Input = #{
        <<"contents">> => [
            #{<<"role">> => <<"user">>,
              <<"parts">> => [#{<<"text">> => <<"hi">>}]}
        ],
        <<"tools">> => [#{
            <<"functionDeclarations">> => [#{
                <<"name">> => <<"search">>,
                <<"description">> => <<"Web search">>,
                <<"parameters">> => #{<<"type">> => <<"object">>}
            }]
        }]
    },
    Result = translator_gemini_claude:request(<<"claude-3">>, Input, false),
    [Tool] = maps:get(<<"tools">>, Result),
    ?assertEqual(<<"search">>, maps:get(<<"name">>, Tool)),
    ?assertEqual(<<"Web search">>, maps:get(<<"description">>, Tool)).

%% ============================================================
%% Claude → Gemini Non-streaming Response Tests
%% ============================================================

nonstream_response_test() ->
    ClaudeResp = #{
        <<"content">> => [
            #{<<"type">> => <<"text">>, <<"text">> => <<"Hello!">>}
        ],
        <<"stop_reason">> => <<"end_turn">>,
        <<"usage">> => #{<<"input_tokens">> => 10, <<"output_tokens">> => 5}
    },
    Result = translator_gemini_claude:response_nonstream(ClaudeResp),
    [Candidate] = maps:get(<<"candidates">>, Result),
    ?assertEqual(<<"STOP">>, maps:get(<<"finishReason">>, Candidate)),
    Content = maps:get(<<"content">>, Candidate),
    [Part] = maps:get(<<"parts">>, Content),
    ?assertEqual(<<"Hello!">>, maps:get(<<"text">>, Part)),
    Usage = maps:get(<<"usageMetadata">>, Result),
    ?assertEqual(10, maps:get(<<"promptTokenCount">>, Usage)).

nonstream_tool_use_response_test() ->
    ClaudeResp = #{
        <<"content">> => [
            #{<<"type">> => <<"tool_use">>,
              <<"name">> => <<"search">>,
              <<"input">> => #{<<"q">> => <<"test">>}}
        ],
        <<"stop_reason">> => <<"tool_use">>,
        <<"usage">> => #{<<"input_tokens">> => 20, <<"output_tokens">> => 15}
    },
    Result = translator_gemini_claude:response_nonstream(ClaudeResp),
    [Candidate] = maps:get(<<"candidates">>, Result),
    Content = maps:get(<<"content">>, Candidate),
    [Part] = maps:get(<<"parts">>, Content),
    FC = maps:get(<<"functionCall">>, Part),
    ?assertEqual(<<"search">>, maps:get(<<"name">>, FC)),
    ?assertEqual(#{<<"q">> => <<"test">>}, maps:get(<<"args">>, FC)).
