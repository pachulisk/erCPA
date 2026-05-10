-module(translator_gemini_openai).
-behaviour(translator).

%% Gemini → OpenAI chat-completions
%% Reverse of translator_openai_gemini

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

register() ->
    translator_registry:register(gemini, openai, ?MODULE).

request(Model, Body, Stream) ->
    Contents = maps:get(<<"contents">>, Body, []),
    System = case maps:get(<<"systemInstruction">>, Body, undefined) of
        undefined -> undefined;
        #{<<"parts">> := Parts} ->
            iolist_to_binary([maps:get(<<"text">>, P, <<>>) || P <- Parts]);
        _ -> undefined
    end,
    Messages = [translate_content(C) || C <- Contents],
    Messages1 = case System of
        undefined -> Messages;
        Sys -> [#{<<"role">> => <<"system">>, <<"content">> => Sys} | Messages]
    end,
    GenConfig = maps:get(<<"generationConfig">>, Body, #{}),
    Result = #{<<"model">> => Model, <<"messages">> => Messages1, <<"stream">> => Stream},
    R1 = maybe_set(<<"max_tokens">>, <<"maxOutputTokens">>, GenConfig, Result),
    R2 = maybe_set(<<"temperature">>, <<"temperature">>, GenConfig, R1),
    R3 = maybe_set(<<"top_p">>, <<"topP">>, GenConfig, R2),
    case maps:get(<<"stopSequences">>, GenConfig, undefined) of
        undefined -> R3;
        Stops -> R3#{<<"stop">> => Stops}
    end.

init_acc() -> #{}.

response_stream(#{<<"choices">> := _} = Event, Acc) ->
    %% Already OpenAI format — pass through
    {[jiffy:encode(Event)], Acc};
response_stream(#{<<"candidates">> := [Cand | _]} = Event, Acc) ->
    Content = maps:get(<<"content">>, Cand, #{}),
    Parts = maps:get(<<"parts">>, Content, []),
    Texts = [maps:get(<<"text">>, P) || P <- Parts, maps:is_key(<<"text">>, P)],
    Text = iolist_to_binary(Texts),
    FinishReason = translate_finish(maps:get(<<"finishReason">>, Cand, undefined)),
    Chunk = #{<<"object">> => <<"chat.completion.chunk">>,
              <<"choices">> => [#{<<"index">> => 0,
                                  <<"delta">> => #{<<"content">> => Text},
                                  <<"finish_reason">> => FinishReason}]},
    Chunk1 = case maps:get(<<"usageMetadata">>, Event, undefined) of
        undefined -> Chunk;
        U -> Chunk#{<<"usage">> => translate_usage(U)}
    end,
    {[jiffy:encode(Chunk1)], Acc};
response_stream(_, Acc) -> {[], Acc}.

response_nonstream(#{<<"candidates">> := [Cand | _]} = Body) ->
    Content = maps:get(<<"content">>, Cand, #{}),
    Parts = maps:get(<<"parts">>, Content, []),
    Text = iolist_to_binary([maps:get(<<"text">>, P, <<>>) || P <- Parts, maps:is_key(<<"text">>, P)]),
    FuncCalls = lists:filtermap(fun(P) ->
        case maps:get(<<"functionCall">>, P, undefined) of
            undefined -> false;
            #{<<"name">> := N, <<"args">> := A} ->
                {true, #{<<"id">> => gen_id(), <<"type">> => <<"function">>,
                         <<"function">> => #{<<"name">> => N, <<"arguments">> => jiffy:encode(A)}}}
        end
    end, Parts),
    Msg = case FuncCalls of
        [] -> #{<<"role">> => <<"assistant">>, <<"content">> => Text};
        _ -> #{<<"role">> => <<"assistant">>, <<"content">> => Text, <<"tool_calls">> => FuncCalls}
    end,
    Usage = translate_usage(maps:get(<<"usageMetadata">>, Body, #{})),
    #{<<"id">> => gen_id(), <<"object">> => <<"chat.completion">>,
      <<"created">> => erlang:system_time(second),
      <<"model">> => maps:get(<<"modelVersion">>, Body, <<>>),
      <<"choices">> => [#{<<"index">> => 0, <<"message">> => Msg,
                          <<"finish_reason">> => translate_finish(maps:get(<<"finishReason">>, Cand, <<"STOP">>))}],
      <<"usage">> => Usage};
response_nonstream(Body) -> Body.

translate_content(#{<<"role">> := <<"model">>, <<"parts">> := Parts}) ->
    #{<<"role">> => <<"assistant">>, <<"content">> => parts_to_text(Parts)};
translate_content(#{<<"role">> := Role, <<"parts">> := Parts}) ->
    #{<<"role">> => Role, <<"content">> => parts_to_text(Parts)}.

parts_to_text(Parts) ->
    iolist_to_binary([maps:get(<<"text">>, P, <<>>) || P <- Parts, maps:is_key(<<"text">>, P)]).

translate_finish(<<"STOP">>) -> <<"stop">>;
translate_finish(<<"MAX_TOKENS">>) -> <<"length">>;
translate_finish(<<"SAFETY">>) -> <<"content_filter">>;
translate_finish(undefined) -> null;
translate_finish(_) -> <<"stop">>.

translate_usage(#{<<"promptTokenCount">> := In, <<"candidatesTokenCount">> := Out}) ->
    #{<<"prompt_tokens">> => In, <<"completion_tokens">> => Out, <<"total_tokens">> => In + Out};
translate_usage(#{<<"promptTokenCount">> := In}) ->
    #{<<"prompt_tokens">> => In, <<"completion_tokens">> => 0, <<"total_tokens">> => In};
translate_usage(_) ->
    #{<<"prompt_tokens">> => 0, <<"completion_tokens">> => 0, <<"total_tokens">> => 0}.

maybe_set(TK, SK, Src, Tgt) ->
    case maps:get(SK, Src, undefined) of undefined -> Tgt; V -> Tgt#{TK => V} end.

gen_id() -> <<"chatcmpl-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.
