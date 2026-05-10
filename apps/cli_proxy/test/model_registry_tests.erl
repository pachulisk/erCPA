-module(model_registry_tests).
-include_lib("eunit/include/eunit.hrl").

model_registry_test_() ->
    {setup,
     fun() -> {ok, _} = model_registry:start_link(), ok end,
     fun(_) -> gen_server:stop(model_registry) end,
     [
      {"initially empty",
       fun() ->
           Models = model_registry:get_available_models(),
           ?assertEqual([], Models)
       end},
      {"register client adds models",
       fun() ->
           ok = model_registry:register_client(<<"client1">>, <<"claude">>, [
               #{<<"id">> => <<"claude-3-sonnet">>, <<"provider">> => <<"claude">>},
               #{<<"id">> => <<"claude-3-opus">>, <<"provider">> => <<"claude">>}
           ]),
           Models = model_registry:get_available_models(),
           ?assertEqual(2, length(Models))
       end},
      {"is_model_available works",
       fun() ->
           ?assert(model_registry:is_model_available(<<"claude-3-sonnet">>)),
           ?assertNot(model_registry:is_model_available(<<"nonexistent">>))
       end},
      {"get_model_info returns info",
       fun() ->
           Info = model_registry:get_model_info(<<"claude-3-sonnet">>),
           ?assertEqual(<<"claude">>, maps:get(<<"provider">>, Info))
       end},
      {"unregister client removes models",
       fun() ->
           ok = model_registry:unregister_client(<<"client1">>),
           ?assertNot(model_registry:is_model_available(<<"claude-3-sonnet">>))
       end},
      {"multiple clients share model",
       fun() ->
           ok = model_registry:register_client(<<"c1">>, <<"claude">>, [
               #{<<"id">> => <<"shared-model">>, <<"provider">> => <<"claude">>}
           ]),
           ok = model_registry:register_client(<<"c2">>, <<"claude">>, [
               #{<<"id">> => <<"shared-model">>, <<"provider">> => <<"claude">>}
           ]),
           ?assert(model_registry:is_model_available(<<"shared-model">>)),
           %% Remove one client, model still available
           ok = model_registry:unregister_client(<<"c1">>),
           ?assert(model_registry:is_model_available(<<"shared-model">>)),
           %% Remove second client, model gone
           ok = model_registry:unregister_client(<<"c2">>),
           ?assertNot(model_registry:is_model_available(<<"shared-model">>))
       end},
      {"quota exceeded blocks model for client",
       fun() ->
           ok = model_registry:register_client(<<"qc">>, <<"claude">>, [
               #{<<"id">> => <<"quota-model">>, <<"provider">> => <<"claude">>}
           ]),
           ?assert(model_registry:is_model_available(<<"quota-model">>, <<"qc">>)),
           model_registry:set_quota_exceeded(<<"qc">>, <<"quota-model">>),
           timer:sleep(10),
           ?assertNot(model_registry:is_model_available(<<"quota-model">>, <<"qc">>)),
           %% Cleanup
           ok = model_registry:unregister_client(<<"qc">>)
       end}
     ]}.
