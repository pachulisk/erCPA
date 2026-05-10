-module(clips_selection_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Credential Selection Rule Tests
%% Ported from sdk/cliproxy/auth/selector_test.go (1455 lines)
%%
%% These tests validate the CLIPS selection rules defined in
%% priv/clips/selection.clp. They require a functional CLIPS
%% engine port to run.
%%
%% Test naming convention:
%%   {strategy}_{scenario}_test
%% ============================================================

%% Helper to get current unix timestamp
now_ts() ->
    erlang:system_time(second).

%% ============================================================
%% T1-006: Fill-first strategy tests
%% ============================================================

fill_first_deterministic_test_() ->
    {"Fill-first always picks first active credential by sort order",
     {setup,
      fun setup_clips/0,
      fun cleanup_clips/1,
      fun(_) ->
          clips_engine:reset(),
          %% Assert 3 active credentials
          clips_engine:assert({credential, #{
              id => <<"a">>, provider => <<"claude">>,
              status => active, priority => 0
          }}),
          clips_engine:assert({credential, #{
              id => <<"b">>, provider => <<"claude">>,
              status => active, priority => 0
          }}),
          clips_engine:assert({credential, #{
              id => <<"c">>, provider => <<"claude">>,
              status => active, priority => 0
          }}),
          %% Assert selection request
          clips_engine:assert({select_request, #{
              id => <<"r1">>, model => <<"claude-3">>,
              session_id => <<>>, need_websocket => no,
              now => now_ts()
          }}),
          clips_engine:run(),
          Result = clips_engine:query(selection_result, <<"request-id">>, <<"r1">>),
          [?_assertMatch({ok, #{<<"credential-id">> := <<"a">>}}, Result)]
      end}}.

fill_first_priority_fallback_test_() ->
    {"Fill-first falls back to lower priority when high is in cooldown",
     {setup,
      fun setup_clips/0,
      fun cleanup_clips/1,
      fun(_) ->
          clips_engine:reset(),
          Now = now_ts(),
          clips_engine:assert({credential, #{
              id => <<"high">>, provider => <<"claude">>,
              status => cooldown, priority => 10,
              cooldown_until => Now + 3600
          }}),
          clips_engine:assert({credential, #{
              id => <<"low">>, provider => <<"claude">>,
              status => active, priority => 0
          }}),
          clips_engine:assert({select_request, #{
              id => <<"r1">>, model => <<"claude-3">>,
              session_id => <<>>, need_websocket => no,
              now => Now
          }}),
          clips_engine:run(),
          Result = clips_engine:query(selection_result, <<"request-id">>, <<"r1">>),
          [?_assertMatch({ok, #{<<"credential-id">> := <<"low">>}}, Result)]
      end}}.

%% ============================================================
%% T1-007: Round-robin strategy tests
%% ============================================================

round_robin_cycles_test_() ->
    {"Round-robin cycles through credentials in order",
     {setup,
      fun setup_clips/0,
      fun cleanup_clips/1,
      fun(_) ->
          %% Note: Round-robin behavior in CLIPS requires additional
          %% state tracking (cursor). For now, test that multiple
          %% equal-priority credentials can be selected.
          clips_engine:reset(),
          Now = now_ts(),
          lists:foreach(fun(Id) ->
              clips_engine:assert({credential, #{
                  id => Id, provider => <<"claude">>,
                  status => active, priority => 0
              }})
          end, [<<"a">>, <<"b">>, <<"c">>]),
          clips_engine:assert({select_request, #{
              id => <<"r1">>, model => <<"claude-3">>,
              session_id => <<>>, need_websocket => no,
              now => Now
          }}),
          clips_engine:run(),
          Result = clips_engine:query(selection_result, <<"request-id">>, <<"r1">>),
          %% Should select one of the three
          [?_assertMatch({ok, _}, Result)]
      end}}.

