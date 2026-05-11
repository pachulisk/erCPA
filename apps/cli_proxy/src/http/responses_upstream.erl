-module(responses_upstream).

%% Linked upstream connection process for Responses API WebSocket
%% Manages connection to upstream provider (Codex WS or HTTP SSE)
%% Routes events back to the handler process

-export([start_link/5]).

-spec start_link(atom(), binary(), map(), pid() | undefined, pid()) -> pid().
start_link(Provider, AuthId, Request, ExistingConn, HandlerPid) ->
    spawn_link(fun() ->
        run(Provider, AuthId, Request, ExistingConn, HandlerPid)
    end).

%%====================================================================
%% Internal
%%====================================================================

run(codex, AuthId, Request, _ExistingConn, HandlerPid) ->
    %% Codex WebSocket upstream
    run_ws_upstream(AuthId, Request, HandlerPid);
run(_Provider, AuthId, Request, _ExistingConn, HandlerPid) ->
    %% Default: HTTP SSE upstream
    run_http_upstream(AuthId, Request, HandlerPid).

%%====================================================================
%% WebSocket upstream (Codex Responses API)
%%====================================================================

run_ws_upstream(AuthId, Request, HandlerPid) ->
    Auth = get_auth_metadata(AuthId),
    BaseURL = maps:get(<<"base_url">>, Auth, <<"https://api.openai.com">>),
    %% Convert HTTP URL to WS
    WsURL = http_to_ws_url(BaseURL),
    Token = maps:get(<<"access_token">>, Auth, <<>>),

    case gun:open(parse_host(WsURL), parse_port(WsURL), #{protocols => [http]}) of
        {ok, ConnPid} ->
            _ = case gun:await_up(ConnPid, 10000) of
                {ok, _} ->
                    Path = <<"/v1/responses">>,
                    Headers = [{<<"authorization">>, <<"Bearer ", Token/binary>>},
                               {<<"content-type">>, <<"application/json">>}],
                    StreamRef = gun:ws_upgrade(ConnPid, Path, Headers),
                    receive
                        {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _} ->
                            %% Connected — send request
                            gun:ws_send(ConnPid, StreamRef, {text, jiffy:encode(Request)}),
                            _ = ws_receive_loop(ConnPid, StreamRef, HandlerPid, []);
                        {gun_response, ConnPid, StreamRef, _, Status, _} ->
                            HandlerPid ! {upstream_error, Status, <<"ws upgrade failed">>};
                        {gun_error, ConnPid, StreamRef, Reason} ->
                            HandlerPid ! {upstream_error, 502, format_error(Reason)}
                    after 10000 ->
                        HandlerPid ! {upstream_error, 408, <<"ws upgrade timeout">>}
                    end;
                {error, Reason} ->
                    HandlerPid ! {upstream_error, 502, format_error(Reason)}
            end,
            gun:close(ConnPid);
        {error, Reason} ->
            HandlerPid ! {upstream_error, 502, format_error(Reason)}
    end.

ws_receive_loop(ConnPid, StreamRef, HandlerPid, OutputAcc) ->
    receive
        {gun_ws, ConnPid, StreamRef, {text, Data}} ->
            case parse_ws_event(Data) of
                done ->
                    HandlerPid ! {upstream_done, OutputAcc, #{}};
                {event, Event} ->
                    HandlerPid ! {upstream_event, Event},
                    %% Accumulate output items for final state
                    NewAcc = maybe_accumulate_output(Event, OutputAcc),
                    ws_receive_loop(ConnPid, StreamRef, HandlerPid, NewAcc);
                skip ->
                    ws_receive_loop(ConnPid, StreamRef, HandlerPid, OutputAcc)
            end;
        {gun_ws, ConnPid, StreamRef, close} ->
            HandlerPid ! {upstream_done, OutputAcc, #{}};
        {gun_down, ConnPid, _, _, _} ->
            HandlerPid ! {upstream_error, 502, <<"connection lost">>}
    after 120000 ->
        HandlerPid ! {upstream_error, 408, <<"timeout">>}
    end.

%%====================================================================
%% HTTP SSE upstream (Claude, Gemini, etc.)
%%====================================================================

run_http_upstream(AuthId, Request, HandlerPid) ->
    Auth = get_auth_metadata(AuthId),
    Provider = maps:get(<<"type">>, Auth, <<"claude">>),
    BaseURL = get_base_url(Provider, Auth),
    URL = <<BaseURL/binary, (get_endpoint(Provider))/binary>>,
    Headers = build_headers(Provider, Auth),
    Body = jiffy:encode(Request#{<<"stream">> => true}),

    case hackney:post(URL, Headers, Body, [{recv_timeout, 120000}, async]) of
        {ok, ClientRef} ->
            http_receive_loop(ClientRef, HandlerPid, [], <<>>);
        {error, Reason} ->
            HandlerPid ! {upstream_error, 502, format_error(Reason)}
    end.

http_receive_loop(ClientRef, HandlerPid, OutputAcc, Buffer) ->
    receive
        {hackney_response, ClientRef, {status, Status, _}} when Status >= 200, Status < 300 ->
            http_receive_loop(ClientRef, HandlerPid, OutputAcc, Buffer);
        {hackney_response, ClientRef, {status, Status, _}} ->
            HandlerPid ! {upstream_error, Status, <<"upstream error">>};
        {hackney_response, ClientRef, {headers, _}} ->
            http_receive_loop(ClientRef, HandlerPid, OutputAcc, Buffer);
        {hackney_response, ClientRef, done} ->
            HandlerPid ! {upstream_done, OutputAcc, #{}};
        {hackney_response, ClientRef, Data} when is_binary(Data) ->
            %% Parse SSE chunks
            FullData = <<Buffer/binary, Data/binary>>,
            {Events, Remaining} = parse_sse_buffer(FullData),
            NewAcc = lists:foldl(fun(Event, Acc) ->
                HandlerPid ! {upstream_event, Event},
                maybe_accumulate_output(Event, Acc)
            end, OutputAcc, Events),
            http_receive_loop(ClientRef, HandlerPid, NewAcc, Remaining);
        {hackney_response, ClientRef, {error, Reason}} ->
            HandlerPid ! {upstream_error, 502, format_error(Reason)}
    after 120000 ->
        HandlerPid ! {upstream_error, 408, <<"timeout">>}
    end.

%%====================================================================
%% Helpers
%%====================================================================

parse_ws_event(<<"[DONE]">>) -> done;
parse_ws_event(Data) ->
    %% May have "data: " prefix from SSE-over-WS
    JSON = case Data of
        <<"data: ", Rest/binary>> -> string:trim(Rest);
        _ -> Data
    end,
    case JSON of
        <<"[DONE]">> -> done;
        <<>> -> skip;
        _ ->
            try
                {event, jiffy:decode(JSON, [return_maps])}
            catch _:_ -> skip
            end
    end.

parse_sse_buffer(Data) ->
    Lines = binary:split(Data, <<"\n\n">>, [global]),
    case Lines of
        [Single] ->
            %% No complete event yet
            {[], Single};
        Parts ->
            {Events, [Last]} = lists:split(length(Parts) - 1, Parts),
            Parsed = lists:filtermap(fun parse_sse_line/1, Events),
            {Parsed, Last}
    end.

parse_sse_line(<<"data: [DONE]", _/binary>>) -> false;
parse_sse_line(<<"data: ", JSON/binary>>) ->
    try
        {true, jiffy:decode(string:trim(JSON), [return_maps])}
    catch _:_ -> false
    end;
parse_sse_line(Line) ->
    case binary:match(Line, <<"data:">>) of
        {Pos, 5} ->
            JSON = string:trim(binary:part(Line, Pos + 5, byte_size(Line) - Pos - 5)),
            try {true, jiffy:decode(JSON, [return_maps])}
            catch _:_ -> false
            end;
        _ -> false
    end.

maybe_accumulate_output(#{<<"type">> := <<"response.output_item.done">>,
                          <<"item">> := Item}, Acc) ->
    [Item | Acc];
maybe_accumulate_output(_, Acc) ->
    Acc.

get_auth_metadata(AuthId) ->
    case whereis(binary_to_atom(<<"cred_", AuthId/binary>>, utf8)) of
        undefined -> #{};
        _Pid ->
            %% Would call credential_proc:get_metadata but we need the full map
            #{}
    end.

get_base_url(<<"claude">>, Auth) ->
    maps:get(<<"base_url">>, Auth, <<"https://api.anthropic.com">>);
get_base_url(<<"gemini">>, Auth) ->
    maps:get(<<"base_url">>, Auth, <<"https://generativelanguage.googleapis.com">>);
get_base_url(_, Auth) ->
    maps:get(<<"base_url">>, Auth, <<"https://api.openai.com">>).

get_endpoint(<<"claude">>) -> <<"/v1/messages">>;
get_endpoint(<<"gemini">>) -> <<"/v1beta/models/gemini-pro:streamGenerateContent?alt=sse">>;
get_endpoint(_) -> <<"/v1/chat/completions">>.

build_headers(<<"claude">>, Auth) ->
    Token = maps:get(<<"access_token">>, Auth, <<>>),
    [{<<"Content-Type">>, <<"application/json">>},
     {<<"x-api-key">>, Token},
     {<<"anthropic-version">>, <<"2023-06-01">>}];
build_headers(_, Auth) ->
    Token = maps:get(<<"access_token">>, Auth, <<>>),
    [{<<"Content-Type">>, <<"application/json">>},
     {<<"Authorization">>, <<"Bearer ", Token/binary>>}].

http_to_ws_url(<<"https://", Rest/binary>>) -> <<"wss://", Rest/binary>>;
http_to_ws_url(<<"http://", Rest/binary>>) -> <<"ws://", Rest/binary>>;
http_to_ws_url(URL) -> URL.

parse_host(<<"wss://", Rest/binary>>) -> parse_host_from(Rest);
parse_host(<<"ws://", Rest/binary>>) -> parse_host_from(Rest);
parse_host(URL) -> parse_host_from(URL).

parse_host_from(HostPath) ->
    case binary:split(HostPath, <<"/">>) of
        [HostPort | _] ->
            case binary:split(HostPort, <<":">>) of
                [Host | _] -> binary_to_list(Host);
                _ -> binary_to_list(HostPort)
            end;
        _ -> "localhost"
    end.

parse_port(<<"wss://", _/binary>>) -> 443;
parse_port(<<"ws://", _/binary>>) -> 80;
parse_port(_) -> 443.

format_error(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).
