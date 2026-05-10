-module(translator_claude_openai_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Claude → OpenAI Request Translation Tests
%% ============================================================

basic_request_with_system_test() ->
    Input = #{
        <<"model">> => <<"gpt-4">>,
        <<"system">> => <<"You are helpful">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>}
        ],
        <<"max_tokens">> => 1024
    },
    Result = translator_claude_openai:request(<<"gpt-4">>, Input, false),
    Messages = maps:get(<<"messages">>, Result),
    ?assertEqual(2, length(Messages)),
    [SysMsg, UserMsg] = Messages,
    ?assertEqual(<<"system">>, maps:get(<<"role">>, SysMsg)),
    ?assertEqual(<<"You are helpful">>, maps:get(<<"content">>, SysMsg)),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, UserMsg)).

no_system_message_test() ->
    Input = #{
        <<"model">> => <<"gpt-4">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}
        ]
    },
    Result = translator_claude_openai:request(<<"gpt-4">>, Input, true),
    Messages = maps:get(<<"messages">>, Result),
    ?assertEqual(1, length(Messages)),
    ?assertEqual(true, maps:get(<<"stream">>, Result)).

tool_use_to_tool_calls_test() ->
    Input = #{
        <<"model">> => <<"gpt-4">>,
        <<"messages">> => [
            #{<<"role">> => <<"assistant">>,
              <<"content">> => [
                  #{<<"type">> => <<"text">>, <<"text">> => <<"Let me search">>},
                  #{<<"type">> => <<"tool_use">>,
                    <<"id">> => <<"toolu_1">>,
                    <<"name">> => <<"search">>,
                    <<"input">> => #{<<"q">> => <<"erlang">>}}
              ]}
        ]
    },
    Result = translator_claude_openai:request(<<"gpt-4">>, Input, false),
    [Msg] = maps:get(<<"messages">>, Result),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Msg)),
    ?assertEqual(<<"Let me search">>, maps:get(<<"content">>, Msg)),
    [TC] = maps:get(<<"tool_calls">>, Msg),
    ?assertEqual(<<"toolu_1">>, maps:get(<<"id">>, TC)),
    Func = maps:get(<<"function">>, TC),
    ?assertEqual(<<"search">>, maps:get(<<"name">>, Func)).

tool_result_to_tool_message_test() ->
    Input = #{
        <<"model">> => <<"gpt-4">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>,
              <<"content">> => [
                  #{<<"type">> => <<"tool_result">>,
                    <<"tool_use_id">> => <<"toolu_1">>,
                    <<"content">> => <<"search results here">>}
              ]}
        ]
    },
    Result = translator_claude_openai:request(<<"gpt-4">>, Input, false),
    %% Should produce tool message(s)
    Messages = maps:get(<<"messages">>, Result),
    %% tool_result becomes a list of tool messages
    [ToolMsg] = Messages,
    ?assertEqual(<<"tool">>, maps:get(<<"role">>, ToolMsg)),
    ?assertEqual(<<"toolu_1">>, maps:get(<<"tool_call_id">>, ToolMsg)).

image_base64_to_data_url_test() ->
    Input = #{
        <<"model">> => <<"gpt-4">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>,
              <<"content">> => [
                  #{<<"type">> => <<"image">>,
                    <<"source">> => #{
                        <<"type">> => <<"base64">>,
                        <<"media_type">> => <<"image/png">>,
                        <<"data">> => <<"iVBOR">>
                    }}
              ]}
        ]
    },
    Result = translator_claude_openai:request(<<"gpt-4">>, Input, false),
    [Msg] = maps:get(<<"messages">>, Result),
    [Part] = maps:get(<<"content">>, Msg),
    ?assertEqual(<<"image_url">>, maps:get(<<"type">>, Part)),
    ImgUrl = maps:get(<<"image_url">>, Part),
    ?assertEqual(<<"data:image/png;base64,iVBOR">>, maps:get(<<"url">>, ImgUrl)).

