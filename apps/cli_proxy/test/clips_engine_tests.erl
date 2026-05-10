-module(clips_engine_tests).
-include_lib("eunit/include/eunit.hrl").

%% These tests verify the clips_engine gen_server API contracts.
%% They use a mock port script that echoes valid JSON responses.

%% Test fixture
clips_engine_test_() ->
    {setup,
     fun() ->
         MockPath = create_mock_port(),
         {ok, _Pid} = clips_engine:start_link(MockPath),
         MockPath
     end,
     fun(MockPath) ->
         gen_server:stop(clips_engine),
         file:delete(MockPath)
     end,
     fun(_MockPath) ->
         [
          {"reset returns ok",
           ?_assertEqual(ok, clips_engine:reset())},
          {"run returns fired count",
           ?_assertEqual({ok, 0}, clips_engine:run())},
          {"assert returns fact id",
           ?_assertMatch({ok, _}, clips_engine:assert({credential, #{id => <<"c1">>}}))},
          {"retract returns ok",
           ?_assertEqual(ok, clips_engine:retract(1))},
          {"retract_all returns ok",
           ?_assertEqual(ok, clips_engine:retract_all(credential))},
          {"query returns error for missing",
           ?_assertEqual(error, clips_engine:query(selection_result, <<"nonexistent">>))}
         ]
     end}.

create_mock_port() ->
    MockPath = filename:join(["/tmp", "mock_clips_port_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".sh"]),
    Script = <<"#!/bin/sh\n"
               "while IFS= read -r line; do\n"
               "  case \"$line\" in\n"
               "    *'\"op\":\"reset\"'*) echo '{\"ok\":true}' ;;\n"
               "    *'\"op\":\"run\"'*) echo '{\"ok\":true,\"fired\":0}' ;;\n"
               "    *'\"op\":\"assert\"'*) echo '{\"ok\":true,\"fact-id\":1}' ;;\n"
               "    *'\"op\":\"retract\"'*) echo '{\"ok\":true}' ;;\n"
               "    *'\"op\":\"retract-all\"'*) echo '{\"ok\":true}' ;;\n"
               "    *'\"op\":\"query\"'*) echo '{\"ok\":true,\"result\":null}' ;;\n"
               "    *'\"op\":\"load\"'*) echo '{\"ok\":true}' ;;\n"
               "    *) echo '{\"error\":\"unknown op\"}' ;;\n"
               "  esac\n"
               "done\n">>,
    ok = file:write_file(MockPath, Script),
    os:cmd("chmod +x " ++ MockPath),
    MockPath.
