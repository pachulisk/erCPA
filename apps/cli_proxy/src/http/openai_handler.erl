-module(openai_handler).

%% Cowboy handler for POST /v1/chat/completions
%% Routes through conductor for credential selection + translation + execution

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
            Req = cowboy_req:reply(429, json_headers(),
                jiffy:encode(#{<<"error">> => #{
                    <<"message">> => <<"Rate limit exceeded">>,
                    <<"type">> => <<"rate_limit_exceeded">>
                }}), Req0),
            {ok, Req, State};
        ok ->
            case access_control:authenticate(Req0) of
                {error, _} ->
                    Req = cowboy_req:reply(401, json_headers(),
                        jiffy:encode(#{<<"error">> => #{
                            <<"message">> => <<"Invalid API key">>,
                            <<"type">> => <<"invalid_api_key">>
                        }}), Req0),
                    {ok, Req, State};
                {ok, _Principal} ->
                    handle_authenticated(Req0, State)
            end
    end.

handle_authenticated(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case jiffy:decode(Body, [return_maps]) of
        Request when is_map(Request) ->
            Model = maps:get(<<"model">>, Request, <<>>),
            Stream = maps:get(<<"stream">>, Request, false),
            case Model of
                <<>> ->
                    reply_error(Req1, 400, <<"model is required">>, State);
                _ ->
                    case Stream of
                        true -> handle_stream(Model, Request, Req1, State);
                        false -> handle_nonstream(Model, Request, Req1, State)
                    end
            end;
        _ ->
            reply_error(Req1, 400, <<"Invalid JSON body">>, State)
    end.

handle_nonstream(Model, Request, Req0, State) ->
    case conductor:execute(openai, Model, Request) of
        {ok, Response} ->
            Req = cowboy_req:reply(200, json_headers(),
                jiffy:encode(Response), Req0),
            {ok, Req, State};
        {error, Status, ErrBody} when is_binary(ErrBody) ->
            %% Try to pass through upstream error
            Req = cowboy_req:reply(Status, json_headers(), ErrBody, Req0),
            {ok, Req, State};
        {error, Status, ErrMsg} ->
            reply_error(Req0, Status, ErrMsg, State)
    end.

handle_stream(Model, Request, Req0, State) ->
    %% For streaming, we start SSE response then forward chunks
    case conductor:execute(openai, Model, Request#{<<"stream">> => true}) of
        {ok, Response} ->
            %% Got a non-stream response despite asking for stream
            %% Wrap it in SSE format
            Headers = sse_headers(),
            Req1 = cowboy_req:stream_reply(200, Headers, Req0),
            Chunk = Response,
            cowboy_req:stream_body(
                iolist_to_binary(sse_parser:format_event(Chunk)), nofin, Req1),
            cowboy_req:stream_body(sse_parser:format_done(), fin, Req1),
            {ok, Req1, State};
        {ok, stream, _StreamPid} ->
            Headers = sse_headers(),
            Req1 = cowboy_req:stream_reply(200, Headers, Req0),
            stream_forward_loop(Req1),
            {ok, Req1, State};
        {error, Status, ErrBody} when is_binary(ErrBody) ->
            Req = cowboy_req:reply(Status, json_headers(), ErrBody, Req0),
            {ok, Req, State};
        {error, Status, ErrMsg} ->
            reply_error(Req0, Status, ErrMsg, State)
    end.

%%====================================================================
%% Internal
%%====================================================================

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

reply_error(Req0, Status, Message, State) ->
    ErrType = case Status of
        400 -> <<"invalid_request_error">>;
        401 -> <<"invalid_api_key">>;
        404 -> <<"model_not_found">>;
        429 -> <<"rate_limit_exceeded">>;
        _ -> <<"internal_server_error">>
    end,
    Req = cowboy_req:reply(Status, json_headers(),
        jiffy:encode(#{<<"error">> => #{
            <<"message">> => Message,
            <<"type">> => ErrType
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
    #{
        <<"access-control-allow-origin">> => <<"*">>,
        <<"access-control-allow-methods">> => <<"GET, POST, PUT, PATCH, DELETE, OPTIONS">>,
        <<"access-control-allow-headers">> => <<"*">>
    }.
