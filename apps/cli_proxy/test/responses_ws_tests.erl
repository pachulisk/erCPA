-module(responses_ws_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Responses API WebSocket Protocol Tests (T5-001)
%% Tests handler logic without a running server
%% ============================================================

%% --- Tool cache repair ---

tool_cache_repairs_orphaned_output_test() ->
    Cache = ets:new(test_tc, [set, public]),
    ets:insert(Cache, {<<"call_1">>, #{
        <<"type">> => <<"function_call">>,
        <<"call_id">> => <<"call_1">>,
        <<"name">> => <<"search">>,
        <<"arguments">> => <<"{}">>
    }}),
    Input = [#{<<"type">> => <<"function_call_output">>,
               <<"call_id">> => <<"call_1">>,
               <<"output">> => <<"result">>}],
    Repaired = responses_ws_handler:repair_tool_calls(Input, Cache),
    ?assertEqual(2, length(Repaired)),
    [First, Second] = Repaired,
    ?assertEqual(<<"function_call">>, maps:get(<<"type">>, First)),
    ?assertEqual(<<"function_call_output">>, maps:get(<<"type">>, Second)),
    ets:delete(Cache).

tool_cache_no_repair_when_not_cached_test() ->
    Cache = ets:new(test_tc2, [set, public]),
    Input = [#{<<"type">> => <<"function_call_output">>,
               <<"call_id">> => <<"unknown_call">>,
               <<"output">> => <<"result">>}],
    Repaired = responses_ws_handler:repair_tool_calls(Input, Cache),
    ?assertEqual(1, length(Repaired)),
    ets:delete(Cache).

tool_cache_leaves_non_output_items_alone_test() ->
    Cache = ets:new(test_tc3, [set, public]),
    Input = [
        #{<<"type">> => <<"message">>, <<"role">> => <<"user">>,
          <<"content">> => <<"hello">>},
        #{<<"type">> => <<"function_call">>,
          <<"call_id">> => <<"call_2">>,
          <<"name">> => <<"bash">>}
    ],
    Repaired = responses_ws_handler:repair_tool_calls(Input, Cache),
    ?assertEqual(2, length(Repaired)),
    ets:delete(Cache).

%% --- Credential unpin via maybe_unpin_auth/2 ---
%% Record #state{} field 4 = pinned_auth_id (1=tag, 2=session_id, 3=execution_id, 4=pinned_auth_id)

credential_unpin_on_401_test() ->
    State = make_test_state(<<"cred-1">>),
    State1 = responses_ws_handler:maybe_unpin_auth(401, State),
    ?assertEqual(undefined, element(4, State1)).

credential_unpin_on_429_test() ->
    State = make_test_state(<<"cred-2">>),
    State1 = responses_ws_handler:maybe_unpin_auth(429, State),
    ?assertEqual(undefined, element(4, State1)).

credential_stays_pinned_on_200_test() ->
    State = make_test_state(<<"cred-3">>),
    State1 = responses_ws_handler:maybe_unpin_auth(200, State),
    ?assertEqual(<<"cred-3">>, element(4, State1)).

credential_stays_pinned_on_500_test() ->
    State = make_test_state(<<"cred-4">>),
    State1 = responses_ws_handler:maybe_unpin_auth(500, State),
    ?assertEqual(<<"cred-4">>, element(4, State1)).

%% --- Error event codes ---

error_403_unpins_test() ->
    State = make_test_state(<<"cred-5">>),
    State1 = responses_ws_handler:maybe_unpin_auth(403, State),
    ?assertEqual(undefined, element(4, State1)).

%%====================================================================
%% Helpers
%%====================================================================

make_test_state(PinnedAuthId) ->
    TC = ets:new(test_state_tc, [set, public]),
    TO = ets:new(test_state_to, [set, public]),
    %% #state{session_id, execution_id, pinned_auth_id, last_request,
    %%         last_response_output, tool_call_cache, tool_output_cache, seq, upstream_pid}
    {state,
     <<"sess_test">>,        %% session_id
     <<"exec_test">>,        %% execution_id
     PinnedAuthId,           %% pinned_auth_id
     undefined,              %% last_request
     [],                     %% last_response_output
     TC,                     %% tool_call_cache
     TO,                     %% tool_output_cache
     0,                      %% seq
     undefined               %% upstream_pid
    }.
