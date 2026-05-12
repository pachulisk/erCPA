-module(management_handler).

%% Cowboy handler for /v0/management/* endpoints
%% Dispatches by path + method to specific handlers

-export([init/2]).

init(Req0, State) ->
    %% Management auth check
    case mgmt_auth(Req0) of
        ok ->
            dispatch(Req0, State);
        {error, Reason} ->
            Req = cowboy_req:reply(401, json_headers(),
                jiffy:encode(#{<<"error">> => Reason}), Req0),
            {ok, Req, State}
    end.

dispatch(Req0, State) ->
    Path = cowboy_req:path(Req0),
    Method = cowboy_req:method(Req0),
    %% Strip /v0/management/ prefix
    BasePath = strip_prefix(Path, <<"/v0/management/">>),
    handle(Method, BasePath, Req0, State).

%%====================================================================
%% Config endpoints
%%====================================================================

handle(<<"GET">>, <<"config">>, Req0, State) ->
    Config = config_loader:get_all(),
    reply_json(200, Config, Req0, State);

handle(<<"PUT">>, <<"config">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Config = jiffy:decode(Body, [return_maps]),
    ok = config_loader:apply_config(Config),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"GET">>, <<"config.yaml">>, Req0, State) ->
    Config = config_loader:get_all(),
    Yaml = json_to_yaml(Config),
    Req = cowboy_req:reply(200,
        maps:merge(cors_headers(), #{<<"content-type">> => <<"text/yaml; charset=utf-8">>}),
        Yaml, Req0),
    {ok, Req, State};

handle(<<"PUT">>, <<"config.yaml">>, Req0, State) ->
    %% Accept JSON body (YAML parsing requires external lib)
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Config = jiffy:decode(Body, [return_maps]),
    ok = config_loader:apply_config(Config),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"config.yaml">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Config = jiffy:decode(Body, [return_maps]),
    ok = config_loader:apply_config(Config),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"GET">>, <<"debug">>, Req0, State) ->
    reply_json(200, config_loader:get(debug, false), Req0, State);

handle(<<"PUT">>, <<"debug">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{debug => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"debug">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{debug => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"GET">>, <<"request-log">>, Req0, State) ->
    reply_json(200, config_loader:get(request_log, false), Req0, State);

handle(<<"PUT">>, <<"request-log">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{request_log => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"request-log">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{request_log => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

%%====================================================================
%% API Keys
%%====================================================================

handle(<<"GET">>, <<"api-keys">>, Req0, State) ->
    Keys = config_loader:get(api_keys, []),
    reply_json(200, Keys, Req0, State);

handle(<<"PUT">>, <<"api-keys">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Keys = jiffy:decode(Body, [return_maps]),
    config_loader:update_api_keys(Keys),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"api-keys">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    New = jiffy:decode(Body, [return_maps]),
    Old = config_loader:get(api_keys, []),
    config_loader:update_api_keys(merge_list(Old, New)),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"DELETE">>, <<"api-keys">>, Req0, State) ->
    config_loader:update_api_keys([]),
    reply_json(200, #{<<"ok">> => true}, Req0, State);

%%====================================================================
%% Auth files
%%====================================================================

handle(<<"GET">>, <<"auth-files">>, Req0, State) ->
    case auth_store:load_all() of
        {ok, Auths} ->
            Sanitized = [sanitize_auth(A) || A <- Auths],
            reply_json(200, Sanitized, Req0, State);
        {error, Reason} ->
            reply_json(500, #{<<"error">> => iolist_to_binary(io_lib:format("~p", [Reason]))},
                       Req0, State)
    end;

handle(<<"POST">>, <<"auth-files">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    AuthData = jiffy:decode(Body, [return_maps]),
    Provider = binary_to_atom(maps:get(<<"type">>, AuthData, <<"unknown">>), utf8),
    case auth_store:save(Provider, AuthData) of
        ok -> reply_json(200, #{<<"ok">> => true}, Req1, State);
        {error, Reason} ->
            reply_json(500, #{<<"error">> => iolist_to_binary(io_lib:format("~p", [Reason]))},
                       Req1, State)
    end;

handle(<<"DELETE">>, <<"auth-files">>, Req0, State) ->
    Id = proplists:get_value(<<"id">>, cowboy_req:parse_qs(Req0), <<>>),
    case auth_store:delete(Id) of
        ok -> reply_json(200, #{<<"ok">> => true}, Req0, State);
        {error, Reason} ->
            reply_json(404, #{<<"error">> => iolist_to_binary(io_lib:format("~p", [Reason]))},
                       Req0, State)
    end;

%%====================================================================
%% Routing
%%====================================================================

handle(<<"GET">>, <<"routing/strategy">>, Req0, State) ->
    Strategy = config_loader:get(routing_strategy, <<"round-robin">>),
    reply_json(200, Strategy, Req0, State);

handle(<<"PUT">>, <<"routing/strategy">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Strategy = jiffy:decode(Body),
    config_loader:apply_config(#{routing_strategy => Strategy}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"routing/strategy">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{routing_strategy => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

%%====================================================================
%% Usage
%%====================================================================

handle(<<"GET">>, <<"api-key-usage">>, Req0, State) ->
    Usage = usage_logger:get_usage(),
    reply_json(200, Usage, Req0, State);

%%====================================================================
%% OAuth
%%====================================================================

handle(<<"GET">>, <<"anthropic-auth-url">>, Req0, State) ->
    {ok, Pid} = oauth_session:start_link(claude, #{no_browser => true}),
    receive
        {oauth_url, Pid, URL} -> reply_json(200, #{<<"url">> => URL}, Req0, State)
    after 5000 ->
        reply_json(500, #{<<"error">> => <<"timeout">>}, Req0, State)
    end;

handle(<<"GET">>, <<"codex-auth-url">>, Req0, State) ->
    {ok, Pid} = oauth_session:start_link(codex, #{no_browser => true}),
    receive
        {oauth_url, Pid, URL} -> reply_json(200, #{<<"url">> => URL}, Req0, State)
    after 5000 ->
        reply_json(500, #{<<"error">> => <<"timeout">>}, Req0, State)
    end;

handle(<<"GET">>, <<"gemini-cli-auth-url">>, Req0, State) ->
    {ok, Pid} = oauth_session:start_link(gemini, #{no_browser => true}),
    receive
        {oauth_url, Pid, URL} -> reply_json(200, #{<<"url">> => URL}, Req0, State)
    after 5000 ->
        reply_json(500, #{<<"error">> => <<"timeout">>}, Req0, State)
    end;

handle(<<"GET">>, <<"kimi-auth-url">>, Req0, State) ->
    case oauth_kimi:request_device_code(#{}) of
        {ok, _DeviceCode, UserCode, VerifyURL} ->
            reply_json(200, #{<<"user_code">> => UserCode,
                              <<"verification_url">> => VerifyURL}, Req0, State);
        {error, Reason} ->
            reply_json(500, #{<<"error">> => iolist_to_binary(io_lib:format("~p", [Reason]))},
                       Req0, State)
    end;

handle(<<"GET">>, <<"antigravity-auth-url">>, Req0, State) ->
    {ok, Pid} = oauth_session:start_link(antigravity, #{no_browser => true}),
    receive
        {oauth_url, Pid, URL} -> reply_json(200, #{<<"url">> => URL}, Req0, State)
    after 5000 ->
        reply_json(500, #{<<"error">> => <<"timeout">>}, Req0, State)
    end;

handle(<<"POST">>, <<"oauth-callback">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"state">> := StateToken, <<"code">> := Code} = jiffy:decode(Body, [return_maps]),
    case oauth_session_registry:find(StateToken) of
        {ok, Pid} ->
            oauth_session:notify_callback(Pid, StateToken, Code),
            reply_json(200, #{<<"ok">> => true}, Req1, State);
        error ->
            reply_json(404, #{<<"error">> => <<"session not found">>}, Req1, State)
    end;

%%====================================================================
%% OAuth status
%%====================================================================

handle(<<"GET">>, <<"get-auth-status">>, Req0, State) ->
    %% Return active OAuth sessions from the registry ETS table
    Sessions = case ets:info(oauth_session_registry_tab) of
        undefined -> [];
        _ ->
            ets:foldl(fun({Token, Pid}, Acc) ->
                case is_process_alive(Pid) of
                    true ->
                        St = try oauth_session:get_state(Pid)
                             catch _:_ -> unknown end,
                        [#{<<"state_token">> => Token,
                           <<"status">> => atom_to_binary(St, utf8)} | Acc];
                    false -> Acc
                end
            end, [], oauth_session_registry_tab)
    end,
    reply_json(200, Sessions, Req0, State);

%%====================================================================
%% Quota status
%%====================================================================

handle(<<"GET">>, <<"quota">>, Req0, State) ->
    %% Return per-credential quota/cooldown status
    Children = supervisor:which_children(credential_sup),
    Statuses = lists:filtermap(fun({_, Pid, _, _}) ->
        case is_pid(Pid) andalso is_process_alive(Pid) of
            true ->
                try
                    {_, StateName, Data} = sys:get_state(Pid),
                    #{id := Id, provider := Prov, backoff_level := BL} = extract_cred_data(Data),
                    {true, #{<<"id">> => Id,
                             <<"provider">> => atom_to_binary(Prov, utf8),
                             <<"state">> => atom_to_binary(StateName, utf8),
                             <<"backoff_level">> => BL}}
                catch _:_ -> false
                end;
            false -> false
        end
    end, Children),
    reply_json(200, Statuses, Req0, State);

%%====================================================================
%% Usage statistics
%%====================================================================

handle(<<"GET">>, <<"usage-statistics-enabled">>, Req0, State) ->
    reply_json(200, config_loader:get(usage_statistics_enabled, false), Req0, State);

handle(<<"PUT">>, <<"usage-statistics-enabled">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{usage_statistics_enabled => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"usage-statistics-enabled">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{usage_statistics_enabled => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"GET">>, <<"usage-queue">>, Req0, State) ->
    QS = cowboy_req:parse_qs(Req0),
    Count = case proplists:get_value(<<"count">>, QS, <<"100">>) of
        C -> binary_to_integer(C)
    end,
    Items = usage_queue:pop_oldest(Count),
    reply_json(200, Items, Req0, State);

%%====================================================================
%% Logging
%%====================================================================

handle(<<"GET">>, <<"logging-to-file">>, Req0, State) ->
    reply_json(200, config_loader:get(logging_to_file, false), Req0, State);

handle(<<"PUT">>, <<"logging-to-file">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{logging_to_file => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"logging-to-file">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{logging_to_file => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"GET">>, <<"ws-auth">>, Req0, State) ->
    reply_json(200, config_loader:get(ws_auth, false), Req0, State);

handle(<<"PUT">>, <<"ws-auth">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{ws_auth => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"ws-auth">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{ws_auth => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

%%====================================================================
%% Logs management
%%====================================================================

handle(<<"GET">>, <<"logs-max-total-size-mb">>, Req0, State) ->
    reply_json(200, config_loader:get(logs_max_total_size_mb, 0), Req0, State);

handle(<<"PUT">>, <<"logs-max-total-size-mb">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{logs_max_total_size_mb => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"logs-max-total-size-mb">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{logs_max_total_size_mb => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"GET">>, <<"error-logs-max-files">>, Req0, State) ->
    reply_json(200, config_loader:get(error_logs_max_files, 10), Req0, State);

handle(<<"PUT">>, <<"error-logs-max-files">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{error_logs_max_files => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"error-logs-max-files">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{error_logs_max_files => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

%%====================================================================
%% Logs listing
%%====================================================================

handle(<<"GET">>, <<"logs">>, Req0, State) ->
    LogDir = config_loader:get(log_dir, "/tmp/ercpa_logs"),
    case file:list_dir(LogDir) of
        {ok, Files} ->
            reply_json(200, [list_to_binary(F) || F <- lists:sort(Files)], Req0, State);
        {error, _} ->
            reply_json(200, [], Req0, State)
    end;

%%====================================================================
%% Request error logs
%%====================================================================

handle(<<"GET">>, <<"request-error-logs">>, Req0, State) ->
    LogDir = config_loader:get(log_dir, "/tmp/ercpa_logs"),
    case file:list_dir(LogDir) of
        {ok, Files} ->
            Logs = lists:filtermap(fun(F) ->
                case lists:suffix(".log", F) of
                    true ->
                        FullPath = filename:join(LogDir, F),
                        case file:read_file_info(FullPath) of
                            {ok, Info} ->
                                {true, #{<<"name">> => list_to_binary(F),
                                         <<"size">> => element(2, Info)}};
                            _ -> {true, #{<<"name">> => list_to_binary(F)}}
                        end;
                    false -> false
                end
            end, lists:sort(Files)),
            reply_json(200, Logs, Req0, State);
        {error, _} ->
            reply_json(200, [], Req0, State)
    end;

handle(<<"GET">>, <<"request-error-logs/", Name/binary>>, Req0, State) ->
    LogDir = config_loader:get(log_dir, "/tmp/ercpa_logs"),
    %% Sanitize name to prevent path traversal
    SafeName = filename:basename(binary_to_list(Name)),
    Path = filename:join(LogDir, SafeName),
    case file:read_file(Path) of
        {ok, Content} ->
            Req = cowboy_req:reply(200,
                #{<<"content-type">> => <<"text/plain">>,
                  <<"content-disposition">> =>
                      iolist_to_binary([<<"attachment; filename=\"">>, SafeName, <<"\"">>])},
                Content, Req0),
            {ok, Req, State};
        {error, _} ->
            reply_json(404, #{<<"error">> => <<"log file not found">>}, Req0, State)
    end;

handle(<<"GET">>, <<"request-log-by-id/", ReqId/binary>>, Req0, State) ->
    LogDir = config_loader:get(log_dir, "/tmp/ercpa_logs"),
    Result = search_log_by_id(LogDir, ReqId),
    case Result of
        {ok, Entry} -> reply_json(200, Entry, Req0, State);
        not_found -> reply_json(404, #{<<"error">> => <<"request not found">>}, Req0, State)
    end;

handle(<<"DELETE">>, <<"logs">>, Req0, State) ->
    LogDir = config_loader:get(log_dir, "/tmp/ercpa_logs"),
    case file:list_dir(LogDir) of
        {ok, Files} ->
            lists:foreach(fun(F) ->
                file:delete(filename:join(LogDir, F))
            end, Files),
            reply_json(200, #{<<"ok">> => true, <<"deleted">> => length(Files)}, Req0, State);
        {error, _} ->
            reply_json(200, #{<<"ok">> => true, <<"deleted">> => 0}, Req0, State)
    end;

%%====================================================================
%% Retry configuration
%%====================================================================

handle(<<"GET">>, <<"request-retry">>, Req0, State) ->
    reply_json(200, config_loader:get(request_retry, 3), Req0, State);

handle(<<"PUT">>, <<"request-retry">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{request_retry => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"request-retry">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{request_retry => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"GET">>, <<"max-retry-interval">>, Req0, State) ->
    reply_json(200, config_loader:get(max_retry_interval, 0), Req0, State);

handle(<<"PUT">>, <<"max-retry-interval">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{max_retry_interval => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"max-retry-interval">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{max_retry_interval => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

%%====================================================================
%% Proxy
%%====================================================================

handle(<<"GET">>, <<"proxy-url">>, Req0, State) ->
    reply_json(200, config_loader:get(proxy_url, <<>>), Req0, State);

handle(<<"PUT">>, <<"proxy-url">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{proxy_url => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"proxy-url">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{proxy_url => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"DELETE">>, <<"proxy-url">>, Req0, State) ->
    config_loader:apply_config(#{proxy_url => <<>>}),
    reply_json(200, #{<<"ok">> => true}, Req0, State);

%%====================================================================
%% Model prefix
%%====================================================================

handle(<<"GET">>, <<"force-model-prefix">>, Req0, State) ->
    reply_json(200, config_loader:get(force_model_prefix, <<>>), Req0, State);

handle(<<"PUT">>, <<"force-model-prefix">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{force_model_prefix => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"force-model-prefix">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{force_model_prefix => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

%%====================================================================
%% Session affinity
%%====================================================================

handle(<<"GET">>, <<"routing/session-affinity">>, Req0, State) ->
    reply_json(200, #{
        <<"enabled">> => config_loader:get(session_affinity_enabled, true),
        <<"ttl">> => config_loader:get(session_affinity_ttl, 3600)
    }, Req0, State);

handle(<<"PUT">>, <<"routing/session-affinity">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body, [return_maps]),
    Updates = case Val of
        M when is_map(M) ->
            maps:fold(fun
                (<<"enabled">>, V, Acc) -> Acc#{session_affinity_enabled => V};
                (<<"ttl">>, V, Acc) -> Acc#{session_affinity_ttl => V};
                (_, _, Acc) -> Acc
            end, #{}, M);
        TTL when is_integer(TTL) ->
            #{session_affinity_ttl => TTL};
        _ -> #{}
    end,
    config_loader:apply_config(Updates),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

%%====================================================================
%% Auth file PATCH operations
%%====================================================================

handle(<<"PATCH">>, <<"auth-files/status">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"id">> := Id, <<"disabled">> := Disabled} = jiffy:decode(Body, [return_maps]),
    case auth_store:update(Id, #{<<"disabled">> => Disabled}) of
        ok -> reply_json(200, #{<<"ok">> => true}, Req1, State);
        {error, Reason} ->
            reply_json(404, #{<<"error">> => iolist_to_binary(io_lib:format("~p", [Reason]))},
                       Req1, State)
    end;

handle(<<"PATCH">>, <<"auth-files/fields">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"id">> := Id} = Data = jiffy:decode(Body, [return_maps]),
    Fields = maps:remove(<<"id">>, Data),
    case auth_store:update(Id, Fields) of
        ok -> reply_json(200, #{<<"ok">> => true}, Req1, State);
        {error, Reason} ->
            reply_json(404, #{<<"error">> => iolist_to_binary(io_lib:format("~p", [Reason]))},
                       Req1, State)
    end;

%%====================================================================
%% Auth files extended
%%====================================================================

handle(<<"GET">>, <<"auth-files/download">>, Req0, State) ->
    Id = proplists:get_value(<<"id">>, cowboy_req:parse_qs(Req0), <<>>),
    case auth_store:load_all() of
        {ok, Auths} ->
            case lists:keyfind(Id, 1, [{maps:get(id, A, <<>>), A} || A <- Auths]) of
                {_, Auth} ->
                    Req = cowboy_req:reply(200,
                        #{<<"content-type">> => <<"application/json">>,
                          <<"content-disposition">> =>
                              iolist_to_binary([<<"attachment; filename=\"">>, Id, <<".json\"">>])},
                        jiffy:encode(Auth), Req0),
                    {ok, Req, State};
                false ->
                    reply_json(404, #{<<"error">> => <<"auth file not found">>}, Req0, State)
            end;
        {error, _} ->
            reply_json(404, #{<<"error">> => <<"auth file not found">>}, Req0, State)
    end;

handle(<<"GET">>, <<"auth-files/models">>, Req0, State) ->
    case auth_store:load_all() of
        {ok, Auths} ->
            Result = lists:map(fun(#{id := Id, provider := Provider, metadata := Meta}) ->
                Models = maps:get(<<"models">>, Meta, []),
                #{<<"id">> => Id,
                  <<"provider">> => atom_to_binary(Provider, utf8),
                  <<"models">> => Models}
            end, Auths),
            reply_json(200, Result, Req0, State);
        {error, Reason} ->
            reply_json(500, #{<<"error">> => iolist_to_binary(io_lib:format("~p", [Reason]))},
                       Req0, State)
    end;

%%====================================================================
%% Model definitions
%%====================================================================

handle(<<"GET">>, <<"model-definitions/", Channel/binary>>, Req0, State) ->
    Models = model_registry:get_available_models(binary_to_atom(Channel, utf8)),
    reply_json(200, Models, Req0, State);

%%====================================================================
%% OAuth excluded models
%%====================================================================

handle(<<"GET">>, <<"oauth-excluded-models">>, Req0, State) ->
    reply_json(200, config_loader:get(oauth_excluded_models, []), Req0, State);

handle(<<"PUT">>, <<"oauth-excluded-models">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body, [return_maps]),
    config_loader:apply_config(#{oauth_excluded_models => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"DELETE">>, <<"oauth-excluded-models">>, Req0, State) ->
    config_loader:apply_config(#{oauth_excluded_models => []}),
    reply_json(200, #{<<"ok">> => true}, Req0, State);

%%====================================================================
%% OAuth model alias
%%====================================================================

handle(<<"GET">>, <<"oauth-model-alias">>, Req0, State) ->
    reply_json(200, config_loader:get(oauth_model_alias, #{}), Req0, State);

handle(<<"PUT">>, <<"oauth-model-alias">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body, [return_maps]),
    config_loader:apply_config(#{oauth_model_alias => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"DELETE">>, <<"oauth-model-alias">>, Req0, State) ->
    config_loader:apply_config(#{oauth_model_alias => #{}}),
    reply_json(200, #{<<"ok">> => true}, Req0, State);

%%====================================================================
%% Quota
%%====================================================================

handle(<<"GET">>, <<"quota-exceeded/switch-project">>, Req0, State) ->
    reply_json(200, config_loader:get(quota_switch_project, false), Req0, State);

handle(<<"GET">>, <<"quota-exceeded/switch-preview-model">>, Req0, State) ->
    reply_json(200, config_loader:get(quota_switch_preview_model, false), Req0, State);

handle(<<"PUT">>, <<"quota-exceeded/switch-preview-model">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{quota_switch_preview_model => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"quota-exceeded/switch-preview-model">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{quota_switch_preview_model => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PUT">>, <<"quota-exceeded/switch-project">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{quota_switch_project => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"quota-exceeded/switch-project">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{quota_switch_project => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

%%====================================================================
%% Rate limiting
%%====================================================================

handle(<<"GET">>, <<"rate-limit">>, Req0, State) ->
    reply_json(200, rate_limiter:get_config(), Req0, State);

handle(<<"PUT">>, <<"rate-limit">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{rate_limit_rpm => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

%%====================================================================
%% Password
%%====================================================================

handle(<<"PUT">>, <<"password">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{password => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

%%====================================================================
%% Payload rules
%%====================================================================

handle(<<"GET">>, <<"payload">>, Req0, State) ->
    reply_json(200, config_loader:get(payload, #{}), Req0, State);

handle(<<"PUT">>, <<"payload">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body, [return_maps]),
    config_loader:apply_config(#{payload => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

%%====================================================================
%% Model aliases & exclusions
%%====================================================================

handle(<<"GET">>, <<"model-aliases">>, Req0, State) ->
    reply_json(200, config_loader:get(model_aliases, #{}), Req0, State);

handle(<<"PUT">>, <<"model-aliases">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body, [return_maps]),
    config_loader:apply_config(#{model_aliases => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"GET">>, <<"model-exclusions">>, Req0, State) ->
    reply_json(200, config_loader:get(model_exclusions, #{}), Req0, State);

handle(<<"PUT">>, <<"model-exclusions">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body, [return_maps]),
    config_loader:apply_config(#{model_exclusions => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

%%====================================================================
%% Provider keys
%%====================================================================

handle(<<"GET">>, <<"gemini-api-key">>, Req0, State) ->
    reply_json(200, config_loader:get(gemini_keys, []), Req0, State);

handle(<<"PUT">>, <<"gemini-api-key">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body, [return_maps]),
    config_loader:apply_config(#{gemini_keys => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"gemini-api-key">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    New = jiffy:decode(Body, [return_maps]),
    Old = config_loader:get(gemini_keys, []),
    config_loader:apply_config(#{gemini_keys => merge_list(Old, New)}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"DELETE">>, <<"gemini-api-key">>, Req0, State) ->
    config_loader:apply_config(#{gemini_keys => []}),
    reply_json(200, #{<<"ok">> => true}, Req0, State);

handle(<<"GET">>, <<"claude-api-key">>, Req0, State) ->
    reply_json(200, config_loader:get(claude_keys, []), Req0, State);

handle(<<"PUT">>, <<"claude-api-key">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body, [return_maps]),
    config_loader:apply_config(#{claude_keys => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"claude-api-key">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    New = jiffy:decode(Body, [return_maps]),
    Old = config_loader:get(claude_keys, []),
    config_loader:apply_config(#{claude_keys => merge_list(Old, New)}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"DELETE">>, <<"claude-api-key">>, Req0, State) ->
    config_loader:apply_config(#{claude_keys => []}),
    reply_json(200, #{<<"ok">> => true}, Req0, State);

handle(<<"GET">>, <<"codex-api-key">>, Req0, State) ->
    reply_json(200, config_loader:get(codex_keys, []), Req0, State);

handle(<<"PUT">>, <<"codex-api-key">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body, [return_maps]),
    config_loader:apply_config(#{codex_keys => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"codex-api-key">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    New = jiffy:decode(Body, [return_maps]),
    Old = config_loader:get(codex_keys, []),
    config_loader:apply_config(#{codex_keys => merge_list(Old, New)}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"DELETE">>, <<"codex-api-key">>, Req0, State) ->
    config_loader:apply_config(#{codex_keys => []}),
    reply_json(200, #{<<"ok">> => true}, Req0, State);

handle(<<"GET">>, <<"openai-compatibility">>, Req0, State) ->
    reply_json(200, config_loader:get(openai_compat, []), Req0, State);

handle(<<"PUT">>, <<"openai-compatibility">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body, [return_maps]),
    config_loader:apply_config(#{openai_compat => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"openai-compatibility">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    New = jiffy:decode(Body, [return_maps]),
    Old = config_loader:get(openai_compat, []),
    config_loader:apply_config(#{openai_compat => merge_list(Old, New)}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"DELETE">>, <<"openai-compatibility">>, Req0, State) ->
    config_loader:apply_config(#{openai_compat => []}),
    reply_json(200, #{<<"ok">> => true}, Req0, State);

handle(<<"GET">>, <<"vertex-api-key">>, Req0, State) ->
    reply_json(200, config_loader:get(vertex_keys, []), Req0, State);

handle(<<"PUT">>, <<"vertex-api-key">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body, [return_maps]),
    config_loader:apply_config(#{vertex_keys => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"vertex-api-key">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    New = jiffy:decode(Body, [return_maps]),
    Old = config_loader:get(vertex_keys, []),
    config_loader:apply_config(#{vertex_keys => merge_list(Old, New)}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"DELETE">>, <<"vertex-api-key">>, Req0, State) ->
    config_loader:apply_config(#{vertex_keys => []}),
    reply_json(200, #{<<"ok">> => true}, Req0, State);

%%====================================================================
%% Vertex import
%%====================================================================

handle(<<"POST">>, <<"vertex/import">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Data = jiffy:decode(Body, [return_maps]),
    File = maps:get(<<"file">>, Data, <<>>),
    Prefix = maps:get(<<"prefix">>, Data, <<>>),
    case vertex_import:import(File, Prefix) of
        ok -> reply_json(200, #{<<"ok">> => true}, Req1, State);
        {error, Reason} ->
            reply_json(400, #{<<"error">> => iolist_to_binary(io_lib:format("~p", [Reason]))},
                       Req1, State)
    end;

%%====================================================================
%% API call testing
%%====================================================================

handle(<<"POST">>, <<"api-call">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    #{<<"model">> := Model} = Params = jiffy:decode(Body, [return_maps]),
    Messages = maps:get(<<"messages">>, Params, [#{<<"role">> => <<"user">>,
                                                     <<"content">> => <<"test">>}]),
    Request = #{<<"model">> => Model, <<"messages">> => Messages,
                <<"stream">> => false},
    CredId = maps:get(<<"credential_id">>, Params, undefined),
    Opts = case CredId of
        undefined -> #{};
        _ -> #{force_credential => CredId}
    end,
    case conductor:execute(openai, Model, Request, Opts) of
        {ok, Resp} ->
            reply_json(200, Resp, Req1, State);
        {error, Status, ErrBody} ->
            reply_json(Status, #{<<"error">> => ErrBody}, Req1, State)
    end;

%%====================================================================
%% Amp
%%====================================================================

handle(<<"GET">>, <<"ampcode">>, Req0, State) ->
    reply_json(200, #{
        <<"upstream_url">> => config_loader:get(ampcode_upstream_url, <<>>),
        <<"upstream_api_key">> => amp_config:get_upstream_api_key(),
        <<"model_mappings">> => amp_config:get_model_mappings(),
        <<"force_model_mappings">> => amp_config:force_model_mappings(),
        <<"restrict_management_to_localhost">> => config_loader:get(ampcode_restrict_mgmt_localhost, true)
    }, Req0, State);

handle(<<"GET">>, <<"ampcode/model-mappings">>, Req0, State) ->
    Mappings = amp_config:get_model_mappings(),
    reply_json(200, Mappings, Req0, State);

handle(<<"PUT">>, <<"ampcode/model-mappings">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Mappings = jiffy:decode(Body, [return_maps]),
    config_loader:apply_config(#{ampcode => #{model_mappings => Mappings}}),
    gen_server:cast(amp_config, reload),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"ampcode/model-mappings">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    New = jiffy:decode(Body, [return_maps]),
    Old = amp_config:get_model_mappings(),
    config_loader:apply_config(#{ampcode => #{model_mappings => merge_list(Old, New)}}),
    gen_server:cast(amp_config, reload),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"DELETE">>, <<"ampcode/model-mappings">>, Req0, State) ->
    config_loader:apply_config(#{ampcode => #{model_mappings => []}}),
    gen_server:cast(amp_config, reload),
    reply_json(200, #{<<"ok">> => true}, Req0, State);

handle(<<"GET">>, <<"ampcode/upstream-url">>, Req0, State) ->
    reply_json(200, config_loader:get(ampcode_upstream_url, <<>>), Req0, State);

handle(<<"PUT">>, <<"ampcode/upstream-url">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{ampcode_upstream_url => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"ampcode/upstream-url">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{ampcode_upstream_url => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"DELETE">>, <<"ampcode/upstream-url">>, Req0, State) ->
    config_loader:apply_config(#{ampcode_upstream_url => <<>>}),
    reply_json(200, #{<<"ok">> => true}, Req0, State);

handle(<<"GET">>, <<"ampcode/upstream-api-keys">>, Req0, State) ->
    reply_json(200, config_loader:get(ampcode_upstream_api_keys, #{}), Req0, State);

handle(<<"PUT">>, <<"ampcode/upstream-api-keys">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body, [return_maps]),
    config_loader:apply_config(#{ampcode_upstream_api_keys => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"ampcode/upstream-api-keys">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    New = jiffy:decode(Body, [return_maps]),
    Old = config_loader:get(ampcode_upstream_api_keys, #{}),
    config_loader:apply_config(#{ampcode_upstream_api_keys => maps:merge(Old, New)}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"DELETE">>, <<"ampcode/upstream-api-keys">>, Req0, State) ->
    config_loader:apply_config(#{ampcode_upstream_api_keys => #{}}),
    reply_json(200, #{<<"ok">> => true}, Req0, State);

handle(<<"GET">>, <<"ampcode/upstream-api-key">>, Req0, State) ->
    reply_json(200, amp_config:get_upstream_api_key(), Req0, State);

handle(<<"PUT">>, <<"ampcode/upstream-api-key">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{ampcode_upstream_api_key => Val}),
    gen_server:cast(amp_config, reload),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"ampcode/upstream-api-key">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{ampcode_upstream_api_key => Val}),
    gen_server:cast(amp_config, reload),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"DELETE">>, <<"ampcode/upstream-api-key">>, Req0, State) ->
    config_loader:apply_config(#{ampcode_upstream_api_key => <<>>}),
    gen_server:cast(amp_config, reload),
    reply_json(200, #{<<"ok">> => true}, Req0, State);

handle(<<"GET">>, <<"ampcode/restrict-management-to-localhost">>, Req0, State) ->
    reply_json(200, config_loader:get(ampcode_restrict_mgmt_localhost, true), Req0, State);

handle(<<"PUT">>, <<"ampcode/restrict-management-to-localhost">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{ampcode_restrict_mgmt_localhost => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"ampcode/restrict-management-to-localhost">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{ampcode_restrict_mgmt_localhost => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"GET">>, <<"ampcode/force-model-mappings">>, Req0, State) ->
    reply_json(200, config_loader:get(ampcode_force_model_mappings, false), Req0, State);

handle(<<"PUT">>, <<"ampcode/force-model-mappings">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{ampcode_force_model_mappings => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

handle(<<"PATCH">>, <<"ampcode/force-model-mappings">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{ampcode_force_model_mappings => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

%%====================================================================
%% Remote management config
%%====================================================================

handle(<<"GET">>, <<"remote-management">>, Req0, State) ->
    reply_json(200, #{
        <<"allow_remote">> => config_loader:get(allow_remote_management, false),
        <<"disable_control_panel">> => config_loader:get(disable_control_panel, false)
    }, Req0, State);

handle(<<"PUT">>, <<"remote-management">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body, [return_maps]),
    Updates = maps:fold(fun
        (<<"allow_remote">>, V, Acc) -> Acc#{allow_remote_management => V};
        (<<"disable_control_panel">>, V, Acc) -> Acc#{disable_control_panel => V};
        (_, _, Acc) -> Acc
    end, #{}, Val),
    config_loader:apply_config(Updates),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

%%====================================================================
%% Latest version
%%====================================================================

handle(<<"GET">>, <<"latest-version">>, Req0, State) ->
    Version = case application:get_key(cli_proxy, vsn) of
        {ok, V} -> list_to_binary(V);
        _ -> <<"0.1.0">>
    end,
    reply_json(200, #{<<"version">> => Version,
                       <<"otp">> => list_to_binary(erlang:system_info(otp_release)),
                       <<"erts">> => list_to_binary(erlang:system_info(version))}, Req0, State);

%%====================================================================
%% Fallback
%%====================================================================

handle(<<"OPTIONS">>, _, Req0, State) ->
    Req = cowboy_req:reply(204, cors_headers(), Req0),
    {ok, Req, State};

handle(_Method, _Path, Req0, State) ->
    reply_json(404, #{<<"error">> => <<"endpoint not found">>}, Req0, State).

%%====================================================================
%% Internal
%%====================================================================

mgmt_auth(Req) ->
    %% Check if request is from localhost or has valid management key
    {IP, _Port} = cowboy_req:peer(Req),
    case is_localhost(IP) of
        true -> ok;
        false ->
            case config_loader:get(allow_remote_management, false) of
                false -> {error, <<"remote management disabled">>};
                true ->
                    Key = extract_mgmt_key(Req),
                    case config_loader:get(management_secret) of
                        undefined -> {error, <<"management secret not configured">>};
                        Secret -> verify_mgmt_key(Key, Secret)
                    end
            end
    end.

is_localhost({127, 0, 0, 1}) -> true;
is_localhost({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
is_localhost(_) -> false.

extract_mgmt_key(Req) ->
    case cowboy_req:header(<<"authorization">>, Req, <<>>) of
        <<"Bearer ", Key/binary>> -> Key;
        _ -> cowboy_req:header(<<"x-management-key">>, Req, <<>>)
    end.

verify_mgmt_key(Key, Secret) ->
    case Key =:= Secret of
        true -> ok;
        false -> {error, <<"invalid management key">>}
    end.

sanitize_auth(Auth) ->
    %% Remove sensitive fields
    Metadata = maps:get(metadata, Auth, #{}),
    Sanitized = maps:without([<<"access_token">>, <<"refresh_token">>,
                              <<"id_token">>, <<"service_account">>], Metadata),
    Auth#{metadata => Sanitized}.

json_to_yaml(Map) when is_map(Map) ->
    iolist_to_binary(yaml_map(Map, 0)).

yaml_map(Map, Indent) ->
    Pad = lists:duplicate(Indent, $\s),
    maps:fold(fun(K, V, Acc) ->
        Key = yaml_key(K),
        case V of
            M when is_map(M), map_size(M) > 0 ->
                [Acc, Pad, Key, ":\n", yaml_map(M, Indent + 2)];
            L when is_list(L) ->
                [Acc, Pad, Key, ":\n", yaml_list(L, Indent + 2)];
            _ ->
                [Acc, Pad, Key, ": ", yaml_scalar(V), "\n"]
        end
    end, [], Map).

yaml_list([], _Indent) -> [];
yaml_list(List, Indent) ->
    Pad = lists:duplicate(Indent, $\s),
    lists:map(fun(Item) ->
        case Item of
            M when is_map(M) ->
                [Pad, "- ", yaml_inline(M), "\n"];
            _ ->
                [Pad, "- ", yaml_scalar(Item), "\n"]
        end
    end, List).

yaml_key(K) when is_atom(K) -> atom_to_list(K);
yaml_key(K) when is_binary(K) -> binary_to_list(K);
yaml_key(K) -> io_lib:format("~p", [K]).

yaml_scalar(true) -> "true";
yaml_scalar(false) -> "false";
yaml_scalar(null) -> "null";
yaml_scalar(V) when is_integer(V) -> integer_to_list(V);
yaml_scalar(V) when is_float(V) -> float_to_list(V, [{decimals, 6}, compact]);
yaml_scalar(V) when is_binary(V) -> ["\"", binary_to_list(V), "\""];
yaml_scalar(V) when is_atom(V) -> atom_to_list(V);
yaml_scalar(V) -> io_lib:format("~p", [V]).

yaml_inline(Map) when is_map(Map) ->
    jiffy:encode(Map).

merge_list(Old, New) when is_list(Old), is_list(New) ->
    Old ++ New;
merge_list(_Old, New) ->
    New.

strip_prefix(Path, Prefix) ->
    PrefixSize = byte_size(Prefix),
    case Path of
        <<Prefix:PrefixSize/binary, Rest/binary>> -> Rest;
        _ -> Path
    end.

extract_cred_data(Data) when is_tuple(Data) ->
    %% credential_proc #data record: {data, Id, Provider, Meta, BackoffLevel, ...}
    #{id => element(2, Data),
      provider => element(3, Data),
      backoff_level => element(5, Data)};
extract_cred_data(_) ->
    #{id => <<"unknown">>, provider => unknown, backoff_level => 0}.

search_log_by_id(LogDir, ReqId) ->
    case file:list_dir(LogDir) of
        {ok, Files} ->
            LogFiles = [filename:join(LogDir, F) || F <- lists:sort(Files),
                        lists:suffix(".log", F)],
            search_files_for_id(LogFiles, ReqId);
        {error, _} -> not_found
    end.

search_files_for_id([], _ReqId) -> not_found;
search_files_for_id([File | Rest], ReqId) ->
    case file:read_file(File) of
        {ok, Content} ->
            Lines = binary:split(Content, <<"\n">>, [global]),
            case find_matching_line(Lines, ReqId) of
                {ok, Entry} -> {ok, Entry};
                not_found -> search_files_for_id(Rest, ReqId)
            end;
        {error, _} -> search_files_for_id(Rest, ReqId)
    end.

find_matching_line([], _ReqId) -> not_found;
find_matching_line([<<>> | Rest], ReqId) -> find_matching_line(Rest, ReqId);
find_matching_line([Line | Rest], ReqId) ->
    case binary:match(Line, ReqId) of
        nomatch -> find_matching_line(Rest, ReqId);
        _ ->
            try {ok, jiffy:decode(Line, [return_maps])}
            catch _:_ -> find_matching_line(Rest, ReqId)
            end
    end.

reply_json(Status, Body, Req0, State) ->
    Req = cowboy_req:reply(Status, json_headers(), jiffy:encode(Body), Req0),
    {ok, Req, State}.

json_headers() ->
    maps:merge(cors_headers(), #{<<"content-type">> => <<"application/json">>}).

cors_headers() ->
    #{<<"access-control-allow-origin">> => <<"*">>,
      <<"access-control-allow-methods">> => <<"GET, POST, PUT, PATCH, DELETE, OPTIONS">>,
      <<"access-control-allow-headers">> => <<"*">>}.
