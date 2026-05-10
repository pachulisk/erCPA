-module(translator_openai_claude_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% OpenAI → Claude Request Translation Tests
%% ============================================================

basic_messages_test() ->
    Input = #{
        <<"model">> => <<"claude-3-sonnet">>,
        <<"messages">> => [
            #{<<"role">> => <<"system">>, <<"content">> => <<"You are helpful">>},
            #{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>}
        ],
        <<"max_tokens">> => 1024,
        <<"stream">> => false
    },
    Result = translator_openai_claude:request(<<"claude-3-sonnet">>, Input, false),
    %% System message extracted to top-level
    ?assertEqual(<<"You are helpful">>, maps:get(<<"system">>, Result)),
    %% Messages only contain user message
    [Msg] = maps:get(<<"messages">>, Result),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, Msg)),
    ?assertEqual(<<"Hello">>, maps:get(<<"content">>, Msg)),
    %% max_tokens preserved
    ?assertEqual(1024, maps:get(<<"max_tokens">>, Result)).

no_system_message_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}
        ]
    },
    Result = translator_openai_claude:request(<<"claude-3">>, Input, true),
    ?assertNot(maps:is_key(<<"system">>, Result)),
    ?assertEqual(true, maps:get(<<"stream">>, Result)).

tool_calls_translation_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"messages">> => [
            #{<<"role">> => <<"assistant">>,
              <<"content">> => <<>>,
              <<"tool_calls">> => [
                  #{<<"id">> => <<"call_1">>,
                    <<"type">> => <<"function">>,
                    <<"function">> => #{
                        <<"name">> => <<"search">>,
                        <<"arguments">> => <<"{\"q\":\"test\"}">>
                    }}
              ]}
        ]
    },
    Result = translator_openai_claude:request(<<"claude-3">>, Input, false),
    [Msg] = maps:get(<<"messages">>, Result),
    Content = maps:get(<<"content">>, Msg),
    %% Should have tool_use content block
    [ToolUse] = Content,
    ?assertEqual(<<"tool_use">>, maps:get(<<"type">>, ToolUse)),
    ?assertEqual(<<"call_1">>, maps:get(<<"id">>, ToolUse)),
    ?assertEqual(<<"search">>, maps:get(<<"name">>, ToolUse)),
    ?assertEqual(#{<<"q">> => <<"test">>}, maps:get(<<"input">>, ToolUse)).

tool_result_translation_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"messages">> => [
            #{<<"role">> => <<"tool">>,
              <<"tool_call_id">> => <<"call_1">>,
              <<"content">> => <<"search result">>}
        ]
    },
    Result = translator_openai_claude:request(<<"claude-3">>, Input, false),
    [Msg] = maps:get(<<"messages">>, Result),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, Msg)),
    [Content] = maps:get(<<"content">>, Msg),
    ?assertEqual(<<"tool_result">>, maps:get(<<"type">>, Content)),
    ?assertEqual(<<"call_1">>, maps:get(<<"tool_use_id">>, Content)).

image_url_to_base64_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>,
              <<"content">> => [
                  #{<<"type">> => <<"text">>, <<"text">> => <<"What's this?">>},
                  #{<<"type">> => <<"image_url">>,
                    <<"image_url">> => #{
                        <<"url">> => <<"data:image/jpeg;base64,/9j/4AAQ">>
                    }}
              ]}
        ]
    },
    Result = translator_openai_claude:request(<<"claude-3">>, Input, false),
    [Msg] = maps:get(<<"messages">>, Result),
    Content = maps:get(<<"content">>, Msg),
    ?assertEqual(2, length(Content)),
    [TextPart, ImagePart] = Content,
    ?assertEqual(<<"text">>, maps:get(<<"type">>, TextPart)),
    ?assertEqual(<<"image">>, maps:get(<<"type">>, ImagePart)),
    Source = maps:get(<<"source">>, ImagePart),
    ?assertEqual(<<"base64">>, maps:get(<<"type">>, Source)),
    ?assertEqual(<<"image/jpeg">>, maps:get(<<"media_type">>, Source)),
    ?assertEqual(<<"/9j/4AAQ">>, maps:get(<<"data">>, Source)).

image_http_url_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>,
              <<"content">> => [
                  #{<<"type">> => <<"image_url">>,
                    <<"image_url">> => #{
                        <<"url">> => <<"https://example.com/img.png">>
                    }}
              ]}
        ]
    },
    Result = translator_openai_claude:request(<<"claude-3">>, Input, false),
    [Msg] = maps:get(<<"messages">>, Result),
    [ImgPart] = maps:get(<<"content">>, Msg),
    Source = maps:get(<<"source">>, ImgPart),
    ?assertEqual(<<"url">>, maps:get(<<"type">>, Source)),
    ?assertEqual(<<"https://example.com/img.png">>, maps:get(<<"url">>, Source)).

tools_translation_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"tools">> => [
            #{<<"type">> => <<"function">>,
              <<"function">> => #{
                  <<"name">> => <<"search">>,
                  <<"description">> => <<"Web search">>,
                  <<"parameters">> => #{
                      <<"type">> => <<"object">>,
                      <<"properties">> => #{
                          <<"q">> => #{<<"type">> => <<"string">>}
                      }
                  }
              }}
        ]
    },
    Result = translator_openai_claude:request(<<"claude-3">>, Input, false),
    [Tool] = maps:get(<<"tools">>, Result),
    ?assertEqual(<<"search">>, maps:get(<<"name">>, Tool)),
    ?assertEqual(<<"Web search">>, maps:get(<<"description">>, Tool)),
    ?assert(maps:is_key(<<"input_schema">>, Tool)).

