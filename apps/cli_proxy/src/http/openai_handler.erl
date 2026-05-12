-module(openai_handler).

%% Cowboy handler for POST /v1/chat/completions
%% Routes through conductor for credential selection + translation + execution

-export([init/2]).

-dialyzer({nowarn_function, [reply_error/4, error_type_fallback/1]}).

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
            RawModel = maps:get(<<"model">>, Request, <<>>),
            Model = model_registry:resolve_alias(RawModel),
            Stream = maps:get(<<"stream">>, Request, false),
            case Model of
                <<>> ->
                    reply_error(Req1, 400, <<"model is required">>, State);
                _ ->
                    %% Update request with resolved model name
                    Request1 = Request#{<<"model">> => Model},
                    case Stream of
                        true -> handle_stream(Model, Request1, Req1, State);
                        false -> handle_nonstream(Model, Request1, Req1, State)
                    end
            end;
        _ ->
            reply_error(Req1, 400, <<"Invalid JSON body">>, State)
    end.

session_opts(Req) ->
    SessionId = cowboy_req:header(<<"x-session-id">>, Req, <<>>),
    ClientReqId = cowboy_req:header(<<"x-client-request-id">>, Req, <<>>),
    #{headers => #{<<"x-session-id">> => SessionId,
                   <<"x-client-request-id">> => ClientReqId}}.

handle_nonstream(Model, Request, Req0, State) ->
    case conductor:execute(openai, Model, Request, session_opts(Req0)) of
        {ok, Response} ->
            Req = cowboy_req:reply(200, json_headers(),
                jiffy:encode(Response), Req0),
            {ok, Req, State};
        {ok, stream, _} ->
            reply_error(Req0, 501, <<"unexpected stream response">>, State);
        {error, Status, ErrBody} ->
            %% Try to pass through upstream error
            Req = cowboy_req:reply(Status, json_headers(), ErrBody, Req0),
            {ok, Req, State}
    end.

handle_stream(Model, Request, Req0, State) ->
    %% For streaming, we start SSE response then forward chunks
    case conductor:execute(openai, Model, Request#{<<"stream">> => true}, session_opts(Req0)) of
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
            Acc = translator_openai_claude:init_acc(),
            stream_translate_loop(Req1, Acc),
            {ok, Req1, State};
        {error, Status, ErrBody} ->
            Req = cowboy_req:reply(Status, json_headers(), ErrBody, Req0),
            {ok, Req, State}
    end.

%%====================================================================
%% Internal
%%====================================================================

stream_translate_loop(Req, Acc) ->
    receive
        {stream_chunk, Data} ->
            Events = sse_parser:parse(Data),
            Acc1 = lists:foldl(fun(done, A) -> A;
                                  ({raw, _}, A) -> A;
                                  (Event, A) when is_map(Event) ->
                                       {Chunks, A2} = translator_openai_claude:response_stream(Event, A),
                                       lists:foreach(fun(Chunk) ->
                                           cowboy_req:stream_body(
                                               sse_parser:format_event(Chunk), nofin, Req)
                                       end, Chunks),
                                       A2;
                                  (_, A) -> A
                               end, Acc, Events),
            stream_translate_loop(Req, Acc1);
        stream_done ->
            cowboy_req:stream_body(sse_parser:format_done(), fin, Req);
        {stream_error, _Status, _Body} ->
            cowboy_req:stream_body(sse_parser:format_done(), fin, Req)
    after 120000 ->
        cowboy_req:stream_body(sse_parser:format_done(), fin, Req)
    end.

reply_error(Req0, Status, Message, State) ->
    ErrType = get_error_type(Status),
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

get_error_type(Status) ->
    case conductor:classify_status(Status) of
        #{<<"error-type">> := ET} when ET =/= <<>> -> ET;
        _ -> error_type_fallback(Status)
    end.

error_type_fallback(400) -> <<"invalid_request_error">>;
error_type_fallback(401) -> <<"invalid_api_key">>;
error_type_fallback(404) -> <<"model_not_found">>;
error_type_fallback(429) -> <<"rate_limit_exceeded">>;
error_type_fallback(_) -> <<"internal_server_error">>.
