-module(responses_compact_handler).

%% POST /v1/responses/compact — non-streaming single JSON response

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
    case access_control:authenticate(Req0) of
        {error, _} ->
            Req = cowboy_req:reply(401, json_headers(),
                jiffy:encode(#{<<"error">> => #{<<"message">> => <<"Unauthorized">>}}), Req0),
            {ok, Req, State};
        {ok, _} ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            case jiffy:decode(Body, [return_maps]) of
                Request when is_map(Request) ->
                    Model = maps:get(<<"model">>, Request, <<>>),
                    case conductor:execute(openai_response, Model,
                                           Request#{<<"stream">> => false}) of
                        {ok, Response} ->
                            Req = cowboy_req:reply(200, json_headers(),
                                jiffy:encode(Response), Req1),
                            {ok, Req, State};
                        {error, Status, ErrBody} ->
                            Req = cowboy_req:reply(Status, json_headers(), ErrBody, Req1),
                            {ok, Req, State}
                    end;
                _ ->
                    Req = cowboy_req:reply(400, json_headers(),
                        jiffy:encode(#{<<"error">> => #{<<"message">> => <<"Invalid JSON">>}}), Req1),
                    {ok, Req, State}
            end
    end.

json_headers() ->
    maps:merge(cors_headers(), #{<<"content-type">> => <<"application/json">>}).

cors_headers() ->
    #{<<"access-control-allow-origin">> => <<"*">>,
      <<"access-control-allow-methods">> => <<"POST, OPTIONS">>,
      <<"access-control-allow-headers">> => <<"*">>}.
