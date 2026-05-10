-module(translator_openai_responses_claude).
-behaviour(translator).

%% Translates OpenAI Responses API format → Claude messages format
%% Source: POST /v1/responses (Responses API)
%% Target: Claude messages API

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([response_stream_responses/1]).
-export([register/0]).

register() ->
    translator_registry:register(openai_response, claude, ?MODULE).

%%====================================================================
%% Request Translation: Responses API → Claude
%%====================================================================

-spec request(binary(), map(), boolean()) -> map().
request(Model, Body, Stream) ->
    Instructions = maps:get(<<"instructions">>, Body, <<>>),
    Input = maps:get(<<"input">>, Body, []),
    Messages = translate_input(Input),

    Result = #{
        <<"model">> => Model,
        <<"messages">> => Messages,
        <<"stream">> => Stream
    },

    R1 = case Instructions of
        <<>> -> Result;
        _ -> Result#{<<"system">> => Instructions}
    end,

    %% max_output_tokens
    R2 = case maps:get(<<"max_output_tokens">>, Body, undefined) of
        undefined -> R1;
        Max -> R1#{<<"max_tokens">> => Max}
    end,

    %% temperature
    R3 = case maps:get(<<"temperature">>, Body, undefined) of
        undefined -> R2;
        Temp -> R2#{<<"temperature">> => Temp}
    end,

    %% tools
    R4 = case maps:get(<<"tools">>, Body, undefined) of
        undefined -> R3;
        [] -> R3;
        Tools -> R3#{<<"tools">> => translate_tools(Tools)}
    end,

    %% reasoning → thinking
    R5 = case maps:get(<<"reasoning">>, Body, undefined) of
        undefined -> R4;
        #{<<"effort">> := Effort} ->
            R4#{<<"thinking">> => #{
                <<"type">> => <<"enabled">>,
                <<"budget_tokens">> => effort_to_budget(Effort)
            }};
        _ -> R4
    end,

    R5.

%%====================================================================
%% Response Translation: Claude → Responses API (streaming events)
%%====================================================================

-record(acc, {
    response_id = <<>> :: binary(),
    model = <<>> :: binary(),
    seq = 0 :: non_neg_integer(),
    current_text = <<>> :: binary(),
    output_items = [] :: [map()],
    tool_calls = [] :: [map()]
}).

-spec init_acc() -> #acc{}.
init_acc() -> #acc{}.

