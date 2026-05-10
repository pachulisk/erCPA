-module(credential_proc_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Credential Process (gen_statem) Tests
%% T3-001: State transitions
%% T3-002: Refresh behavior
%% ============================================================

basic_lifecycle_test_() ->
    {setup,
     fun() ->
         {ok, Pid} = credential_proc:start_link(#{
             id => <<"test-cred-1">>,
             provider => claude,
             metadata => #{<<"access_token">> => <<"sk-test">>}
         }),
         Pid
     end,
     fun(Pid) -> credential_proc:stop(Pid) end,
     fun(Pid) ->
         [
          {"starts in ready/available state",
           ?_assertEqual(available, credential_proc:get_status(Pid, <<"claude-3">>))},
          {"get_metadata returns stored value",
           ?_assertEqual(<<"sk-test">>, credential_proc:get_metadata(Pid, <<"access_token">>))},
          {"get_metadata returns undefined for missing key",
           ?_assertEqual(undefined, credential_proc:get_metadata(Pid, <<"nonexistent">>))}
         ]
     end}.

mark_result_429_test_() ->
    {"429 puts model in cooldown",
     {setup,
      fun() ->
          {ok, Pid} = credential_proc:start_link(#{
              id => <<"test-cred-429">>,
              provider => claude,
              metadata => #{},
              backoff_base_ms => 50
          }),
          Pid
      end,
      fun(Pid) -> credential_proc:stop(Pid) end,
      fun(Pid) ->
          ok = credential_proc:mark_result(Pid, <<"claude-3">>, 429),
          [?_assertEqual(unavailable, credential_proc:get_status(Pid, <<"claude-3">>))]
      end}}.

mark_result_200_clears_cooldown_test_() ->
    {"200 after 429 clears model cooldown",
     {setup,
      fun() ->
          {ok, Pid} = credential_proc:start_link(#{
              id => <<"test-cred-200">>,
              provider => claude,
              metadata => #{},
              backoff_base_ms => 50
          }),
          Pid
      end,
      fun(Pid) -> credential_proc:stop(Pid) end,
      fun(Pid) ->
          ok = credential_proc:mark_result(Pid, <<"claude-3">>, 429),
          ?assertEqual(unavailable, credential_proc:get_status(Pid, <<"claude-3">>)),
          ok = credential_proc:mark_result(Pid, <<"claude-3">>, 200),
          [?_assertEqual(available, credential_proc:get_status(Pid, <<"claude-3">>))]
      end}}.

cooldown_expires_test_() ->
    {"Cooldown auto-expires after backoff delay",
     {timeout, 5,
      fun() ->
          {ok, Pid} = credential_proc:start_link(#{
              id => <<"test-cred-expire">>,
              provider => claude,
              metadata => #{},
              backoff_base_ms => 50  %% 50ms process-level backoff
          }),
          ok = credential_proc:mark_result(Pid, <<"claude-3">>, 429),
          ?assertEqual(unavailable, credential_proc:get_status(Pid, <<"claude-3">>)),
          %% Model cooldown is min(2^0, 1800) = 1 second based on system time
          %% Process cooldown is 50ms. After process returns to ready,
          %% model state still checks cooldown_until vs now.
          %% Wait for model-level cooldown to expire (1s + margin)
          timer:sleep(1200),
          ?assertEqual(available, credential_proc:get_status(Pid, <<"claude-3">>)),
          credential_proc:stop(Pid)
      end}}.

disabled_is_terminal_test_() ->
    {"Disabled state blocks all requests",
     {setup,
      fun() ->
          {ok, Pid} = credential_proc:start_link(#{
              id => <<"test-cred-dis">>,
              provider => claude,
              metadata => #{}
          }),
          Pid
      end,
      fun(Pid) -> credential_proc:stop(Pid) end,
      fun(Pid) ->
          credential_proc:disable(Pid),
          timer:sleep(10),  %% Let cast propagate
          [
           {"disabled returns disabled status",
            ?_assertEqual(disabled, credential_proc:get_status(Pid, <<"claude-3">>))},
           {"mark_result doesn't change state when disabled",
            fun() ->
                ok = credential_proc:mark_result(Pid, <<"claude-3">>, 200),
                ?assertEqual(disabled, credential_proc:get_status(Pid, <<"claude-3">>))
            end}
          ]
      end}}.

enable_after_disable_test_() ->
    {"Enable returns process to ready state",
     {timeout, 5,
      fun() ->
          {ok, Pid} = credential_proc:start_link(#{
              id => <<"test-cred-en">>,
              provider => claude,
              metadata => #{}
          }),
          credential_proc:disable(Pid),
          timer:sleep(10),
          ?assertEqual(disabled, credential_proc:get_status(Pid, <<"claude-3">>)),
          credential_proc:enable(Pid),
          timer:sleep(10),
          ?assertEqual(available, credential_proc:get_status(Pid, <<"claude-3">>)),
          credential_proc:stop(Pid)
      end}}.

thinking_suffix_shares_state_test_() ->
    {"Thinking suffix model(high) shares state with base model",
     {setup,
      fun() ->
          {ok, Pid} = credential_proc:start_link(#{
              id => <<"test-cred-suffix">>,
              provider => claude,
              metadata => #{}
          }),
          Pid
      end,
      fun(Pid) -> credential_proc:stop(Pid) end,
      fun(Pid) ->
          ok = credential_proc:mark_result(Pid, <<"claude-3">>, 429),
          [
           {"base model unavailable",
            ?_assertEqual(unavailable, credential_proc:get_status(Pid, <<"claude-3">>))},
           {"suffixed model also unavailable",
            ?_assertEqual(unavailable, credential_proc:get_status(Pid, <<"claude-3(high)">>))}
          ]
      end}}.

auth_error_30min_hold_test_() ->
    {"401/403 triggers 30-minute hold",
     {setup,
      fun() ->
          {ok, Pid} = credential_proc:start_link(#{
              id => <<"test-cred-auth">>,
              provider => claude,
              metadata => #{}
          }),
          Pid
      end,
      fun(Pid) -> credential_proc:stop(Pid) end,
      fun(Pid) ->
          ok = credential_proc:mark_result(Pid, <<"claude-3">>, 401),
          [?_assertEqual(unavailable, credential_proc:get_status(Pid, <<"claude-3">>))]
      end}}.
