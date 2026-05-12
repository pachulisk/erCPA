-module(translator_claude_codex).
-behaviour(translator).

%% Translates Claude messages format -> Codex (OpenAI Responses API) format
%% Source: Claude messages API
%% Target: Codex responses format (input array with instructions)
%% Reverse of translator_codex_claude.

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

register() ->
    translator_registry:register(claude, codex, ?MODULE).

%%====================================================================
%% Request Translation: Claude -> Codex
%%====================================================================

-spec request(binary(), map(), boolean()) -> map().
request(Model, Body, Stream) ->
    Messages = maps:get(<<"messages">>, Body, []),
    System = maps:get(<<"system">>, Body, undefined),
    Input = translate_messages(Messages),

    Result = #{
        <<"model">> => Model,
        <<"input">> => Input,
        <<"stream">> => Stream
    },

    R1 = case System of
        undefined -> Result;
        Sys when is_binary(Sys) -> Result#{<<"instructions">> => Sys};
        Sys when is_list(Sys) ->
            Text = iolist_to_binary([maps:get(<<"text">>, S, <<>>) || S <- Sys]),
            Result#{<<"instructions">> => Text}
    end,

    %% Map max_tokens -> max_output_tokens
    R2 = case maps:get(<<"max_tokens">>, Body, undefined) of
        undefined -> R1;
        Max -> R1#{<<"max_output_tokens">> => Max}
    end,

    %% Map temperature
    R3 = case maps:get(<<"temperature">>, Body, undefined) of
        undefined -> R2;
        Temp -> R2#{<<"temperature">> => Temp}
    end,

    %% Map tools: Claude schema -> Codex schema
    R4 = case maps:get(<<"tools">>, Body, undefined) of
        undefined -> R3;
        Tools -> R3#{<<"tools">> => translate_tools(Tools)}
    end,

    R4.

%%====================================================================
%% Response Translation: Codex -> Claude (streaming)
%%====================================================================

-record(acc, {
    response_id = <<>> :: binary(),
    model = <<>> :: binary(),
    current_text = <<>> :: binary(),
    block_started = false :: boolean()
}).

-spec init_acc() -> #acc{}.
init_acc() -> #acc{}.

-spec response_stream(map(), #acc{}) -> {[iodata()], #acc{}}.
response_stream(#{<<"type">> := <<"response.created">>,
                  <<"response">> := Resp}, Acc) ->
    Id = maps:get(<<"id">>, Resp, <<>>),
    Model = maps:get(<<"model">>, Resp, <<>>),
    %% Emit message_start
    Event = #{
        <<"type">> => <<"message_start">>,
        <<"message">> => #{
            <<"id">> => Id,
            <<"type">> => <<"message">>,
            <<"role">> => <<"assistant">>,
            <<"model">> => Model,
            <<"content">> => [],
            <<"usage">> => #{<<"input_tokens">> => 0, <<"output_tokens">> => 0}
        }
    },
    {[jiffy:encode(Event)], Acc#acc{response_id = Id, model = Model}};

response_stream(#{<<"type">> := <<"response.output_text.delta">>,
                  <<"delta">> := Text}, Acc) ->
    %% If first text delta, emit content_block_start
    StartEvents = case Acc#acc.block_started of
        false ->
            BlockStart = #{
                <<"type">> => <<"content_block_start">>,
                <<"index">> => 0,
                <<"content_block">> => #{<<"type">> => <<"text">>, <<"text">> => <<>>}
            },
            [jiffy:encode(BlockStart)];
        true -> []
    end,
    %% Emit content_block_delta with text_delta
    Delta = #{
        <<"type">> => <<"content_block_delta">>,
        <<"index">> => 0,
        <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => Text}
    },
    {StartEvents ++ [jiffy:encode(Delta)],
     Acc#acc{block_started = true,
             current_text = <<(Acc#acc.current_text)/binary, Text/binary>>}};

response_stream(#{<<"type">> := <<"response.completed">>,
                  <<"response">> := Resp}, Acc) ->
    Usage = maps:get(<<"usage">>, Resp, #{}),
    %% Emit message_delta with stop_reason and usage
    Event = #{
        <<"type">> => <<"message_delta">>,
        <<"delta">> => #{<<"stop_reason">> => <<"end_turn">>},
        <<"usage">> => #{
            <<"input_tokens">> => maps:get(<<"input_tokens">>, Usage, 0),
            <<"output_tokens">> => maps:get(<<"output_tokens">>, Usage, 0)
        }
    },
    {[jiffy:encode(Event)], Acc};

response_stream(_Event, Acc) ->
    {[], Acc}.

%%====================================================================
%% Response Translation: Codex -> Claude (non-streaming)
%%====================================================================

