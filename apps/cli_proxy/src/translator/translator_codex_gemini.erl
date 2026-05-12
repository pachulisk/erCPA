-module(translator_codex_gemini).
-behaviour(translator).

%% Codex (Responses API) -> Gemini generateContent format

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

register() ->
    translator_registry:register(codex, gemini, ?MODULE).

%%====================================================================
%% Request Translation: Codex -> Gemini
%%====================================================================

-spec request(binary(), map(), boolean()) -> map().
request(_Model, Body, _Stream) ->
    Instructions = maps:get(<<"instructions">>, Body, <<>>),
    Input = maps:get(<<"input">>, Body, []),
    Contents = translate_input(Input),

    Result = #{<<"contents">> => Contents},

    R1 = case Instructions of
        <<>> -> Result;
        _ -> Result#{<<"systemInstruction">> => #{<<"parts">> => [#{<<"text">> => Instructions}]}}
    end,

    %% Generation config
    GenConfig = build_generation_config(Body),
    R2 = case map_size(GenConfig) of
        0 -> R1;
        _ -> R1#{<<"generationConfig">> => GenConfig}
    end,

    R3 = R2#{<<"safetySettings">> => default_safety_settings()},

    %% Tools
    case maps:get(<<"tools">>, Body, undefined) of
        undefined -> R3;
        [] -> R3;
        Tools -> R3#{<<"tools">> => [#{<<"functionDeclarations">> => translate_tools(Tools)}]}
    end.

%%====================================================================
%% Response Translation: Gemini -> Codex (streaming)
%%====================================================================

-record(acc, {
    response_id = <<>> :: binary(),
    model = <<>> :: binary(),
    current_text = <<>> :: binary(),
    seq = 0 :: non_neg_integer()
}).

-spec init_acc() -> #acc{}.
init_acc() -> #acc{}.

