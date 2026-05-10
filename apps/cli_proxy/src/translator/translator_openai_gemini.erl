-module(translator_openai_gemini).
-behaviour(translator).

%% Translates OpenAI chat-completions format → Gemini generateContent format
%% Source: POST /v1/chat/completions (OpenAI)
%% Target: POST /v1beta/models/MODEL:generateContent (Gemini)

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

register() ->
    translator_registry:register(openai, gemini, ?MODULE).

%%====================================================================
%% Request Translation: OpenAI → Gemini
%%====================================================================

-spec request(binary(), map(), boolean()) -> map().
request(_Model, Body, _Stream) ->
    Messages = maps:get(<<"messages">>, Body, []),
    {SystemInstruction, Contents} = extract_system_and_contents(Messages),

    Result = #{<<"contents">> => Contents},

    R1 = case SystemInstruction of
        undefined -> Result;
        Sys -> Result#{<<"systemInstruction">> => #{<<"parts">> => [#{<<"text">> => Sys}]}}
    end,

    %% Generation config
    GenConfig = build_generation_config(Body),
    R2 = case map_size(GenConfig) of
        0 -> R1;
        _ -> R1#{<<"generationConfig">> => GenConfig}
    end,

    %% Safety settings (permissive defaults)
    R3 = R2#{<<"safetySettings">> => default_safety_settings()},

    %% Tools
    R4 = case maps:get(<<"tools">>, Body, undefined) of
        undefined -> R3;
        Tools -> R3#{<<"tools">> => [#{<<"functionDeclarations">> => translate_tools(Tools)}]}
    end,

    R4.

%%====================================================================
%% Response Translation: Gemini → OpenAI (streaming)
%%====================================================================

-record(acc, {
    response_id = <<>> :: binary(),
    model = <<>> :: binary(),
    has_content = false :: boolean(),
    text_acc = <<>> :: binary()
}).

-spec init_acc() -> #acc{}.
init_acc() ->
    #acc{}.