-spec response_nonstream(map()) -> map().
response_nonstream(#{<<"output">> := Output} = Body) ->
    Content = output_to_content(Output),
    Usage = maps:get(<<"usage">>, Body, #{}),
    #{
        <<"id">> => maps:get(<<"id">>, Body, <<>>),
        <<"type">> => <<"message">>,
        <<"role">> => <<"assistant">>,
        <<"model">> => maps:get(<<"model">>, Body, <<>>),
        <<"content">> => Content,
        <<"stop_reason">> => <<"end_turn">>,
        <<"usage">> => #{
            <<"input_tokens">> => maps:get(<<"input_tokens">>, Usage, 0),
            <<"output_tokens">> => maps:get(<<"output_tokens">>, Usage, 0)
        }
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
    %% Content blocks may contain text and tool_use
    {TextParts, ToolUseParts} = lists:partition(
        fun(#{<<"type">> := T}) -> T =/= <<"tool_use">>;
           (_) -> true
        end, Content),
    Texts = [maps:get(<<"text">>, P, <<>>) || P <- TextParts,
             maps:get(<<"type">>, P, <<>>) =:= <<"text">>],
    TextItems = case Texts of
        [] -> [];
        _ ->
            FullText = iolist_to_binary(Texts),
            [#{<<"type">> => <<"message">>,
               <<"role">> => <<"assistant">>,
               <<"content">> => FullText}]
    end,
    ToolItems = [#{
        <<"type">> => <<"function_call">>,
        <<"call_id">> => maps:get(<<"id">>, TU, <<>>),
        <<"name">> => maps:get(<<"name">>, TU, <<>>),
        <<"arguments">> => jiffy:encode(maps:get(<<"input">>, TU, #{}))
    } || TU <- ToolUseParts],
    TextItems ++ ToolItems;

translate_message(#{<<"role">> := <<"user">>, <<"content">> := Content})
  when is_list(Content) ->
    %% Check for tool_result blocks
    case lists:any(fun(#{<<"type">> := T}) -> T =:= <<"tool_result">>; (_) -> false end, Content) of
        true ->
            [#{<<"type">> => <<"function_call_output">>,
               <<"call_id">> => maps:get(<<"tool_use_id">>, C, <<>>),
               <<"output">> => ensure_text(maps:get(<<"content">>, C, <<>>))}
             || C <- Content, maps:get(<<"type">>, C, <<>>) =:= <<"tool_result">>];
        false ->
            Text = iolist_to_binary([maps:get(<<"text">>, P, <<>>) || P <- Content,
                                     maps:get(<<"type">>, P, <<>>) =:= <<"text">>]),
            [#{<<"type">> => <<"message">>,
               <<"role">> => <<"user">>,
               <<"content">> => Text}]
    end;

translate_message(#{<<"role">> := Role, <<"content">> := Content}) when is_binary(Content) ->
    [#{<<"type">> => <<"message">>, <<"role">> => Role, <<"content">> => Content}];

translate_message(_) ->
    [].

ensure_text(T) when is_binary(T) -> T;
ensure_text(Parts) when is_list(Parts) ->
    iolist_to_binary([maps:get(<<"text">>, P, <<>>) || P <- Parts]);
ensure_text(_) -> <<>>.

translate_tools(Tools) ->
    [#{<<"type">> => <<"function">>,
       <<"name">> => maps:get(<<"name">>, T, <<>>),
       <<"description">> => maps:get(<<"description">>, T, <<>>),
       <<"parameters">> => maps:get(<<"input_schema">>, T, #{})}
     || T <- Tools].

%%====================================================================
%% Internal - Response
%%====================================================================

output_to_content(Output) when is_list(Output) ->
    lists:flatten([output_item_to_content(I) || I <- Output]);
output_to_content(_) -> [].

output_item_to_content(#{<<"type">> := <<"message">>,
                         <<"content">> := Content}) when is_list(Content) ->
    Texts = [maps:get(<<"text">>, C, <<>>) || C <- Content,
             maps:get(<<"type">>, C, <<>>) =:= <<"output_text">>],
    case Texts of
        [] -> [];
        _ -> [#{<<"type">> => <<"text">>, <<"text">> => iolist_to_binary(Texts)}]
    end;
output_item_to_content(#{<<"type">> := <<"function_call">>,
                         <<"call_id">> := CallId,
                         <<"name">> := Name,
                         <<"arguments">> := Args}) ->
    Input = try jiffy:decode(Args, [return_maps]) catch _:_ -> #{} end,
    [#{<<"type">> => <<"tool_use">>,
       <<"id">> => CallId,
       <<"name">> => Name,
       <<"input">> => Input}];
output_item_to_content(_) -> [].
