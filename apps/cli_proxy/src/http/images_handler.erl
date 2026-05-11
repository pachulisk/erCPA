-module(images_handler).

%% Cowboy handler for POST /v1/images/generations and /v1/images/edits
%% Proxies image generation requests to capable providers (Codex/OpenAI)

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
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case jiffy:decode(Body, [return_maps]) of
        Request when is_map(Request) ->
            Model = maps:get(<<"model">>, Request, <<"dall-e-3">>),
            %% Route to codex executor (OpenAI compatible)
            case conductor:execute(openai, Model, Request) of
                {ok, Response} ->
                    Req = cowboy_req:reply(200, json_headers(),
                        jiffy:encode(Response), Req1),
                    {ok, Req, State};
                {error, Status, ErrBody} when is_binary(ErrBody) ->
                    Req = cowboy_req:reply(Status, json_headers(), ErrBody, Req1),
                    {ok, Req, State};
                {error, Status, ErrMsg} ->
                    reply_error(Req1, Status, ErrMsg, State)
            end;
        _ ->
            reply_error(Req1, 400, <<"Invalid JSON body">>, State)
    end.

reply_error(Req0, Status, Message, State) ->
    Req = cowboy_req:reply(Status, json_headers(),
        jiffy:encode(#{<<"error">> => #{
            <<"message">> => Message,
            <<"type">> => <<"invalid_request_error">>
        }}), Req0),
    {ok, Req, State}.

json_headers() ->
    maps:merge(cors_headers(), #{<<"content-type">> => <<"application/json">>}).

cors_headers() ->
    #{<<"access-control-allow-origin">> => <<"*">>,
      <<"access-control-allow-methods">> => <<"GET, POST, OPTIONS">>,
      <<"access-control-allow-headers">> => <<"*">>}.
