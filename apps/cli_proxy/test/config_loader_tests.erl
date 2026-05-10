-module(config_loader_tests).
-include_lib("eunit/include/eunit.hrl").

config_loader_test_() ->
    {setup,
     fun() ->
         {ok, _} = config_loader:start_link(#{
             port => 8317,
             debug => false,
             api_keys => [<<"key1">>, <<"key2">>]
         }),
         ok
     end,
     fun(_) ->
         gen_server:stop(config_loader)
     end,
     [
      {"get existing key",
       ?_assertEqual(8317, config_loader:get(port))},
      {"get missing key returns undefined",
       ?_assertEqual(undefined, config_loader:get(nonexistent))},
      {"get missing key with default",
       ?_assertEqual(42, config_loader:get(nonexistent, 42))},
      {"get_all returns map",
       fun() ->
           All = config_loader:get_all(),
           ?assert(is_map(All)),
           ?assertEqual(8317, maps:get(port, All))
       end},
      {"apply_config replaces values",
       fun() ->
           ok = config_loader:apply_config(#{port => 9999, host => <<"0.0.0.0">>}),
           ?assertEqual(9999, config_loader:get(port)),
           ?assertEqual(<<"0.0.0.0">>, config_loader:get(host))
       end},
      {"update_api_keys replaces key set",
       fun() ->
           ok = config_loader:update_api_keys([<<"new_key">>]),
           ?assertEqual([<<"new_key">>], config_loader:get(api_keys))
       end}
     ]}.