-spec response_stream(map(), #acc{}) -> {[iodata()], #acc{}}.
response_stream(#{<<"candidates">> := [Candidate | _]} = Event, Acc) ->
    Content = maps:get(<<"content">>, Candidate, #{}),
    Parts = maps:get(<<"parts">>, Content, []),
    FinishReason = maps:get(<<"finishReason">>, Candidate, undefined),

    %% Extract text from parts
    Texts = [maps:get(<<"text">>, P) || P <- Parts, maps:is_key(<<"text">>, P)],
    Text = iolist_to_binary(Texts),

    %% Build OpenAI-format chunk
    Chunks = case Text of
        <<>> -> [];
        _ ->
            Chunk = #{
                <<"id">> => Acc#acc.response_id,
                <<"object">> => <<"chat.completion.chunk">>,
                <<"model">> => Acc#acc.model,
                <<"choices">> => [#{
                    <<"index">> => 0,
                    <<"delta">> => #{<<"content">> => Text},
                    <<"finish_reason">> => translate_finish_reason(FinishReason)
                }]
            },
            [jiffy:encode(Chunk)]
    end,

    %% Handle function calls
    FuncChunks = lists:filtermap(fun(P) ->
        case maps:get(<<"functionCall">>, P, undefined) of
            undefined -> false;
            FC -> {true, build_function_call_chunk(FC, Acc)}
        end
    end, Parts),

    %% Usage metadata
    UsageChunks = case maps:get(<<"usageMetadata">>, Event, undefined) of
        undefined -> [];
        Usage ->
            case FinishReason of
                undefined -> [];
                _ ->
                    UChunk = #{
                        <<"id">> => Acc#acc.response_id,
                        <<"object">> => <<"chat.completion.chunk">>,
                        <<"model">> => Acc#acc.model,
                        <<"choices">> => [#{
                            <<"index">> => 0,
                            <<"delta">> => #{},
                            <<"finish_reason">> => translate_finish_reason(FinishReason)
                        }],
                        <<"usage">> => translate_usage(Usage)
                    },
                    [jiffy:encode(UChunk)]
            end
    end,

    AllChunks = Chunks ++ [jiffy:encode(C) || C <- FuncChunks] ++ UsageChunks,
    {AllChunks, Acc#acc{has_content = true, text_acc = <<(Acc#acc.text_acc)/binary, Text/binary>>}};

response_stream(_Event, Acc) ->
    {[], Acc}.

%%====================================================================
%% Response Translation: Gemini → OpenAI (non-streaming)
%%====================================================================

-spec response_nonstream(map()) -> map().
response_nonstream(#{<<"candidates">> := [Candidate | _]} = Body) ->
    Content = maps:get(<<"content">>, Candidate, #{}),
    Parts = maps:get(<<"parts">>, Content, []),
    FinishReason = maps:get(<<"finishReason">>, Candidate, <<"STOP">>),

    %% Extract text
    Texts = [maps:get(<<"text">>, P) || P <- Parts, maps:is_key(<<"text">>, P)],
    Text = iolist_to_binary(Texts),

    %% Extract function calls
    FuncCalls = lists:filtermap(fun(P) ->
        case maps:get(<<"functionCall">>, P, undefined) of
            undefined -> false;
            #{<<"name">> := Name, <<"args">> := Args} ->
                {true, #{
                    <<"id">> => generate_call_id(),
                    <<"type">> => <<"function">>,
                    <<"function">> => #{
                        <<"name">> => Name,
                        <<"arguments">> => jiffy:encode(Args)
                    }
                }}
        end
    end, Parts),

    Message = case FuncCalls of
        [] -> #{<<"role">> => <<"assistant">>, <<"content">> => Text};
        _ -> #{<<"role">> => <<"assistant">>, <<"content">> => Text,
               <<"tool_calls">> => FuncCalls}
    end,

    Usage = translate_usage(maps:get(<<"usageMetadata">>, Body, #{})),

    #{
        <<"id">> => generate_response_id(),
        <<"object">> => <<"chat.completion">>,
        <<"created">> => erlang:system_time(second),
        <<"model">> => maps:get(<<"modelVersion">>, Body, <<>>),
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"message">> => Message,
            <<"finish_reason">> => translate_finish_reason(FinishReason)
        }],
        <<"usage">> => Usage
    };
response_nonstream(Body) ->
    Body.

%%====================================================================
%% Internal - Request
%%====================================================================

extract_system_and_contents(Messages) ->
    case Messages of
        [#{<<"role">> := <<"system">>, <<"content">> := Sys} | Rest] ->
            {ensure_text(Sys), [translate_message(M) || M <- Rest]};
        _ ->
            {undefined, [translate_message(M) || M <- Messages]}
    end.

translate_message(#{<<"role">> := <<"assistant">>} = Msg) ->
    #{<<"role">> => <<"model">>, <<"parts">> => message_to_parts(Msg)};
translate_message(#{<<"role">> := <<"tool">>} = Msg) ->
    %% Tool result → functionResponse
    CallId = maps:get(<<"tool_call_id">>, Msg, <<>>),
    Content = maps:get(<<"content">>, Msg, <<>>),
    #{<<"role">> => <<"user">>,
      <<"parts">> => [#{<<"functionResponse">> => #{
          <<"name">> => CallId,
          <<"response">> => #{<<"result">> => Content}
      }}]};
