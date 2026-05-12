-module(amp_provider_handler).

%% Cowboy handler for /api/provider/:provider/v1/... routes
%% Extracts provider from path, routes locally or proxies upstream

-export([init/2]).

init(Req0, State) ->
    case amp_config:is_enabled() of
        false ->
            Req = cowboy_req:reply(404, #{}, <<"Amp module not enabled">>, Req0),
            {ok, Req, State};
        true ->
            route(Req0, State)
    end.

route(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, cors_headers(), Req0),
            {ok, Req, State};
        <<"POST">> ->
            handle_post(Req0, State);
        _ ->
            %% GET, PUT, DELETE, etc. - proxy upstream
            proxy_upstream(Req0, State)
    end.

handle_post(Req0, State) ->
    ProviderBin = cowboy_req:binding(provider, Req0, <<>>),
    case map_provider(ProviderBin) of
        {local, Provider} ->
            handle_local(Provider, Req0, State);
        upstream ->
            proxy_upstream(Req0, State)
    end.

handle_local(Provider, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case catch jiffy:decode(Body, [return_maps]) of
        Request when is_map(Request) ->
            RawModel = maps:get(<<"model">>, Request, <<>>),
            Model = model_registry:resolve_alias(RawModel),
            Stream = maps:get(<<"stream">>, Request, false),
            Request1 = Request#{<<"model">> => Model},
            Opts = session_opts(Req1),
            case Stream of
                true ->
                    handle_stream(Provider, Model, Request1, Req1, State, Opts);
                false ->
                    handle_nonstream(Provider, Model, Request1, Req1, State, Opts)
            end;
        _ ->
            Req = cowboy_req:reply(400, json_headers(),
                jiffy:encode(#{<<"error">> => <<"invalid JSON body">>}), Req1),
            {ok, Req, State}
    end.

handle_nonstream(Provider, Model, Request, Req0, State, Opts) ->
    case conductor:execute(Provider, Model, Request, Opts) of
        {ok, Response} ->
            Req = cowboy_req:reply(200, json_headers(),
                jiffy:encode(Response), Req0),
            {ok, Req, State};
        {ok, stream, _} ->
            Req = cowboy_req:reply(501, json_headers(),
                jiffy:encode(#{<<"error">> => <<"unexpected stream">>}), Req0),
            {ok, Req, State};
        {error, Status, ErrBody} ->
            Req = cowboy_req:reply(Status, json_headers(), ErrBody, Req0),
            {ok, Req, State}
    end.

handle_stream(Provider, Model, Request, Req0, State, Opts) ->
    case conductor:execute(Provider, Model, Request#{<<"stream">> => true}, Opts) of
        {ok, Response} ->
            Headers = sse_headers(),
            Req1 = cowboy_req:stream_reply(200, Headers, Req0),
            cowboy_req:stream_body(
                iolist_to_binary(sse_parser:format_event(Response)), nofin, Req1),
            cowboy_req:stream_body(sse_parser:format_done(), fin, Req1),
            {ok, Req1, State};
        {ok, stream, _StreamPid} ->
            Headers = sse_headers(),
            Req1 = cowboy_req:stream_reply(200, Headers, Req0),
            stream_loop(Req1),
            {ok, Req1, State};
        {error, Status, ErrBody} ->
            Req = cowboy_req:reply(Status, json_headers(), ErrBody, Req0),
            {ok, Req, State}
    end.

stream_loop(Req) ->
    receive
        {stream_chunk, Data} ->
            cowboy_req:stream_body(Data, nofin, Req),
            stream_loop(Req);
        stream_done ->
            cowboy_req:stream_body(sse_parser:format_done(), fin, Req);
        {stream_error, _Status, _Body} ->
            cowboy_req:stream_body(sse_parser:format_done(), fin, Req)
    after 120000 ->
        cowboy_req:stream_body(sse_parser:format_done(), fin, Req)
    end.

proxy_upstream(Req0, State) ->
    case amp_proxy:proxy_request(Req0, State) of
        {ok, Req, NewState} ->
            {ok, Req, NewState};
        {error, Status, Body} ->
            Req = cowboy_req:reply(Status, json_headers(), Body, Req0),
            {ok, Req, State}
    end.

%%====================================================================
%% Internal - Provider mapping
%%====================================================================

map_provider(<<"claude">>) -> {local, claude};
map_provider(<<"anthropic">>) -> {local, claude};
map_provider(<<"gemini">>) -> {local, gemini};
map_provider(<<"google">>) -> {local, gemini};
map_provider(<<"openai">>) -> {local, codex};
map_provider(<<"codex">>) -> {local, codex};
map_provider(<<"vertex">>) -> {local, vertex};
map_provider(<<"aistudio">>) -> {local, aistudio};
map_provider(<<"antigravity">>) -> {local, antigravity};
map_provider(<<"kimi">>) -> {local, kimi};
map_provider(_) -> upstream.

session_opts(Req) ->
    SessionId = cowboy_req:header(<<"x-session-id">>, Req, <<>>),
    ClientReqId = cowboy_req:header(<<"x-client-request-id">>, Req, <<>>),
    #{headers => #{<<"x-session-id">> => SessionId,
                   <<"x-client-request-id">> => ClientReqId}}.

%%====================================================================
%% Internal - Response helpers
%%====================================================================

json_headers() ->
    maps:merge(cors_headers(), #{<<"content-type">> => <<"application/json">>}).

sse_headers() ->
    maps:merge(cors_headers(), #{
        <<"content-type">> => <<"text/event-stream">>,
        <<"cache-control">> => <<"no-cache">>,
        <<"connection">> => <<"keep-alive">>
    }).

cors_headers() ->
    #{<<"access-control-allow-origin">> => <<"*">>,
      <<"access-control-allow-methods">> => <<"GET, POST, PUT, PATCH, DELETE, OPTIONS">>,
      <<"access-control-allow-headers">> => <<"*">>}.
