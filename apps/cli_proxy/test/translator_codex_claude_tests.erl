-module(translator_codex_claude_tests).
-include_lib("eunit/include/eunit.hrl").

%% T2-010: Codex → Claude translation tests

basic_request_with_instructions_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"instructions">> => <<"You are a coding assistant">>,
        <<"input">> => [
            #{<<"type">> => <<"message">>, <<"role">> => <<"user">>,
              <<"content">> => <<"Write hello world">>}
        ],
        <<"max_output_tokens">> => 2048
    },
    Result = translator_codex_claude:request(<<"claude-3">>, Input, true),
    ?assertEqual(<<"You are a coding assistant">>, maps:get(<<"system">>, Result)),
    ?assertEqual(2048, maps:get(<<"max_tokens">>, Result)),
    [Msg] = maps:get(<<"messages">>, Result),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, Msg)),
    ?assertEqual(<<"Write hello world">>, maps:get(<<"content">>, Msg)).

function_call_input_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"input">> => [
            #{<<"type">> => <<"function_call">>,
              <<"call_id">> => <<"call_1">>,
              <<"name">> => <<"run_code">>,
              <<"arguments">> => <<"{\"code\":\"print('hi')\"}">>}
        ]
    },
    Result = translator_codex_claude:request(<<"claude-3">>, Input, false),
    [Msg] = maps:get(<<"messages">>, Result),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Msg)),
    [Content] = maps:get(<<"content">>, Msg),
    ?assertEqual(<<"tool_use">>, maps:get(<<"type">>, Content)),
    ?assertEqual(<<"call_1">>, maps:get(<<"id">>, Content)),
    ?assertEqual(#{<<"code">> => <<"print('hi')">>}, maps:get(<<"input">>, Content)).

function_call_output_input_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"input">> => [
            #{<<"type">> => <<"function_call_output">>,
              <<"call_id">> => <<"call_1">>,
              <<"output">> => <<"hi\n">>}
        ]
    },
    Result = translator_codex_claude:request(<<"claude-3">>, Input, false),
    [Msg] = maps:get(<<"messages">>, Result),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, Msg)),
    [Content] = maps:get(<<"content">>, Msg),
    ?assertEqual(<<"tool_result">>, maps:get(<<"type">>, Content)),
    ?assertEqual(<<"call_1">>, maps:get(<<"tool_use_id">>, Content)).

nonstream_response_test() ->
    ClaudeResp = #{
        <<"id">> => <<"msg_123">>,
        <<"model">> => <<"claude-3">>,
        <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"Done!">>}],
        <<"stop_reason">> => <<"end_turn">>,
        <<"usage">> => #{<<"input_tokens">> => 50, <<"output_tokens">> => 10}
    },
    Result = translator_codex_claude:response_nonstream(ClaudeResp),
    ?assertEqual(<<"response">>, maps:get(<<"object">>, Result)),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, Result)),
    [Item] = maps:get(<<"output">>, Result),
    ?assertEqual(<<"message">>, maps:get(<<"type">>, Item)),
    [Content] = maps:get(<<"content">>, Item),
    ?assertEqual(<<"Done!">>, maps:get(<<"text">>, Content)),
    Usage = maps:get(<<"usage">>, Result),
    ?assertEqual(60, maps:get(<<"total_tokens">>, Usage)).

tools_translation_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"input">> => [#{<<"type">> => <<"message">>, <<"role">> => <<"user">>,
                          <<"content">> => <<"hi">>}],
        <<"tools">> => [#{
            <<"type">> => <<"function">>,
            <<"name">> => <<"bash">>,
            <<"description">> => <<"Run shell commands">>,
            <<"parameters">> => #{<<"type">> => <<"object">>}
        }]
    },
    Result = translator_codex_claude:request(<<"claude-3">>, Input, false),
    [Tool] = maps:get(<<"tools">>, Result),
    ?assertEqual(<<"bash">>, maps:get(<<"name">>, Tool)),
    ?assertEqual(<<"Run shell commands">>, maps:get(<<"description">>, Tool)).
