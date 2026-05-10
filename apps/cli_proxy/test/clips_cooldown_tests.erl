-module(clips_cooldown_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Cooldown / State Transition Rule Tests
%% Ported from conductor cooldown logic
%%
%% Tests validate rules in priv/clips/cooldown.clp
%% ============================================================

now_ts() ->
    erlang:system_time(second).

%% ============================================================
%% T1-010: mark_success clears cooldown
%% ============================================================

mark_success_clears_cooldown_test_() ->
    {"200 response clears model cooldown and resets backoff",
     {setup,
      fun setup_clips/0,
      fun cleanup_clips/1,
      fun(_) ->
          clips_engine:reset(),
          Now = now_ts(),
          %% Credential exists and is active
          clips_engine:assert({credential, #{
              id => <<"c1">>, provider => <<"claude">>,
              status => active, priority => 0
          }}),
          %% Model is in cooldown
          clips_engine:assert({model_state, #{
              credential_id => <<"c1">>, model => <<"claude-3">>,
              available => no, cooldown_until => Now + 600,
              backoff_level => 2
          }}),
          %% Success result
          clips_engine:assert({result, #{
              credential_id => <<"c1">>, model => <<"claude-3">>,
              status_code => 200, now => Now
          }}),
          clips_engine:run(),
          Result = clips_engine:query(model_state, <<"credential-id">>, <<"c1">>),
          [?_assertMatch({ok, #{<<"available">> := <<"yes">>,
                                <<"backoff-level">> := 0}}, Result)]
      end}}.

%% ============================================================
%% T1-011: 429 triggers exponential backoff
%% ============================================================

mark_429_exponential_backoff_test_() ->
    {"429 response triggers exponential backoff cooldown",
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
          %% Model currently available with backoff level 0
          clips_engine:assert({model_state, #{
              credential_id => <<"c1">>, model => <<"claude-3">>,
              available => yes, cooldown_until => 0,
              backoff_level => 0
          }}),
          %% 429 result
          clips_engine:assert({result, #{
              credential_id => <<"c1">>, model => <<"claude-3">>,
              status_code => 429, now => Now
          }}),
          clips_engine:run(),
          Result = clips_engine:query(model_state, <<"credential-id">>, <<"c1">>),
          [
           ?_assertMatch({ok, #{<<"available">> := <<"no">>}}, Result),
           ?_assertMatch({ok, #{<<"backoff-level">> := 1}}, Result),
           %% Cooldown should be >= now + 1 (2^0 * 1 = 1 second)
           fun() ->
               case Result of
                   {ok, #{<<"cooldown-until">> := CU}} ->
                       ?assert(CU >= Now + 1);
                   _ ->
                       ?assert(false)
               end
           end
          ]
      end}}.

mark_429_level2_backoff_test_() ->
    {"Repeated 429 increases backoff exponentially",
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
          %% Model already at backoff level 3
          clips_engine:assert({model_state, #{
              credential_id => <<"c1">>, model => <<"claude-3">>,
              available => yes, cooldown_until => 0,
              backoff_level => 3
          }}),
          clips_engine:assert({result, #{
              credential_id => <<"c1">>, model => <<"claude-3">>,
              status_code => 429, now => Now
          }}),
          clips_engine:run(),
          Result = clips_engine:query(model_state, <<"credential-id">>, <<"c1">>),
          [
           ?_assertMatch({ok, #{<<"backoff-level">> := 4}}, Result),
           %% Cooldown should be 2^3 * 1 = 8 seconds (capped at 1800)
           fun() ->
               case Result of
                   {ok, #{<<"cooldown-until">> := CU}} ->
                       ?assert(CU >= Now + 8);
                   _ ->
                       ?assert(false)
               end
           end
          ]
      end}}.

%% ============================================================
%% T1-012: 401/402/403 triggers 30-minute hold
%% ============================================================

mark_401_30min_hold_test_() ->
    {"401 response triggers 30-minute cooldown hold",
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
          clips_engine:assert({model_state, #{
              credential_id => <<"c1">>, model => <<"claude-3">>,
              available => yes, cooldown_until => 0,
              backoff_level => 0
          }}),
          clips_engine:assert({result, #{
              credential_id => <<"c1">>, model => <<"claude-3">>,
              status_code => 401, now => Now
          }}),
          clips_engine:run(),
          Result = clips_engine:query(model_state, <<"credential-id">>, <<"c1">>),
          [
           ?_assertMatch({ok, #{<<"available">> := <<"no">>}}, Result),
           ?_assertMatch({ok, #{<<"backoff-level">> := 0}}, Result),
           %% 30-minute hold
           fun() ->
               case Result of
                   {ok, #{<<"cooldown-until">> := CU}} ->
                       ?assert(CU >= Now + 1800);
                   _ ->
                       ?assert(false)
               end
           end
          ]
      end}}.

mark_403_same_as_401_test_() ->
    {"403 response triggers same 30-minute hold as 401",
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
          clips_engine:assert({model_state, #{
              credential_id => <<"c1">>, model => <<"claude-3">>,
              available => yes, cooldown_until => 0,
              backoff_level => 0
          }}),
          clips_engine:assert({result, #{
              credential_id => <<"c1">>, model => <<"claude-3">>,
              status_code => 403, now => Now
          }}),
          clips_engine:run(),
          Result = clips_engine:query(model_state, <<"credential-id">>, <<"c1">>),
          [?_assertMatch({ok, #{<<"available">> := <<"no">>}}, Result)]
      end}}.

mark_5xx_short_cooldown_test_() ->
    {"5xx response triggers short cooldown (not 30min)",
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
          clips_engine:assert({model_state, #{
              credential_id => <<"c1">>, model => <<"claude-3">>,
              available => yes, cooldown_until => 0,
              backoff_level => 0
          }}),
          clips_engine:assert({result, #{
              credential_id => <<"c1">>, model => <<"claude-3">>,
              status_code => 502, now => Now
          }}),
          clips_engine:run(),
          Result = clips_engine:query(model_state, <<"credential-id">>, <<"c1">>),
          [
           ?_assertMatch({ok, #{<<"available">> := <<"no">>}}, Result),
           %% Short cooldown (1-60s, not 1800s)
           fun() ->
               case Result of
                   {ok, #{<<"cooldown-until">> := CU}} ->
                       ?assert(CU =< Now + 60);
                   _ ->
                       ?assert(false)
               end
           end
          ]
      end}}.

%% ============================================================
%% Setup / Cleanup helpers
%% ============================================================

setup_clips() ->
    case whereis(clips_engine) of
        undefined ->
            PortPath = real_port_path(),
            case filelib:is_file(PortPath) of
                true ->
                    {ok, _} = clips_engine:start_link(PortPath),
                    real_port;
                false ->
                    {ok, _} = clips_engine:start_link(create_mock_port()),
                    mock
            end;
        _Pid ->
            already_running
    end.

cleanup_clips(already_running) -> ok;
cleanup_clips(real_port) -> gen_server:stop(clips_engine);
cleanup_clips(mock) -> gen_server:stop(clips_engine).

real_port_path() ->
    case code:priv_dir(cli_proxy) of
        {error, _} -> "/nonexistent";
        PrivDir -> filename:join(PrivDir, "clips_port")
    end.

create_mock_port() ->
    MockPath = filename:join(["/tmp", "mock_clips_cd_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".sh"]),
    Script = <<"#!/bin/sh\nwhile IFS= read -r line; do\necho '{\"ok\":true,\"result\":null}'\ndone\n">>,
    ok = file:write_file(MockPath, Script),
    os:cmd("chmod +x " ++ MockPath),
    MockPath.
