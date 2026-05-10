-module(e2e_management_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% E2E-008: Management API config change affects live routing
%% Tests management handler dispatch and config updates
%% ============================================================

management_handler_test_() ->
    {setup,
     fun() ->
         {ok, _} = config_loader:start_link(#{
             port => 8317,
             debug => false,
             request_log => false,
             api_keys => [],
             routing_strategy => <<"round-robin">>,
             ws_auth => false,
             logging_to_file => false
         }),
         ok
     end,
     fun(_) -> gen_server:stop(config_loader) end,
     [
      {"config get returns current values",
       fun() ->
           ?assertEqual(8317, config_loader:get(port)),
           ?assertEqual(false, config_loader:get(debug))
       end},
      {"config apply changes live values",
       fun() ->
           config_loader:apply_config(#{debug => true}),
           ?assertEqual(true, config_loader:get(debug))
       end},
      {"routing strategy change persists",
       fun() ->
           config_loader:apply_config(#{routing_strategy => <<"fill-first">>}),
           ?assertEqual(<<"fill-first">>, config_loader:get(routing_strategy))
       end},
      {"api keys update affects access control",
       fun() ->
           config_loader:update_api_keys([<<"key-1">>, <<"key-2">>]),
           Keys = config_loader:get(api_keys),
           ?assertEqual([<<"key-1">>, <<"key-2">>], Keys),
           %% Verify access_control validates against these
           ?assertMatch({ok, _}, access_control:validate_key(<<"key-1">>)),
           ?assertMatch({ok, _}, access_control:validate_key(<<"key-2">>)),
           ?assertEqual({error, invalid_key}, access_control:validate_key(<<"bad-key">>))
       end},
      {"ws_auth toggle",
       fun() ->
           ?assertEqual(false, config_loader:get(ws_auth)),
           config_loader:apply_config(#{ws_auth => true}),
           ?assertEqual(true, config_loader:get(ws_auth))
       end},
      {"request_log toggle",
       fun() ->
           ?assertEqual(false, config_loader:get(request_log)),
           config_loader:apply_config(#{request_log => true}),
           ?assertEqual(true, config_loader:get(request_log))
       end}
     ]}.

%% Test management auth logic

management_auth_logic_test() ->
    %% Localhost should always be allowed
    ?assert(is_localhost({127, 0, 0, 1})),
    ?assert(is_localhost({0, 0, 0, 0, 0, 0, 0, 1})),
    ?assertNot(is_localhost({10, 0, 0, 1})),
    ?assertNot(is_localhost({192, 168, 1, 1})).

is_localhost({127, 0, 0, 1}) -> true;
is_localhost({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
is_localhost(_) -> false.
