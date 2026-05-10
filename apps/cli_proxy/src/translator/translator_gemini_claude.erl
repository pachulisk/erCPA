-module(translator_gemini_claude).
-behaviour(translator).

%% Translates Gemini generateContent format → Claude messages format
%% Source: Gemini API response format
%% Target: Claude messages API format

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

register() ->
    translator_registry:register(gemini, claude, ?MODULE).

%%====================================================================
%% Request Translation: Gemini → Claude
%%====================================================================

-spec request(binary(), map(), boolean()) -> map().
request(Model, Body, Stream) ->
    Contents = maps:get(<<"contents">>, Body, []),
    Messages = translate_contents(Contents),

    %% Extract system instruction
    System = case maps:get(<<"systemInstruction">>, Body, undefined) of
        undefined -> undefined;
        #{<<"parts">> := Parts} ->
            Texts = [maps:get(<<"text">>, P, <<>>) || P <- Parts],
            iolist_to_binary(Texts);
        _ -> undefined
    end,

    Result = #{
        <<"model">> => Model,
        <<"messages">> => Messages,
        <<"stream">> => Stream
    },

    R1 = case System of
        undefined -> Result;
        Sys -> Result#{<<"system">> => Sys}
    end,

    %% Map generation config
    GenConfig = maps:get(<<"generationConfig">>, Body, #{}),
    R2 = maybe_set_from(<<"max_tokens">>, <<"maxOutputTokens">>, GenConfig, R1),
    R3 = maybe_set_from(<<"temperature">>, <<"temperature">>, GenConfig, R2),
    R4 = maybe_set_from(<<"top_p">>, <<"topP">>, GenConfig, R3),

    %% Map stop sequences
    R5 = case maps:get(<<"stopSequences">>, GenConfig, undefined) of
        undefined -> R4;
        Stops -> R4#{<<"stop_sequences">> => Stops}
    end,

    %% Map tools
    R6 = case maps:get(<<"tools">>, Body, undefined) of
        undefined -> R5;
        Tools -> R5#{<<"tools">> => translate_tools(Tools)}
    end,

    R6.

%%====================================================================
%% Response Translation: Claude → Gemini (streaming)
%%====================================================================

-record(acc, {
    has_content = false :: boolean(),
    tool_name_map = #{} :: #{binary() => binary()},
    text_acc = <<>> :: binary()
}).

-spec init_acc() -> #acc{}.
init_acc() -> #acc{}.

-spec response_stream(map(), #acc{}) -> {[iodata()], #acc{}}.
response_stream(#{<<"type">> := <<"content_block_delta">>,
                  <<"delta">> := #{<<"type">> := <<"text_delta">>,
                                   <<"text">> := Text}}, Acc) ->
    %% Text delta → Gemini candidate with text part
    Event = #{
        <<"candidates">> => [#{
            <<"content">> => #{
                <<"role">> => <<"model">>,
                <<"parts">> => [#{<<"text">> => Text}]
            }
        }]
    },
    {[jiffy:encode(Event)], Acc#acc{has_content = true,
                                     text_acc = <<(Acc#acc.text_acc)/binary, Text/binary>>}};

response_stream(#{<<"type">> := <<"content_block_start">>,
                  <<"content_block">> := #{<<"type">> := <<"tool_use">>,
                                           <<"id">> := _Id,
                                           <<"name">> := Name}}, Acc) ->
    %% Tool use start — accumulate name
    {[], Acc#acc{tool_name_map = maps:put(Name, <<>>, Acc#acc.tool_name_map)}};

response_stream(#{<<"type">> := <<"content_block_delta">>,
                  <<"delta">> := #{<<"type">> := <<"input_json_delta">>,
                                   <<"partial_json">> := _Partial}}, Acc) ->
    %% Tool input accumulation — Gemini gets full args at stop
    {[], Acc};

response_stream(#{<<"type">> := <<"content_block_stop">>,
                  <<"index">> := _Idx}, Acc) ->
    {[], Acc};

response_stream(#{<<"type">> := <<"message_delta">>,
                  <<"usage">> := Usage}, Acc) ->
    %% Final event with usage
    Event = #{
        <<"usageMetadata">> => #{
            <<"promptTokenCount">> => maps:get(<<"input_tokens">>, Usage, 0),
            <<"candidatesTokenCount">> => maps:get(<<"output_tokens">>, Usage, 0)
        }
    },
    {[jiffy:encode(Event)], Acc};

