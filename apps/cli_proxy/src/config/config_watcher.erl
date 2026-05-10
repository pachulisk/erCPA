-module(config_watcher).
-behaviour(gen_server).

%% Watches config file and auth directory for changes
%% Uses fs library for filesystem notifications
%% On change: hash compare → reload → notify dependents

-export([start_link/1, start_link/2, force_reload/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    config_path :: string(),
    auth_dir :: string(),
    config_hash :: binary() | undefined,
    fs_pid :: pid() | undefined
}).

%%====================================================================
%% API
%%====================================================================

start_link(ConfigPath) ->
    start_link(ConfigPath, undefined).

start_link(ConfigPath, AuthDir) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [ConfigPath, AuthDir], []).

-spec force_reload() -> ok.
force_reload() ->
    gen_server:cast(?MODULE, force_reload).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([ConfigPath, AuthDir]) ->
    %% Initial load
    Hash = load_and_apply_config(ConfigPath),

    %% Start filesystem watcher
    FsPid = start_fs_watcher(ConfigPath, AuthDir),

    {ok, #state{
        config_path = ConfigPath,
        auth_dir = AuthDir,
        config_hash = Hash,
        fs_pid = FsPid
    }}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(force_reload, #state{config_path = Path} = State) ->
    NewHash = load_and_apply_config(Path),
    {noreply, State#state{config_hash = NewHash}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({_Pid, {fs, file_event}, {ChangedPath, Events}}, State) ->
    handle_file_event(ChangedPath, Events, State);

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal
%%====================================================================

handle_file_event(ChangedPath, Events, #state{config_path = ConfigPath} = State) ->
    IsModified = lists:member(modified, Events) orelse
                 lists:member(created, Events) orelse
                 lists:member(renamed, Events),

    case IsModified of
        false -> {noreply, State};
        true ->
            ChangedStr = if
                is_binary(ChangedPath) -> binary_to_list(ChangedPath);
                true -> ChangedPath
            end,
            case ChangedStr =:= ConfigPath of
                true ->
                    %% Config file changed
                    handle_config_change(State);
                false ->
                    %% Auth file changed
                    handle_auth_change(ChangedStr, Events, State)
            end
    end.

handle_config_change(#state{config_path = Path, config_hash = OldHash} = State) ->
    case file:read_file(Path) of
        {ok, Content} ->
            NewHash = crypto:hash(sha256, Content),
            case NewHash =:= OldHash of
                true ->
                    {noreply, State};
                false ->
                    load_and_apply_config(Path),
                    {noreply, State#state{config_hash = NewHash}}
            end;
        {error, _} ->
            {noreply, State}
    end.

handle_auth_change(FilePath, Events, State) ->
    case lists:member(removed, Events) of
        true ->
            %% Auth file removed — unregister credential
            Id = list_to_binary(filename:basename(FilePath, ".json")),
            credential_sup:stop_credential(Id);
        false ->
            %% Auth file added/modified — reload credential
            reload_auth_file(FilePath)
    end,
    {noreply, State}.

load_and_apply_config(Path) ->
    case file:read_file(Path) of
        {ok, Content} ->
            Hash = crypto:hash(sha256, Content),
            %% Parse YAML/JSON config
            Config = parse_config(Content),
            config_loader:apply_config(Config),
            Hash;
        {error, _} ->
            undefined
    end.

parse_config(Content) ->
    %% Try JSON first, then simple YAML
    try
        jiffy:decode(Content, [return_maps])
    catch _:_ ->
        parse_yaml(Content)
    end.

parse_yaml(Content) ->
    Lines = binary:split(Content, <<"\n">>, [global, trim_all]),
    lists:foldl(fun(Line, Acc) ->
        case Line of
            <<"#", _/binary>> -> Acc;  %% comment
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

reload_auth_file(FilePath) ->
    case file:read_file(FilePath) of
        {ok, Bin} ->
            try
                Data = jiffy:decode(Bin, [return_maps]),
                Id = maps:get(<<"id">>, Data,
                    list_to_binary(filename:basename(FilePath, ".json"))),
                Provider = binary_to_atom(maps:get(<<"type">>, Data, <<"unknown">>), utf8),
                %% Start or update credential process
                credential_sup:start_credential(#{
                    id => Id,
                    provider => Provider,
                    metadata => Data
                })
            catch _:_ -> ok
            end;
        {error, _} -> ok
    end.

start_fs_watcher(ConfigPath, AuthDir) ->
    Paths = [ConfigPath | case AuthDir of
        undefined -> [];
        Dir -> [Dir]
    end],
    case fs:start_link(config_fs_watcher, Paths) of
        {ok, Pid} ->
            fs:subscribe(config_fs_watcher),
            Pid;
        {error, _} ->
            undefined
    end.
