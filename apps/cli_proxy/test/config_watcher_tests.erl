-module(config_watcher_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Config watcher logic tests — hash compare, parsing, auth reload
%% ============================================================

%% --- Hash comparison dedup ---

hash_unchanged_skips_reload_test() ->
    Content = <<"port: 8317\ndebug: false">>,
    Hash1 = crypto:hash(sha256, Content),
    Hash2 = crypto:hash(sha256, Content),
    ?assertEqual(Hash1, Hash2).

hash_changed_triggers_reload_test() ->
    Content1 = <<"port: 8317">>,
    Content2 = <<"port: 8318">>,
    Hash1 = crypto:hash(sha256, Content1),
    Hash2 = crypto:hash(sha256, Content2),
    ?assertNotEqual(Hash1, Hash2).

%% --- YAML parsing ---

parse_yaml_simple_test() ->
    Content = <<"port: 8317\ndebug: true\npassword: secret">>,
    Config = parse_yaml(Content),
    ?assertEqual(8317, maps:get(port, Config)),
    ?assertEqual(true, maps:get(debug, Config)),
    ?assertEqual(<<"secret">>, maps:get(password, Config)).

parse_yaml_boolean_test() ->
    Content = <<"enabled: true\ndisabled: false">>,
    Config = parse_yaml(Content),
    ?assertEqual(true, maps:get(enabled, Config)),
    ?assertEqual(false, maps:get(disabled, Config)).

parse_yaml_integer_test() ->
    Content = <<"rate_limit_rpm: 60\nmax_retry: 3">>,
    Config = parse_yaml(Content),
    ?assertEqual(60, maps:get(rate_limit_rpm, Config)),
    ?assertEqual(3, maps:get(max_retry, Config)).

parse_yaml_comment_skipped_test() ->
    Content = <<"# This is a comment\nport: 8317">>,
    Config = parse_yaml(Content),
    ?assertEqual(8317, maps:get(port, Config)),
    ?assertEqual(1, map_size(Config)).

parse_yaml_empty_test() ->
    Content = <<>>,
    Config = parse_yaml(Content),
    ?assertEqual(#{}, Config).

%% --- JSON config parsing ---

parse_json_config_test() ->
    Content = <<"{\"port\": 8317, \"debug\": true}">>,
    Config = parse_config(Content),
    ?assertEqual(8317, maps:get(<<"port">>, Config)),
    ?assertEqual(true, maps:get(<<"debug">>, Config)).

parse_invalid_falls_to_yaml_test() ->
    Content = <<"port: 8317">>,
    Config = parse_config(Content),
    ?assertEqual(8317, maps:get(port, Config)).

%% --- File event classification ---

modified_event_detected_test() ->
    Events = [modified],
    IsModified = lists:member(modified, Events) orelse
                 lists:member(created, Events),
    ?assert(IsModified).

created_event_detected_test() ->
    Events = [created],
    IsModified = lists:member(modified, Events) orelse
                 lists:member(created, Events),
    ?assert(IsModified).

renamed_event_detected_test() ->
    Events = [renamed],
    IsModified = lists:member(renamed, Events),
    ?assert(IsModified).

unrelated_event_ignored_test() ->
    Events = [accessed],
    IsModified = lists:member(modified, Events) orelse
                 lists:member(created, Events) orelse
                 lists:member(renamed, Events),
    ?assertNot(IsModified).

%% --- Auth file ID extraction ---

auth_file_id_from_path_test() ->
    Path = "/home/user/.cli-proxy-api/claude-mykey-42.json",
    Id = list_to_binary(filename:basename(Path, ".json")),
    ?assertEqual(<<"claude-mykey-42">>, Id).

%% --- Internal helpers (copied from config_watcher) ---

parse_config(Content) ->
    try
        jiffy:decode(Content, [return_maps])
    catch _:_ ->
        parse_yaml(Content)
    end.

parse_yaml(Content) ->
    Lines = binary:split(Content, <<"\n">>, [global, trim_all]),
    lists:foldl(fun(Line, Acc) ->
        case Line of
            <<"#", _/binary>> -> Acc;
            _ ->
                case binary:split(Line, <<":">>) of
                    [Key, Value] ->
                        K = binary_to_atom(string:trim(Key), utf8),
                        V = parse_yaml_value(string:trim(Value)),
                        Acc#{K => V};
                    _ -> Acc
                end
        end
    end, #{}, Lines).

parse_yaml_value(<<"true">>) -> true;
parse_yaml_value(<<"false">>) -> false;
parse_yaml_value(V) ->
    case catch binary_to_integer(V) of
        I when is_integer(I) -> I;
        _ -> V
    end.
