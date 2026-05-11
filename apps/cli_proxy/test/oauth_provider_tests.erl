-module(oauth_provider_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% OAuth provider tests — auth URL, PKCE, token endpoints
%% ============================================================

%% --- Claude OAuth ---

claude_auth_url_contains_client_id_test() ->
    URL = oauth_claude:auth_url(<<"state1">>, <<"verifier1">>),
    ?assert(binary:match(URL, <<"client_id=">>) =/= nomatch).

claude_auth_url_contains_pkce_test() ->
    URL = oauth_claude:auth_url(<<"s">>, <<"v">>),
    ?assert(binary:match(URL, <<"code_challenge=">>) =/= nomatch),
    ?assert(binary:match(URL, <<"code_challenge_method=S256">>) =/= nomatch).

claude_auth_url_contains_state_test() ->
    URL = oauth_claude:auth_url(<<"my-state">>, <<"v">>),
    ?assert(binary:match(URL, <<"state=my-state">>) =/= nomatch).

claude_auth_url_contains_redirect_test() ->
    URL = oauth_claude:auth_url(<<"s">>, <<"v">>),
    ?assert(binary:match(URL, <<"redirect_uri=">>) =/= nomatch),
    ?assert(binary:match(URL, <<"54545">>) =/= nomatch).

claude_auth_url_response_type_test() ->
    URL = oauth_claude:auth_url(<<"s">>, <<"v">>),
    ?assert(binary:match(URL, <<"response_type=code">>) =/= nomatch).

%% --- Codex OAuth ---

codex_auth_url_contains_openai_test() ->
    URL = oauth_codex:auth_url(<<"state1">>, <<"verifier1">>),
    ?assert(binary:match(URL, <<"openai.com">>) =/= nomatch orelse
            binary:match(URL, <<"auth0.com">>) =/= nomatch).

codex_auth_url_contains_state_test() ->
    URL = oauth_codex:auth_url(<<"test-state">>, <<"v">>),
    ?assert(binary:match(URL, <<"state=test-state">>) =/= nomatch).

codex_auth_url_contains_pkce_test() ->
    URL = oauth_codex:auth_url(<<"s">>, <<"v">>),
    ?assert(binary:match(URL, <<"code_challenge=">>) =/= nomatch).

%% --- Gemini OAuth ---

gemini_auth_url_google_test() ->
    URL = oauth_gemini:auth_url(<<"state1">>, <<>>),
    ?assert(binary:match(URL, <<"accounts.google.com">>) =/= nomatch).

gemini_auth_url_scope_test() ->
    URL = oauth_gemini:auth_url(<<"s">>, <<>>),
    ?assert(binary:match(URL, <<"scope=">>) =/= nomatch).

gemini_auth_url_state_test() ->
    URL = oauth_gemini:auth_url(<<"my-state">>, <<>>),
    ?assert(binary:match(URL, <<"state=my-state">>) =/= nomatch).

%% --- Antigravity OAuth ---

antigravity_auth_url_state_test() ->
    URL = oauth_antigravity:auth_url(<<"state-ag">>, <<>>),
    ?assert(is_binary(URL)),
    ?assert(binary:match(URL, <<"state=state-ag">>) =/= nomatch).

antigravity_auth_url_is_valid_test() ->
    URL = oauth_antigravity:auth_url(<<"s">>, <<>>),
    ?assert(byte_size(URL) > 20).

%% --- Kimi OAuth (device code flow) ---

kimi_is_device_flow_test() ->
    %% Kimi uses device authorization grant, not browser redirect
    %% Verify the module exports device-related functions
    Exports = oauth_kimi:module_info(exports),
    ?assert(lists:member({request_device_code, 1}, Exports)),
    ?assert(lists:member({poll_device_token, 2}, Exports)).

%% --- PKCE helpers ---

pkce_verifier_uniqueness_test() ->
    V1 = base64:encode(crypto:strong_rand_bytes(32)),
    V2 = base64:encode(crypto:strong_rand_bytes(32)),
    ?assertNotEqual(V1, V2).

pkce_challenge_from_verifier_test() ->
    Verifier = <<"test-verifier-string">>,
    Challenge = base64:encode(crypto:hash(sha256, Verifier), #{mode => urlsafe, padding => false}),
    ?assert(is_binary(Challenge)),
    ?assert(byte_size(Challenge) > 0),
    %% Same verifier always produces same challenge
    Challenge2 = base64:encode(crypto:hash(sha256, Verifier), #{mode => urlsafe, padding => false}),
    ?assertEqual(Challenge, Challenge2).

%% --- State token generation ---

state_token_unique_test() ->
    S1 = base64:encode(crypto:strong_rand_bytes(16)),
    S2 = base64:encode(crypto:strong_rand_bytes(16)),
    ?assertNotEqual(S1, S2).
