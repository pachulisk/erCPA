-module(codex_ws_executor).
-behaviour(gen_server).

%% Codex (OpenAI) WebSocket executor
%% Uses gun for WSS connections to OpenAI realtime API
%% Falls back to codex_executor for standard HTTP when WS is not needed

-export([start_link/1, execute/4, execute_stream/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_WS_HOST, "api.openai.com").
-define(DEFAULT_WS_PORT, 443).
-define(DEFAULT_WS_PATH, "/v1/realtime").
-define(CONNECT_TIMEOUT, 10000).
-define(RECV_TIMEOUT, 120000).

-record(state, {
    config :: map()
}).

%%====================================================================
%% API
%%====================================================================

start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Config], []).

-spec execute(binary(), map(), map(), map()) -> {ok, map()} | {error, integer(), binary()}.
execute(AuthId, Auth, Request, Opts) ->
    gen_server:call(?MODULE, {execute, AuthId, Auth, Request, Opts}, ?RECV_TIMEOUT).

-spec execute_stream(binary(), map(), map(), map()) -> {ok, pid()} | {error, integer(), binary()}.
execute_stream(AuthId, Auth, Request, Opts) ->
    gen_server:call(?MODULE, {execute_stream, AuthId, Auth, Request, Opts}, ?RECV_TIMEOUT).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Config]) ->
    {ok, #state{config = Config}}.

handle_call({execute, AuthId, Auth, Request, Opts}, From, State) ->
    spawn_link(fun() ->
        Result = do_execute(AuthId, Auth, Request, Opts),
        gen_server:reply(From, Result)
    end),
    {noreply, State};

handle_call({execute_stream, AuthId, Auth, Request, Opts}, From, State) ->
    Caller = maps:get(caller, Opts, element(1, From)),
    spawn_link(fun() ->
        Result = do_execute_stream(AuthId, Auth, Request, Opts, Caller),
        gen_server:reply(From, Result)
    end),
    {noreply, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal - Execute (collect all WS frames, return complete response)
%%====================================================================

do_execute(AuthId, Auth, Request, Opts) ->
    case connect_ws(Auth) of
        {ok, ConnPid, StreamRef} ->
            JsonBin = jiffy:encode(Request),
            gun:ws_send(ConnPid, StreamRef, {text, JsonBin}),
            Result = collect_ws_response(ConnPid, StreamRef, []),
            gun:close(ConnPid),
            Result;
        {error, _Reason} ->
            %% Fall back to HTTP executor
            codex_executor:execute(AuthId, Auth, Request, Opts)
    end.

%%====================================================================
%% Internal - Execute Stream (forward WS frames to caller)
%%====================================================================

do_execute_stream(AuthId, Auth, Request, Opts, Caller) ->
    case connect_ws(Auth) of
        {ok, ConnPid, StreamRef} ->
            JsonBin = jiffy:encode(Request),
            gun:ws_send(ConnPid, StreamRef, {text, JsonBin}),
            _ = ws_stream_loop(ConnPid, StreamRef, Caller),
            gun:close(ConnPid),
            {ok, self()};
        {error, _Reason} ->
            %% Fall back to HTTP executor
            codex_executor:execute_stream(AuthId, Auth, Request, Opts)
    end.

%%====================================================================
%% Internal - WebSocket connection
%%====================================================================

connect_ws(Auth) ->
    {Host, Port, Path} = parse_ws_endpoint(Auth),
    TlsOpts = [{verify, verify_none}],
    GunOpts = #{
        transport => tls,
        tls_opts => TlsOpts,
        connect_timeout => ?CONNECT_TIMEOUT
    },
    case gun:open(Host, Port, GunOpts) of
        {ok, ConnPid} ->
            case gun:await_up(ConnPid, ?CONNECT_TIMEOUT) of
                {ok, _Protocol} ->
                    Token = extract_token(Auth),
                    UA = maps:get(<<"user_agent">>, Auth,
                             maps:get(<<"user-agent">>, Auth, <<>>)),
                    WsHeaders = [
                        {<<"authorization">>, <<"Bearer ", Token/binary>>},
                        {<<"content-type">>, <<"application/json">>},
                        {<<"openai-beta">>, <<"responses_websockets=2026-02-06">>},
                        {<<"x-codex-beta-features">>,
                            maps:get(<<"x-codex-beta-features">>, Auth, <<"streaming">>)},
                        {<<"x-client-request-id">>, generate_request_id()}
                    ] ++ maybe_session_id_header(UA),
                    StreamRef = gun:ws_upgrade(ConnPid, Path, WsHeaders),
                    case await_ws_upgrade(ConnPid, StreamRef) of
                        ok ->
                            {ok, ConnPid, StreamRef};
                        {error, UpgradeErr} ->
                            gun:close(ConnPid),
                            {error, UpgradeErr}
                    end;
                {error, AwaitErr} ->
                    gun:close(ConnPid),
                    {error, AwaitErr}
            end;
        {error, OpenErr} ->
            {error, OpenErr}
    end.

await_ws_upgrade(ConnPid, StreamRef) ->
    receive
        {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _Headers} ->
            ok;
        {gun_response, ConnPid, StreamRef, _IsFin, Status, _Headers} ->
            {error, {ws_upgrade_failed, Status}};
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, Reason}
    after ?CONNECT_TIMEOUT ->
        {error, ws_upgrade_timeout}
    end.

