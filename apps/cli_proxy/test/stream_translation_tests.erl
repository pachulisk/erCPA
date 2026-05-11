-module(stream_translation_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Streaming SSE translation: Claude events → OpenAI chunks
%% ============================================================

%% --- message_start → initial chunk ---

message_start_test() ->
    Acc0 = translator_openai_claude:init_acc(),
    Event = #{<<"type">> => <<"message_start">>,
              <<"message">> => #{<<"id">> => <<"msg-1">>, <<"model">> => <<"test-model">>}},
    {Chunks, _Acc1} = translator_openai_claude:response_stream(Event, Acc0),
    ?assertEqual(1, length(Chunks)),
    Parsed = jiffy:decode(hd(Chunks), [return_maps]),
    ?assertEqual(<<"chat.completion.chunk">>, maps:get(<<"object">>, Parsed)),
    ?assertEqual(<<"msg-1">>, maps:get(<<"id">>, Parsed)),
    ?assertEqual(<<"test-model">>, maps:get(<<"model">>, Parsed)).

%% --- content_block_delta text → delta content ---

text_delta_test() ->
    Acc0 = translator_openai_claude:init_acc(),
    %% Set up acc with id/model from message_start
    StartEvent = #{<<"type">> => <<"message_start">>,
                   <<"message">> => #{<<"id">> => <<"msg-2">>, <<"model">> => <<"m">>}},
    {_, Acc1} = translator_openai_claude:response_stream(StartEvent, Acc0),

    DeltaEvent = #{<<"type">> => <<"content_block_delta">>,
                   <<"delta">> => #{<<"type">> => <<"text_delta">>,
                                    <<"text">> => <<"Hello">>}},
    {Chunks, _Acc2} = translator_openai_claude:response_stream(DeltaEvent, Acc1),
    ?assertEqual(1, length(Chunks)),
    Parsed = jiffy:decode(hd(Chunks), [return_maps]),
    [Choice] = maps:get(<<"choices">>, Parsed),
    Delta = maps:get(<<"delta">>, Choice),
    ?assertEqual(<<"Hello">>, maps:get(<<"content">>, Delta, undefined)).

%% --- thinking_delta → reasoning_content ---

thinking_delta_test() ->
    Acc0 = translator_openai_claude:init_acc(),
    StartEvent = #{<<"type">> => <<"message_start">>,
                   <<"message">> => #{<<"id">> => <<"msg-3">>, <<"model">> => <<"m">>}},
    {_, Acc1} = translator_openai_claude:response_stream(StartEvent, Acc0),

    ThinkEvent = #{<<"type">> => <<"content_block_delta">>,
                   <<"delta">> => #{<<"type">> => <<"thinking_delta">>,
                                    <<"thinking">> => <<"Let me think...">>}},
    {Chunks, _Acc2} = translator_openai_claude:response_stream(ThinkEvent, Acc1),
    ?assertEqual(1, length(Chunks)),
    Parsed = jiffy:decode(hd(Chunks), [return_maps]),
    [Choice] = maps:get(<<"choices">>, Parsed),
    Delta = maps:get(<<"delta">>, Choice),
    ?assertEqual(<<"Let me think...">>, maps:get(<<"reasoning_content">>, Delta)).

%% --- message_delta → finish_reason ---

message_delta_stop_test() ->
    Acc0 = translator_openai_claude:init_acc(),
    StartEvent = #{<<"type">> => <<"message_start">>,
                   <<"message">> => #{<<"id">> => <<"msg-4">>, <<"model">> => <<"m">>}},
    {_, Acc1} = translator_openai_claude:response_stream(StartEvent, Acc0),

    DeltaEvent = #{<<"type">> => <<"message_delta">>,
                   <<"delta">> => #{<<"stop_reason">> => <<"end_turn">>},
                   <<"usage">> => #{<<"output_tokens">> => 42}},
    {Chunks, _Acc2} = translator_openai_claude:response_stream(DeltaEvent, Acc1),
    ?assertEqual(1, length(Chunks)),
    Parsed = jiffy:decode(hd(Chunks), [return_maps]),
    [Choice] = maps:get(<<"choices">>, Parsed),
    ?assertEqual(<<"stop">>, maps:get(<<"finish_reason">>, Choice)).

