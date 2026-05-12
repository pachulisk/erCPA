-module(translator_openai_codex).
-behaviour(translator).

%% Translates OpenAI chat-completions format -> Codex (Responses API) format
%% Source: OpenAI chat completions
%% Target: Codex responses format (input array with instructions)
%% Reverse of translator_codex_openai.

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

register() ->
    translator_registry:register(openai, codex, ?MODULE).

%%====================================================================
%% Request Translation: OpenAI -> Codex
%%====================================================================

-spec request(binary(), map(), boolean()) -> map().
request(Model, Body, Stream) ->
    Messages = maps:get(<<"messages">>, Body, []),
    {Instructions, UserMessages} = extract_system(Messages),
    Input = translate_messages(UserMessages),

    Result = #{
        <<"model">> => Model,
        <<"input">> => Input,
        <<"stream">> => Stream
    },

    R1 = case Instructions of
        <<>> -> Result;
        _ -> Result#{<<"instructions">> => Instructions}
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

    %% Map tools: OpenAI schema -> Codex schema
    R4 = case maps:get(<<"tools">>, Body, undefined) of
        undefined -> R3;
        Tools -> R3#{<<"tools">> => translate_tools(Tools)}
    end,

    R4.

%%====================================================================
%% Response Translation: Codex -> OpenAI (streaming)
%%====================================================================

init_acc() -> #{}.

-spec response_stream(map(), map()) -> {[iodata()], map()}.
response_stream(#{<<"type">> := <<"response.output_text.delta">>,
                  <<"delta">> := Text}, Acc) ->
    %% Codex text delta -> OpenAI chat.completion.chunk
    Id = maps:get(id, Acc, <<>>),
    Chunk = #{
        <<"id">> => Id,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"delta">> => #{<<"content">> => Text},
            <<"finish_reason">> => null
        }]
    },
    {[jiffy:encode(Chunk)], Acc};

response_stream(#{<<"type">> := <<"response.created">>,
                  <<"response">> := Resp}, Acc) ->
    Id = maps:get(<<"id">>, Resp, <<>>),
    Model = maps:get(<<"model">>, Resp, <<>>),
    %% Emit initial chunk with role
    Chunk = #{
        <<"id">> => Id,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"model">> => Model,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"delta">> => #{<<"role">> => <<"assistant">>},
            <<"finish_reason">> => null
        }]
    },
    {[jiffy:encode(Chunk)], Acc#{id => Id, model => Model}};

response_stream(#{<<"type">> := <<"response.completed">>,
                  <<"response">> := Resp}, Acc) ->
    Id = maps:get(id, Acc, <<>>),
    Usage = maps:get(<<"usage">>, Resp, #{}),
    Chunk = #{
        <<"id">> => Id,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"delta">> => #{},
            <<"finish_reason">> => <<"stop">>
        }],
        <<"usage">> => #{
            <<"prompt_tokens">> => maps:get(<<"input_tokens">>, Usage, 0),
            <<"completion_tokens">> => maps:get(<<"output_tokens">>, Usage, 0),
            <<"total_tokens">> => maps:get(<<"total_tokens">>, Usage, 0)
        }
    },
    {[jiffy:encode(Chunk)], Acc};

response_stream(_Event, Acc) ->
    {[], Acc}.

%%====================================================================
%% Response Translation: Codex -> OpenAI (non-streaming)
%%====================================================================

-spec response_nonstream(map()) -> map().
response_nonstream(#{<<"output">> := Output} = Body) ->
    {Content, ToolCalls} = output_to_message(Output),
    Usage = maps:get(<<"usage">>, Body, #{}),
    Message = case ToolCalls of
        [] -> #{<<"role">> => <<"assistant">>, <<"content">> => Content};
        _ -> #{<<"role">> => <<"assistant">>, <<"content">> => Content,
               <<"tool_calls">> => ToolCalls}
    end,
    #{
        <<"id">> => maps:get(<<"id">>, Body, <<>>),
        <<"object">> => <<"chat.completion">>,
        <<"created">> => erlang:system_time(second),
        <<"model">> => maps:get(<<"model">>, Body, <<>>),
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"message">> => Message,
            <<"finish_reason">> => <<"stop">>
        }],
        <<"usage">> => #{
            <<"prompt_tokens">> => maps:get(<<"input_tokens">>, Usage, 0),
            <<"completion_tokens">> => maps:get(<<"output_tokens">>, Usage, 0),
            <<"total_tokens">> => maps:get(<<"total_tokens">>, Usage, 0)
        }
    };
