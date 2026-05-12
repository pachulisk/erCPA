-module(gemini_native_handler).

%% Cowboy handler for Gemini native routes:
%%   GET  /v1beta/models          — list models (Gemini format)
%%   POST /v1beta/models/:model:generateContent
%%   POST /v1beta/models/:model:streamGenerateContent
%%
%% Routes are matched via /v1beta/models/[...] in cowboy router

-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    case Method of
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, cors_headers(), Req0),
            {ok, Req, State};
        _ ->
            handle(Method, Req0, State)
    end.

handle(<<"GET">>, Req0, State) ->
    %% GET /v1beta/models — list models in Gemini format
    {IP, _Port} = cowboy_req:peer(Req0),
    case rate_limiter:check(IP) of
        {error, rate_limited} ->
            reply_error(Req0, 429, <<"Rate limit exceeded">>, State);
        ok ->
            case access_control:authenticate(Req0) of
                {error, _} ->
                    reply_error(Req0, 401, <<"Invalid API key">>, State);
                {ok, _} ->
                    Models = model_registry:get_available_models(gemini),
                    GeminiModels = [format_gemini_model(M) || M <- Models],
                    reply_json(200, #{<<"models">> => GeminiModels}, Req0, State)
            end
    end;

handle(<<"POST">>, Req0, State) ->
    %% POST /v1beta/models/:model:action
    {IP, _Port} = cowboy_req:peer(Req0),
    case rate_limiter:check(IP) of
        {error, rate_limited} ->
            reply_error(Req0, 429, <<"Rate limit exceeded">>, State);
        ok ->
            case access_control:authenticate(Req0) of
                {error, _} ->
                    reply_error(Req0, 401, <<"Invalid API key">>, State);
                {ok, _} ->
                    handle_generate(Req0, State)
            end
    end;

handle(_, Req0, State) ->
    Req = cowboy_req:reply(405, #{}, <<"Method Not Allowed">>, Req0),
    {ok, Req, State}.

handle_generate(Req0, State) ->
    Path = cowboy_req:path(Req0),
    case parse_model_action(Path) of
        {ok, Model, Action} ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            Request = jiffy:decode(Body, [return_maps]),
            ResolvedModel = model_registry:resolve_alias(Model),
            Stream = Action =:= <<"streamGenerateContent">>,
            %% Build request in Gemini format, conductor handles translation
            GeminiReq = Request#{<<"model">> => ResolvedModel,
                                  <<"stream">> => Stream},
            case Stream of
                false ->
                    handle_nonstream(ResolvedModel, GeminiReq, Req1, State);
                true ->
                    handle_stream(ResolvedModel, GeminiReq, Req1, State)
            end;
        error ->
            reply_error(Req0, 400, <<"Invalid model/action path">>, State)
    end.

handle_nonstream(Model, Request, Req0, State) ->
    case conductor:execute(gemini, Model, Request) of
        {ok, Response} ->
            reply_json(200, Response, Req0, State);
        {error, Status, ErrBody} ->
            Req = cowboy_req:reply(Status, json_headers(), ErrBody, Req0),
            {ok, Req, State}
    end.

handle_stream(Model, Request, Req0, State) ->
    case conductor:execute(gemini, Model, Request#{<<"stream">> => true}) of
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

parse_model_action(Path) ->
    %% Path: /v1beta/models/gemini-pro:generateContent
    case binary:split(Path, <<"/v1beta/models/">>) of
        [<<>>, Rest] ->
            %% Rest = "gemini-pro:generateContent"
            case binary:split(Rest, <<":">>) of
                [Model, Action] when Model =/= <<>>, Action =/= <<>> ->
                    {ok, Model, Action};
                [_ModelOnly] ->
                    %% No action — likely just GET /v1beta/models/modelname
                    error
            end;
        _ -> error
    end.

format_gemini_model(#{<<"id">> := Id} = M) ->
    #{<<"name">> => <<"models/", Id/binary>>,
      <<"version">> => <<"1">>,
      <<"displayName">> => maps:get(<<"display_name">>, M, Id),
      <<"supportedGenerationMethods">> => [<<"generateContent">>, <<"streamGenerateContent">>]}.

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
