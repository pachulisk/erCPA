-module(git_store).
-behaviour(auth_store).

%% Git repository-backed auth storage
%% Clones remote repo, reads/writes JSON files, pushes changes
%% Config: {git_repo, "https://..."}, {git_branch, "main"}

-export([load_all/0, save/2, update/2, delete/1, load_config/0, save_config/1]).

-define(LOCAL_DIR, "/tmp/ercpa_git_store").

load_all() ->
    ensure_cloned(),
    Dir = ?LOCAL_DIR,
    Files = filelib:wildcard(filename:join(Dir, "*.json")),
    Creds = lists:filtermap(fun(Path) ->
        case file:read_file(Path) of
            {ok, Bin} ->
                try
                    Data = jiffy:decode(Bin, [return_maps]),
                    Id = maps:get(<<"id">>, Data,
                        list_to_binary(filename:basename(Path, ".json"))),
                    Provider = binary_to_atom(maps:get(<<"type">>, Data, <<"unknown">>), utf8),
                    {true, #{
                        id => Id,
                        provider => Provider,
                        metadata => Data,
                        disabled => maps:get(<<"disabled">>, Data, false)
                    }}
                catch _:_ -> false
                end;
            _ -> false
        end
    end, Files),
    {ok, Creds}.

save(Provider, TokenData) ->
    ensure_cloned(),
    Id = maps:get(<<"id">>, TokenData, generate_id(Provider)),
    Filename = <<(atom_to_binary(Provider, utf8))/binary, "-", Id/binary, ".json">>,
    Path = filename:join(?LOCAL_DIR, binary_to_list(Filename)),
    Data = TokenData#{<<"type">> => atom_to_binary(Provider, utf8)},
    ok = file:write_file(Path, jiffy:encode(Data, [pretty])),
    git_commit_push("Add credential " ++ binary_to_list(Id)),
    ok.

update(Id, NewMetadata) ->
    ensure_cloned(),
    case find_file(Id) of
        {ok, Path} ->
            {ok, Bin} = file:read_file(Path),
            Existing = jiffy:decode(Bin, [return_maps]),
            Updated = maps:merge(Existing, NewMetadata),
            ok = file:write_file(Path, jiffy:encode(Updated, [pretty])),
            git_commit_push("Update credential " ++ binary_to_list(Id)),
            ok;
        error ->
            {error, not_found}
    end.

delete(Id) ->
    ensure_cloned(),
    case find_file(Id) of
        {ok, Path} ->
            file:delete(Path),
            git_commit_push("Delete credential " ++ binary_to_list(Id)),
            ok;
        error ->
            {error, not_found}
    end.

load_config() ->
    ensure_cloned(),
    ConfigPath = filename:join(?LOCAL_DIR, "config.json"),
    case file:read_file(ConfigPath) of
        {ok, Bin} -> {ok, jiffy:decode(Bin, [return_maps])};
        {error, enoent} -> {ok, #{}};
        {error, Reason} -> {error, Reason}
    end.

save_config(Config) ->
    ensure_cloned(),
    ConfigPath = filename:join(?LOCAL_DIR, "config.json"),
    ok = file:write_file(ConfigPath, jiffy:encode(Config, [pretty])),
    git_commit_push("Update config"),
    ok.

%%====================================================================
%% Internal
%%====================================================================

ensure_cloned() ->
    case filelib:is_dir(?LOCAL_DIR) of
        true ->
            os:cmd("cd " ++ ?LOCAL_DIR ++ " && git pull --quiet 2>/dev/null");
        false ->
            Repo = binary_to_list(config_loader:get(git_repo, <<>>)),
            Branch = binary_to_list(config_loader:get(git_branch, <<"main">>)),
            os:cmd("git clone --branch " ++ Branch ++ " --depth 1 " ++ Repo ++ " " ++ ?LOCAL_DIR)
    end.

git_commit_push(Msg) ->
    Cmd = "cd " ++ ?LOCAL_DIR ++ " && git add -A && git commit -m '" ++ Msg ++ "' && git push",
    os:cmd(Cmd).

find_file(Id) ->
    Files = filelib:wildcard(filename:join(?LOCAL_DIR, "*.json")),
    find_in_files(Files, Id).

find_in_files([], _) -> error;
find_in_files([Path | Rest], Id) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            try
                Data = jiffy:decode(Bin, [return_maps]),
                FileId = maps:get(<<"id">>, Data,
                    list_to_binary(filename:basename(Path, ".json"))),
                case FileId =:= Id of
                    true -> {ok, Path};
                    false -> find_in_files(Rest, Id)
                end
            catch _:_ -> find_in_files(Rest, Id)
            end;
        _ -> find_in_files(Rest, Id)
    end.

generate_id(Provider) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    <<(atom_to_binary(Provider, utf8))/binary, "-", Suffix/binary>>.
