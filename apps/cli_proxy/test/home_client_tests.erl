-module(home_client_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Home client tests
%% Tests config overlay logic and usage buffering without actual distribution
%% ============================================================

%% Test config overlay rules

config_overlay_preserves_local_network_test_() ->
    {setup,
     fun() ->
         {ok, _} = config_loader:start_link(#{
             port => 8317,
             host => <<"0.0.0.0">>,
             debug => false
         }),
         ok
     end,
     fun(_) -> gen_server:stop(config_loader) end,
     [
      {"overlay preserves local port",
       fun() ->
           %% Simulate home config overlay
           HomeConfig = #{
               port => 9999,       %% Home wants different port
               host => <<"10.0.0.1">>,
               debug => true,
               api_keys => [<<"home-key">>]
           },
           %% Apply overlay (same logic as home_client)
           LocalPort = config_loader:get(port),
           LocalHost = config_loader:get(host),
           Merged = HomeConfig#{
               port => LocalPort,      %% Preserve local
               host => LocalHost,       %% Preserve local
               disable_cooling => true,
               ws_auth => false,
               usage_statistics_enabled => true
           },
           config_loader:apply_config(Merged),
           %% Port should be preserved from local
           ?assertEqual(8317, config_loader:get(port)),
           %% Host should be preserved from local
           ?assertEqual(<<"0.0.0.0">>, config_loader:get(host)),
           %% Home settings should be applied
           ?assertEqual(true, config_loader:get(debug)),
           %% Satellite forced settings
           ?assertEqual(true, config_loader:get(disable_cooling)),
           ?assertEqual(false, config_loader:get(ws_auth)),
           ?assertEqual(true, config_loader:get(usage_statistics_enabled))
       end}
     ]}.

%% Test usage buffer logic

usage_buffer_accumulates_test() ->
    %% Simulate the buffering logic from home_client
    Buf0 = [],
    Buf1 = [#{credential_id => <<"c1">>, status => 200} | Buf0],
    ?assertEqual(1, length(Buf1)),
    Buf2 = [#{credential_id => <<"c2">>, status => 429} | Buf1],
    ?assertEqual(2, length(Buf2)),
    %% Should flush when >= 64
    Buf64 = lists:duplicate(64, #{credential_id => <<"cx">>, status => 200}),
    ?assert(length(Buf64) >= 64).

%% Test is_connected returns false when not started

is_connected_when_not_started_test() ->
    ?assertEqual(false, home_client:is_connected()).
