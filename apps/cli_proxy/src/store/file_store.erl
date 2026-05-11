-module(file_store).
-behaviour(auth_store).

%% File system storage backend
%% Stores auth credentials as JSON files in a configured directory

-export([load_all/0, save/2, update/2, delete/1, load_config/0, save_config/1]).

-dialyzer({nowarn_function, [load_all/0, save/2]}).

%%====================================================================
%% auth_store callbacks
%%====================================================================

-spec load_all() -> {ok, [map()]} | {error, term()}.
load_all() ->
    Dir = auth_dir(),
    case filelib:is_dir(Dir) of
        false -> {ok, []};
        true ->
            Files = filelib:wildcard(filename:join(Dir, "*.json")),
            AuthFiles = lists:filtermap(fun(Path) ->
                case file:read_file(Path) of
                    {ok, Bin} ->
                        try
                            Data = jiffy:decode(Bin, [return_maps]),
                            Id = maps:get(<<"id">>, Data,
                                    filename:basename(Path, ".json")),
                            Provider = detect_provider(Data),
                            {true, #{
                                id => ensure_bin(Id),
                                provider => Provider,
                                filename => list_to_binary(Path),
                                metadata => Data,
                                disabled => maps:get(<<"disabled">>, Data, false)
                            }}
                        catch _:_ -> false
                        end;
                    {error, _} -> false
                end
            end, Files),
            {ok, AuthFiles}
    end.

-spec save(atom(), map()) -> ok | {error, term()}.
save(Provider, TokenData) ->
    Dir = auth_dir(),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    Filename = generate_filename(Provider, TokenData),
    Path = filename:join(Dir, Filename),
    Data = TokenData#{<<"type">> => atom_to_binary(Provider, utf8)},
    ok = file:write_file(Path, jiffy:encode(Data, [pretty])).

-spec update(binary(), map()) -> ok | {error, term()}.
update(Id, NewMetadata) ->
    Dir = auth_dir(),
    %% Find file by ID
    case find_file_by_id(Dir, Id) of
        {ok, Path} ->
            case file:read_file(Path) of
                {ok, Bin} ->
                    Existing = jiffy:decode(Bin, [return_maps]),
                    Updated = maps:merge(Existing, NewMetadata),
                    ok = file:write_file(Path, jiffy:encode(Updated, [pretty]));
                {error, Reason} ->
                    {error, Reason}
            end;
        error ->
            {error, not_found}
    end.

-spec delete(binary()) -> ok | {error, term()}.
delete(Id) ->
    Dir = auth_dir(),
    case find_file_by_id(Dir, Id) of
        {ok, Path} -> file:delete(Path);
        error -> {error, not_found}
    end.

-spec load_config() -> {ok, map()} | {error, term()}.
load_config() ->
    ConfigPath = config_path(),
    case file:read_file(ConfigPath) of
        {ok, Bin} ->
            %% Simple YAML-like parsing (key: value per line)
            {ok, parse_yaml_simple(Bin)};
        {error, enoent} ->
            {ok, #{}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec save_config(map()) -> ok | {error, term()}.
save_config(Config) ->
    ConfigPath = config_path(),
    ok = filelib:ensure_dir(ConfigPath),
    Yaml = format_yaml_simple(Config),
    file:write_file(ConfigPath, Yaml).

%%====================================================================
%% Internal
%%====================================================================

auth_dir() ->
    case config_loader:get(auth_dir) of
        undefined -> expand_home("~/.cli-proxy-api/");
        Dir when is_list(Dir) -> expand_home(Dir);
        Dir when is_binary(Dir) -> expand_home(binary_to_list(Dir))
    end.

config_path() ->
    case config_loader:get(config_path) of
        undefined -> expand_home("~/.cli-proxy-api/config.yaml");
        Path when is_list(Path) -> Path;
        Path when is_binary(Path) -> binary_to_list(Path)
    end.

expand_home("~/" ++ Rest) ->
    Home = os:getenv("HOME", "/tmp"),
    filename:join(Home, Rest);
expand_home(Path) ->
    Path.

detect_provider(#{<<"type">> := Type}) ->
    binary_to_atom(Type, utf8);
detect_provider(_) ->
    unknown.

generate_filename(Provider, TokenData) ->
    Email = maps:get(<<"email">>, TokenData, <<"unknown">>),
    Suffix = integer_to_list(erlang:unique_integer([positive])),
    lists:flatten(io_lib:format("~s-~s-~s.json",
        [Provider, Email, Suffix])).

find_file_by_id(Dir, Id) ->
    Files = filelib:wildcard(filename:join(Dir, "*.json")),
    find_in_files(Files, Id).

find_in_files([], _Id) -> error;
find_in_files([Path | Rest], Id) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            try
                Data = jiffy:decode(Bin, [return_maps]),
                FileId = maps:get(<<"id">>, Data,
                    list_to_binary(filename:basename(Path, ".json"))),
                case ensure_bin(FileId) =:= Id of
                    true -> {ok, Path};
                    false -> find_in_files(Rest, Id)
                end
            catch _:_ -> find_in_files(Rest, Id)
            end;
        _ -> find_in_files(Rest, Id)
    end.

ensure_bin(B) when is_binary(B) -> B;
ensure_bin(L) when is_list(L) -> list_to_binary(L);
ensure_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).

parse_yaml_simple(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global, trim_all]),
    lists:foldl(fun(Line, Acc) ->
        case binary:split(Line, <<":">>) of
            [Key, Value] ->
                K = string:trim(Key),
                V = string:trim(Value),
                Acc#{K => parse_yaml_value(V)};
            _ -> Acc
        end
    end, #{}, Lines).

parse_yaml_value(<<"true">>) -> true;
parse_yaml_value(<<"false">>) -> false;
parse_yaml_value(V) ->
    case catch binary_to_integer(V) of
        I when is_integer(I) -> I;
        _ -> V
    end.

format_yaml_simple(Config) ->
    Lines = maps:fold(fun(K, V, Acc) ->
        Line = io_lib:format("~s: ~s\n", [K, format_yaml_val(V)]),
        [Line | Acc]
    end, [], Config),
    iolist_to_binary(lists:reverse(Lines)).

format_yaml_val(true) -> <<"true">>;
format_yaml_val(false) -> <<"false">>;
format_yaml_val(V) when is_integer(V) -> integer_to_binary(V);
format_yaml_val(V) when is_binary(V) -> V;
format_yaml_val(V) -> iolist_to_binary(io_lib:format("~p", [V])).