-spec response_stream(map(), #acc{}) -> {[iodata()], #acc{}}.
response_stream(#{<<"type">> := <<"message_start">>,
                  <<"message">> := Msg}, Acc) ->
    Id = maps:get(<<"id">>, Msg, <<>>),
    Model = maps:get(<<"model">>, Msg, <<>>),
    Events = [
        #{<<"type">> => <<"response.created">>,
          <<"sequence_number">> => 0,
          <<"response">> => #{<<"id">> => Id, <<"status">> => <<"in_progress">>,
                              <<"model">> => Model, <<"output">> => []}},
        #{<<"type">> => <<"response.in_progress">>,
          <<"sequence_number">> => 1}
    ],
    {[jiffy:encode(E) || E <- Events],
     Acc#acc{response_id = Id, model = Model, seq = 2}};

response_stream(#{<<"type">> := <<"content_block_start">>,
                  <<"index">> := Idx,
                  <<"content_block">> := #{<<"type">> := <<"text">>}}, Acc) ->
    Event = #{
        <<"type">> => <<"response.output_item.added">>,
        <<"sequence_number">> => Acc#acc.seq,
        <<"output_index">> => Idx,
        <<"item">> => #{<<"type">> => <<"message">>, <<"role">> => <<"assistant">>,
                        <<"status">> => <<"in_progress">>, <<"content">> => []}
    },
    {[jiffy:encode(Event)], Acc#acc{seq = Acc#acc.seq + 1}};

response_stream(#{<<"type">> := <<"content_block_delta">>,
                  <<"delta">> := #{<<"type">> := <<"text_delta">>,
                                   <<"text">> := Text}}, Acc) ->
    Event = #{
        <<"type">> => <<"response.output_text.delta">>,
        <<"sequence_number">> => Acc#acc.seq,
        <<"output_index">> => 0,
        <<"content_index">> => 0,
        <<"delta">> => Text
    },
    {[jiffy:encode(Event)],
     Acc#acc{seq = Acc#acc.seq + 1,
             current_text = <<(Acc#acc.current_text)/binary, Text/binary>>}};

response_stream(#{<<"type">> := <<"content_block_start">>,
                  <<"index">> := Idx,
                  <<"content_block">> := #{<<"type">> := <<"tool_use">>,
                                           <<"id">> := ToolId,
                                           <<"name">> := Name}}, Acc) ->
    Event = #{
        <<"type">> => <<"response.output_item.added">>,
        <<"sequence_number">> => Acc#acc.seq,
        <<"output_index">> => Idx,
        <<"item">> => #{<<"type">> => <<"function_call">>,
                        <<"call_id">> => ToolId,
                        <<"name">> => Name,
                        <<"status">> => <<"in_progress">>,
                        <<"arguments">> => <<>>}
    },
    {[jiffy:encode(Event)], Acc#acc{seq = Acc#acc.seq + 1}};

response_stream(#{<<"type">> := <<"content_block_delta">>,
                  <<"delta">> := #{<<"type">> := <<"input_json_delta">>,
                                   <<"partial_json">> := Partial}}, Acc) ->
    Event = #{
        <<"type">> => <<"response.function_call_arguments.delta">>,
        <<"sequence_number">> => Acc#acc.seq,
        <<"output_index">> => 0,
        <<"delta">> => Partial
    },
    {[jiffy:encode(Event)], Acc#acc{seq = Acc#acc.seq + 1}};

response_stream(#{<<"type">> := <<"message_delta">>,
                  <<"usage">> := Usage}, Acc) ->
    Event = #{
        <<"type">> => <<"response.completed">>,
        <<"sequence_number">> => Acc#acc.seq,
        <<"response">> => #{
            <<"id">> => Acc#acc.response_id,
            <<"status">> => <<"completed">>,
            <<"model">> => Acc#acc.model,
            <<"output">> => [#{
                <<"type">> => <<"message">>,
                <<"role">> => <<"assistant">>,
                <<"status">> => <<"completed">>,
                <<"content">> => [#{<<"type">> => <<"output_text">>,
                                    <<"text">> => Acc#acc.current_text}]
            }],
            <<"usage">> => #{
                <<"input_tokens">> => maps:get(<<"input_tokens">>, Usage, 0),
                <<"output_tokens">> => maps:get(<<"output_tokens">>, Usage, 0),
                <<"total_tokens">> => maps:get(<<"input_tokens">>, Usage, 0) +
                                      maps:get(<<"output_tokens">>, Usage, 0)
            }
        }
    },
    {[jiffy:encode(Event)], Acc#acc{seq = Acc#acc.seq + 1}};

response_stream(_Event, Acc) ->
    {[], Acc}.

%%====================================================================
%% Responses API event pass-through (for WS handler)
%%====================================================================

-spec response_stream_responses(map()) -> [map()].
response_stream_responses(Event) ->
    %% For now, delegates to response_stream logic
    Acc0 = init_acc(),
    {Chunks, _} = response_stream(Event, Acc0),
    [jiffy:decode(C, [return_maps]) || C <- Chunks].

%%====================================================================
%% Response Translation: Claude → Responses API (non-streaming)
%%====================================================================

-spec response_nonstream(map()) -> map().
response_nonstream(#{<<"content">> := Content} = Body) ->
    Id = maps:get(<<"id">>, Body, <<>>),
    Model = maps:get(<<"model">>, Body, <<>>),
    Usage = maps:get(<<"usage">>, Body, #{}),

    OutputItems = content_to_output_items(Content),

    #{
        <<"id">> => Id,
        <<"object">> => <<"response">>,
        <<"status">> => <<"completed">>,
        <<"model">> => Model,
        <<"output">> => OutputItems,
        <<"usage">> => #{
            <<"input_tokens">> => maps:get(<<"input_tokens">>, Usage, 0),
            <<"output_tokens">> => maps:get(<<"output_tokens">>, Usage, 0),
            <<"total_tokens">> => maps:get(<<"input_tokens">>, Usage, 0) +
                                  maps:get(<<"output_tokens">>, Usage, 0)
        }
    };
response_nonstream(Body) ->
    Body.

%%====================================================================
%% Internal
%%====================================================================

translate_input(Input) ->
    lists:filtermap(fun translate_input_item/1, Input).

translate_input_item(#{<<"type">> := <<"message">>, <<"role">> := Role,
                       <<"content">> := Content}) when is_binary(Content) ->
    {true, #{<<"role">> => Role, <<"content">> => Content}};

translate_input_item(#{<<"type">> := <<"message">>, <<"role">> := Role,
                       <<"content">> := Content}) when is_list(Content) ->
    Translated = [translate_content_part(C) || C <- Content],
    {true, #{<<"role">> => Role, <<"content">> => Translated}};

translate_input_item(#{<<"type">> := <<"function_call">>,
                       <<"call_id">> := CallId,
                       <<"name">> := Name,
                       <<"arguments">> := Args}) ->
    Input = try jiffy:decode(Args, [return_maps]) catch _:_ -> #{} end,
    {true, #{<<"role">> => <<"assistant">>,
             <<"content">> => [#{<<"type">> => <<"tool_use">>,
                                 <<"id">> => CallId,
                                 <<"name">> => Name,
                                 <<"input">> => Input}]}};

