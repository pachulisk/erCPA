-module(responses_handler).

%% Cowboy handler for POST /v1/responses (HTTP, non-WebSocket)
%% Supports both streaming (SSE) and non-streaming modes

-export([init/2]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> -> handle_post(Req0, State);
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
                {ok, _} ->
                    handle_authenticated(Req0, State)
            end
    end.

handle_authenticated(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case jiffy:decode(Body, [return_maps]) of
        Request when is_map(Request) ->
            Model = maps:get(<<"model">>, Request, <<>>),
            Stream = maps:get(<<"stream">>, Request, true),
            case Model of
                <<>> -> reply_error(Req1, 400, <<"model is required">>, State);
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
    case conductor:execute(openai_response, Model, Request) of
        {ok, Response} ->
            Req = cowboy_req:reply(200, json_headers(),
                jiffy:encode(Response), Req0),
            {ok, Req, State};
        {error, Status, ErrBody} ->
            Req = cowboy_req:reply(Status, json_headers(), ensure_json_error(Status, ErrBody), Req0),
            {ok, Req, State}
    end.

handle_stream(Model, Request, Req0, State) ->
    case conductor:execute(openai_response, Model, Request#{<<"stream">> => true}) of
        {ok, Response} ->
            %% Wrap non-stream response in SSE events
            Headers = sse_headers(),
            Req1 = cowboy_req:stream_reply(200, Headers, Req0),
            CreatedEvent = #{
                <<"type">> => <<"response.created">>,
                <<"sequence_number">> => 0,
                <<"response">> => Response#{<<"status">> => <<"completed">>}
            },
            CompletedEvent = #{
                <<"type">> => <<"response.completed">>,
                <<"sequence_number">> => 1,
                <<"response">> => Response
            },
            cowboy_req:stream_body(iolist_to_binary(sse_parser:format_event(CreatedEvent)), nofin, Req1),
            cowboy_req:stream_body(iolist_to_binary(sse_parser:format_event(CompletedEvent)), nofin, Req1),
            cowboy_req:stream_body(sse_parser:format_done(), fin, Req1),
            {ok, Req1, State};
        {error, Status, ErrBody} ->
            Req = cowboy_req:reply(Status, json_headers(), ensure_json_error(Status, ErrBody), Req0),
            {ok, Req, State}
    end.

%%====================================================================
%% Internal
%%====================================================================

reply_error(Req0, Status, Message, State) ->
    Req = cowboy_req:reply(Status, json_headers(),
        jiffy:encode(#{<<"error">> => #{
            <<"message">> => Message,
            <<"type">> => <<"invalid_request_error">>
        }}), Req0),
    {ok, Req, State}.

ensure_json_error(Status, Body) when is_binary(Body) ->
    try jiffy:decode(Body, [return_maps]) of
        M when is_map(M) -> Body;
        _ -> wrap_error(Status, Body)
    catch _:_ ->
        wrap_error(Status, Body)
    end.

wrap_error(Status, Body) ->
    jiffy:encode(#{<<"error">> => #{<<"message">> => Body,
                                     <<"type">> => error_type(Status)}}).

error_type(400) -> <<"invalid_request_error">>;
error_type(401) -> <<"invalid_api_key">>;
error_type(429) -> <<"rate_limit_exceeded">>;
error_type(_) -> <<"internal_server_error">>.

json_headers() ->
    maps:merge(cors_headers(), #{<<"content-type">> => <<"application/json">>}).

sse_headers() ->
    maps:merge(cors_headers(), #{
        <<"content-type">> => <<"text/event-stream">>,
        <<"cache-control">> => <<"no-cache">>
    }).

cors_headers() ->
    #{<<"access-control-allow-origin">> => <<"*">>,
      <<"access-control-allow-methods">> => <<"POST, OPTIONS">>,
      <<"access-control-allow-headers">> => <<"*">>}.
