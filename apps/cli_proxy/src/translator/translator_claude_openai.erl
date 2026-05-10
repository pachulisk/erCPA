-module(translator_claude_openai).
-behaviour(translator).

%% Translates Claude messages format → OpenAI chat-completions format
%% Source: POST /v1/messages (Claude)
%% Target: POST /v1/chat/completions (OpenAI)

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

register() ->
    translator_registry:register(claude, openai, ?MODULE).

%%====================================================================
%% Request Translation: Claude → OpenAI
%%====================================================================

-spec request(binary(), map(), boolean()) -> map().
request(Model, Body, Stream) ->
    Messages = maps:get(<<"messages">>, Body, []),
    System = maps:get(<<"system">>, Body, undefined),

    %% Prepend system message if present
    OpenAIMessages = case System of
        undefined -> translate_messages(Messages);
        Sys when is_binary(Sys) ->
            [#{<<"role">> => <<"system">>, <<"content">> => Sys}
             | translate_messages(Messages)];
        Sys when is_list(Sys) ->
            %% System is array of content blocks
            Text = iolist_to_binary([maps:get(<<"text">>, S, <<>>) || S <- Sys]),
            [#{<<"role">> => <<"system">>, <<"content">> => Text}
             | translate_messages(Messages)]
    end,

    Result = #{
        <<"model">> => Model,
        <<"messages">> => OpenAIMessages,
        <<"stream">> => Stream
    },

    R1 = maybe_set(<<"max_tokens">>, Body, Result),
    R2 = maybe_set(<<"temperature">>, Body, R1),
    R3 = maybe_set(<<"top_p">>, Body, R2),

    %% Map tools
    R4 = case maps:get(<<"tools">>, Body, undefined) of
        undefined -> R3;
        Tools -> R3#{<<"tools">> => translate_tools(Tools)}
    end,

    %% Map stop_sequences → stop
    R5 = case maps:get(<<"stop_sequences">>, Body, undefined) of
        undefined -> R4;
        Stops -> R4#{<<"stop">> => Stops}
    end,

    R5.

%%====================================================================
%% Response Translation: OpenAI → Claude (streaming)
%%====================================================================

-record(acc, {
    response_id = <<>> :: binary(),
    model = <<>> :: binary(),
    content_blocks = [] :: [map()],
    current_text = <<>> :: binary(),
    tool_calls = [] :: [map()],
    usage = #{} :: map(),
    finish_reason = <<>> :: binary()
}).

-spec init_acc() -> #acc{}.
init_acc() ->
    #acc{}.

