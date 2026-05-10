-module(file_store_tests).
-include_lib("eunit/include/eunit.hrl").

file_store_test_() ->
    {setup,
     fun() ->
         TestDir = "/tmp/ercpa_test_store_" ++ integer_to_list(erlang:unique_integer([positive])),
         ok = filelib:ensure_dir(filename:join(TestDir, "dummy")),
         {ok, _} = config_loader:start_link(#{
             auth_dir => list_to_binary(TestDir),
             config_path => list_to_binary(filename:join(TestDir, "config.yaml"))
         }),
         TestDir
     end,
     fun(TestDir) ->
         gen_server:stop(config_loader),
         os:cmd("rm -rf " ++ TestDir)
     end,
     fun(TestDir) ->
         [
          {"load_all empty dir returns empty list",
           fun() ->
               {ok, Auths} = file_store:load_all(),
               ?assertEqual([], Auths)
           end},
          {"save creates file",
           fun() ->
               ok = file_store:save(claude, #{
                   <<"email">> => <<"test@example.com">>,
                   <<"access_token">> => <<"sk-test">>
               }),
               Files = filelib:wildcard(filename:join(TestDir, "*.json")),
               ?assert(length(Files) > 0)
           end},
          {"load_all finds saved file",
           fun() ->
               {ok, Auths} = file_store:load_all(),
               ?assert(length(Auths) > 0),
               [Auth | _] = Auths,
               ?assertEqual(claude, maps:get(provider, Auth))
           end},
          {"save_config and load_config roundtrip",
           fun() ->
               ok = file_store:save_config(#{<<"port">> => 8317, <<"debug">> => true}),
               {ok, Config} = file_store:load_config(),
               ?assertEqual(8317, maps:get(<<"port">>, Config)),
               ?assertEqual(true, maps:get(<<"debug">>, Config))
           end},
          {"delete removes file",
           fun() ->
               %% Save a file first
               ok = file_store:save(codex, #{
                   <<"id">> => <<"delete-me">>,
                   <<"email">> => <<"del@test.com">>,
                   <<"access_token">> => <<"token">>
               }),
               %% Verify it exists
               {ok, Auths1} = file_store:load_all(),
               HasIt = lists:any(fun(A) -> maps:get(id, A) =:= <<"delete-me">> end, Auths1),
               ?assert(HasIt),
               %% Delete
               ok = file_store:delete(<<"delete-me">>),
               %% Verify gone
               {ok, Auths2} = file_store:load_all(),
               HasIt2 = lists:any(fun(A) -> maps:get(id, A) =:= <<"delete-me">> end, Auths2),
               ?assertNot(HasIt2)
           end}
         ]
     end}.
