-module(translator_openai_claude).
-behaviour(translator).

%% Translates OpenAI chat-completions format → Claude messages format
%% Source: POST /v1/chat/completions (OpenAI)
%% Target: POST /v1/messages (Claude)

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

register() ->
    translator_registry:register(openai, claude, ?MODULE).

%%====================================================================
%% Request Translation: OpenAI → Claude
%%====================================================================

-spec request(binary(), map(), boolean()) -> map().
request(Model, Body, Stream) ->
    Messages = maps:get(<<"messages">>, Body, []),
    {System, UserMessages} = extract_system(Messages),
    TranslatedMessages = translate_messages(UserMessages),

    Result = #{
        <<"model">> => Model,
        <<"messages">> => TranslatedMessages,
        <<"stream">> => Stream
    },

    %% Add system if present
    R1 = case System of
        <<>> -> Result;
        _ -> Result#{<<"system">> => System}
    end,

    %% Map max_tokens
    R2 = case maps:get(<<"max_tokens">>, Body, undefined) of
        undefined -> R1;
        MaxTokens -> R1#{<<"max_tokens">> => MaxTokens}
    end,

    %% Map temperature
    R3 = case maps:get(<<"temperature">>, Body, undefined) of
        undefined -> R2;
        Temp -> R2#{<<"temperature">> => Temp}
    end,

    %% Map top_p
    R4 = case maps:get(<<"top_p">>, Body, undefined) of
        undefined -> R3;
        TopP -> R3#{<<"top_p">> => TopP}
    end,

    %% Map tools
    R5 = case maps:get(<<"tools">>, Body, undefined) of
        undefined -> R4;
        Tools -> R4#{<<"tools">> => translate_tools(Tools)}
    end,

    %% Map stop sequences
    R6 = case maps:get(<<"stop">>, Body, undefined) of
        undefined -> R5;
        Stop when is_list(Stop) -> R5#{<<"stop_sequences">> => Stop};
        Stop when is_binary(Stop) -> R5#{<<"stop_sequences">> => [Stop]};
        _ -> R5
    end,

    R6.

%%====================================================================
%% Response Translation: Claude → OpenAI (streaming)
%%====================================================================

-record(acc, {
    response_id = <<>> :: binary(),
    model = <<>> :: binary(),
    finish_reason = <<>> :: binary(),
    tool_calls = #{} :: #{integer() => map()},
    usage = #{} :: map()
}).

-spec init_acc() -> #acc{}.
init_acc() ->
    #acc{}.

-spec response_stream(map(), #acc{}) -> {[iodata()], #acc{}}.
response_stream(#{<<"type">> := <<"message_start">>,
                  <<"message">> := Msg}, Acc) ->
    Id = maps:get(<<"id">>, Msg, <<>>),
    Model = maps:get(<<"model">>, Msg, <<>>),
    Chunk = build_stream_chunk(Id, Model, <<>>, null, #{}),
    {[jiffy:encode(Chunk)], Acc#acc{response_id = Id, model = Model}};

response_stream(#{<<"type">> := <<"content_block_delta">>,
                  <<"delta">> := #{<<"type">> := <<"text_delta">>,
                                   <<"text">> := Text}}, Acc) ->
    Chunk = build_stream_chunk(Acc#acc.response_id, Acc#acc.model, Text, null, #{}),
    {[jiffy:encode(Chunk)], Acc};

response_stream(#{<<"type">> := <<"content_block_delta">>,
                  <<"delta">> := #{<<"type">> := <<"thinking_delta">>,
                                   <<"thinking">> := Thinking}}, Acc) ->
    Chunk = #{
        <<"id">> => Acc#acc.response_id,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"model">> => Acc#acc.model,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"delta">> => #{<<"reasoning_content">> => Thinking},
            <<"finish_reason">> => null
        }]
    },
    {[jiffy:encode(Chunk)], Acc};