parse_ws_endpoint(Auth) ->
    BaseURL = maps:get(<<"ws_url">>, Auth,
                  maps:get(<<"base_url">>, Auth, <<>>)),
    case BaseURL of
        <<>> ->
            {?DEFAULT_WS_HOST, ?DEFAULT_WS_PORT, ?DEFAULT_WS_PATH};
        URL ->
            parse_url(URL)
    end.

parse_url(<<"wss://", Rest/binary>>) ->
    parse_host_path(Rest, 443);
parse_url(<<"ws://", Rest/binary>>) ->
    parse_host_path(Rest, 80);
parse_url(<<"https://", Rest/binary>>) ->
    parse_host_path(Rest, 443);
parse_url(_) ->
    {?DEFAULT_WS_HOST, ?DEFAULT_WS_PORT, ?DEFAULT_WS_PATH}.

parse_host_path(HostPath, DefaultPort) ->
    case binary:split(HostPath, <<"/">>) of
        [HostPort] ->
            {Host, Port} = parse_host_port(HostPort, DefaultPort),
            {Host, Port, ?DEFAULT_WS_PATH};
        [HostPort, Path] ->
            {Host, Port} = parse_host_port(HostPort, DefaultPort),
            {Host, Port, <<"/", Path/binary>>}
    end.

parse_host_port(HostPort, DefaultPort) ->
    case binary:split(HostPort, <<":">>) of
        [Host] ->
            {binary_to_list(Host), DefaultPort};
        [Host, PortBin] ->
            Port = try binary_to_integer(PortBin) catch _:_ -> DefaultPort end,
            {binary_to_list(Host), Port}
    end.

extract_token(Auth) ->
    maps:get(<<"access_token">>, Auth,
        maps:get(<<"api_key">>, Auth, <<>>)).

generate_request_id() ->
    Hex = integer_to_binary(erlang:unique_integer([positive]), 16),
    <<"req_ws_", Hex/binary>>.

maybe_session_id_header(UA) ->
    case binary:match(UA, <<"Mac OS">>) of
        {_, _} ->
            SessionId = base64:encode(crypto:strong_rand_bytes(16)),
            [{<<"session_id">>, SessionId}];
        nomatch ->
            []
    end.

%%====================================================================
%% Internal - WS frame collection (non-stream)
%%====================================================================

collect_ws_response(ConnPid, StreamRef, Acc) ->
    receive
        {gun_ws, ConnPid, StreamRef, {text, Data}} ->
            case jiffy:decode(Data, [return_maps]) of
                #{<<"type">> := <<"response.done">>} = Frame ->
                    Response = maps:get(<<"response">>, Frame, Frame),
                    {ok, Response};
                #{<<"type">> := <<"error">>} = ErrFrame ->
                    ErrMsg = maps:get(<<"error">>, ErrFrame, ErrFrame),
                    {error, 502, jiffy:encode(ErrMsg)};
                Frame ->
                    collect_ws_response(ConnPid, StreamRef, [Frame | Acc])
            end;
        {gun_ws, ConnPid, StreamRef, close} ->
            %% Connection closed; assemble from accumulated frames
            case Acc of
                [] -> {error, 502, <<"empty response">>};
                _ -> {ok, lists:last(lists:reverse(Acc))}
            end;
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, 502, iolist_to_binary(io_lib:format("~p", [Reason]))}
    after ?RECV_TIMEOUT ->
        {error, 408, <<"timeout">>}
    end.

%%====================================================================
%% Internal - WS frame streaming
%%====================================================================

ws_stream_loop(ConnPid, StreamRef, Caller) ->
    receive
        {gun_ws, ConnPid, StreamRef, {text, Data}} ->
            Caller ! {stream_chunk, Data},
            %% Check if this is a terminal frame
            case catch jiffy:decode(Data, [return_maps]) of
                #{<<"type">> := <<"response.done">>} ->
                    Caller ! stream_done;
                #{<<"type">> := <<"error">>} ->
                    Caller ! {stream_error, 502, Data};
                _ ->
                    ws_stream_loop(ConnPid, StreamRef, Caller)
            end;
        {gun_ws, ConnPid, StreamRef, close} ->
            Caller ! stream_done;
        {gun_error, ConnPid, StreamRef, Reason} ->
            Caller ! {stream_error, 502, iolist_to_binary(io_lib:format("~p", [Reason]))}
    after ?RECV_TIMEOUT ->
        Caller ! {stream_error, 408, <<"timeout">>}
    end.
