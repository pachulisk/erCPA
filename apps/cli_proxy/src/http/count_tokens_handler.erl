-module(count_tokens_handler).

%% Cowboy handler for POST /v1/messages/count_tokens
%% Proxies token counting requests to Claude API

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
                jiffy:encode(#{<<"error">> => #{
                    <<"message">> => <<"Invalid API key">>,
                    <<"type">> => <<"invalid_api_key">>
                }}), Req0),
            {ok, Req, State};
        {ok, _} ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            Request = jiffy:decode(Body, [return_maps]),
            Model = maps:get(<<"model">>, Request, <<>>),
            case conductor:execute(claude, Model, Request) of
                {ok, Response} ->
                    Req = cowboy_req:reply(200, json_headers(),
                        jiffy:encode(Response), Req1),
                    {ok, Req, State};
                {error, Status, ErrBody} when is_binary(ErrBody) ->
                    Req = cowboy_req:reply(Status, json_headers(), ErrBody, Req1),
                    {ok, Req, State};
                {error, Status, ErrMsg} ->
                    Req = cowboy_req:reply(Status, json_headers(),
                        jiffy:encode(#{<<"error">> => #{<<"message">> => ErrMsg}}), Req1),
                    {ok, Req, State}
            end
    end.

json_headers() ->
    maps:merge(cors_headers(), #{<<"content-type">> => <<"application/json">>}).

cors_headers() ->
    #{<<"access-control-allow-origin">> => <<"*">>,
      <<"access-control-allow-methods">> => <<"GET, POST, OPTIONS">>,
      <<"access-control-allow-headers">> => <<"*">>}.
