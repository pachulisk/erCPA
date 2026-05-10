-module(translator_claude_gemini).
-behaviour(translator).

%% Claude → Gemini

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

register() ->
    translator_registry:register(claude, gemini, ?MODULE).

request(Model, Body, _Stream) ->
    Messages = maps:get(<<"messages">>, Body, []),
    System = maps:get(<<"system">>, Body, undefined),
    Contents = [translate_msg(M) || M <- Messages],
    Result = #{<<"contents">> => Contents},
    R1 = case System of
        undefined -> Result;
        Sys when is_binary(Sys) ->
            Result#{<<"systemInstruction">> => #{<<"parts">> => [#{<<"text">> => Sys}]}};
        _ -> Result
    end,
    GenConfig = #{},
    G1 = maybe_set(<<"maxOutputTokens">>, <<"max_tokens">>, Body, GenConfig),
    G2 = maybe_set(<<"temperature">>, <<"temperature">>, Body, G1),
    G3 = maybe_set(<<"topP">>, <<"top_p">>, Body, G2),
    G4 = case maps:get(<<"stop_sequences">>, Body, undefined) of
        undefined -> G3; Stops -> G3#{<<"stopSequences">> => Stops} end,
    R2 = case map_size(G4) of 0 -> R1; _ -> R1#{<<"generationConfig">> => G4} end,
    R3 = R2#{<<"safetySettings">> => default_safety()},
    case maps:get(<<"tools">>, Body, undefined) of
        undefined -> R3;
        Tools -> R3#{<<"tools">> => [#{<<"functionDeclarations">> => translate_tools(Tools)}]}
    end.

init_acc() -> #{}.

response_stream(#{<<"candidates">> := _} = Event, Acc) ->
    %% Already Gemini — convert to Claude
    {Chunks, _} = translator_gemini_claude:response_stream(Event, translator_gemini_claude:init_acc()),
    {Chunks, Acc};
response_stream(_, Acc) -> {[], Acc}.

response_nonstream(#{<<"content">> := Content} = Body) ->
    %% Claude → Gemini
    Parts = content_to_parts(Content),
    StopReason = translate_stop(maps:get(<<"stop_reason">>, Body, <<"end_turn">>)),
    Usage = maps:get(<<"usage">>, Body, #{}),
    #{<<"candidates">> => [#{
        <<"content">> => #{<<"role">> => <<"model">>, <<"parts">> => Parts},
        <<"finishReason">> => StopReason
    }],
    <<"usageMetadata">> => #{
        <<"promptTokenCount">> => maps:get(<<"input_tokens">>, Usage, 0),
        <<"candidatesTokenCount">> => maps:get(<<"output_tokens">>, Usage, 0),
        <<"totalTokenCount">> => maps:get(<<"input_tokens">>, Usage, 0) +
                                 maps:get(<<"output_tokens">>, Usage, 0)}};
response_nonstream(Body) -> Body.

translate_msg(#{<<"role">> := <<"assistant">>, <<"content">> := Content}) when is_list(Content) ->
    #{<<"role">> => <<"model">>, <<"parts">> => [translate_part(P) || P <- Content]};
translate_msg(#{<<"role">> := <<"assistant">>, <<"content">> := C}) when is_binary(C) ->
    #{<<"role">> => <<"model">>, <<"parts">> => [#{<<"text">> => C}]};
translate_msg(#{<<"role">> := Role, <<"content">> := Content}) when is_list(Content) ->
    #{<<"role">> => Role, <<"parts">> => [translate_part(P) || P <- Content]};
translate_msg(#{<<"role">> := Role, <<"content">> := C}) when is_binary(C) ->
    #{<<"role">> => Role, <<"parts">> => [#{<<"text">> => C}]};
translate_msg(M) -> M.

translate_part(#{<<"type">> := <<"text">>, <<"text">> := T}) -> #{<<"text">> => T};
translate_part(#{<<"type">> := <<"tool_use">>, <<"name">> := N, <<"input">> := I}) ->
    #{<<"functionCall">> => #{<<"name">> => N, <<"args">> => I}};
translate_part(#{<<"type">> := <<"tool_result">>, <<"tool_use_id">> := Id, <<"content">> := C}) ->
    #{<<"functionResponse">> => #{<<"name">> => Id, <<"response">> => #{<<"result">> => C}}};
translate_part(#{<<"type">> := <<"image">>, <<"source">> := #{<<"media_type">> := M, <<"data">> := D}}) ->
    #{<<"inlineData">> => #{<<"mimeType">> => M, <<"data">> => D}};
translate_part(_) -> #{<<"text">> => <<>>}.

content_to_parts(Content) when is_list(Content) ->
    lists:filtermap(fun
        (#{<<"type">> := <<"text">>, <<"text">> := T}) -> {true, #{<<"text">> => T}};
        (#{<<"type">> := <<"tool_use">>, <<"name">> := N, <<"input">> := I}) ->
            {true, #{<<"functionCall">> => #{<<"name">> => N, <<"args">> => I}}};
        (_) -> false
    end, Content);
content_to_parts(_) -> [].

translate_tools(Tools) ->
    [#{<<"name">> => maps:get(<<"name">>, T, <<>>),
       <<"description">> => maps:get(<<"description">>, T, <<>>),
       <<"parameters">> => maps:get(<<"input_schema">>, T, #{})} || T <- Tools].

translate_stop(<<"end_turn">>) -> <<"STOP">>;
translate_stop(<<"max_tokens">>) -> <<"MAX_TOKENS">>;
translate_stop(<<"tool_use">>) -> <<"STOP">>;
translate_stop(_) -> <<"STOP">>.

default_safety() ->
    [#{<<"category">> => C, <<"threshold">> => <<"BLOCK_NONE">>}
     || C <- [<<"HARM_CATEGORY_HARASSMENT">>, <<"HARM_CATEGORY_HATE_SPEECH">>,
              <<"HARM_CATEGORY_SEXUALLY_EXPLICIT">>, <<"HARM_CATEGORY_DANGEROUS_CONTENT">>]].

maybe_set(TK, SK, S, T) -> case maps:get(SK, S, undefined) of undefined -> T; V -> T#{TK => V} end.