stop_sequences_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"stop">> => [<<"Human:">>, <<"Assistant:">>]
    },
    Result = translator_openai_claude:request(<<"claude-3">>, Input, false),
    ?assertEqual([<<"Human:">>, <<"Assistant:">>], maps:get(<<"stop_sequences">>, Result)).

%% ============================================================
%% Non-streaming Response Translation Tests
%% ============================================================

nonstream_basic_response_test() ->
    ClaudeResp = #{
        <<"id">> => <<"msg_123">>,
        <<"type">> => <<"message">>,
        <<"role">> => <<"assistant">>,
        <<"model">> => <<"claude-3-sonnet">>,
        <<"content">> => [
            #{<<"type">> => <<"text">>, <<"text">> => <<"Hello world">>}
        ],
        <<"stop_reason">> => <<"end_turn">>,
        <<"usage">> => #{
            <<"input_tokens">> => 10,
            <<"output_tokens">> => 5
        }
    },
    Result = translator_openai_claude:response_nonstream(ClaudeResp),
    ?assertEqual(<<"chat.completion">>, maps:get(<<"object">>, Result)),
    ?assertEqual(<<"msg_123">>, maps:get(<<"id">>, Result)),
    [Choice] = maps:get(<<"choices">>, Result),
    ?assertEqual(<<"stop">>, maps:get(<<"finish_reason">>, Choice)),
    Msg = maps:get(<<"message">>, Choice),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Msg)),
    ?assertEqual(<<"Hello world">>, maps:get(<<"content">>, Msg)),
    Usage = maps:get(<<"usage">>, Result),
    ?assertEqual(10, maps:get(<<"prompt_tokens">>, Usage)),
    ?assertEqual(5, maps:get(<<"completion_tokens">>, Usage)),
    ?assertEqual(15, maps:get(<<"total_tokens">>, Usage)).

nonstream_tool_use_response_test() ->
    ClaudeResp = #{
        <<"id">> => <<"msg_456">>,
        <<"model">> => <<"claude-3-sonnet">>,
        <<"content">> => [
            #{<<"type">> => <<"tool_use">>,
              <<"id">> => <<"toolu_1">>,
              <<"name">> => <<"search">>,
              <<"input">> => #{<<"q">> => <<"hello">>}}
        ],
        <<"stop_reason">> => <<"tool_use">>,
        <<"usage">> => #{<<"input_tokens">> => 20, <<"output_tokens">> => 10}
    },
    Result = translator_openai_claude:response_nonstream(ClaudeResp),
    [Choice] = maps:get(<<"choices">>, Result),
    ?assertEqual(<<"tool_calls">>, maps:get(<<"finish_reason">>, Choice)),
    Msg = maps:get(<<"message">>, Choice),
    [ToolCall] = maps:get(<<"tool_calls">>, Msg),
    ?assertEqual(<<"toolu_1">>, maps:get(<<"id">>, ToolCall)),
    Func = maps:get(<<"function">>, ToolCall),
    ?assertEqual(<<"search">>, maps:get(<<"name">>, Func)).

%% ============================================================
%% Streaming Response Translation Tests
%% ============================================================

streaming_text_delta_test() ->
    %% First send message_start to set response_id/model in acc
    StartEvent = #{<<"type">> => <<"message_start">>,
                   <<"message">> => #{<<"id">> => <<"msg_1">>,
                                      <<"model">> => <<"claude-3">>}},
    Acc0 = translator_openai_claude:init_acc(),
    {_, Acc1} = translator_openai_claude:response_stream(StartEvent, Acc0),
    %% Then send text delta
    Event = #{<<"type">> => <<"content_block_delta">>,
              <<"index">> => 0,
              <<"delta">> => #{<<"type">> => <<"text_delta">>,
                              <<"text">> => <<"Hello">>}},
    {Chunks, _Acc2} = translator_openai_claude:response_stream(Event, Acc1),
    ?assertEqual(1, length(Chunks)),
    [ChunkJSON] = Chunks,
    Decoded = jiffy:decode(ChunkJSON, [return_maps]),
    [Choice] = maps:get(<<"choices">>, Decoded),
    Delta = maps:get(<<"delta">>, Choice),
    ?assertEqual(<<"Hello">>, maps:get(<<"content">>, Delta)).

streaming_message_start_test() ->
    Event = #{<<"type">> => <<"message_start">>,
              <<"message">> => #{<<"id">> => <<"msg_abc">>,
                                 <<"model">> => <<"claude-3-sonnet">>}},
    Acc0 = translator_openai_claude:init_acc(),
    {Chunks, _Acc1} = translator_openai_claude:response_stream(Event, Acc0),
    ?assertEqual(1, length(Chunks)),
    %% Verify the chunk contains the response id
    [ChunkJSON] = Chunks,
    Decoded = jiffy:decode(ChunkJSON, [return_maps]),
    ?assertEqual(<<"msg_abc">>, maps:get(<<"id">>, Decoded)),
    ?assertEqual(<<"claude-3-sonnet">>, maps:get(<<"model">>, Decoded)).

streaming_unknown_event_ignored_test() ->
    Event = #{<<"type">> => <<"ping">>},
    Acc0 = translator_openai_claude:init_acc(),
    {Chunks, _Acc1} = translator_openai_claude:response_stream(Event, Acc0),
    ?assertEqual([], Chunks).
