-module(payload_rules).

%% Pure function module for payload manipulation rules
%% Applies default/override/filter rules based on model/protocol matching

-export([apply_rules/4]).

%%====================================================================
%% API
%%====================================================================

-spec apply_rules(Body :: map(), Model :: binary(), Protocol :: atom(),
                  Config :: map()) -> map().
apply_rules(Body, Model, Protocol, Config) ->
    B1 = apply_defaults(Body, Model, Protocol, maps:get(default, Config, [])),
    B2 = apply_defaults(B1, Model, Protocol, maps:get(default_raw, Config, [])),
    B3 = apply_overrides(B2, Model, Protocol, maps:get(override, Config, [])),
    B4 = apply_overrides(B3, Model, Protocol, maps:get(override_raw, Config, [])),
    B5 = apply_filters(B4, Model, Protocol, maps:get(filter, Config, [])),
    B5.

%%====================================================================
%% Defaults: set only if path doesn't exist
%%====================================================================

apply_defaults(Body, Model, Protocol, Rules) ->
    lists:foldl(fun(#{models := ModelPatterns, params := Params}, Acc) ->
        case matches_any(Model, Protocol, ModelPatterns) of
            true ->
                maps:fold(fun(Path, Value, B) ->
                    case path_exists(B, Path) of
                        true  -> B;
                        false -> set_path(B, Path, Value)
                    end
                end, Acc, Params);
            false ->
                Acc
        end
    end, Body, Rules).

%%====================================================================
%% Overrides: always set (last write wins)
%%====================================================================

apply_overrides(Body, Model, Protocol, Rules) ->
    lists:foldl(fun(#{models := ModelPatterns, params := Params}, Acc) ->
        case matches_any(Model, Protocol, ModelPatterns) of
            true ->
                maps:fold(fun(Path, Value, B) ->
                    set_path(B, Path, Value)
                end, Acc, Params);
            false ->
                Acc
        end
    end, Body, Rules).

%%====================================================================
%% Filters: remove paths
%%====================================================================

apply_filters(Body, Model, Protocol, Rules) ->
    lists:foldl(fun(#{models := ModelPatterns, params := Paths}, Acc) ->
        case matches_any(Model, Protocol, ModelPatterns) of
            true ->
                lists:foldl(fun(Path, B) ->
                    remove_path(B, Path)
                end, Acc, Paths);
            false ->
                Acc
        end
    end, Body, Rules).

%%====================================================================
%% Pattern matching
%%====================================================================

matches_any(Model, Protocol, Patterns) ->
    lists:any(fun(#{name := NamePattern} = P) ->
        ProtoPattern = maps:get(protocol, P, <<>>),
        matches_protocol(Protocol, ProtoPattern) andalso
        matches_wildcard(Model, NamePattern)
    end, Patterns).

matches_protocol(_Protocol, <<>>) -> true;
matches_protocol(Protocol, Pattern) ->
    atom_to_binary(Protocol, utf8) =:= Pattern.

matches_wildcard(_Str, <<"*">>) -> true;
matches_wildcard(Str, Pattern) ->
    %% Convert wildcard to regex
    Escaped = binary:replace(Pattern, <<"*">>, <<".*">>, [global]),
    Regex = <<"^", Escaped/binary, "$">>,
    case re:run(Str, Regex) of
        {match, _} -> true;
        nomatch -> false
    end.

%%====================================================================
%% JSON path operations (nested map access)
%%====================================================================

%% Check if path exists in nested map
path_exists(Map, Path) when is_map(Map) ->
    Keys = binary:split(Path, <<".">>, [global]),
    path_exists_keys(Map, Keys).

path_exists_keys(_Map, []) -> true;
path_exists_keys(Map, [Key | Rest]) when is_map(Map) ->
    case maps:is_key(Key, Map) of
        true -> path_exists_keys(maps:get(Key, Map), Rest);
        false -> false
    end;
path_exists_keys(_, _) -> false.

%% Set value at path in nested map
set_path(Map, Path, Value) when is_map(Map) ->
    Keys = binary:split(Path, <<".">>, [global]),
    set_path_keys(Map, Keys, Value).

set_path_keys(Map, [Key], Value) when is_map(Map) ->
    maps:put(Key, Value, Map);
set_path_keys(Map, [Key | Rest], Value) when is_map(Map) ->
    SubMap = maps:get(Key, Map, #{}),
    maps:put(Key, set_path_keys(SubMap, Rest, Value), Map);
set_path_keys(Map, _, _) ->
    Map.

%% Remove value at path in nested map
remove_path(Map, Path) when is_map(Map) ->
    Keys = binary:split(Path, <<".">>, [global]),
    remove_path_keys(Map, Keys).

remove_path_keys(Map, [Key]) when is_map(Map) ->
    maps:remove(Key, Map);
remove_path_keys(Map, [Key | Rest]) when is_map(Map) ->
    case maps:get(Key, Map, undefined) of
        undefined -> Map;
        SubMap when is_map(SubMap) ->
            maps:put(Key, remove_path_keys(SubMap, Rest), Map);
        _ -> Map
    end;
remove_path_keys(Map, _) ->
    Map.
