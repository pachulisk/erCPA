-module(translator_remaining_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tests for remaining translator pairs

%% --- Codex → OpenAI ---

codex_to_openai_request_test() ->
    Input = #{
        <<"model">> => <<"gpt-4">>,
        <<"instructions">> => <<"Help me">>,
        <<"input">> => [
            #{<<"type">> => <<"message">>, <<"role">> => <<"user">>,
              <<"content">> => <<"Hello">>}
        ],
        <<"max_output_tokens">> => 2048
    },
    Result = translator_codex_openai:request(<<"gpt-4">>, Input, false),
    Messages = maps:get(<<"messages">>, Result),
    ?assertEqual(2, length(Messages)),
    [Sys, User] = Messages,
    ?assertEqual(<<"system">>, maps:get(<<"role">>, Sys)),
    ?assertEqual(<<"Help me">>, maps:get(<<"content">>, Sys)),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, User)),
    ?assertEqual(2048, maps:get(<<"max_tokens">>, Result)).

codex_to_openai_func_call_test() ->
    Input = #{
        <<"model">> => <<"gpt-4">>,
        <<"input">> => [
            #{<<"type">> => <<"function_call">>, <<"call_id">> => <<"c1">>,
              <<"name">> => <<"bash">>, <<"arguments">> => <<"{\"cmd\":\"ls\"}">>},
            #{<<"type">> => <<"function_call_output">>, <<"call_id">> => <<"c1">>,
              <<"output">> => <<"file1.txt">>}
        ]
    },
    Result = translator_codex_openai:request(<<"gpt-4">>, Input, false),
    Messages = maps:get(<<"messages">>, Result),
    ?assertEqual(2, length(Messages)),
    [AssistantMsg, ToolMsg] = Messages,
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, AssistantMsg)),
    ?assertEqual(<<"tool">>, maps:get(<<"role">>, ToolMsg)).

codex_to_openai_nonstream_response_test() ->
    OpenAIResp = #{
        <<"id">> => <<"chatcmpl-1">>,
        <<"model">> => <<"gpt-4">>,
        <<"choices">> => [#{<<"message">> => #{<<"role">> => <<"assistant">>,
                                               <<"content">> => <<"Done">>},
                            <<"finish_reason">> => <<"stop">>}],
        <<"usage">> => #{<<"prompt_tokens">> => 10, <<"completion_tokens">> => 5,
                         <<"total_tokens">> => 15}
    },
    Result = translator_codex_openai:response_nonstream(OpenAIResp),
    ?assertEqual(<<"response">>, maps:get(<<"object">>, Result)),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, Result)),
    [Item] = maps:get(<<"output">>, Result),
    ?assertEqual(<<"message">>, maps:get(<<"type">>, Item)),
    [Content] = maps:get(<<"content">>, Item),
    ?assertEqual(<<"Done">>, maps:get(<<"text">>, Content)).

%% --- Gemini → OpenAI ---

gemini_to_openai_request_test() ->
    Input = #{
        <<"contents">> => [
            #{<<"role">> => <<"user">>,
              <<"parts">> => [#{<<"text">> => <<"Hello">>}]}
        ],
        <<"systemInstruction">> => #{<<"parts">> => [#{<<"text">> => <<"Be brief">>}]},
        <<"generationConfig">> => #{<<"maxOutputTokens">> => 1024, <<"temperature">> => 0.5}
    },
    Result = translator_gemini_openai:request(<<"gpt-4">>, Input, false),
    Messages = maps:get(<<"messages">>, Result),
    ?assertEqual(2, length(Messages)),
    [Sys, User] = Messages,
    ?assertEqual(<<"system">>, maps:get(<<"role">>, Sys)),
    ?assertEqual(<<"Be brief">>, maps:get(<<"content">>, Sys)),
    ?assertEqual(1024, maps:get(<<"max_tokens">>, Result)),
    ?assertEqual(0.5, maps:get(<<"temperature">>, Result)).

gemini_to_openai_nonstream_response_test() ->
    GeminiResp = #{
        <<"candidates">> => [#{
            <<"content">> => #{<<"role">> => <<"model">>,
                               <<"parts">> => [#{<<"text">> => <<"Hi!">>}]},
            <<"finishReason">> => <<"STOP">>
        }],
        <<"usageMetadata">> => #{<<"promptTokenCount">> => 5, <<"candidatesTokenCount">> => 3},
        <<"modelVersion">> => <<"gemini-pro">>
    },
    Result = translator_gemini_openai:response_nonstream(GeminiResp),
    ?assertEqual(<<"chat.completion">>, maps:get(<<"object">>, Result)),
    [Choice] = maps:get(<<"choices">>, Result),
    ?assertEqual(<<"stop">>, maps:get(<<"finish_reason">>, Choice)),
    Msg = maps:get(<<"message">>, Choice),
    ?assertEqual(<<"Hi!">>, maps:get(<<"content">>, Msg)).

%% --- Claude → Gemini ---

claude_to_gemini_request_test() ->
    Input = #{
        <<"model">> => <<"gemini-pro">>,
        <<"system">> => <<"Be concise">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}
        ],
        <<"max_tokens">> => 2048,
        <<"temperature">> => 0.8
    },
    Result = translator_claude_gemini:request(<<"gemini-pro">>, Input, false),
    ?assert(maps:is_key(<<"contents">>, Result)),
    ?assert(maps:is_key(<<"systemInstruction">>, Result)),
    SysInst = maps:get(<<"systemInstruction">>, Result),
    [#{<<"text">> := <<"Be concise">>}] = maps:get(<<"parts">>, SysInst),
    GenConfig = maps:get(<<"generationConfig">>, Result),
    ?assertEqual(2048, maps:get(<<"maxOutputTokens">>, GenConfig)),
    ?assertEqual(0.8, maps:get(<<"temperature">>, GenConfig)).

claude_to_gemini_tool_use_test() ->
    Input = #{
        <<"model">> => <<"gemini-pro">>,
        <<"messages">> => [
            #{<<"role">> => <<"assistant">>,
              <<"content">> => [#{<<"type">> => <<"tool_use">>,
                                  <<"name">> => <<"search">>,
                                  <<"input">> => #{<<"q">> => <<"test">>}}]}
        ]
    },
    Result = translator_claude_gemini:request(<<"gemini-pro">>, Input, false),
    [Content] = maps:get(<<"contents">>, Result),
    ?assertEqual(<<"model">>, maps:get(<<"role">>, Content)),
    [Part] = maps:get(<<"parts">>, Content),
    FC = maps:get(<<"functionCall">>, Part),
    ?assertEqual(<<"search">>, maps:get(<<"name">>, FC)).

claude_to_gemini_nonstream_response_test() ->
    ClaudeResp = #{
        <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"Result">>}],
        <<"stop_reason">> => <<"end_turn">>,
        <<"usage">> => #{<<"input_tokens">> => 10, <<"output_tokens">> => 5}
    },
    Result = translator_claude_gemini:response_nonstream(ClaudeResp),
    [Cand] = maps:get(<<"candidates">>, Result),
    ?assertEqual(<<"STOP">>, maps:get(<<"finishReason">>, Cand)),
    Content = maps:get(<<"content">>, Cand),
    [Part] = maps:get(<<"parts">>, Content),
    ?assertEqual(<<"Result">>, maps:get(<<"text">>, Part)),
    Usage = maps:get(<<"usageMetadata">>, Result),
    ?assertEqual(10, maps:get(<<"promptTokenCount">>, Usage)).