tools_translation_test() ->
    Input = #{
        <<"model">> => <<"gpt-4">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"tools">> => [
            #{<<"name">> => <<"search">>,
              <<"description">> => <<"Search the web">>,
              <<"input_schema">> => #{<<"type">> => <<"object">>}}
        ]
    },
    Result = translator_claude_openai:request(<<"gpt-4">>, Input, false),
    [Tool] = maps:get(<<"tools">>, Result),
    ?assertEqual(<<"function">>, maps:get(<<"type">>, Tool)),
    Func = maps:get(<<"function">>, Tool),
    ?assertEqual(<<"search">>, maps:get(<<"name">>, Func)),
    ?assertEqual(<<"Search the web">>, maps:get(<<"description">>, Func)).

stop_sequences_to_stop_test() ->
    Input = #{
        <<"model">> => <<"gpt-4">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"stop_sequences">> => [<<"END">>]
    },
    Result = translator_claude_openai:request(<<"gpt-4">>, Input, false),
    ?assertEqual([<<"END">>], maps:get(<<"stop">>, Result)).

%% ============================================================
%% Non-streaming Response Translation Tests (OpenAI → Claude)
%% ============================================================

nonstream_response_test() ->
    OpenAIResp = #{
        <<"id">> => <<"chatcmpl-123">>,
        <<"object">> => <<"chat.completion">>,
        <<"model">> => <<"gpt-4">>,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"message">> => #{
                <<"role">> => <<"assistant">>,
                <<"content">> => <<"Hello there">>
            },
            <<"finish_reason">> => <<"stop">>
        }],
        <<"usage">> => #{
            <<"prompt_tokens">> => 10,
            <<"completion_tokens">> => 5,
            <<"total_tokens">> => 15
        }
    },
    Result = translator_claude_openai:response_nonstream(OpenAIResp),
    ?assertEqual(<<"message">>, maps:get(<<"type">>, Result)),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Result)),
    ?assertEqual(<<"end_turn">>, maps:get(<<"stop_reason">>, Result)),
    Content = maps:get(<<"content">>, Result),
    [TextBlock] = Content,
    ?assertEqual(<<"text">>, maps:get(<<"type">>, TextBlock)),
    ?assertEqual(<<"Hello there">>, maps:get(<<"text">>, TextBlock)),
    Usage = maps:get(<<"usage">>, Result),
    ?assertEqual(10, maps:get(<<"input_tokens">>, Usage)),
    ?assertEqual(5, maps:get(<<"output_tokens">>, Usage)).

nonstream_tool_calls_response_test() ->
    OpenAIResp = #{
        <<"id">> => <<"chatcmpl-456">>,
        <<"model">> => <<"gpt-4">>,
        <<"choices">> => [#{
            <<"message">> => #{
                <<"role">> => <<"assistant">>,
                <<"content">> => <<>>,
                <<"tool_calls">> => [#{
                    <<"id">> => <<"call_1">>,
                    <<"type">> => <<"function">>,
                    <<"function">> => #{
                        <<"name">> => <<"get_weather">>,
                        <<"arguments">> => <<"{\"city\":\"SF\"}">>
                    }
                }]
            },
            <<"finish_reason">> => <<"tool_calls">>
        }],
        <<"usage">> => #{<<"prompt_tokens">> => 20, <<"completion_tokens">> => 10,
                         <<"total_tokens">> => 30}
    },
    Result = translator_claude_openai:response_nonstream(OpenAIResp),
    ?assertEqual(<<"tool_use">>, maps:get(<<"stop_reason">>, Result)),
    Content = maps:get(<<"content">>, Result),
    [ToolUse] = Content,
    ?assertEqual(<<"tool_use">>, maps:get(<<"type">>, ToolUse)),
    ?assertEqual(<<"call_1">>, maps:get(<<"id">>, ToolUse)),
    ?assertEqual(<<"get_weather">>, maps:get(<<"name">>, ToolUse)),
    ?assertEqual(#{<<"city">> => <<"SF">>}, maps:get(<<"input">>, ToolUse)).