response_nonstream(Body) ->
    Body.

%%====================================================================
%% Internal - Request
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
    lists:flatten([translate_message(M) || M <- Messages]).

translate_message(#{<<"role">> := <<"assistant">>, <<"tool_calls">> := ToolCalls} = Msg) ->
    %% Assistant message with tool calls -> function_call items
    TextItem = case maps:get(<<"content">>, Msg, <<>>) of
        <<>> -> [];
        null -> [];
        Text when is_binary(Text) ->
            [#{<<"type">> => <<"message">>,
               <<"role">> => <<"assistant">>,
               <<"content">> => Text}];
        _ -> []
    end,
    ToolItems = [#{
        <<"type">> => <<"function_call">>,
        <<"call_id">> => maps:get(<<"id">>, TC, <<>>),
        <<"name">> => maps:get(<<"name">>, maps:get(<<"function">>, TC, #{}), <<>>),
        <<"arguments">> => maps:get(<<"arguments">>, maps:get(<<"function">>, TC, #{}), <<"{}">>)
    } || TC <- ToolCalls],
    TextItem ++ ToolItems;

translate_message(#{<<"role">> := <<"tool">>, <<"tool_call_id">> := CallId,
                    <<"content">> := Content}) ->
    [#{<<"type">> => <<"function_call_output">>,
       <<"call_id">> => CallId,
       <<"output">> => ensure_binary(Content)}];

translate_message(#{<<"role">> := Role, <<"content">> := Content}) when is_binary(Content) ->
    [#{<<"type">> => <<"message">>, <<"role">> => Role, <<"content">> => Content}];

translate_message(#{<<"role">> := Role, <<"content">> := Content}) when is_list(Content) ->
    %% Multi-part content -> flatten to text
    Text = iolist_to_binary([maps:get(<<"text">>, P, <<>>) || P <- Content,
                             maps:get(<<"type">>, P, <<>>) =:= <<"text">>]),
    [#{<<"type">> => <<"message">>, <<"role">> => Role, <<"content">> => Text}];

translate_message(_) ->
    [].

translate_tools(Tools) ->
    lists:filtermap(fun
        (#{<<"type">> := <<"function">>, <<"function">> := Func}) ->
            {true, #{<<"type">> => <<"function">>,
                     <<"name">> => maps:get(<<"name">>, Func, <<>>),
                     <<"description">> => maps:get(<<"description">>, Func, <<>>),
                     <<"parameters">> => maps:get(<<"parameters">>, Func, #{})}};
        (_) -> false
    end, Tools).

%%====================================================================
%% Internal - Response
%%====================================================================

output_to_message(Output) when is_list(Output) ->
    Texts = lists:filtermap(fun
        (#{<<"type">> := <<"message">>, <<"content">> := Content}) when is_list(Content) ->
            T = iolist_to_binary([maps:get(<<"text">>, C, <<>>) || C <- Content,
                                  maps:get(<<"type">>, C, <<>>) =:= <<"output_text">>]),
            case T of <<>> -> false; _ -> {true, T} end;
        (_) -> false
    end, Output),
    Content = case Texts of
        [] -> <<>>;
        _ -> iolist_to_binary(Texts)
    end,
    ToolCalls = lists:filtermap(fun
        (#{<<"type">> := <<"function_call">>,
           <<"call_id">> := Id, <<"name">> := Name, <<"arguments">> := Args}) ->
            {true, #{<<"id">> => Id,
                     <<"type">> => <<"function">>,
                     <<"function">> => #{<<"name">> => Name, <<"arguments">> => Args}}};
        (_) -> false
    end, Output),
    {Content, ToolCalls};
output_to_message(_) ->
    {<<>>, []}.