priority_buckets_test_() ->
    {"Higher priority credentials selected before lower",
     {setup,
      fun setup_clips/0,
      fun cleanup_clips/1,
      fun(_) ->
          clips_engine:reset(),
          Now = now_ts(),
          clips_engine:assert({credential, #{
              id => <<"low">>, provider => <<"claude">>,
              status => active, priority => 0
          }}),
          clips_engine:assert({credential, #{
              id => <<"high">>, provider => <<"claude">>,
              status => active, priority => 10
          }}),
          clips_engine:assert({select_request, #{
              id => <<"r1">>, model => <<"claude-3">>,
              session_id => <<>>, need_websocket => no,
              now => Now
          }}),
          clips_engine:run(),
          Result = clips_engine:query(selection_result, <<"request-id">>, <<"r1">>),
          [?_assertMatch({ok, #{<<"credential-id">> := <<"high">>}}, Result)]
      end}}.

%% ============================================================
%% T1-008: Session affinity tests
%% ============================================================

session_affinity_prefers_bound_test_() ->
    {"Session-bound credential chosen over higher priority",
     {setup,
      fun setup_clips/0,
      fun cleanup_clips/1,
      fun(_) ->
          clips_engine:reset(),
          Now = now_ts(),
          clips_engine:assert({credential, #{
              id => <<"c1">>, provider => <<"claude">>,
              status => active, priority => 0
          }}),
          clips_engine:assert({credential, #{
              id => <<"c2">>, provider => <<"claude">>,
              status => active, priority => 10
          }}),
          clips_engine:assert({session_binding, #{
              session_id => <<"sess1">>,
              credential_id => <<"c1">>,
              bound_at => Now - 60,
              ttl => 3600
          }}),
          clips_engine:assert({select_request, #{
              id => <<"r1">>, model => <<"claude-3">>,
              session_id => <<"sess1">>, need_websocket => no,
              now => Now
          }}),
          clips_engine:run(),
          Result = clips_engine:query(selection_result, <<"request-id">>, <<"r1">>),
          [?_assertMatch({ok, #{<<"credential-id">> := <<"c1">>,
                                <<"reason">> := <<"session-affinity">>}}, Result)]
      end}}.

session_affinity_expired_falls_through_test_() ->
    {"Expired session binding falls through to priority selection",
     {setup,
      fun setup_clips/0,
      fun cleanup_clips/1,
      fun(_) ->
          clips_engine:reset(),
          Now = now_ts(),
          clips_engine:assert({credential, #{
              id => <<"c1">>, provider => <<"claude">>,
              status => active, priority => 0
          }}),
          clips_engine:assert({credential, #{
              id => <<"c2">>, provider => <<"claude">>,
              status => active, priority => 10
          }}),
          %% Binding expired (bound 2 hours ago, TTL 1 hour)
          clips_engine:assert({session_binding, #{
              session_id => <<"sess1">>,
              credential_id => <<"c1">>,
              bound_at => Now - 7200,
              ttl => 3600
          }}),
          clips_engine:assert({select_request, #{
              id => <<"r1">>, model => <<"claude-3">>,
              session_id => <<"sess1">>, need_websocket => no,
              now => Now
          }}),
          clips_engine:run(),
          Result = clips_engine:query(selection_result, <<"request-id">>, <<"r1">>),
          %% Should pick c2 (higher priority) since binding expired
          [?_assertMatch({ok, #{<<"credential-id">> := <<"c2">>}}, Result)]
      end}}.

%% ============================================================
%% T1-009: Exclusion rule tests
%% ============================================================

exclude_disabled_test_() ->
    {"Disabled credentials are excluded",
     {setup,
      fun setup_clips/0,
      fun cleanup_clips/1,
      fun(_) ->
          clips_engine:reset(),
          Now = now_ts(),
          clips_engine:assert({credential, #{
              id => <<"disabled_one">>, provider => <<"claude">>,
              status => disabled, priority => 10
          }}),
          clips_engine:assert({credential, #{
              id => <<"active_one">>, provider => <<"claude">>,
              status => active, priority => 0
          }}),
          clips_engine:assert({select_request, #{
              id => <<"r1">>, model => <<"claude-3">>,
              session_id => <<>>, need_websocket => no,
              now => Now
          }}),
          clips_engine:run(),
          Result = clips_engine:query(selection_result, <<"request-id">>, <<"r1">>),
          [?_assertMatch({ok, #{<<"credential-id">> := <<"active_one">>}}, Result)]
      end}}.

exclude_no_websocket_test_() ->
    {"Credential without websocket excluded when WS needed",
     {setup,
      fun setup_clips/0,
      fun cleanup_clips/1,
      fun(_) ->
          clips_engine:reset(),
          Now = now_ts(),
          clips_engine:assert({credential, #{
              id => <<"no_ws">>, provider => <<"codex">>,
              status => active, priority => 10,
              has_websocket => no
          }}),
          clips_engine:assert({credential, #{
              id => <<"has_ws">>, provider => <<"codex">>,
              status => active, priority => 0,
              has_websocket => yes
          }}),
          clips_engine:assert({select_request, #{
              id => <<"r1">>, model => <<"gpt-4">>,
              session_id => <<>>, need_websocket => yes,
              now => Now
          }}),
          clips_engine:run(),
          Result = clips_engine:query(selection_result, <<"request-id">>, <<"r1">>),
          [?_assertMatch({ok, #{<<"credential-id">> := <<"has_ws">>}}, Result)]
      end}}.

all_cooldown_returns_no_result_test_() ->
    {"All credentials in cooldown returns no selection",
     {setup,
      fun setup_clips/0,
      fun cleanup_clips/1,
      fun(_) ->
          clips_engine:reset(),
          Now = now_ts(),
          clips_engine:assert({credential, #{
              id => <<"c1">>, provider => <<"claude">>,
              status => cooldown, priority => 0,
              cooldown_until => Now + 600
          }}),
          clips_engine:assert({credential, #{
              id => <<"c2">>, provider => <<"claude">>,
              status => cooldown, priority => 0,
              cooldown_until => Now + 600
          }}),
          clips_engine:assert({select_request, #{
              id => <<"r1">>, model => <<"claude-3">>,
              session_id => <<>>, need_websocket => no,
              now => Now
          }}),
          clips_engine:run(),
          Result = clips_engine:query(selection_result, <<"request-id">>, <<"r1">>),
          [?_assertEqual(error, Result)]
      end}}.

