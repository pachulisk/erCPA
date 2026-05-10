-module(translator_codex_claude).
-behaviour(translator).

%% Translates Codex (OpenAI Responses API) format → Claude messages format
%% Source: Codex responses format (input array with instructions)
%% Target: Claude messages API

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

register() ->
    translator_registry:register(codex, claude, ?MODULE).

%%====================================================================
%% Request Translation: Codex → Claude
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

    %% Map max_output_tokens → max_tokens
    R2 = case maps:get(<<"max_output_tokens">>, Body, undefined) of
        undefined -> R1;
        Max -> R1#{<<"max_tokens">> => Max}
    end,

    %% Map temperature
    R3 = case maps:get(<<"temperature">>, Body, undefined) of
        undefined -> R2;
        Temp -> R2#{<<"temperature">> => Temp}
    end,

    %% Map tools
    R4 = case maps:get(<<"tools">>, Body, undefined) of
        undefined -> R3;
        Tools -> R3#{<<"tools">> => translate_tools(Tools)}
    end,

    R4.

%%====================================================================
%% Response Translation: Claude → Codex (streaming)
%%====================================================================

-record(acc, {
    response_id = <<>> :: binary(),
    model = <<>> :: binary(),
    output_items = [] :: [map()],
    current_text = <<>> :: binary(),
    seq = 0 :: non_neg_integer()
}).

-spec init_acc() -> #acc{}.
init_acc() -> #acc{}.

-spec response_stream(map(), #acc{}) -> {[iodata()], #acc{}}.
response_stream(#{<<"type">> := <<"message_start">>,
                  <<"message">> := Msg}, Acc) ->
    Id = maps:get(<<"id">>, Msg, <<>>),
    Model = maps:get(<<"model">>, Msg, <<>>),
    %% Emit response.created event
    Event = #{
        <<"type">> => <<"response.created">>,
        <<"sequence_number">> => 0,
        <<"response">> => #{
            <<"id">> => Id,
            <<"object">> => <<"response">>,
            <<"status">> => <<"in_progress">>,
            <<"output">> => [],
            <<"model">> => Model
        }
    },
    {[jiffy:encode(Event)], Acc#acc{response_id = Id, model = Model, seq = 1}};

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

response_stream(#{<<"type">> := <<"message_delta">>,
                  <<"usage">> := Usage}, Acc) ->
    %% Emit response.completed
    Event = #{
        <<"type">> => <<"response.completed">>,
        <<"sequence_number">> => Acc#acc.seq,
        <<"response">> => #{
            <<"id">> => Acc#acc.response_id,
            <<"object">> => <<"response">>,
            <<"status">> => <<"completed">>,
            <<"model">> => Acc#acc.model,
            <<"output">> => [#{
                <<"type">> => <<"message">>,
                <<"role">> => <<"assistant">>,
                <<"content">> => [#{
                    <<"type">> => <<"output_text">>,
                    <<"text">> => Acc#acc.current_text
                }]
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
%% Response Translation: Claude → Codex (non-streaming)
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
%% Internal - Request
%%====================================================================

translate_input(Input) ->
    lists:filtermap(fun translate_input_item/1, Input).

translate_input_item(#{<<"type">> := <<"message">>, <<"role">> := Role,
                       <<"content">> := Content}) when is_binary(Content) ->
    {true, #{<<"role">> => Role, <<"content">> => Content}};

translate_input_item(#{<<"type">> := <<"message">>, <<"role">> := Role,
                       <<"content">> := Content}) when is_list(Content) ->
    ClaudeContent = [translate_input_content(C) || C <- Content],
    {true, #{<<"role">> => Role, <<"content">> => ClaudeContent}};

translate_input_item(#{<<"type">> := <<"function_call">>,
                       <<"call_id">> := CallId,
                       <<"name">> := Name,
                       <<"arguments">> := Args}) ->
    Input = try jiffy:decode(Args, [return_maps]) catch _:_ -> #{} end,
    {true, #{<<"role">> => <<"assistant">>,
             <<"content">> => [#{
                 <<"type">> => <<"tool_use">>,
                 <<"id">> => CallId,
                 <<"name">> => Name,
                 <<"input">> => Input
             }]}};

translate_input_item(#{<<"type">> := <<"function_call_output">>,
                       <<"call_id">> := CallId,
                       <<"output">> := Output}) ->
    {true, #{<<"role">> => <<"user">>,
             <<"content">> => [#{
                 <<"type">> => <<"tool_result">>,
                 <<"tool_use_id">> => CallId,
                 <<"content">> => Output
             }]}};

translate_input_item(_) ->
    false.

translate_input_content(#{<<"type">> := <<"input_text">>, <<"text">> := Text}) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text};
translate_input_content(#{<<"type">> := <<"output_text">>, <<"text">> := Text}) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text};
translate_input_content(Other) ->
    Other.

translate_tools(Tools) ->
    lists:filtermap(fun
        (#{<<"type">> := <<"function">>, <<"name">> := Name} = T) ->
            {true, #{
                <<"name">> => Name,
                <<"description">> => maps:get(<<"description">>, T, <<>>),
                <<"input_schema">> => maps:get(<<"parameters">>, T, #{})
            }};
        (_) -> false
    end, Tools).

%%====================================================================
%% Internal - Response
%%====================================================================

content_to_output_items(Content) when is_list(Content) ->
    %% Group text and tool_use separately
    Texts = [maps:get(<<"text">>, C, <<>>) || C <- Content,
             maps:get(<<"type">>, C, <<>>) =:= <<"text">>],
    ToolUses = [C || C <- Content, maps:get(<<"type">>, C, <<>>) =:= <<"tool_use">>],

    TextItem = case Texts of
        [] -> [];
        _ ->
            FullText = iolist_to_binary(Texts),
            [#{<<"type">> => <<"message">>,
               <<"role">> => <<"assistant">>,
               <<"content">> => [#{<<"type">> => <<"output_text">>, <<"text">> => FullText}]}]
    end,

    ToolItems = [#{
        <<"type">> => <<"function_call">>,
        <<"call_id">> => maps:get(<<"id">>, TU, <<>>),
        <<"name">> => maps:get(<<"name">>, TU, <<>>),
        <<"arguments">> => jiffy:encode(maps:get(<<"input">>, TU, #{}))
    } || TU <- ToolUses],

    TextItem ++ ToolItems;
content_to_output_items(_) ->
    [].