response_stream(#{<<"type">> := <<"content_block_start">>,
                  <<"index">> := Idx,
                  <<"content_block">> := #{<<"type">> := <<"tool_use">>,
                                           <<"id">> := ToolId,
                                           <<"name">> := Name}}, Acc) ->
    ToolCalls = maps:put(Idx, #{id => ToolId, name => Name, args => <<>>},
                         Acc#acc.tool_calls),
    %% Emit tool call start chunk
    Chunk = #{
        <<"id">> => Acc#acc.response_id,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"model">> => Acc#acc.model,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"delta">> => #{
                <<"tool_calls">> => [#{
                    <<"index">> => Idx,
                    <<"id">> => ToolId,
                    <<"type">> => <<"function">>,
                    <<"function">> => #{<<"name">> => Name, <<"arguments">> => <<>>}
                }]
            },
            <<"finish_reason">> => null
        }]
    },
    {[jiffy:encode(Chunk)], Acc#acc{tool_calls = ToolCalls}};

response_stream(#{<<"type">> := <<"content_block_delta">>,
                  <<"index">> := Idx,
                  <<"delta">> := #{<<"type">> := <<"input_json_delta">>,
                                   <<"partial_json">> := Partial}}, Acc) ->
    %% Accumulate tool call arguments
    ToolCalls = case maps:get(Idx, Acc#acc.tool_calls, undefined) of
        undefined -> Acc#acc.tool_calls;
        TC -> maps:put(Idx, TC#{args => <<(maps:get(args, TC))/binary, Partial/binary>>},
                       Acc#acc.tool_calls)
    end,
    Chunk = #{
        <<"id">> => Acc#acc.response_id,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"model">> => Acc#acc.model,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"delta">> => #{
                <<"tool_calls">> => [#{
                    <<"index">> => Idx,
                    <<"function">> => #{<<"arguments">> => Partial}
                }]
            },
            <<"finish_reason">> => null
        }]
    },
    {[jiffy:encode(Chunk)], Acc#acc{tool_calls = ToolCalls}};

response_stream(#{<<"type">> := <<"message_delta">>,
                  <<"delta">> := Delta} = Event, Acc) ->
    StopReason = maps:get(<<"stop_reason">>, Delta, <<>>),
    FinishReason = translate_stop_reason(StopReason),
    Usage = maps:get(<<"usage">>, Event, #{}),
    Chunk = #{
        <<"id">> => Acc#acc.response_id,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"model">> => Acc#acc.model,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"delta">> => #{},
            <<"finish_reason">> => FinishReason
        }],
        <<"usage">> => translate_usage_stream(Usage, Acc#acc.usage)
    },
    {[jiffy:encode(Chunk)], Acc#acc{finish_reason = FinishReason, usage = Usage}};

response_stream(_Event, Acc) ->
    {[], Acc}.

%%====================================================================
%% Response Translation: Claude → OpenAI (non-streaming)
%%====================================================================

-spec response_nonstream(map()) -> map().
response_nonstream(#{<<"content">> := Content} = Body) ->
    #{
        <<"id">> => maps:get(<<"id">>, Body, <<>>),
        <<"object">> => <<"chat.completion">>,
        <<"created">> => erlang:system_time(second),
        <<"model">> => maps:get(<<"model">>, Body, <<>>),
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"message">> => build_message_from_content(Content),
            <<"finish_reason">> => translate_stop_reason(
                maps:get(<<"stop_reason">>, Body, <<>>))
        }],
        <<"usage">> => translate_usage(maps:get(<<"usage">>, Body, #{}))
    };
response_nonstream(Body) ->
    Body.

%%====================================================================
%% Internal helpers
%%====================================================================

extract_system(Messages) ->
    case Messages of
        [#{<<"role">> := <<"system">>, <<"content">> := Sys} | Rest] ->
            {ensure_binary(Sys), Rest};
        _ ->
            {<<>>, Messages}
    end.

ensure_binary(S) when is_binary(S) -> S;
ensure_binary(Parts) when is_list(Parts) ->
    iolist_to_binary([maps:get(<<"text">>, P, <<>>) || P <- Parts,
                      maps:get(<<"type">>, P, <<>>) =:= <<"text">>]);
ensure_binary(_) -> <<>>.

translate_messages(Messages) ->
    [translate_message(M) || M <- Messages].

translate_message(#{<<"role">> := <<"assistant">>, <<"tool_calls">> := ToolCalls} = Msg) ->
    %% Assistant message with tool calls → tool_use content blocks
    TextContent = case maps:get(<<"content">>, Msg, <<>>) of
        <<>> -> [];
        null -> [];
        Text when is_binary(Text) -> [#{<<"type">> => <<"text">>, <<"text">> => Text}];
        Parts when is_list(Parts) -> Parts
    end,
    ToolUseBlocks = [translate_tool_call_to_use(TC) || TC <- ToolCalls],
    #{<<"role">> => <<"assistant">>,
      <<"content">> => TextContent ++ ToolUseBlocks};

translate_message(#{<<"role">> := <<"tool">>, <<"tool_call_id">> := CallId,
                    <<"content">> := Content}) ->
    %% Tool result message → tool_result content block
    #{<<"role">> => <<"user">>,
      <<"content">> => [#{
          <<"type">> => <<"tool_result">>,
          <<"tool_use_id">> => CallId,
          <<"content">> => Content
      }]};

