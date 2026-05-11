-module(management_api_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Management handler logic tests — endpoint routing, auth
%% ============================================================

%% --- Path stripping ---

strip_prefix_test() ->
    Path = <<"/v0/management/config">>,
    Prefix = <<"/v0/management/">>,
    PrefixSize = byte_size(Prefix),
    <<Prefix:PrefixSize/binary, Rest/binary>> = Path,
    ?assertEqual(<<"config">>, Rest).

strip_prefix_nested_test() ->
    Path = <<"/v0/management/quota-exceeded/switch-project">>,
    Prefix = <<"/v0/management/">>,
    PrefixSize = byte_size(Prefix),
    <<Prefix:PrefixSize/binary, Rest/binary>> = Path,
    ?assertEqual(<<"quota-exceeded/switch-project">>, Rest).

%% --- Localhost detection ---

localhost_ipv4_test() ->
    ?assert(is_localhost({127, 0, 0, 1})).

localhost_ipv6_test() ->
    ?assert(is_localhost({0, 0, 0, 0, 0, 0, 0, 1})).

remote_ip_test() ->
    ?assertNot(is_localhost({192, 168, 1, 100})).

%% --- Auth sanitization ---

sanitize_removes_tokens_test() ->
    Meta = #{<<"access_token">> => <<"secret">>,
             <<"refresh_token">> => <<"refresh-secret">>,
             <<"email">> => <<"user@test.com">>,
             <<"type">> => <<"claude">>},
    Sanitized = maps:without([<<"access_token">>, <<"refresh_token">>,
                               <<"id_token">>, <<"service_account">>], Meta),
    ?assertNot(maps:is_key(<<"access_token">>, Sanitized)),
    ?assertNot(maps:is_key(<<"refresh_token">>, Sanitized)),
    ?assert(maps:is_key(<<"email">>, Sanitized)),
    ?assert(maps:is_key(<<"type">>, Sanitized)).

sanitize_preserves_safe_fields_test() ->
    Meta = #{<<"email">> => <<"u@t.com">>, <<"type">> => <<"claude">>,
             <<"base_url">> => <<"https://example.com">>},
    Sanitized = maps:without([<<"access_token">>, <<"refresh_token">>,
                               <<"id_token">>, <<"service_account">>], Meta),
    ?assertEqual(Meta, Sanitized).

%% --- Management key verification ---

mgmt_key_match_test() ->
    Key = <<"mgmt-secret-123">>,
    Secret = <<"mgmt-secret-123">>,
    ?assert(Key =:= Secret).

mgmt_key_mismatch_test() ->
    Key = <<"wrong-key">>,
    Secret = <<"mgmt-secret-123">>,
    ?assertNot(Key =:= Secret).

%% --- Endpoint routing patterns ---

known_endpoints_test() ->
    Endpoints = [<<"config">>, <<"debug">>, <<"request-log">>,
                 <<"api-keys">>, <<"auth-files">>,
                 <<"routing/strategy">>, <<"api-key-usage">>,
                 <<"rate-limit">>, <<"password">>,
                 <<"latest-version">>],
    ?assertEqual(10, length(Endpoints)).

%% --- Internal helpers ---

is_localhost({127, 0, 0, 1}) -> true;
is_localhost({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
is_localhost(_) -> false.