translate_message(#{<<"role">> := Role} = Msg) ->
    #{<<"role">> => Role, <<"parts">> => message_to_parts(Msg)}.

message_to_parts(#{<<"content">> := Content, <<"tool_calls">> := ToolCalls}) ->
    TextParts = case Content of
        <<>> -> [];
        null -> [];
        T when is_binary(T) -> [#{<<"text">> => T}];
        _ -> []
    end,
    FuncParts = [#{<<"functionCall">> => #{
        <<"name">> => maps:get(<<"name">>, maps:get(<<"function">>, TC)),
        <<"args">> => try jiffy:decode(maps:get(<<"arguments">>, maps:get(<<"function">>, TC)), [return_maps])
                     catch _:_ -> #{} end
    }} || TC <- ToolCalls],
    TextParts ++ FuncParts;

message_to_parts(#{<<"content">> := Content}) when is_binary(Content) ->
    [#{<<"text">> => Content}];

message_to_parts(#{<<"content">> := Content}) when is_list(Content) ->
    [translate_content_part(P) || P <- Content];

message_to_parts(_) ->
    [#{<<"text">> => <<>>}].

translate_content_part(#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
    #{<<"text">> => Text};
translate_content_part(#{<<"type">> := <<"image_url">>,
                         <<"image_url">> := #{<<"url">> := URL}}) ->
    case parse_data_url(URL) of
        {ok, MimeType, Data} ->
            #{<<"inlineData">> => #{<<"mimeType">> => MimeType, <<"data">> => Data}};
        {url, _} ->
            #{<<"text">> => <<"[image]">>}
    end;
translate_content_part(_) ->
    #{<<"text">> => <<>>}.

parse_data_url(<<"data:", Rest/binary>>) ->
    case binary:split(Rest, <<";">>) of
        [MimeType, <<"base64,", Data/binary>>] -> {ok, MimeType, Data};
        _ -> {url, <<"data:", Rest/binary>>}
    end;
parse_data_url(URL) ->
    {url, URL}.

ensure_text(S) when is_binary(S) -> S;
ensure_text(_) -> <<>>.

build_generation_config(Body) ->
    Opts = [
        {<<"temperature">>, maps:get(<<"temperature">>, Body, undefined)},
        {<<"topP">>, maps:get(<<"top_p">>, Body, undefined)},
        {<<"maxOutputTokens">>, maps:get(<<"max_tokens">>, Body, undefined)},
        {<<"stopSequences">>, maps:get(<<"stop">>, Body, undefined)}
    ],
    maps:from_list([{K, V} || {K, V} <- Opts, V =/= undefined]).

translate_tools(Tools) ->
    [translate_tool(T) || T <- Tools, maps:get(<<"type">>, T, <<>>) =:= <<"function">>].

translate_tool(#{<<"function">> := Func}) ->
    #{<<"name">> => maps:get(<<"name">>, Func, <<>>),
      <<"description">> => maps:get(<<"description">>, Func, <<>>),
      <<"parameters">> => maps:get(<<"parameters">>, Func, #{})};
translate_tool(T) -> T.

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

translate_finish_reason(<<"STOP">>) -> <<"stop">>;
translate_finish_reason(<<"MAX_TOKENS">>) -> <<"length">>;
translate_finish_reason(<<"SAFETY">>) -> <<"content_filter">>;
translate_finish_reason(<<"RECITATION">>) -> <<"stop">>;
translate_finish_reason(undefined) -> null;
translate_finish_reason(null) -> null;
translate_finish_reason(_) -> <<"stop">>.

translate_usage(#{<<"promptTokenCount">> := In, <<"candidatesTokenCount">> := Out}) ->
    #{<<"prompt_tokens">> => In, <<"completion_tokens">> => Out,
      <<"total_tokens">> => In + Out};
translate_usage(#{<<"promptTokenCount">> := In}) ->
    #{<<"prompt_tokens">> => In, <<"completion_tokens">> => 0,
      <<"total_tokens">> => In};
translate_usage(_) ->
    #{<<"prompt_tokens">> => 0, <<"completion_tokens">> => 0, <<"total_tokens">> => 0}.

build_function_call_chunk(#{<<"name">> := Name, <<"args">> := Args}, Acc) ->
    #{
        <<"id">> => Acc#acc.response_id,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"model">> => Acc#acc.model,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"delta">> => #{
                <<"tool_calls">> => [#{
                    <<"index">> => 0,
                    <<"id">> => generate_call_id(),
                    <<"type">> => <<"function">>,
                    <<"function">> => #{
                        <<"name">> => Name,
                        <<"arguments">> => jiffy:encode(Args)
                    }
                }]
            },
            <<"finish_reason">> => null
        }]
    }.

generate_response_id() ->
    <<"chatcmpl-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

generate_call_id() ->
    <<"call_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.
