-module(ws_relay_handler).

%% WebSocket relay handler — proxies WS connections to upstream providers
%% Used by Codex, AiStudio for persistent WS connections
%% Route: /v1/ws

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

-record(state, {
    upstream_pid :: pid() | undefined,
    provider :: atom(),
    auth_id :: binary(),
    auth :: map()
}).

init(Req, _Opts) ->
    case access_control:authenticate(Req) of
        {error, _} ->
            Req1 = cowboy_req:reply(401, #{}, <<"Unauthorized">>, Req),
            {ok, Req1, #state{}};
        {ok, _} ->
            Provider = extract_provider(Req),
            {cowboy_websocket, Req, #state{provider = Provider}}
    end.

websocket_init(#state{provider = Provider} = State) ->
    %% Select credential for this provider
    case conductor:select_credential(<<"*">>, #{}, <<>>) of
        {ok, AuthId, _Provider} ->
            case credential_proc:get_auth(AuthId) of
                {ok, Auth} ->
                    case connect_upstream(Provider, Auth) of
                        {ok, Pid} ->
                            {ok, State#state{upstream_pid = Pid, auth_id = AuthId, auth = Auth}};
                        {error, _} ->
                            {reply, {close, 1011, <<"upstream connection failed">>}, State}
                    end;
                {error, _} ->
                    {reply, {close, 1011, <<"credential not found">>}, State}
            end;
        {error, _} ->
            {reply, {close, 1008, <<"no credential available">>}, State}
    end.

%% Client → Upstream
websocket_handle({text, Msg}, #state{upstream_pid = Pid} = State) when Pid =/= undefined ->
    gun:ws_send(Pid, default, {text, Msg}),
    {ok, State};
websocket_handle({binary, Msg}, #state{upstream_pid = Pid} = State) when Pid =/= undefined ->
    gun:ws_send(Pid, default, {binary, Msg}),
    {ok, State};
websocket_handle(_Frame, State) ->
    {ok, State}.

%% Upstream → Client
websocket_info({gun_ws, _Pid, _Ref, {text, Msg}}, State) ->
    {reply, {text, Msg}, State};
websocket_info({gun_ws, _Pid, _Ref, {binary, Msg}}, State) ->
    {reply, {binary, Msg}, State};
websocket_info({gun_ws, _Pid, _Ref, close}, State) ->
    {reply, {close, 1000, <<"upstream closed">>}, State};
websocket_info({gun_down, _Pid, _, _, _}, State) ->
    {reply, {close, 1011, <<"upstream disconnected">>}, State};
websocket_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _Req, #state{upstream_pid = Pid}) ->
    case Pid of
        undefined -> ok;
        _ -> catch gun:close(Pid)
    end,
    ok.

%%====================================================================
%% Internal
%%====================================================================

extract_provider(Req) ->
    QS = cowboy_req:parse_qs(Req),
    ProvBin = proplists:get_value(<<"provider">>, QS, <<"codex">>),
    binary_to_atom(ProvBin, utf8).

connect_upstream(codex, Auth) ->
    BaseURL = maps:get(<<"base_url">>, Auth, <<"wss://api.openai.com">>),
    connect_ws(BaseURL, "/v1/realtime");
connect_upstream(aistudio, Auth) ->
    BaseURL = maps:get(<<"base_url">>, Auth, <<"wss://generativelanguage.googleapis.com">>),
    connect_ws(BaseURL, "/ws");
connect_upstream(_, Auth) ->
    BaseURL = maps:get(<<"base_url">>, Auth, <<"wss://localhost">>),
    connect_ws(BaseURL, "/ws").

connect_ws(URL, Path) ->
    case uri_string:parse(URL) of
        #{host := Host, port := Port} ->
            TransOpts = case Port of
                443 -> #{protocols => [http], transport => tls};
                _ -> #{protocols => [http]}
            end,
            case gun:open(binary_to_list(Host), Port, TransOpts) of
                {ok, Pid} ->
                    {ok, _} = gun:await_up(Pid, 5000),
                    gun:ws_upgrade(Pid, Path),
                    receive
                        {gun_upgrade, Pid, _, _, _} -> {ok, Pid};
                        {gun_response, Pid, _, _, Status, _} -> {error, {ws_upgrade_failed, Status}}
                    after 5000 ->
                        gun:close(Pid),
                        {error, timeout}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        #{host := Host} ->
            connect_ws(<<URL/binary>>, Host, 443, Path);
        _ ->
            {error, invalid_url}
    end.

connect_ws(_URL, Host, Port, Path) ->
    case gun:open(binary_to_list(Host), Port, #{protocols => [http], transport => tls}) of
        {ok, Pid} ->
            {ok, _} = gun:await_up(Pid, 5000),
            gun:ws_upgrade(Pid, Path),
            receive
                {gun_upgrade, Pid, _, _, _} -> {ok, Pid};
                {gun_response, Pid, _, _, Status, _} -> {error, {ws_upgrade_failed, Status}}
            after 5000 ->
                gun:close(Pid),
                {error, timeout}
            end;
        {error, Reason} ->
            {error, Reason}
    end.