-spec response_stream(map(), #acc{}) -> {[iodata()], #acc{}}.
response_stream(#{<<"id">> := Id, <<"model">> := Model,
                  <<"choices">> := [#{<<"delta">> := Delta} | _]} = Event, Acc) ->
    Acc1 = Acc#acc{response_id = Id, model = Model},

    %% Process delta content
    {Chunks, Acc2} = process_delta(Delta, Event, Acc1),
    {Chunks, Acc2};

response_stream(#{<<"choices">> := [#{<<"delta">> := Delta} | _]} = Event, Acc) ->
    {Chunks, Acc1} = process_delta(Delta, Event, Acc),
    {Chunks, Acc1};

response_stream(_Event, Acc) ->
    {[], Acc}.

-spec response_nonstream(map()) -> map().
response_nonstream(#{<<"choices">> := [#{<<"message">> := Msg} | _]} = Body) ->
    Content = build_claude_content(Msg),
    StopReason = translate_finish_reason(
        maps:get(<<"finish_reason">>,
                 hd(maps:get(<<"choices">>, Body)), <<>>)),
    #{
        <<"id">> => maps:get(<<"id">>, Body, <<>>),
        <<"type">> => <<"message">>,
        <<"role">> => <<"assistant">>,
        <<"model">> => maps:get(<<"model">>, Body, <<>>),
        <<"content">> => Content,
        <<"stop_reason">> => StopReason,
        <<"usage">> => translate_usage(maps:get(<<"usage">>, Body, #{}))
    };
response_nonstream(Body) ->
    Body.

%%====================================================================
%% Internal - Request
%%====================================================================

translate_messages(Messages) ->
    lists:flatten([translate_message(M) || M <- Messages]).

translate_message(#{<<"role">> := <<"assistant">>, <<"content">> := Content})
  when is_list(Content) ->
    %% Claude content blocks → OpenAI message
    {TextParts, ToolUseParts} = lists:partition(
        fun(#{<<"type">> := T}) -> T =/= <<"tool_use">>;
           (_) -> true
        end, Content),
    Text = iolist_to_binary([maps:get(<<"text">>, P, <<>>) || P <- TextParts,
                             maps:get(<<"type">>, P, <<>>) =:= <<"text">>]),
    Base = #{<<"role">> => <<"assistant">>, <<"content">> => Text},
    case ToolUseParts of
        [] -> Base;
        _ -> Base#{<<"tool_calls">> => [tool_use_to_call(T) || T <- ToolUseParts]}
    end;

translate_message(#{<<"role">> := <<"user">>, <<"content">> := Content})
  when is_list(Content) ->
    %% Check if content contains tool_result blocks
    case lists:any(fun(#{<<"type">> := T}) -> T =:= <<"tool_result">>; (_) -> false end, Content) of
        true ->
            %% Convert tool_results to tool messages
            [tool_result_to_msg(C) || C <- Content, maps:get(<<"type">>, C, <<>>) =:= <<"tool_result">>];
        false ->
            #{<<"role">> => <<"user">>,
              <<"content">> => [translate_content_part(P) || P <- Content]}
    end;

translate_message(#{<<"role">> := Role, <<"content">> := Content}) when is_binary(Content) ->
    #{<<"role">> => Role, <<"content">> => Content};

translate_message(Msg) ->
    Msg.

translate_content_part(#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text};
translate_content_part(#{<<"type">> := <<"image">>, <<"source">> := Source}) ->
    URL = case maps:get(<<"type">>, Source) of
        <<"base64">> ->
            MimeType = maps:get(<<"media_type">>, Source, <<"image/jpeg">>),
            Data = maps:get(<<"data">>, Source, <<>>),
            <<"data:", MimeType/binary, ";base64,", Data/binary>>;
        <<"url">> ->
            maps:get(<<"url">>, Source, <<>>)
    end,
    #{<<"type">> => <<"image_url">>,
      <<"image_url">> => #{<<"url">> => URL}};
translate_content_part(Part) ->
    Part.

tool_use_to_call(#{<<"id">> := Id, <<"name">> := Name, <<"input">> := Input}) ->
    #{<<"id">> => Id,
      <<"type">> => <<"function">>,
      <<"function">> => #{
          <<"name">> => Name,
          <<"arguments">> => jiffy:encode(Input)
      }};
tool_use_to_call(Other) -> Other.

tool_result_to_msg(#{<<"tool_use_id">> := Id, <<"content">> := Content}) ->
    #{<<"role">> => <<"tool">>,
      <<"tool_call_id">> => Id,
      <<"content">> => ensure_text(Content)};
tool_result_to_msg(Other) -> Other.

ensure_text(T) when is_binary(T) -> T;
ensure_text(Parts) when is_list(Parts) ->
    iolist_to_binary([maps:get(<<"text">>, P, <<>>) || P <- Parts]);
ensure_text(_) -> <<>>.

translate_tools(Tools) ->
    [translate_tool(T) || T <- Tools].

translate_tool(#{<<"name">> := Name} = T) ->
    #{<<"type">> => <<"function">>,
      <<"function">> => #{
          <<"name">> => Name,
          <<"description">> => maps:get(<<"description">>, T, <<>>),
          <<"parameters">> => maps:get(<<"input_schema">>, T, #{})
      }};
translate_tool(T) -> T.

maybe_set(Key, Source, Target) ->
    case maps:get(Key, Source, undefined) of
        undefined -> Target;
        Val -> Target#{Key => Val}
    end.

%%====================================================================
%% Internal - Response (streaming)
%%====================================================================

process_delta(Delta, Event, Acc) ->
    %% Handle text content
    Acc1 = case maps:get(<<"content">>, Delta, undefined) of
        undefined -> Acc;
        Text ->
            %% Build Claude content_block_delta event
            Acc#acc{current_text = <<(Acc#acc.current_text)/binary, Text/binary>>}
    end,

    %% Handle finish reason
    Acc2 = case maps:get(<<"finish_reason">>, Event, undefined) of
        undefined ->
            case maps:get(<<"finish_reason">>,
                         hd(maps:get(<<"choices">>, Event, [#{}])), undefined) of
                undefined -> Acc1;
                null -> Acc1;
                FR -> Acc1#acc{finish_reason = FR}
            end;
        _ -> Acc1
    end,

    %% Build Claude SSE events from the delta
    Chunks = build_claude_stream_events(Delta, Acc2),
    {Chunks, Acc2}.

build_claude_stream_events(Delta, Acc) ->
    case maps:get(<<"content">>, Delta, undefined) of
        undefined -> [];
        Text when is_binary(Text), Text =/= <<>> ->
            Event = #{
                <<"type">> => <<"content_block_delta">>,
                <<"index">> => 0,
                <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => Text}
            },
            [jiffy:encode(Event)];
        _ -> []
    end ++
    case maps:get(<<"reasoning_content">>, Delta, undefined) of
        undefined -> [];
        Thinking when is_binary(Thinking), Thinking =/= <<>> ->
            Event = #{
                <<"type">> => <<"content_block_delta">>,
                <<"index">> => 0,
                <<"delta">> => #{<<"type">> => <<"thinking_delta">>,
                                 <<"thinking">> => Thinking}
            },
            [jiffy:encode(Event)];
        _ -> []
    end ++
    case Acc#acc.finish_reason of
        <<>> -> [];
        _FR -> []  %% Final event handled separately
    end.

%%====================================================================
%% Internal - Response (non-streaming)
%%====================================================================

build_claude_content(#{<<"content">> := Content, <<"tool_calls">> := ToolCalls}) ->
    TextBlocks = case Content of
        <<>> -> [];
        null -> [];
        T when is_binary(T) -> [#{<<"type">> => <<"text">>, <<"text">> => T}];
        _ -> []
    end,
    ToolBlocks = [call_to_tool_use(TC) || TC <- ToolCalls],
    TextBlocks ++ ToolBlocks;

build_claude_content(#{<<"content">> := Content}) when is_binary(Content) ->
    [#{<<"type">> => <<"text">>, <<"text">> => Content}];

build_claude_content(_) ->
    [].

call_to_tool_use(#{<<"id">> := Id, <<"function">> := #{<<"name">> := Name,
                                                        <<"arguments">> := Args}}) ->
    Input = try jiffy:decode(Args, [return_maps]) catch _:_ -> #{} end,
    #{<<"type">> => <<"tool_use">>, <<"id">> => Id,
      <<"name">> => Name, <<"input">> => Input};
call_to_tool_use(Other) -> Other.

translate_finish_reason(<<"stop">>) -> <<"end_turn">>;
translate_finish_reason(<<"length">>) -> <<"max_tokens">>;
translate_finish_reason(<<"tool_calls">>) -> <<"tool_use">>;
translate_finish_reason(<<"content_filter">>) -> <<"end_turn">>;
translate_finish_reason(_) -> <<"end_turn">>.

translate_usage(#{<<"prompt_tokens">> := In, <<"completion_tokens">> := Out}) ->
    #{<<"input_tokens">> => In, <<"output_tokens">> => Out};
translate_usage(_) ->
    #{<<"input_tokens">> => 0, <<"output_tokens">> => 0}.
