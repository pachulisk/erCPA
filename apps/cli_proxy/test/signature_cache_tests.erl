-module(signature_cache_tests).
-include_lib("eunit/include/eunit.hrl").

signature_cache_test_() ->
    {setup,
     fun() -> {ok, _} = signature_cache:start_link(), ok end,
     fun(_) -> gen_server:stop(signature_cache) end,
     [
      {"cache and retrieve signature",
       fun() ->
           Sig = binary:copy(<<"A">>, 60),  %% 60 bytes, meets minimum
           ok = signature_cache:cache(<<"claude-3-sonnet">>, <<"thinking text">>, Sig),
           ?assertEqual({ok, Sig}, signature_cache:get(<<"claude-3-sonnet">>, <<"thinking text">>))
       end},
      {"miss for uncached text",
       fun() ->
           ?assertEqual(miss, signature_cache:get(<<"claude-3">>, <<"never cached">>))
       end},
      {"same model group shares cache",
       fun() ->
           Sig = binary:copy(<<"B">>, 50),
           ok = signature_cache:cache(<<"claude-3-opus">>, <<"shared text">>, Sig),
           %% Different claude model, same group
           ?assertEqual({ok, Sig}, signature_cache:get(<<"claude-3-sonnet">>, <<"shared text">>))
       end},
      {"different model groups don't share",
       fun() ->
           Sig = binary:copy(<<"C">>, 50),
           ok = signature_cache:cache(<<"claude-3">>, <<"isolated">>, Sig),
           ?assertEqual(miss, signature_cache:get(<<"gpt-4">>, <<"isolated">>))
       end},
      {"short signature rejected",
       fun() ->
           ok = signature_cache:cache(<<"claude-3">>, <<"short sig text">>, <<"short">>),
           ?assertEqual(miss, signature_cache:get(<<"claude-3">>, <<"short sig text">>))
       end},
      {"clear removes all entries",
       fun() ->
           Sig = binary:copy(<<"D">>, 50),
           ok = signature_cache:cache(<<"claude-3">>, <<"will be cleared">>, Sig),
           ok = signature_cache:clear(),
           ?assertEqual(miss, signature_cache:get(<<"claude-3">>, <<"will be cleared">>))
       end}
     ]}.