translate_message(#{<<"role">> := Role, <<"content">> := Content}) when is_binary(Content) ->
    #{<<"role">> => Role, <<"content">> => Content};

translate_message(#{<<"role">> := Role, <<"content">> := Content}) when is_list(Content) ->
    %% Multi-part content (text + images)
    #{<<"role">> => Role, <<"content">> => [translate_content_part(P) || P <- Content]};

translate_message(Msg) ->
    Msg.

translate_content_part(#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text};

translate_content_part(#{<<"type">> := <<"image_url">>,
                         <<"image_url">> := #{<<"url">> := URL}}) ->
    case parse_data_url(URL) of
        {ok, MimeType, Data} ->
            #{<<"type">> => <<"image">>,
              <<"source">> => #{
                  <<"type">> => <<"base64">>,
                  <<"media_type">> => MimeType,
                  <<"data">> => Data
              }};
        {url, _} ->
            #{<<"type">> => <<"image">>,
              <<"source">> => #{
                  <<"type">> => <<"url">>,
                  <<"url">> => URL
              }}
    end;

translate_content_part(Part) ->
    Part.

parse_data_url(<<"data:", Rest/binary>>) ->
    case binary:split(Rest, <<";">>) of
        [MimeType, <<"base64,", Data/binary>>] ->
            {ok, MimeType, Data};
        _ ->
            {url, <<"data:", Rest/binary>>}
    end;
parse_data_url(URL) ->
    {url, URL}.

translate_tool_call_to_use(#{<<"id">> := Id, <<"function">> := Func}) ->
    Name = maps:get(<<"name">>, Func, <<>>),
    ArgsStr = maps:get(<<"arguments">>, Func, <<"{}">>),
    Input = try jiffy:decode(ArgsStr, [return_maps]) catch _:_ -> #{} end,
    #{<<"type">> => <<"tool_use">>,
      <<"id">> => Id,
      <<"name">> => Name,
      <<"input">> => Input};
translate_tool_call_to_use(TC) ->
    TC.

translate_tools(Tools) ->
    [translate_tool(T) || T <- Tools].

translate_tool(#{<<"type">> := <<"function">>, <<"function">> := Func}) ->
    #{<<"name">> => maps:get(<<"name">>, Func, <<>>),
      <<"description">> => maps:get(<<"description">>, Func, <<>>),
      <<"input_schema">> => maps:get(<<"parameters">>, Func, #{})};
translate_tool(T) ->
    T.

translate_stop_reason(<<"end_turn">>) -> <<"stop">>;
translate_stop_reason(<<"stop_sequence">>) -> <<"stop">>;
translate_stop_reason(<<"max_tokens">>) -> <<"length">>;
translate_stop_reason(<<"tool_use">>) -> <<"tool_calls">>;
translate_stop_reason(<<>>) -> null;
translate_stop_reason(_) -> <<"stop">>.

translate_usage(#{<<"input_tokens">> := In, <<"output_tokens">> := Out} = U) ->
    Base = #{
        <<"prompt_tokens">> => In,
        <<"completion_tokens">> => Out,
        <<"total_tokens">> => In + Out
    },
    %% Add cache tokens if present
    case maps:get(<<"cache_read_input_tokens">>, U, 0) of
        0 -> Base;
        CacheRead -> Base#{<<"prompt_tokens_details">> =>
                           #{<<"cached_tokens">> => CacheRead}}
    end;
translate_usage(_) ->
    #{<<"prompt_tokens">> => 0, <<"completion_tokens">> => 0, <<"total_tokens">> => 0}.

translate_usage_stream(Usage, _PrevUsage) ->
    translate_usage(Usage).

build_stream_chunk(Id, Model, Text, FinishReason, _Extra) ->
    Delta = case Text of
        <<>> -> #{};
        _ -> #{<<"content">> => Text}
    end,
    #{
        <<"id">> => Id,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"model">> => Model,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"delta">> => Delta,
            <<"finish_reason">> => FinishReason
        }]
    }.

build_message_from_content(Content) when is_list(Content) ->
    %% Extract text and tool_use blocks
    {Texts, ToolCalls} = lists:partition(
        fun(#{<<"type">> := T}) -> T =:= <<"text">>;
           (_) -> true
        end, Content),
    TextStr = iolist_to_binary([maps:get(<<"text">>, T, <<>>) || T <- Texts]),
    Base = #{<<"role">> => <<"assistant">>, <<"content">> => TextStr},
    case ToolCalls of
        [] -> Base;
        _ -> Base#{<<"tool_calls">> => [translate_use_to_call(TC) || TC <- ToolCalls]}
    end;
build_message_from_content(Content) when is_binary(Content) ->
    #{<<"role">> => <<"assistant">>, <<"content">> => Content};
build_message_from_content(_) ->
    #{<<"role">> => <<"assistant">>, <<"content">> => <<>>}.

translate_use_to_call(#{<<"type">> := <<"tool_use">>, <<"id">> := Id,
                        <<"name">> := Name, <<"input">> := Input}) ->
    #{<<"id">> => Id,
      <<"type">> => <<"function">>,
      <<"function">> => #{
          <<"name">> => Name,
          <<"arguments">> => jiffy:encode(Input)
      }};
translate_use_to_call(Other) ->
    Other.