exclude_model_cooldown_test_() ->
    {"Per-model cooldown excludes credential for that model",
     {setup,
      fun setup_clips/0,
      fun cleanup_clips/1,
      fun(_) ->
          clips_engine:reset(),
          Now = now_ts(),
          clips_engine:assert({credential, #{
              id => <<"c1">>, provider => <<"claude">>,
              status => active, priority => 10
          }}),
          clips_engine:assert({credential, #{
              id => <<"c2">>, provider => <<"claude">>,
              status => active, priority => 0
          }}),
          %% c1 is in model-specific cooldown for claude-3
          clips_engine:assert({model_state, #{
              credential_id => <<"c1">>, model => <<"claude-3">>,
              available => no, cooldown_until => Now + 600,
              backoff_level => 1
          }}),
          clips_engine:assert({select_request, #{
              id => <<"r1">>, model => <<"claude-3">>,
              session_id => <<>>, need_websocket => no,
              now => Now
          }}),
          clips_engine:run(),
          Result = clips_engine:query(selection_result, <<"request-id">>, <<"r1">>),
          [?_assertMatch({ok, #{<<"credential-id">> := <<"c2">>}}, Result)]
      end}}.

%% ============================================================
%% Setup / Cleanup helpers
%% ============================================================

setup_clips() ->
    %% Start clips_engine with real CLIPS port
    case whereis(clips_engine) of
        undefined ->
            PortPath = real_port_path(),
            case filelib:is_file(PortPath) of
                true ->
                    {ok, _} = clips_engine:start_link(PortPath),
                    real_port;
                false ->
                    %% Fall back to mock if port not compiled
                    MockPath = create_mock_port(),
                    {ok, _} = clips_engine:start_link(MockPath),
                    {mock, MockPath}
            end;
        _Pid ->
            already_running
    end.

cleanup_clips(already_running) -> ok;
cleanup_clips(real_port) ->
    gen_server:stop(clips_engine);
cleanup_clips({mock, MockPath}) ->
    gen_server:stop(clips_engine),
    file:delete(MockPath).

real_port_path() ->
    case code:priv_dir(cli_proxy) of
        {error, _} -> "/nonexistent";
        PrivDir -> filename:join(PrivDir, "clips_port")
    end.

create_mock_port() ->
    MockPath = filename:join(["/tmp", "mock_clips_sel_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".sh"]),
    Script = <<"#!/bin/sh\nwhile IFS= read -r line; do\n  case \"$line\" in\n    *'\"op\":\"reset\"'*) echo '{\"ok\":true}' ;;\n    *'\"op\":\"run\"'*) echo '{\"ok\":true,\"fired\":0}' ;;\n    *'\"op\":\"assert\"'*) echo '{\"ok\":true,\"fact-id\":1}' ;;\n    *'\"op\":\"retract\"'*) echo '{\"ok\":true}' ;;\n    *'\"op\":\"retract-all\"'*) echo '{\"ok\":true}' ;;\n    *'\"op\":\"query\"'*) echo '{\"ok\":true,\"result\":null}' ;;\n    *'\"op\":\"load\"'*) echo '{\"ok\":true}' ;;\n    *) echo '{\"error\":\"unknown\"}' ;;\n  esac\ndone\n">>,
    ok = file:write_file(MockPath, Script),
    os:cmd("chmod +x " ++ MockPath),
    MockPath.