translate_input_item(#{<<"type">> := <<"function_call_output">>,
                       <<"call_id">> := CallId,
                       <<"output">> := Output}) ->
    {true, #{<<"role">> => <<"user">>,
             <<"content">> => [#{<<"type">> => <<"tool_result">>,
                                 <<"tool_use_id">> => CallId,
                                 <<"content">> => Output}]}};

translate_input_item(_) ->
    false.

translate_content_part(#{<<"type">> := <<"input_text">>, <<"text">> := Text}) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text};
translate_content_part(#{<<"type">> := <<"output_text">>, <<"text">> := Text}) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text};
translate_content_part(Other) ->
    Other.

translate_tools(Tools) ->
    lists:filtermap(fun
        (#{<<"type">> := <<"function">>, <<"name">> := Name} = T) ->
            {true, #{<<"name">> => Name,
                     <<"description">> => maps:get(<<"description">>, T, <<>>),
                     <<"input_schema">> => maps:get(<<"parameters">>, T, #{})}};
        (_) -> false
    end, Tools).

effort_to_budget(<<"low">>) -> 4096;
effort_to_budget(<<"medium">>) -> 16384;
effort_to_budget(<<"high">>) -> 65536;
effort_to_budget(<<"max">>) -> 128000;
effort_to_budget(_) -> 16384.

content_to_output_items(Content) when is_list(Content) ->
    Texts = [maps:get(<<"text">>, C, <<>>) || C <- Content,
             maps:get(<<"type">>, C, <<>>) =:= <<"text">>],
    ToolUses = [C || C <- Content, maps:get(<<"type">>, C, <<>>) =:= <<"tool_use">>],

    TextItems = case Texts of
        [] -> [];
        _ ->
            [#{<<"type">> => <<"message">>,
               <<"role">> => <<"assistant">>,
               <<"status">> => <<"completed">>,
               <<"content">> => [#{<<"type">> => <<"output_text">>,
                                   <<"text">> => iolist_to_binary(Texts)}]}]
    end,

    ToolItems = [#{<<"type">> => <<"function_call">>,
                   <<"call_id">> => maps:get(<<"id">>, TU, <<>>),
                   <<"name">> => maps:get(<<"name">>, TU, <<>>),
                   <<"arguments">> => jiffy:encode(maps:get(<<"input">>, TU, #{}))}
                 || TU <- ToolUses],

    TextItems ++ ToolItems;
content_to_output_items(_) ->
    [].
