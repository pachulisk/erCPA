-module(translator_gemini_codex).
-behaviour(translator).

%% Gemini generateContent format -> Codex (Responses API)

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

register() ->
    translator_registry:register(gemini, codex, ?MODULE).

%%====================================================================
%% Request Translation: Gemini -> Codex
%%====================================================================

-spec request(binary(), map(), boolean()) -> map().
request(Model, Body, Stream) ->
    Contents = maps:get(<<"contents">>, Body, []),
    Input = translate_contents(Contents),

    %% Extract system instruction -> instructions
    Instructions = case maps:get(<<"systemInstruction">>, Body, undefined) of
        undefined -> <<>>;
        #{<<"parts">> := Parts} ->
            iolist_to_binary([maps:get(<<"text">>, P, <<>>) || P <- Parts]);
        _ -> <<>>
    end,

    Result = #{
        <<"model">> => Model,
        <<"input">> => Input,
        <<"stream">> => Stream
    },

    R1 = case Instructions of
        <<>> -> Result;
        _ -> Result#{<<"instructions">> => Instructions}
    end,

    %% Map generation config
    GenConfig = maps:get(<<"generationConfig">>, Body, #{}),
    R2 = case maps:get(<<"maxOutputTokens">>, GenConfig, undefined) of
        undefined -> R1;
        Max -> R1#{<<"max_output_tokens">> => Max}
    end,

    R3 = case maps:get(<<"temperature">>, GenConfig, undefined) of
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
%% Response Translation: Codex -> Gemini (streaming)
%%====================================================================

init_acc() -> #{}.

-spec response_stream(map(), map()) -> {[iodata()], map()}.
response_stream(#{<<"type">> := <<"response.output_text.delta">>,
                  <<"delta">> := Text}, Acc) ->
    %% Codex text delta -> Gemini candidate
    Event = #{
        <<"candidates">> => [#{
            <<"content">> => #{
                <<"role">> => <<"model">>,
                <<"parts">> => [#{<<"text">> => Text}]
            }
        }]
    },
    {[jiffy:encode(Event)], Acc};
response_stream(#{<<"type">> := <<"response.completed">>,
                  <<"response">> := Resp}, Acc) ->
    Usage = maps:get(<<"usage">>, Resp, #{}),
    Event = #{
        <<"candidates">> => [#{
            <<"content">> => #{<<"role">> => <<"model">>, <<"parts">> => []},
            <<"finishReason">> => <<"STOP">>
        }],
        <<"usageMetadata">> => #{
            <<"promptTokenCount">> => maps:get(<<"input_tokens">>, Usage, 0),
            <<"candidatesTokenCount">> => maps:get(<<"output_tokens">>, Usage, 0),
            <<"totalTokenCount">> => maps:get(<<"total_tokens">>, Usage, 0)
        }
    },
    {[jiffy:encode(Event)], Acc};
response_stream(_, Acc) -> {[], Acc}.

%%====================================================================
%% Response Translation: Codex -> Gemini (non-streaming)
%%====================================================================

-spec response_nonstream(map()) -> map().
response_nonstream(#{<<"output">> := Output} = Body) ->
    Parts = output_to_parts(Output),
    Usage = maps:get(<<"usage">>, Body, #{}),
    #{
        <<"candidates">> => [#{
            <<"content">> => #{<<"role">> => <<"model">>, <<"parts">> => Parts},
            <<"finishReason">> => <<"STOP">>
        }],
        <<"usageMetadata">> => #{
            <<"promptTokenCount">> => maps:get(<<"input_tokens">>, Usage, 0),
            <<"candidatesTokenCount">> => maps:get(<<"output_tokens">>, Usage, 0),
            <<"totalTokenCount">> => maps:get(<<"total_tokens">>, Usage, 0)
        }
    };
response_nonstream(Body) -> Body.

%%====================================================================
%% Internal - Request
%%====================================================================

translate_contents(Contents) ->
    lists:filtermap(fun translate_content/1, Contents).

translate_content(#{<<"role">> := <<"model">>, <<"parts">> := Parts}) ->
    Items = parts_to_input_items(<<"assistant">>, Parts),
    case Items of
        [] -> false;
        _ -> {true, hd(Items)}
    end;
translate_content(#{<<"role">> := Role, <<"parts">> := Parts}) ->
    Items = parts_to_input_items(Role, Parts),
    case Items of
        [] -> false;
        _ -> {true, hd(Items)}
    end;
translate_content(_) -> false.

parts_to_input_items(Role, Parts) ->
    lists:filtermap(fun
        (#{<<"text">> := Text}) ->
            {true, #{<<"type">> => <<"message">>, <<"role">> => Role,
                     <<"content">> => Text}};
        (#{<<"functionCall">> := #{<<"name">> := Name, <<"args">> := Args}}) ->
            {true, #{<<"type">> => <<"function_call">>,
                     <<"call_id">> => generate_call_id(),
                     <<"name">> => Name,
                     <<"arguments">> => jiffy:encode(Args)}};
        (#{<<"functionResponse">> := #{<<"name">> := Name, <<"response">> := Resp}}) ->
            {true, #{<<"type">> => <<"function_call_output">>,
                     <<"call_id">> => Name,
                     <<"output">> => maps:get(<<"result">>, Resp, <<>>)}};
        (_) -> false
    end, Parts).

translate_tools(ToolsArray) ->
    lists:flatmap(fun(#{<<"functionDeclarations">> := Decls}) ->
        [#{<<"type">> => <<"function">>,
           <<"name">> => maps:get(<<"name">>, D, <<>>),
           <<"description">> => maps:get(<<"description">>, D, <<>>),
           <<"parameters">> => maps:get(<<"parameters">>, D, #{})}
         || D <- Decls];
    (_) -> []
    end, ToolsArray).

%%====================================================================
%% Internal - Response
%%====================================================================

output_to_parts(Output) when is_list(Output) ->
    lists:filtermap(fun
        (#{<<"type">> := <<"message">>, <<"content">> := Content}) when is_list(Content) ->
            Texts = [maps:get(<<"text">>, C, <<>>) || C <- Content,
                     maps:get(<<"type">>, C, <<>>) =:= <<"output_text">>],
            case Texts of
                [] -> false;
                _ -> {true, #{<<"text">> => iolist_to_binary(Texts)}}
            end;
        (#{<<"type">> := <<"function_call">>, <<"name">> := Name, <<"arguments">> := Args}) ->
            ParsedArgs = try jiffy:decode(Args, [return_maps]) catch _:_ -> #{} end,
            {true, #{<<"functionCall">> => #{<<"name">> => Name, <<"args">> => ParsedArgs}}};
        (_) -> false
    end, Output);
output_to_parts(_) -> [].

generate_call_id() ->
    <<"call_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.
