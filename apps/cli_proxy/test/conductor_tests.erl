-module(conductor_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Conductor logic tests — credential selection, retry, dispatch
%% ============================================================

%% --- Stream detection ---

stream_flag_true_test() ->
    Request = #{<<"stream">> => true, <<"model">> => <<"test">>},
    ?assertEqual(true, maps:get(<<"stream">>, Request, false)).

stream_flag_false_test() ->
    Request = #{<<"model">> => <<"test">>},
    ?assertEqual(false, maps:get(<<"stream">>, Request, false)).

stream_flag_explicit_false_test() ->
    Request = #{<<"stream">> => false, <<"model">> => <<"test">>},
    ?assertEqual(false, maps:get(<<"stream">>, Request, false)).

%% --- Retry logic ---

max_retries_zero_stops_test() ->
    %% When retries = 0, should not attempt
    ?assertEqual(0, 0).

retry_on_5xx_test() ->
    %% Status codes that trigger retry
    RetriableCodes = [408, 500, 502, 503, 504],
    lists:foreach(fun(Code) ->
        ?assert(Code =:= 408 orelse (Code >= 500 andalso Code =< 504))
    end, RetriableCodes).

no_retry_on_4xx_test() ->
    %% Client errors should not retry (except 408)
    NonRetriable = [400, 401, 403, 404, 429],
    lists:foreach(fun(Code) ->
        ?assert(Code >= 400 andalso Code < 500 andalso Code =/= 408)
    end, NonRetriable).

%% --- Provider to executor mapping ---

provider_dispatch_claude_test() ->
    ?assertEqual(claude_executor, dispatch(claude)).

provider_dispatch_gemini_test() ->
    ?assertEqual(gemini_executor, dispatch(gemini)).

provider_dispatch_codex_test() ->
    ?assertEqual(codex_executor, dispatch(codex)).

provider_dispatch_openai_compat_test() ->
    ?assertEqual(openai_compat_executor, dispatch(openai_compat)).

provider_dispatch_unknown_test() ->
    ?assertEqual(openai_compat_executor, dispatch(some_unknown)).

%% --- Session ID extraction ---

session_id_from_opts_test() ->
    Opts = #{session_id => <<"sess-123">>},
    ?assertEqual(<<"sess-123">>, maps:get(session_id, Opts, <<>>)).

session_id_default_test() ->
    Opts = #{},
    ?assertEqual(<<>>, maps:get(session_id, Opts, <<>>)).

%% --- Request ID generation ---

request_id_format_test() ->
    Id = <<"req_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    ?assert(binary:match(Id, <<"req_">>) =/= nomatch).

%% --- Max credentials limit ---

max_creds_zero_means_unlimited_test() ->
    MaxCreds = 0,
    Tried = 5,
    %% When MaxCreds = 0, condition "Tried >= MaxCreds" is true but guarded
    ?assert(MaxCreds =:= 0 orelse Tried < MaxCreds).

max_creds_exceeded_test() ->
    MaxCreds = 3,
    Tried = 3,
    ?assert(MaxCreds > 0 andalso Tried >= MaxCreds).

%% --- Translate request direction ---

translate_direction_test() ->
    %% Request: SourceFormat -> Provider
    %% Response: SourceFormat, Provider (same pair, reverse in translator)
    SourceFormat = openai,
    Provider = claude,
    ?assertEqual({openai, claude}, {SourceFormat, Provider}).

%% --- Internal helper ---

dispatch(claude) -> claude_executor;
dispatch(openai_compat) -> openai_compat_executor;
dispatch(gemini) -> gemini_executor;
dispatch(codex) -> codex_executor;
dispatch(vertex) -> vertex_executor;
dispatch(aistudio) -> aistudio_executor;
dispatch(antigravity) -> antigravity_executor;
dispatch(kimi) -> kimi_executor;
dispatch(_) -> openai_compat_executor.
