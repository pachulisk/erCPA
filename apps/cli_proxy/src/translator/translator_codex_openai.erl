-module(translator_codex_openai).
-behaviour(translator).

%% Codex (Responses API) → OpenAI chat-completions

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

register() ->
    translator_registry:register(codex, openai, ?MODULE).

request(Model, Body, Stream) ->
    Instructions = maps:get(<<"instructions">>, Body, <<>>),
    Input = maps:get(<<"input">>, Body, []),
    Messages = translate_input(Input),
    Messages1 = case Instructions of
        <<>> -> Messages;
        _ -> [#{<<"role">> => <<"system">>, <<"content">> => Instructions} | Messages]
    end,
    Result = #{<<"model">> => Model, <<"messages">> => Messages1, <<"stream">> => Stream},
    R1 = maybe_set(<<"max_tokens">>, <<"max_output_tokens">>, Body, Result),
    R2 = maybe_set(<<"temperature">>, <<"temperature">>, Body, R1),
    case maps:get(<<"tools">>, Body, undefined) of
        undefined -> R2;
        [] -> R2;
        Tools -> R2#{<<"tools">> => translate_tools(Tools)}
    end.

init_acc() -> #{}.

response_stream(#{<<"choices">> := [#{<<"delta">> := Delta} | _]} = Event, Acc) ->
    %% OpenAI chunk → Codex responses event
    Text = maps:get(<<"content">>, Delta, <<>>),
    case Text of
        <<>> -> {[], Acc};
        _ ->
            E = #{<<"type">> => <<"response.output_text.delta">>,
                  <<"delta">> => Text, <<"output_index">> => 0, <<"content_index">> => 0},
            {[jiffy:encode(E)], Acc}
    end;
response_stream(_, Acc) -> {[], Acc}.

response_nonstream(#{<<"choices">> := [#{<<"message">> := Msg} | _]} = Body) ->
    Content = maps:get(<<"content">>, Msg, <<>>),
    ToolCalls = maps:get(<<"tool_calls">>, Msg, []),
    TextItems = case Content of
        <<>> -> [];
        _ -> [#{<<"type">> => <<"message">>, <<"role">> => <<"assistant">>,
               <<"content">> => [#{<<"type">> => <<"output_text">>, <<"text">> => Content}]}]
    end,
    ToolItems = [#{<<"type">> => <<"function_call">>,
                   <<"call_id">> => maps:get(<<"id">>, TC, <<>>),
                   <<"name">> => maps:get(<<"name">>, maps:get(<<"function">>, TC)),
                   <<"arguments">> => maps:get(<<"arguments">>, maps:get(<<"function">>, TC))}
                 || TC <- ToolCalls],
    Usage = maps:get(<<"usage">>, Body, #{}),
    #{<<"id">> => maps:get(<<"id">>, Body, <<>>),
      <<"object">> => <<"response">>, <<"status">> => <<"completed">>,
      <<"model">> => maps:get(<<"model">>, Body, <<>>),
      <<"output">> => TextItems ++ ToolItems,
      <<"usage">> => #{<<"input_tokens">> => maps:get(<<"prompt_tokens">>, Usage, 0),
                       <<"output_tokens">> => maps:get(<<"completion_tokens">>, Usage, 0),
                       <<"total_tokens">> => maps:get(<<"total_tokens">>, Usage, 0)}};
response_nonstream(Body) -> Body.

translate_input(Input) ->
    lists:filtermap(fun
        (#{<<"type">> := <<"message">>, <<"role">> := R, <<"content">> := C}) when is_binary(C) ->
            {true, #{<<"role">> => R, <<"content">> => C}};
        (#{<<"type">> := <<"message">>, <<"role">> := R, <<"content">> := C}) when is_list(C) ->
            Text = iolist_to_binary([maps:get(<<"text">>, P, <<>>) || P <- C]),
            {true, #{<<"role">> => R, <<"content">> => Text}};
        (#{<<"type">> := <<"function_call">>, <<"call_id">> := Id, <<"name">> := N, <<"arguments">> := A}) ->
            {true, #{<<"role">> => <<"assistant">>, <<"content">> => <<>>,
                     <<"tool_calls">> => [#{<<"id">> => Id, <<"type">> => <<"function">>,
                                            <<"function">> => #{<<"name">> => N, <<"arguments">> => A}}]}};
        (#{<<"type">> := <<"function_call_output">>, <<"call_id">> := Id, <<"output">> := O}) ->
            {true, #{<<"role">> => <<"tool">>, <<"tool_call_id">> => Id, <<"content">> => O}};
        (_) -> false
    end, Input).

translate_tools(Tools) ->
    lists:filtermap(fun
        (#{<<"type">> := <<"function">>, <<"name">> := N} = T) ->
            {true, #{<<"type">> => <<"function">>,
                     <<"function">> => #{<<"name">> => N,
                                         <<"description">> => maps:get(<<"description">>, T, <<>>),
                                         <<"parameters">> => maps:get(<<"parameters">>, T, #{})}}};
        (_) -> false
    end, Tools).

maybe_set(TargetKey, SourceKey, Source, Target) ->
    case maps:get(SourceKey, Source, undefined) of
        undefined -> Target;
        Val -> Target#{TargetKey => Val}
    end.