-spec response_stream(map(), #acc{}) -> {[iodata()], #acc{}}.
response_stream(#{<<"candidates">> := [Candidate | _]} = _Event, Acc) ->
    Content = maps:get(<<"content">>, Candidate, #{}),
    Parts = maps:get(<<"parts">>, Content, []),

    Texts = [maps:get(<<"text">>, P) || P <- Parts, maps:is_key(<<"text">>, P)],
    Text = iolist_to_binary(Texts),

    case Text of
        <<>> -> {[], Acc};
        _ ->
            E = #{<<"type">> => <<"response.output_text.delta">>,
                  <<"sequence_number">> => Acc#acc.seq,
                  <<"delta">> => Text,
                  <<"output_index">> => 0,
                  <<"content_index">> => 0},
            {[jiffy:encode(E)],
             Acc#acc{seq = Acc#acc.seq + 1,
                     current_text = <<(Acc#acc.current_text)/binary, Text/binary>>}}
    end;
response_stream(_, Acc) -> {[], Acc}.

%%====================================================================
%% Response Translation: Gemini -> Codex (non-streaming)
%%====================================================================

-spec response_nonstream(map()) -> map().
response_nonstream(#{<<"candidates">> := [Candidate | _]} = Body) ->
    Content = maps:get(<<"content">>, Candidate, #{}),
    Parts = maps:get(<<"parts">>, Content, []),

    %% Extract text
    Texts = [maps:get(<<"text">>, P) || P <- Parts, maps:is_key(<<"text">>, P)],
    Text = iolist_to_binary(Texts),

    %% Extract function calls
    FuncCalls = lists:filtermap(fun(P) ->
        case maps:get(<<"functionCall">>, P, undefined) of
            undefined -> false;
            #{<<"name">> := Name, <<"args">> := Args} ->
                {true, #{<<"type">> => <<"function_call">>,
                         <<"call_id">> => generate_call_id(),
                         <<"name">> => Name,
                         <<"arguments">> => jiffy:encode(Args)}}
        end
    end, Parts),

    TextItems = case Text of
        <<>> -> [];
        _ -> [#{<<"type">> => <<"message">>,
               <<"role">> => <<"assistant">>,
               <<"content">> => [#{<<"type">> => <<"output_text">>, <<"text">> => Text}]}]
    end,

    Usage = translate_usage(maps:get(<<"usageMetadata">>, Body, #{})),

    #{<<"id">> => generate_response_id(),
      <<"object">> => <<"response">>,
      <<"status">> => <<"completed">>,
      <<"model">> => maps:get(<<"modelVersion">>, Body, <<>>),
      <<"output">> => TextItems ++ FuncCalls,
      <<"usage">> => Usage};
response_nonstream(Body) -> Body.

%%====================================================================
%% Internal - Request
%%====================================================================

translate_input(Input) ->
    lists:filtermap(fun
        (#{<<"type">> := <<"message">>, <<"role">> := R, <<"content">> := C}) when is_binary(C) ->
            Role = codex_role_to_gemini(R),
            {true, #{<<"role">> => Role, <<"parts">> => [#{<<"text">> => C}]}};
        (#{<<"type">> := <<"message">>, <<"role">> := R, <<"content">> := C}) when is_list(C) ->
            Text = iolist_to_binary([maps:get(<<"text">>, P, <<>>) || P <- C]),
            Role = codex_role_to_gemini(R),
            {true, #{<<"role">> => Role, <<"parts">> => [#{<<"text">> => Text}]}};
        (#{<<"type">> := <<"function_call">>, <<"name">> := N, <<"arguments">> := A}) ->
            Args = try jiffy:decode(A, [return_maps]) catch _:_ -> #{} end,
            {true, #{<<"role">> => <<"model">>,
                     <<"parts">> => [#{<<"functionCall">> => #{<<"name">> => N, <<"args">> => Args}}]}};
        (#{<<"type">> := <<"function_call_output">>, <<"call_id">> := Id, <<"output">> := O}) ->
            {true, #{<<"role">> => <<"user">>,
                     <<"parts">> => [#{<<"functionResponse">> => #{
                         <<"name">> => Id,
                         <<"response">> => #{<<"result">> => O}
                     }}]}};
        (_) -> false
    end, Input).

codex_role_to_gemini(<<"assistant">>) -> <<"model">>;
codex_role_to_gemini(Role) -> Role.

build_generation_config(Body) ->
    Opts = [
        {<<"temperature">>, maps:get(<<"temperature">>, Body, undefined)},
        {<<"maxOutputTokens">>, maps:get(<<"max_output_tokens">>, Body, undefined)}
    ],
    maps:from_list([{K, V} || {K, V} <- Opts, V =/= undefined]).

translate_tools(Tools) ->
    lists:filtermap(fun
        (#{<<"type">> := <<"function">>, <<"name">> := N} = T) ->
            {true, #{<<"name">> => N,
                     <<"description">> => maps:get(<<"description">>, T, <<>>),
                     <<"parameters">> => maps:get(<<"parameters">>, T, #{})}};
        (_) -> false
    end, Tools).

default_safety_settings() ->
    Categories = [
        <<"HARM_CATEGORY_HARASSMENT">>,
        <<"HARM_CATEGORY_HATE_SPEECH">>,
        <<"HARM_CATEGORY_SEXUALLY_EXPLICIT">>,
        <<"HARM_CATEGORY_DANGEROUS_CONTENT">>
    ],
    [#{<<"category">> => C, <<"threshold">> => <<"BLOCK_NONE">>} || C <- Categories].

%%====================================================================
%% Internal - Response
%%====================================================================

translate_usage(#{<<"promptTokenCount">> := In, <<"candidatesTokenCount">> := Out}) ->
    #{<<"input_tokens">> => In, <<"output_tokens">> => Out, <<"total_tokens">> => In + Out};
translate_usage(#{<<"promptTokenCount">> := In}) ->
    #{<<"input_tokens">> => In, <<"output_tokens">> => 0, <<"total_tokens">> => In};
translate_usage(_) ->
    #{<<"input_tokens">> => 0, <<"output_tokens">> => 0, <<"total_tokens">> => 0}.

generate_response_id() ->
    <<"resp_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

generate_call_id() ->
    <<"call_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.
