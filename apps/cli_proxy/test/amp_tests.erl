-module(amp_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% AMP model mapper + config tests
%% ============================================================

%% --- Model name resolution ---

exact_match_test() ->
    Mappings = #{<<"gpt-4">> => <<"claude-3-opus">>},
    Model = <<"gpt-4">>,
    Result = maps:get(Model, Mappings, Model),
    ?assertEqual(<<"claude-3-opus">>, Result).

no_match_passthrough_test() ->
    Mappings = #{<<"gpt-4">> => <<"claude-3-opus">>},
    Model = <<"gpt-3.5">>,
    Result = maps:get(Model, Mappings, Model),
    ?assertEqual(<<"gpt-3.5">>, Result).

empty_mappings_passthrough_test() ->
    Mappings = #{},
    Model = <<"test-model">>,
    Result = maps:get(Model, Mappings, Model),
    ?assertEqual(<<"test-model">>, Result).

%% --- Regex pattern matching ---

regex_match_test() ->
    Pattern = "^gpt-4.*",
    Model = <<"gpt-4-turbo">>,
    {ok, RE} = re:compile(Pattern),
    ?assertMatch({match, _}, re:run(Model, RE)).

regex_no_match_test() ->
    Pattern = "^gpt-4.*",
    Model = <<"claude-3">>,
    {ok, RE} = re:compile(Pattern),
    ?assertEqual(nomatch, re:run(Model, RE)).

%% --- Config defaults ---

amp_upstream_url_default_test() ->
    Config = #{},
    URL = maps:get(<<"upstream_url">>, Config, <<"https://ampcode.com">>),
    ?assertEqual(<<"https://ampcode.com">>, URL).

amp_upstream_url_override_test() ->
    Config = #{<<"upstream_url">> => <<"https://custom-amp.example.com">>},
    URL = maps:get(<<"upstream_url">>, Config, <<"https://ampcode.com">>),
    ?assertEqual(<<"https://custom-amp.example.com">>, URL).

%% --- API key resolution ---

amp_api_key_from_config_test() ->
    Config = #{<<"api_key">> => <<"amp-key-123">>},
    Key = maps:get(<<"api_key">>, Config, <<>>),
    ?assertEqual(<<"amp-key-123">>, Key).

amp_api_key_env_fallback_test() ->
    Config = #{},
    Key = maps:get(<<"api_key">>, Config, <<>>),
    ?assertEqual(<<>>, Key).

%% --- Force model mappings flag ---

force_mappings_enabled_test() ->
    Config = #{<<"force_model_mappings">> => true},
    Force = maps:get(<<"force_model_mappings">>, Config, false),
    ?assert(Force).

force_mappings_default_test() ->
    Config = #{},
    Force = maps:get(<<"force_model_mappings">>, Config, false),
    ?assertNot(Force).
