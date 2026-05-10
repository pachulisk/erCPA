-module(translator_responses_tests).
-include_lib("eunit/include/eunit.hrl").

%% T2-012: OpenAI Responses API → Claude translation tests

basic_responses_request_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"instructions">> => <<"Be helpful">>,
        <<"input">> => [
            #{<<"type">> => <<"message">>, <<"role">> => <<"user">>,
              <<"content">> => [#{<<"type">> => <<"input_text">>,
                                  <<"text">> => <<"Hello">>}]}
        ],
        <<"max_output_tokens">> => 4096,
        <<"temperature">> => 0.7
    },
    Result = translator_openai_responses_claude:request(<<"claude-3">>, Input, true),
    ?assertEqual(<<"Be helpful">>, maps:get(<<"system">>, Result)),
    ?assertEqual(4096, maps:get(<<"max_tokens">>, Result)),
    ?assertEqual(0.7, maps:get(<<"temperature">>, Result)),
    [Msg] = maps:get(<<"messages">>, Result),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, Msg)),
    [Content] = maps:get(<<"content">>, Msg),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Content)),
    ?assertEqual(<<"Hello">>, maps:get(<<"text">>, Content)).

function_call_and_output_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"input">> => [
            #{<<"type">> => <<"function_call">>,
              <<"call_id">> => <<"call_abc">>,
              <<"name">> => <<"search">>,
              <<"arguments">> => <<"{\"q\":\"erlang\"}">>},
            #{<<"type">> => <<"function_call_output">>,
              <<"call_id">> => <<"call_abc">>,
              <<"output">> => <<"Results found">>}
        ]
    },
    Result = translator_openai_responses_claude:request(<<"claude-3">>, Input, false),
    Messages = maps:get(<<"messages">>, Result),
    ?assertEqual(2, length(Messages)),
    [AssistantMsg, UserMsg] = Messages,
    %% function_call → assistant with tool_use
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, AssistantMsg)),
    [ToolUse] = maps:get(<<"content">>, AssistantMsg),
    ?assertEqual(<<"tool_use">>, maps:get(<<"type">>, ToolUse)),
    ?assertEqual(<<"search">>, maps:get(<<"name">>, ToolUse)),
    %% function_call_output → user with tool_result
    ?assertEqual(<<"user">>, maps:get(<<"role">>, UserMsg)),
    [ToolResult] = maps:get(<<"content">>, UserMsg),
    ?assertEqual(<<"tool_result">>, maps:get(<<"type">>, ToolResult)).

reasoning_to_thinking_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"input">> => [#{<<"type">> => <<"message">>, <<"role">> => <<"user">>,
                          <<"content">> => <<"Think carefully">>}],
        <<"reasoning">> => #{<<"effort">> => <<"high">>}
    },
    Result = translator_openai_responses_claude:request(<<"claude-3">>, Input, false),
    Thinking = maps:get(<<"thinking">>, Result),
    ?assertEqual(<<"enabled">>, maps:get(<<"type">>, Thinking)),
    ?assertEqual(65536, maps:get(<<"budget_tokens">>, Thinking)).

tools_in_responses_format_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"input">> => [#{<<"type">> => <<"message">>, <<"role">> => <<"user">>,
                          <<"content">> => <<"hi">>}],
        <<"tools">> => [#{
            <<"type">> => <<"function">>,
            <<"name">> => <<"bash">>,
            <<"description">> => <<"Execute commands">>,
            <<"parameters">> => #{<<"type">> => <<"object">>}
        }]
    },
    Result = translator_openai_responses_claude:request(<<"claude-3">>, Input, false),
    [Tool] = maps:get(<<"tools">>, Result),
    ?assertEqual(<<"bash">>, maps:get(<<"name">>, Tool)).

nonstream_response_test() ->
    ClaudeResp = #{
        <<"id">> => <<"msg_xyz">>,
        <<"model">> => <<"claude-3">>,
        <<"content">> => [
            #{<<"type">> => <<"text">>, <<"text">> => <<"Hello!">>}
        ],
        <<"usage">> => #{<<"input_tokens">> => 10, <<"output_tokens">> => 5}
    },
    Result = translator_openai_responses_claude:response_nonstream(ClaudeResp),
    ?assertEqual(<<"response">>, maps:get(<<"object">>, Result)),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, Result)),
    [Item] = maps:get(<<"output">>, Result),
    ?assertEqual(<<"message">>, maps:get(<<"type">>, Item)),
    [Content] = maps:get(<<"content">>, Item),
    ?assertEqual(<<"Hello!">>, maps:get(<<"text">>, Content)),
    Usage = maps:get(<<"usage">>, Result),
    ?assertEqual(15, maps:get(<<"total_tokens">>, Usage)).

empty_instructions_not_set_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"input">> => [#{<<"type">> => <<"message">>, <<"role">> => <<"user">>,
                          <<"content">> => <<"hi">>}]
    },
    Result = translator_openai_responses_claude:request(<<"claude-3">>, Input, false),
    ?assertNot(maps:is_key(<<"system">>, Result)).
