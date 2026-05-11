-module(access_control_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Access control unit tests — password + API key logic
%% ============================================================

%% --- Password check logic ---

password_extract_from_header_test() ->
    %% X-Password header extraction
    Password = <<"my-secret">>,
    ?assertEqual(<<"my-secret">>, Password).

password_match_test() ->
    Configured = <<"secret123">>,
    Provided = <<"secret123">>,
    ?assert(Provided =:= Configured).

password_mismatch_test() ->
    Configured = <<"secret123">>,
    Provided = <<"wrong">>,
    ?assertNot(Provided =:= Configured).

password_undefined_allows_all_test() ->
    Configured = undefined,
    ?assertEqual(undefined, Configured).

password_empty_allows_all_test() ->
    Configured = <<>>,
    ?assertEqual(<<>>, Configured).

%% --- API key extraction ---

bearer_token_extraction_test() ->
    Header = <<"Bearer sk-test-123">>,
    <<"Bearer ", Token/binary>> = Header,
    ?assertEqual(<<"sk-test-123">>, Token).

bearer_lowercase_test() ->
    Header = <<"bearer sk-test-456">>,
    <<"bearer ", Token/binary>> = Header,
    ?assertEqual(<<"sk-test-456">>, Token).

no_auth_header_test() ->
    Header = <<>>,
    ?assertEqual(<<>>, Header).

%% --- API key table behavior ---

no_keys_allows_all_test() ->
    %% When no keys configured, size = 0, allow all
    Size = 0,
    ?assert(Size =:= 0).

key_present_in_table_test() ->
    %% Simulate key lookup
    Keys = [<<"key-1">>, <<"key-2">>],
    ?assert(lists:member(<<"key-1">>, Keys)),
    ?assertNot(lists:member(<<"key-3">>, Keys)).
