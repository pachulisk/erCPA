-module(messages_handler).

%% Cowboy handler for POST /v1/messages
%% Claude Messages API (native Anthropic format)
%% Translates to internal format via conductor and routes to appropriate provider

-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    case Method of
        <<"POST">> ->
            handle_post(Req0, State);
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, cors_headers(), Req0),
            {ok, Req, State};
        _ ->
            Req = cowboy_req:reply(405, #{}, <<"Method Not Allowed">>, Req0),
            {ok, Req, State}
    end.

handle_post(Req0, State) ->
    {IP, _Port} = cowboy_req:peer(Req0),
    case rate_limiter:check(IP) of
        {error, rate_limited} ->
            reply_error(Req0, 429, <<"rate_limit_error">>,
                        <<"Rate limit exceeded">>, State);
        ok ->
            case access_control:authenticate(Req0) of
                {error, _} ->
                    reply_error(Req0, 401, <<"authentication_error">>,
                                <<"Invalid API key">>, State);
                {ok, _Principal} ->
                    handle_authenticated(Req0, State)
            end
    end.

handle_authenticated(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case jiffy:decode(Body, [return_maps]) of
        Request when is_map(Request) ->
            RawModel = maps:get(<<"model">>, Request, <<>>),
            Model = model_registry:resolve_alias(RawModel),
            Stream = maps:get(<<"stream">>, Request, false),
            case Model of
                <<>> ->
                    reply_error(Req1, 400, <<"invalid_request_error">>,
                                <<"model is required">>, State);
                _ ->
                    Request1 = Request#{<<"model">> => Model},
                    case Stream of
                        true -> handle_stream(Model, Request1, Req1, State);
                        false -> handle_nonstream(Model, Request1, Req1, State)
                    end
            end;
        _ ->
            reply_error(Req1, 400, <<"invalid_request_error">>,
                        <<"Invalid JSON body">>, State)
    end.

handle_nonstream(Model, Request, Req0, State) ->
    case conductor:execute(claude, Model, Request) of
        {ok, Response} ->
            Req = cowboy_req:reply(200, json_headers(),
                jiffy:encode(Response), Req0),
            {ok, Req, State};
        {ok, stream, _} ->
            reply_error(Req0, 500, <<"api_error">>,
                        <<"unexpected stream response">>, State);
        {error, Status, ErrBody} ->
            Req = cowboy_req:reply(Status, json_headers(), ErrBody, Req0),
            {ok, Req, State}
    end.

handle_stream(Model, Request, Req0, State) ->
    case conductor:execute(claude, Model, Request#{<<"stream">> => true}) of
        {ok, Response} ->
            Headers = sse_headers(),
            Req1 = cowboy_req:stream_reply(200, Headers, Req0),
            cowboy_req:stream_body(
                sse_parser:format_event(Response), nofin, Req1),
            cowboy_req:stream_body(sse_parser:format_done(), fin, Req1),
            {ok, Req1, State};
        {ok, stream, _StreamPid} ->
            Headers = sse_headers(),
            Req1 = cowboy_req:stream_reply(200, Headers, Req0),
            stream_forward_loop(Req1),
            {ok, Req1, State};
        {error, Status, ErrBody} ->
            Req = cowboy_req:reply(Status, json_headers(), ErrBody, Req0),
            {ok, Req, State}
    end.

stream_forward_loop(Req) ->
    receive
        {stream_chunk, Data} ->
            cowboy_req:stream_body(Data, nofin, Req),
            stream_forward_loop(Req);
        stream_done ->
            cowboy_req:stream_body(sse_parser:format_done(), fin, Req);
        {stream_error, _Status, _Body} ->
            cowboy_req:stream_body(sse_parser:format_done(), fin, Req)
    after 120000 ->
        cowboy_req:stream_body(sse_parser:format_done(), fin, Req)
    end.

reply_error(Req0, Status, Type, Message, State) ->
    Req = cowboy_req:reply(Status, json_headers(),
        jiffy:encode(#{<<"type">> => <<"error">>,
                       <<"error">> => #{
                           <<"type">> => Type,
                           <<"message">> => Message
                       }}), Req0),
    {ok, Req, State}.

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
