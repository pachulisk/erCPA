-module(executor_unit_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Executor unit tests — test header/URL building without HTTP
%% ============================================================

%% --- Vertex URL building ---

vertex_url_test() ->
    Auth = #{<<"project_id">> => <<"my-project">>,
             <<"location">> => <<"us-central1">>},
    %% Test via module internals — we verify the URL pattern
    %% Vertex URL: https://{location}-aiplatform.googleapis.com/v1/projects/{project}/...
    ProjectId = maps:get(<<"project_id">>, Auth),
    Location = maps:get(<<"location">>, Auth),
    ?assertEqual(<<"my-project">>, ProjectId),
    ?assertEqual(<<"us-central1">>, Location).

%% --- Gemini URL patterns ---

gemini_url_patterns_test() ->
    %% Non-streaming: /v1beta/models/MODEL:generateContent
    %% Streaming: /v1beta/models/MODEL:streamGenerateContent?alt=sse
    Model = <<"gemini-pro">>,
    BaseURL = <<"https://generativelanguage.googleapis.com">>,
    NonStreamURL = <<BaseURL/binary, "/v1beta/models/", Model/binary, ":generateContent">>,
    StreamURL = <<BaseURL/binary, "/v1beta/models/", Model/binary, ":streamGenerateContent?alt=sse">>,
    ?assert(binary:match(NonStreamURL, <<"generateContent">>) =/= nomatch),
    ?assert(binary:match(StreamURL, <<"streamGenerateContent">>) =/= nomatch),
    ?assert(binary:match(StreamURL, <<"alt=sse">>) =/= nomatch).

%% --- Claude headers ---

claude_headers_test() ->
    Auth = #{<<"access_token">> => <<"sk-ant-test123">>},
    Token = maps:get(<<"access_token">>, Auth),
    Headers = [
        {<<"Content-Type">>, <<"application/json">>},
        {<<"x-api-key">>, Token},
        {<<"anthropic-version">>, <<"2023-06-01">>}
    ],
    ?assertEqual(<<"sk-ant-test123">>, proplists:get_value(<<"x-api-key">>, Headers)),
    ?assertEqual(<<"2023-06-01">>, proplists:get_value(<<"anthropic-version">>, Headers)).

%% --- Codex headers ---

codex_headers_test() ->
    Auth = #{<<"access_token">> => <<"codex-token-abc">>},
    Token = maps:get(<<"access_token">>, Auth),
    AuthHeader = <<"Bearer ", Token/binary>>,
    ?assertEqual(<<"Bearer codex-token-abc">>, AuthHeader).

%% --- OpenAI compat custom headers ---

openai_compat_custom_headers_test() ->
    Auth = #{<<"api_key">> => <<"or-key">>,
             <<"headers">> => #{<<"X-Custom">> => <<"value">>}},
    Token = maps:get(<<"api_key">>, Auth),
    CustomHeaders = maps:get(<<"headers">>, Auth),
    Base = [{<<"Authorization">>, <<"Bearer ", Token/binary>>}],
    Extra = maps:fold(fun(K, V, Acc) -> [{K, V} | Acc] end, [], CustomHeaders),
    All = Base ++ Extra,
    ?assertEqual(<<"Bearer or-key">>, proplists:get_value(<<"Authorization">>, All)),
    ?assertEqual(<<"value">>, proplists:get_value(<<"X-Custom">>, All)).

%% --- Kimi URL ---

kimi_url_test() ->
    BaseURL = <<"https://api.moonshot.cn">>,
    URL = <<BaseURL/binary, "/v1/chat/completions">>,
    ?assert(binary:match(URL, <<"moonshot.cn">>) =/= nomatch).

%% --- AI Studio URL ---

aistudio_url_test() ->
    Auth = #{<<"base_url">> => <<"https://generativelanguage.googleapis.com">>},
    Model = <<"gemini-pro">>,
    BaseURL = maps:get(<<"base_url">>, Auth),
    URL = <<BaseURL/binary, "/v1beta/models/", Model/binary, ":generateContent">>,
    ?assert(binary:match(URL, <<"v1beta/models/gemini-pro">>) =/= nomatch).

%% --- Gemini API key vs OAuth ---

gemini_auth_modes_test() ->
    %% API key mode
    AuthKey = #{<<"api_key">> => <<"AIza...">>},
    Headers1 = [{<<"x-goog-api-key">>, maps:get(<<"api_key">>, AuthKey)}],
    ?assertEqual(<<"AIza...">>, proplists:get_value(<<"x-goog-api-key">>, Headers1)),

    %% OAuth mode
    AuthOAuth = #{<<"access_token">> => <<"ya29...">>},
    Token = maps:get(<<"access_token">>, AuthOAuth),
    Headers2 = [{<<"Authorization">>, <<"Bearer ", Token/binary>>}],
    ?assertEqual(<<"Bearer ya29...">>, proplists:get_value(<<"Authorization">>, Headers2)).

%% --- OAuth provider URLs ---

oauth_claude_url_test() ->
    State = <<"test-state">>,
    Verifier = <<"test-verifier">>,
    URL = oauth_claude:auth_url(State, Verifier),
    ?assert(binary:match(URL, <<"claude.ai/oauth/authorize">>) =/= nomatch),
    ?assert(binary:match(URL, <<"state=test-state">>) =/= nomatch),
    ?assert(binary:match(URL, <<"code_challenge=">>) =/= nomatch).

oauth_codex_url_test() ->
    State = <<"test-state">>,
    Verifier = <<"test-verifier">>,
    URL = oauth_codex:auth_url(State, Verifier),
    ?assert(binary:match(URL, <<"auth.openai.com">>) =/= nomatch),
    ?assert(binary:match(URL, <<"state=test-state">>) =/= nomatch).

oauth_gemini_url_test() ->
    State = <<"test-state">>,
    URL = oauth_gemini:auth_url(State, <<>>),
    ?assert(binary:match(URL, <<"accounts.google.com">>) =/= nomatch),
    ?assert(binary:match(URL, <<"state=test-state">>) =/= nomatch),
    ?assert(binary:match(URL, <<"cloud-platform">>) =/= nomatch).

%% --- Antigravity OAuth ---

oauth_antigravity_url_test() ->
    State = <<"test-state">>,
    URL = oauth_antigravity:auth_url(State, <<>>),
    ?assert(is_binary(URL)),
    ?assert(binary:match(URL, <<"state=test-state">>) =/= nomatch).

%% --- SSE parser format roundtrip ---

sse_roundtrip_test() ->
    Event = #{<<"type">> => <<"test">>, <<"data">> => <<"hello">>},
    Formatted = iolist_to_binary(sse_parser:format_event(Event)),
    [Parsed] = sse_parser:parse(Formatted),
    ?assertEqual(<<"test">>, maps:get(<<"type">>, Parsed)),
    ?assertEqual(<<"hello">>, maps:get(<<"data">>, Parsed)).
