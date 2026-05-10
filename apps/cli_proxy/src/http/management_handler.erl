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
