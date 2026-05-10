-module(usage_logger_tests).
-include_lib("eunit/include/eunit.hrl").

usage_logger_test_() ->
    {setup,
     fun() -> {ok, _} = usage_logger:start_link(), ok end,
     fun(_) -> gen_server:stop(usage_logger) end,
     [
      {"initially empty",
       fun() ->
           ?assertEqual([], usage_logger:get_usage())
       end},
      {"log success increments counter",
       fun() ->
           usage_logger:log(#{credential_id => <<"c1">>, status => 200}),
           timer:sleep(10),
           #{success := S, failed := F} = usage_logger:get_usage(<<"c1">>),
           ?assertEqual(1, S),
           ?assertEqual(0, F)
       end},
      {"log failure increments failed counter",
       fun() ->
           usage_logger:log(#{credential_id => <<"c2">>, status => 429}),
           timer:sleep(10),
           #{success := S, failed := F} = usage_logger:get_usage(<<"c2">>),
           ?assertEqual(0, S),
           ?assertEqual(1, F)
       end},
      {"batch_log processes multiple records",
       fun() ->
           usage_logger:batch_log(node(), [
               #{credential_id => <<"c3">>, status => 200},
               #{credential_id => <<"c3">>, status => 200},
               #{credential_id => <<"c3">>, status => 500}
           ]),
           timer:sleep(10),
           #{success := S, failed := F} = usage_logger:get_usage(<<"c3">>),
           ?assertEqual(2, S),
           ?assertEqual(1, F)
       end},
      {"get_usage returns all",
       fun() ->
           All = usage_logger:get_usage(),
           ?assert(length(All) >= 3)
       end}
     ]}.
