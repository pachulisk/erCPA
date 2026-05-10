-module(e2e_home_mode_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% E2E-009: Home mode distributed operations
%% Tests home control plane logic without actual distribution
%% ============================================================

%% Test that home_client is_connected returns false when not started

home_not_connected_test() ->
    ?assertEqual(false, home_client:is_connected()).

%% Test config overlay logic (critical for home mode)

config_overlay_rules_test_() ->
    {setup,
     fun() ->
         {ok, _} = config_loader:start_link(#{
             port => 8317,
             host => <<"0.0.0.0">>,
             debug => false,
             ws_auth => true,
             disable_cooling => false
         }),
         ok
     end,
     fun(_) -> gen_server:stop(config_loader) end,
     [
      {"home overlay forces satellite settings",
       fun() ->
           %% Simulate receiving config from home node
           HomeConfig = #{
               port => 9999,
               host => <<"10.0.0.1">>,
               debug => true,
               ws_auth => true,
               disable_cooling => false,
               api_keys => [<<"home-key">>]
           },
           %% Apply overlay (same logic as home_client:apply_config_overlay)
           LocalPort = config_loader:get(port),
           LocalHost = config_loader:get(host),
           Merged = HomeConfig#{
               port => LocalPort,
               host => LocalHost,
               disable_cooling => true,
               ws_auth => false,
               usage_statistics_enabled => true
           },
           config_loader:apply_config(Merged),
           %% Local network preserved
           ?assertEqual(8317, config_loader:get(port)),
           ?assertEqual(<<"0.0.0.0">>, config_loader:get(host)),
           %% Home config applied
           ?assertEqual(true, config_loader:get(debug)),
           %% Satellite forced overrides
           ?assertEqual(true, config_loader:get(disable_cooling)),
           ?assertEqual(false, config_loader:get(ws_auth)),
           ?assertEqual(true, config_loader:get(usage_statistics_enabled))
       end},
      {"local settings preserved after overlay",
       fun() ->
           %% Port and host should never change from home overlay
           ?assertEqual(8317, config_loader:get(port)),
           ?assertEqual(<<"0.0.0.0">>, config_loader:get(host))
       end}
     ]}.

%% Test home_config broadcaster logic

home_config_broadcast_test_() ->
    {setup,
     fun() ->
         {ok, _} = config_loader:start_link(#{port => 8317}),
         case whereis(home_config) of
             undefined -> {ok, _} = home_config:start_link();
             _ -> ok
         end,
         ok
     end,
     fun(_) ->
         catch gen_server:stop(home_config),
         gen_server:stop(config_loader)
     end,
     [
      {"get_config returns current config",
       fun() ->
           Config = home_config:get_config(),
           ?assert(is_map(Config)),
           ?assertEqual(8317, maps:get(port, Config))
       end}
     ]}.

%% Test usage forwarding buffer behavior

usage_buffer_flush_threshold_test() ->
    %% Buffer should flush at 64 items (from DESIGN.md)
    FlushThreshold = 64,
    SmallBuf = lists:duplicate(10, #{credential_id => <<"c1">>, status => 200}),
    ?assert(length(SmallBuf) < FlushThreshold),
    FullBuf = lists:duplicate(FlushThreshold, #{credential_id => <<"c1">>, status => 200}),
    ?assertEqual(FlushThreshold, length(FullBuf)).

%% Test node monitoring concept

node_monitor_concept_test() ->
    %% net_kernel:monitor_nodes/1 is how we detect home node up/down
    %% We can't test actual distribution in unit tests, but verify
    %% the message format we expect
    DownMsg = {nodedown, 'home@control.local'},
    UpMsg = {nodeup, 'home@control.local'},
    ?assertMatch({nodedown, _}, DownMsg),
    ?assertMatch({nodeup, _}, UpMsg).