response_stream(_Event, Acc) ->
    {[], Acc}.

%%====================================================================
%% Response Translation: Claude → Gemini (non-streaming)
%%====================================================================

-spec response_nonstream(map()) -> map().
response_nonstream(#{<<"content">> := Content} = Body) ->
    Parts = content_to_parts(Content),
    FinishReason = translate_stop_reason(maps:get(<<"stop_reason">>, Body, <<"end_turn">>)),
    Usage = maps:get(<<"usage">>, Body, #{}),

    #{
        <<"candidates">> => [#{
            <<"content">> => #{
                <<"role">> => <<"model">>,
                <<"parts">> => Parts
            },
            <<"finishReason">> => FinishReason
        }],
        <<"usageMetadata">> => #{
            <<"promptTokenCount">> => maps:get(<<"input_tokens">>, Usage, 0),
            <<"candidatesTokenCount">> => maps:get(<<"output_tokens">>, Usage, 0),
            <<"totalTokenCount">> => maps:get(<<"input_tokens">>, Usage, 0) +
                                     maps:get(<<"output_tokens">>, Usage, 0)
        }
    };
response_nonstream(Body) ->
    Body.

%%====================================================================
%% Internal - Request
%%====================================================================

translate_contents(Contents) ->
    lists:map(fun translate_content/1, Contents).

translate_content(#{<<"role">> := <<"model">>, <<"parts">> := Parts}) ->
    #{<<"role">> => <<"assistant">>,
      <<"content">> => parts_to_claude_content(Parts)};
translate_content(#{<<"role">> := Role, <<"parts">> := Parts}) ->
    #{<<"role">> => Role,
      <<"content">> => parts_to_claude_content(Parts)}.

parts_to_claude_content(Parts) ->
    lists:filtermap(fun translate_part/1, Parts).

translate_part(#{<<"text">> := Text}) ->
    {true, #{<<"type">> => <<"text">>, <<"text">> => Text}};
translate_part(#{<<"inlineData">> := #{<<"mimeType">> := Mime, <<"data">> := Data}}) ->
    {true, #{<<"type">> => <<"image">>,
             <<"source">> => #{<<"type">> => <<"base64">>,
                               <<"media_type">> => Mime,
                               <<"data">> => Data}}};
translate_part(#{<<"functionCall">> := #{<<"name">> := Name, <<"args">> := Args}}) ->
    {true, #{<<"type">> => <<"tool_use">>,
             <<"id">> => generate_tool_id(),
             <<"name">> => Name,
             <<"input">> => Args}};
translate_part(#{<<"functionResponse">> := #{<<"name">> := Name, <<"response">> := Resp}}) ->
    {true, #{<<"type">> => <<"tool_result">>,
             <<"tool_use_id">> => Name,
             <<"content">> => maps:get(<<"result">>, Resp, <<>>)}};
translate_part(_) ->
    false.

translate_tools(ToolsArray) ->
    lists:flatmap(fun(#{<<"functionDeclarations">> := Decls}) ->
        [#{<<"name">> => maps:get(<<"name">>, D, <<>>),
           <<"description">> => maps:get(<<"description">>, D, <<>>),
           <<"input_schema">> => maps:get(<<"parameters">>, D, #{})}
         || D <- Decls];
    (_) -> []
    end, ToolsArray).

maybe_set_from(TargetKey, SourceKey, Source, Target) ->
    case maps:get(SourceKey, Source, undefined) of
        undefined -> Target;
        Val -> Target#{TargetKey => Val}
    end.

%%====================================================================
%% Internal - Response
%%====================================================================

content_to_parts(Content) when is_list(Content) ->
    lists:filtermap(fun
        (#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
            {true, #{<<"text">> => Text}};
        (#{<<"type">> := <<"tool_use">>, <<"name">> := Name, <<"input">> := Input}) ->
            {true, #{<<"functionCall">> => #{<<"name">> => Name, <<"args">> => Input}}};
        (_) -> false
    end, Content);
content_to_parts(_) ->
    [].

translate_stop_reason(<<"end_turn">>) -> <<"STOP">>;
translate_stop_reason(<<"stop_sequence">>) -> <<"STOP">>;
translate_stop_reason(<<"max_tokens">>) -> <<"MAX_TOKENS">>;
translate_stop_reason(<<"tool_use">>) -> <<"STOP">>;
translate_stop_reason(_) -> <<"STOP">>.

generate_tool_id() ->
    <<"toolu_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.
