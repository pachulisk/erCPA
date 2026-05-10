-module(http_handler_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% HTTP Handler Unit Tests
%% Tests handler logic without requiring a running server.
%% Full HTTP integration tests are in proxy_integration_SUITE (Common Test).
%% ============================================================

%% Verify modules compile and export expected functions
handler_exports_test() ->
    ?assert(erlang:function_exported(openai_handler, init, 2)),
    ?assert(erlang:function_exported(health_handler, init, 2)),
    ?assert(erlang:function_exported(models_handler, init, 2)).

%% Verify SSE formatter produces correct output
sse_format_in_handler_test() ->
    Chunk = #{<<"id">> => <<"test">>, <<"choices">> => []},
    Formatted = iolist_to_binary(sse_parser:format_event(Chunk)),
    ?assert(binary:match(Formatted, <<"data: ">>) =/= nomatch),
    ?assert(binary:match(Formatted, <<"\n\n">>) =/= nomatch).

%% Verify access control with no keys allows all
access_no_keys_allows_all_test() ->
    %% When api_keys_tab doesn't exist, validate_key allows through
    ?assertMatch({ok, _}, access_control:validate_key(<<"any-key">>)).
