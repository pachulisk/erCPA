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

handle(<<"GET">>, <<"debug">>, Req0, State) ->
    reply_json(200, config_loader:get(debug, false), Req0, State);

handle(<<"PUT">>, <<"debug">>, Req0, State) ->
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
    Id = cowboy_req:qs_val(<<"id">>, Req0, <<>>),
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

handle(<<"GET">>, <<"ws-auth">>, Req0, State) ->
    reply_json(200, config_loader:get(ws_auth, false), Req0, State);

handle(<<"PUT">>, <<"ws-auth">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{ws_auth => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

%%====================================================================
%% Quota
%%====================================================================

handle(<<"GET">>, <<"quota-exceeded/switch-project">>, Req0, State) ->
    reply_json(200, config_loader:get(quota_switch_project, false), Req0, State);

handle(<<"PUT">>, <<"quota-exceeded/switch-project">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Val = jiffy:decode(Body),
    config_loader:apply_config(#{quota_switch_project => Val}),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

%%====================================================================
%% Provider keys
%%====================================================================

handle(<<"GET">>, <<"gemini-api-key">>, Req0, State) ->
    reply_json(200, config_loader:get(gemini_keys, []), Req0, State);

handle(<<"GET">>, <<"claude-api-key">>, Req0, State) ->
    reply_json(200, config_loader:get(claude_keys, []), Req0, State);

handle(<<"GET">>, <<"codex-api-key">>, Req0, State) ->
    reply_json(200, config_loader:get(codex_keys, []), Req0, State);

handle(<<"GET">>, <<"openai-compatibility">>, Req0, State) ->
    reply_json(200, config_loader:get(openai_compat, []), Req0, State);

handle(<<"GET">>, <<"vertex-api-key">>, Req0, State) ->
    reply_json(200, config_loader:get(vertex_keys, []), Req0, State);

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
%% Amp
%%====================================================================

handle(<<"GET">>, <<"ampcode/model-mappings">>, Req0, State) ->
    Mappings = amp_config:get_model_mappings(),
    reply_json(200, Mappings, Req0, State);

handle(<<"PUT">>, <<"ampcode/model-mappings">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Mappings = jiffy:decode(Body, [return_maps]),
    config_loader:apply_config(#{ampcode => #{model_mappings => Mappings}}),
    gen_server:cast(amp_config, reload),
    reply_json(200, #{<<"ok">> => true}, Req1, State);

%%====================================================================
%% Latest version
%%====================================================================

handle(<<"GET">>, <<"latest-version">>, Req0, State) ->
    reply_json(200, #{<<"version">> => <<"0.1.0">>}, Req0, State);

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
            Key = extract_mgmt_key(Req),
            case config_loader:get(management_secret) of
                undefined -> {error, <<"remote management disabled">>};
                Secret -> verify_mgmt_key(Key, Secret)
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

strip_prefix(Path, Prefix) ->
    PrefixSize = byte_size(Prefix),
    case Path of
        <<Prefix:PrefixSize/binary, Rest/binary>> -> Rest;
        _ -> Path
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
