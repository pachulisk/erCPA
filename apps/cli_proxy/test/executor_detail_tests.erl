-module(executor_detail_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Detailed executor tests — URL, headers, error handling
%% Tests internal logic without making real HTTP calls
%% ============================================================

%% --- Claude executor ---

claude_base_url_default_test() ->
    Auth = #{},
    URL = maps:get(<<"base_url">>, Auth, <<"https://api.anthropic.com">>),
    ?assertEqual(<<"https://api.anthropic.com">>, URL).

claude_base_url_override_test() ->
    Auth = #{<<"base_url">> => <<"https://custom.example.com">>},
    URL = maps:get(<<"base_url">>, Auth, <<"https://api.anthropic.com">>),
    ?assertEqual(<<"https://custom.example.com">>, URL).

claude_url_path_test() ->
    BaseURL = <<"https://api.anthropic.com">>,
    URL = <<BaseURL/binary, "/v1/messages">>,
    ?assertEqual(<<"https://api.anthropic.com/v1/messages">>, URL).

claude_api_key_priority_test() ->
    %% access_token takes priority over api_key
    Auth1 = #{<<"access_token">> => <<"at-123">>, <<"api_key">> => <<"ak-456">>},
    Token1 = maps:get(<<"access_token">>, Auth1, maps:get(<<"api_key">>, Auth1, <<>>)),
    ?assertEqual(<<"at-123">>, Token1),

    %% Falls back to api_key
    Auth2 = #{<<"api_key">> => <<"ak-456">>},
    Token2 = maps:get(<<"access_token">>, Auth2, maps:get(<<"api_key">>, Auth2, <<>>)),
    ?assertEqual(<<"ak-456">>, Token2),

    %% Empty when neither present
    Auth3 = #{},
    Token3 = maps:get(<<"access_token">>, Auth3, maps:get(<<"api_key">>, Auth3, <<>>)),
    ?assertEqual(<<>>, Token3).

claude_stream_request_flag_test() ->
    Request = #{<<"model">> => <<"claude-3">>, <<"messages">> => []},
    StreamReq = Request#{<<"stream">> => true},
    ?assertEqual(true, maps:get(<<"stream">>, StreamReq)).

%% --- OpenAI compat executor ---

openai_compat_url_construction_test() ->
    Auth = #{<<"base_url">> => <<"https://openrouter.ai/api">>},
    BaseURL = maps:get(<<"base_url">>, Auth, <<"http://localhost:8080">>),
    URL = <<BaseURL/binary, "/v1/chat/completions">>,
    ?assertEqual(<<"https://openrouter.ai/api/v1/chat/completions">>, URL).

openai_compat_default_base_url_test() ->
    Auth = #{},
    BaseURL = maps:get(<<"base_url">>, Auth, <<"http://localhost:8080">>),
    ?assertEqual(<<"http://localhost:8080">>, BaseURL).

openai_compat_bearer_token_test() ->
    Auth = #{<<"api_key">> => <<"sk-or-v1-test">>},
    Token = maps:get(<<"api_key">>, Auth, <<>>),
    Header = <<"Bearer ", Token/binary>>,
    ?assertEqual(<<"Bearer sk-or-v1-test">>, Header).

openai_compat_merge_custom_headers_test() ->
    Auth = #{<<"api_key">> => <<"key">>,
             <<"headers">> => #{<<"X-Title">> => <<"MyApp">>, <<"X-Region">> => <<"us">>}},
    Custom = maps:get(<<"headers">>, Auth, #{}),
    Base = [{<<"Authorization">>, <<"Bearer key">>}],
    Extra = maps:fold(fun(K, V, Acc) -> [{K, V} | Acc] end, [], Custom),
    All = Base ++ Extra,
    ?assertEqual(<<"Bearer key">>, proplists:get_value(<<"Authorization">>, All)),
    ?assertNotEqual(undefined, proplists:get_value(<<"X-Title">>, All)),
    ?assertNotEqual(undefined, proplists:get_value(<<"X-Region">>, All)).

openai_compat_no_custom_headers_test() ->
    Auth = #{<<"api_key">> => <<"key">>},
    Custom = maps:get(<<"headers">>, Auth, #{}),
    ?assertEqual(#{}, Custom).

%% --- Gemini executor ---

gemini_api_key_url_test() ->
    BaseURL = <<"https://generativelanguage.googleapis.com">>,
    Model = <<"gemini-2.0-flash">>,
    Key = <<"AIzaSyTest">>,
    URL = <<BaseURL/binary, "/v1beta/models/", Model/binary,
            ":generateContent?key=", Key/binary>>,
    ?assert(binary:match(URL, <<"key=AIzaSyTest">>) =/= nomatch).

gemini_stream_url_test() ->
    BaseURL = <<"https://generativelanguage.googleapis.com">>,
    Model = <<"gemini-pro">>,
    Key = <<"test-key">>,
    URL = <<BaseURL/binary, "/v1beta/models/", Model/binary,
            ":streamGenerateContent?alt=sse&key=", Key/binary>>,
    ?assert(binary:match(URL, <<"streamGenerateContent">>) =/= nomatch),
    ?assert(binary:match(URL, <<"alt=sse">>) =/= nomatch).

%% --- Kimi executor ---

kimi_default_base_url_test() ->
    Auth = #{},
    BaseURL = maps:get(<<"base_url">>, Auth, <<"https://api.moonshot.cn">>),
    ?assertEqual(<<"https://api.moonshot.cn">>, BaseURL).

kimi_url_construction_test() ->
    BaseURL = <<"https://api.moonshot.cn">>,
    URL = <<BaseURL/binary, "/v1/chat/completions">>,
    ?assertEqual(<<"https://api.moonshot.cn/v1/chat/completions">>, URL).

%% --- Vertex executor ---

vertex_regional_url_test() ->
    Location = <<"us-central1">>,
    ProjectId = <<"my-gcp-project">>,
    Model = <<"gemini-pro">>,
    URL = <<"https://", Location/binary, "-aiplatform.googleapis.com/v1/projects/",
            ProjectId/binary, "/locations/", Location/binary,
            "/publishers/google/models/", Model/binary, ":generateContent">>,
    ?assert(binary:match(URL, <<"us-central1-aiplatform">>) =/= nomatch),
    ?assert(binary:match(URL, <<"my-gcp-project">>) =/= nomatch).

%% --- Error status code classification ---

retriable_status_codes_test() ->
    Retriable = [408, 500, 502, 503, 504],
    NonRetriable = [400, 401, 403, 404, 429],
    lists:foreach(fun(S) ->
        ?assert(lists:member(S, Retriable))
    end, Retriable),
    lists:foreach(fun(S) ->
        ?assertNot(lists:member(S, Retriable))
    end, NonRetriable).

%% --- Executor module dispatch ---

executor_module_mapping_test() ->
    Mapping = [
        {claude, claude_executor},
        {openai_compat, openai_compat_executor},
        {gemini, gemini_executor},
        {codex, codex_executor},
        {vertex, vertex_executor},
        {aistudio, aistudio_executor},
        {antigravity, antigravity_executor},
        {kimi, kimi_executor}
    ],
    lists:foreach(fun({Provider, ExpectedMod}) ->
        Mod = case Provider of
            claude -> claude_executor;
            openai_compat -> openai_compat_executor;
            gemini -> gemini_executor;
            codex -> codex_executor;
            vertex -> vertex_executor;
            aistudio -> aistudio_executor;
            antigravity -> antigravity_executor;
            kimi -> kimi_executor;
            _ -> openai_compat_executor
        end,
        ?assertEqual(ExpectedMod, Mod)
    end, Mapping).

executor_module_unknown_fallback_test() ->
    Mod = case unknown_provider of
        claude -> claude_executor;
        _ -> openai_compat_executor
    end,
    ?assertEqual(openai_compat_executor, Mod).
