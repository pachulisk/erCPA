-module(gemini_cli_handler).

%% Cowboy handler for POST /v1internal:method
%% Routes through conductor for Gemini CLI format requests

-export([init/2]).

init(Req0, State) ->
    %% Validate path starts with "v1internal:"
    PathSegment = cowboy_req:binding(gemini_cli_path, Req0, <<>>),
    case PathSegment of
        <<"v1internal:", _Method/binary>> ->
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
            end;
        _ ->
            %% Not a v1internal: path — return 404
            Req = cowboy_req:reply(404, #{}, <<"Not Found">>, Req0),
            {ok, Req, State}
    end.

handle_post(Req0, State) ->
    {IP, _Port} = cowboy_req:peer(Req0),
    case rate_limiter:check(IP) of
        {error, rate_limited} ->
            reply_error(Req0, 429, <<"Rate limit exceeded">>, State);
        ok ->
            case access_control:authenticate(Req0) of
                {error, _} ->
                    reply_error(Req0, 401, <<"Invalid API key">>, State);
                {ok, _} ->
                    handle_authenticated(Req0, State)
            end
    end.

handle_authenticated(Req0, State) ->
    {ok, RawBody, Req1} = cowboy_req:read_body(Req0),
    case jiffy:decode(RawBody, [return_maps]) of
        Request when is_map(Request) ->
            Model = maps:get(<<"model">>, Request, <<>>),
            ResolvedModel = model_registry:resolve_alias(Model),
            Stream = maps:get(<<"stream">>, Request, false),
            GeminiReq = Request#{<<"model">> => ResolvedModel,
                                  <<"stream">> => Stream},
            case Stream of
                true -> handle_stream(ResolvedModel, GeminiReq, Req1, State);
                false -> handle_nonstream(ResolvedModel, GeminiReq, Req1, State)
            end;
        _ ->
            reply_error(Req1, 400, <<"Invalid JSON body">>, State)
    end.

handle_nonstream(Model, Request, Req0, State) ->
    case conductor:execute(gemini_cli, Model, Request) of
        {ok, Response} ->
            reply_json(200, Response, Req0, State);
        {error, Status, ErrBody} ->
            Req = cowboy_req:reply(Status, json_headers(), ErrBody, Req0),
            {ok, Req, State}
    end.

handle_stream(Model, Request, Req0, State) ->
    case conductor:execute(gemini_cli, Model, Request#{<<"stream">> => true}) of
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

%%====================================================================
%% Internal
%%====================================================================

reply_json(Status, Body, Req0, State) ->
    Req = cowboy_req:reply(Status, json_headers(), jiffy:encode(Body), Req0),
    {ok, Req, State}.

reply_error(Req0, Status, Message, State) ->
    Req = cowboy_req:reply(Status, json_headers(),
        jiffy:encode(#{<<"error">> => #{
            <<"code">> => Status,
            <<"message">> => Message,
            <<"status">> => error_status(Status)
        }}), Req0),
    {ok, Req, State}.

-dialyzer({nowarn_function, [error_status/1]}).

error_status(400) -> <<"INVALID_ARGUMENT">>;
error_status(401) -> <<"UNAUTHENTICATED">>;
error_status(429) -> <<"RESOURCE_EXHAUSTED">>;
error_status(_) -> <<"INTERNAL">>.

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
      <<"access-control-allow-methods">> => <<"GET, POST, OPTIONS">>,
      <<"access-control-allow-headers">> => <<"*">>}.
