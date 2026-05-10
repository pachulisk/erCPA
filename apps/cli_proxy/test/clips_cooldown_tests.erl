-module(clips_cooldown_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Cooldown / State Transition Rule Tests
%% Uses a single clips_engine instance for all tests
%% ============================================================

now_ts() -> erlang:system_time(second).

clips_cooldown_test_() ->
    {setup,
     fun setup_clips/0,
     fun cleanup_clips/1,
     fun(SetupResult) ->
         case SetupResult of
             skip -> [];
             _ -> cooldown_tests()
         end
     end}.

cooldown_tests() ->
    [
     {"200 clears model cooldown",
      fun() ->
          clips_engine:reset(),
          Now = now_ts(),
          clips_engine:assert({credential, #{id => <<"c1">>, provider => <<"claude">>,
                                             status => active, priority => 0}}),
          clips_engine:assert({model_state, #{credential_id => <<"c1">>, model => <<"claude-3">>,
                                              available => no, cooldown_until => Now + 600,
                                              backoff_level => 2}}),
          clips_engine:assert({result, #{credential_id => <<"c1">>, model => <<"claude-3">>,
                                         status_code => 200, now => Now}}),
          clips_engine:run(),
          Result = clips_engine:query(model_state, <<"credential-id">>, <<"c1">>),
          ?assertMatch({ok, #{<<"available">> := <<"yes">>, <<"backoff-level">> := 0}}, Result)
      end},
     {"429 triggers exponential backoff",
      fun() ->
          clips_engine:reset(),
          Now = now_ts(),
          clips_engine:assert({credential, #{id => <<"c1">>, provider => <<"claude">>,
                                             status => active, priority => 0}}),
          clips_engine:assert({model_state, #{credential_id => <<"c1">>, model => <<"claude-3">>,
                                              available => yes, cooldown_until => 0,
                                              backoff_level => 0}}),
          clips_engine:assert({result, #{credential_id => <<"c1">>, model => <<"claude-3">>,
                                         status_code => 429, now => Now}}),
          clips_engine:run(),
          Result = clips_engine:query(model_state, <<"credential-id">>, <<"c1">>),
          ?assertMatch({ok, #{<<"available">> := <<"no">>}}, Result),
          {ok, #{<<"backoff-level">> := BL}} = Result,
          ?assertEqual(1, BL),
          {ok, #{<<"cooldown-until">> := CU}} = Result,
          ?assert(CU >= Now + 1)
      end},
     {"401 triggers 30-minute hold",
      fun() ->
          clips_engine:reset(),
          Now = now_ts(),
          clips_engine:assert({credential, #{id => <<"c1">>, provider => <<"claude">>,
                                             status => active, priority => 0}}),
          clips_engine:assert({model_state, #{credential_id => <<"c1">>, model => <<"claude-3">>,
                                              available => yes, cooldown_until => 0,
                                              backoff_level => 0}}),
          clips_engine:assert({result, #{credential_id => <<"c1">>, model => <<"claude-3">>,
                                         status_code => 401, now => Now}}),
          clips_engine:run(),
          Result = clips_engine:query(model_state, <<"credential-id">>, <<"c1">>),
          ?assertMatch({ok, #{<<"available">> := <<"no">>}}, Result),
          {ok, #{<<"cooldown-until">> := CU}} = Result,
          ?assert(CU >= Now + 1800)
      end},
     {"403 same as 401",
      fun() ->
          clips_engine:reset(),
          Now = now_ts(),
          clips_engine:assert({credential, #{id => <<"c1">>, provider => <<"claude">>,
                                             status => active, priority => 0}}),
          clips_engine:assert({model_state, #{credential_id => <<"c1">>, model => <<"claude-3">>,
                                              available => yes, cooldown_until => 0,
                                              backoff_level => 0}}),
          clips_engine:assert({result, #{credential_id => <<"c1">>, model => <<"claude-3">>,
                                         status_code => 403, now => Now}}),
          clips_engine:run(),
          Result = clips_engine:query(model_state, <<"credential-id">>, <<"c1">>),
          ?assertMatch({ok, #{<<"available">> := <<"no">>}}, Result)
      end},
     {"5xx short cooldown",
      fun() ->
          clips_engine:reset(),
          Now = now_ts(),
          clips_engine:assert({credential, #{id => <<"c1">>, provider => <<"claude">>,
                                             status => active, priority => 0}}),
          clips_engine:assert({model_state, #{credential_id => <<"c1">>, model => <<"claude-3">>,
                                              available => yes, cooldown_until => 0,
                                              backoff_level => 0}}),
          clips_engine:assert({result, #{credential_id => <<"c1">>, model => <<"claude-3">>,
                                         status_code => 502, now => Now}}),
          clips_engine:run(),
          Result = clips_engine:query(model_state, <<"credential-id">>, <<"c1">>),
          ?assertMatch({ok, #{<<"available">> := <<"no">>}}, Result),
          {ok, #{<<"cooldown-until">> := CU}} = Result,
          ?assert(CU =< Now + 60)
      end},
     {"repeated 429 increases backoff",
      fun() ->
          clips_engine:reset(),
          Now = now_ts(),
          clips_engine:assert({credential, #{id => <<"c1">>, provider => <<"claude">>,
                                             status => active, priority => 0}}),
          clips_engine:assert({model_state, #{credential_id => <<"c1">>, model => <<"claude-3">>,
                                              available => yes, cooldown_until => 0,
                                              backoff_level => 3}}),
          clips_engine:assert({result, #{credential_id => <<"c1">>, model => <<"claude-3">>,
                                         status_code => 429, now => Now}}),
          clips_engine:run(),
          Result = clips_engine:query(model_state, <<"credential-id">>, <<"c1">>),
          {ok, #{<<"backoff-level">> := BL}} = Result,
          ?assertEqual(4, BL)
      end}
    ].

setup_clips() ->
    case whereis(clips_engine) of
        undefined ->
            PortPath = real_port_path(),
            case filelib:is_file(PortPath) of
                true ->
                    {ok, _} = clips_engine:start_link(PortPath),
                    started;
                false ->
                    skip
            end;
        _Pid ->
            reused
    end.

cleanup_clips(started) -> gen_server:stop(clips_engine);
cleanup_clips(_) -> ok.

real_port_path() ->
    case code:priv_dir(cli_proxy) of
        {error, _} -> "/nonexistent";
        PrivDir -> filename:join(PrivDir, "clips_port")
    end.
