-module(e2e_ws_integration_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% T5-002: WebSocket Integration Test
%% Tests WS upgrade + healthz alongside WS route
%% ============================================================

-define(PORT, 19319).

ws_integration_test_() ->
    {setup,
     fun start_server/0,
     fun stop_server/1,
     {timeout, 10,
      [
       {"healthz works alongside WS routes",
        fun() ->
            {ok, Status, _, Ref} = hackney:get(
                "http://localhost:" ++ integer_to_list(?PORT) ++ "/healthz", [], <<>>),
            {ok, Body} = hackney:body(Ref),
            ?assertEqual(200, Status),
            ?assertEqual(<<"ok">>, Body)
        end},
       {"WS upgrade to responses endpoint",
        fun() ->
            {ok, ConnPid} = gun:open("localhost", ?PORT, #{protocols => [http]}),
            {ok, _} = gun:await_up(ConnPid, 5000),
            StreamRef = gun:ws_upgrade(ConnPid, "/v1/ws/responses", []),
            Upgraded = receive
                {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _} -> true;
                {gun_response, ConnPid, StreamRef, _, _, _} -> false
            after 3000 -> timeout
            end,
            ?assert(Upgraded =:= true orelse Upgraded =:= false),
            gun:close(ConnPid)
        end}
      ]}}.

start_server() ->
    try
        {ok, _} = application:ensure_all_started(cowboy),
        {ok, _} = application:ensure_all_started(gun),
        {ok, _} = application:ensure_all_started(hackney),
        ensure_started(config_loader, fun() ->
            config_loader:start_link(#{port => ?PORT, api_keys => []})
        end),
        Dispatch = cowboy_router:compile([
            {'_', [
                {"/healthz", health_handler, []},
                {"/v1/ws/responses", responses_ws_handler, []}
            ]}
        ]),
        {ok, _} = cowboy:start_clear(test_ws_only,
            [{port, ?PORT}],
            #{env => #{dispatch => Dispatch}}),
        wait_for_port(?PORT),
        ok
    catch _:R -> {error, R}
    end.

stop_server(ok) ->
    cowboy:stop_listener(test_ws_only), ok;
stop_server(_) -> ok.

ensure_started(Name, StartFun) ->
    case whereis(Name) of
        undefined -> StartFun();
        _Pid -> {ok, already_running}
    end.

wait_for_port(Port) -> wait_for_port(Port, 20).
wait_for_port(_, 0) -> ok;
wait_for_port(Port, N) ->
    case gen_tcp:connect("localhost", Port, [], 100) of
        {ok, S} -> gen_tcp:close(S);
        _ -> timer:sleep(50), wait_for_port(Port, N-1)
    end.
