-module(incremental_input_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tests for incremental vs full-transcript input mode detection

%% The handler checks for previous_response_id to decide mode

has_previous_response_id_test() ->
    Req = #{<<"type">> => <<"response.create">>,
            <<"model">> => <<"gpt-4">>,
            <<"previous_response_id">> => <<"resp_abc123">>,
            <<"input">> => [#{<<"type">> => <<"message">>,
                              <<"role">> => <<"user">>,
                              <<"content">> => <<"continue">>}]},
    ?assert(has_prev_id(Req)).

no_previous_response_id_test() ->
    Req = #{<<"type">> => <<"response.create">>,
            <<"model">> => <<"gpt-4">>,
            <<"input">> => [#{<<"type">> => <<"message">>,
                              <<"role">> => <<"user">>,
                              <<"content">> => <<"hello">>}]},
    ?assertNot(has_prev_id(Req)).

empty_previous_response_id_test() ->
    Req = #{<<"type">> => <<"response.create">>,
            <<"model">> => <<"gpt-4">>,
            <<"previous_response_id">> => <<>>,
            <<"input">> => []},
    ?assertNot(has_prev_id(Req)).

null_previous_response_id_test() ->
    Req = #{<<"type">> => <<"response.create">>,
            <<"model">> => <<"gpt-4">>,
            <<"previous_response_id">> => null,
            <<"input">> => []},
    ?assertNot(has_prev_id(Req)).

%% Transcript merge: previous output prepended to new input

merge_empty_previous_test() ->
    Input = [#{<<"type">> => <<"message">>, <<"role">> => <<"user">>,
               <<"content">> => <<"hi">>}],
    Result = merge_transcript([], Input),
    ?assertEqual(Input, Result).

merge_with_previous_output_test() ->
    PrevOutput = [#{<<"type">> => <<"message">>,
                    <<"role">> => <<"assistant">>,
                    <<"content">> => [#{<<"type">> => <<"output_text">>,
                                       <<"text">> => <<"I said hello">>}]}],
    NewInput = [#{<<"type">> => <<"message">>, <<"role">> => <<"user">>,
                  <<"content">> => <<"continue">>}],
    Result = merge_transcript(PrevOutput, NewInput),
    ?assertEqual(2, length(Result)),
    [Prev, New] = Result,
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Prev)),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, New)).

%%====================================================================
%% Helpers — reimplements handler logic for isolated testing
%%====================================================================

has_prev_id(#{<<"previous_response_id">> := PrevId})
  when PrevId =/= <<>>, PrevId =/= null, PrevId =/= undefined ->
    true;
has_prev_id(_) ->
    false.

merge_transcript([], Input) -> Input;
merge_transcript(PrevOutput, Input) ->
    PrevAsInput = [output_to_input(O) || O <- PrevOutput],
    PrevAsInput ++ Input.

output_to_input(#{<<"type">> := <<"message">>, <<"content">> := Content} = Item) ->
    Role = maps:get(<<"role">>, Item, <<"assistant">>),
    #{<<"type">> => <<"message">>, <<"role">> => Role, <<"content">> => Content};
output_to_input(Item) ->
    Item.