%% --- Unknown events produce no chunks ---

unknown_event_skipped_test() ->
    Acc0 = translator_openai_claude:init_acc(),
    Event = #{<<"type">> => <<"ping">>},
    {Chunks, _Acc1} = translator_openai_claude:response_stream(Event, Acc0),
    ?assertEqual([], Chunks).

message_stop_skipped_test() ->
    Acc0 = translator_openai_claude:init_acc(),
    Event = #{<<"type">> => <<"message_stop">>},
    {Chunks, _Acc1} = translator_openai_claude:response_stream(Event, Acc0),
    ?assertEqual([], Chunks).

%% --- Tool use streaming ---

tool_use_start_test() ->
    Acc0 = translator_openai_claude:init_acc(),
    StartEvent = #{<<"type">> => <<"message_start">>,
                   <<"message">> => #{<<"id">> => <<"msg-5">>, <<"model">> => <<"m">>}},
    {_, Acc1} = translator_openai_claude:response_stream(StartEvent, Acc0),

    ToolEvent = #{<<"type">> => <<"content_block_start">>,
                  <<"index">> => 0,
                  <<"content_block">> => #{<<"type">> => <<"tool_use">>,
                                           <<"id">> => <<"toolu_1">>,
                                           <<"name">> => <<"get_weather">>}},
    {Chunks, _Acc2} = translator_openai_claude:response_stream(ToolEvent, Acc1),
    ?assertEqual(1, length(Chunks)),
    Parsed = jiffy:decode(hd(Chunks), [return_maps]),
    [Choice] = maps:get(<<"choices">>, Parsed),
    Delta = maps:get(<<"delta">>, Choice),
    [ToolCall] = maps:get(<<"tool_calls">>, Delta),
    ?assertEqual(<<"get_weather">>, maps:get(<<"name">>, maps:get(<<"function">>, ToolCall))).

%% --- SSE parser integration ---

sse_parse_claude_events_test() ->
    Data = <<"event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"model\":\"x\"}}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\n\n">>,
    Events = sse_parser:parse(Data),
    ?assertEqual(2, length(Events)),
    [E1, E2] = Events,
    ?assertEqual(<<"message_start">>, maps:get(<<"type">>, E1)),
    ?assertEqual(<<"content_block_delta">>, maps:get(<<"type">>, E2)).

%% --- Multiple text deltas accumulate ---

multiple_deltas_test() ->
    Acc0 = translator_openai_claude:init_acc(),
    StartEvent = #{<<"type">> => <<"message_start">>,
                   <<"message">> => #{<<"id">> => <<"msg-6">>, <<"model">> => <<"m">>}},
    {_, Acc1} = translator_openai_claude:response_stream(StartEvent, Acc0),

    Delta1 = #{<<"type">> => <<"content_block_delta">>,
               <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => <<"Hello">>}},
    {C1, Acc2} = translator_openai_claude:response_stream(Delta1, Acc1),
    ?assertEqual(1, length(C1)),

    Delta2 = #{<<"type">> => <<"content_block_delta">>,
               <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => <<" world">>}},
    {C2, _Acc3} = translator_openai_claude:response_stream(Delta2, Acc2),
    ?assertEqual(1, length(C2)),

    P2 = jiffy:decode(hd(C2), [return_maps]),
    [Choice] = maps:get(<<"choices">>, P2),
    ?assertEqual(<<" world">>, maps:get(<<"content">>, maps:get(<<"delta">>, Choice), undefined)).

%% --- Init acc is clean ---

init_acc_clean_test() ->
    Acc = translator_openai_claude:init_acc(),
    ?assert(is_tuple(Acc)).
