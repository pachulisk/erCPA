-module(amp_routes_handler).

%% Cowboy handler for AMP management and root proxy routes
%% Handles: /api/* (internal, user, auth, meta, telemetry, threads, etc.)
%%          /threads, /docs, /settings, /auth, RSS feeds
%% All routes proxy to upstream via amp_proxy:proxy_request/2

-export([init/2]).

init(Req0, State) ->
    case amp_config:is_enabled() of
        false ->
            Req = cowboy_req:reply(404, json_headers(),
                jiffy:encode(#{<<"error">> => <<"Amp module not enabled">>}), Req0),
            {ok, Req, State};
        true ->
            handle_proxy(Req0, State)
    end.

handle_proxy(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, cors_headers(), Req0),
            {ok, Req, State};
        _ ->
            case amp_proxy:proxy_request(Req0, State) of
                {ok, Req, NewState} ->
                    {ok, Req, NewState};
                {error, Status, Body} ->
                    Req = cowboy_req:reply(Status, json_headers(), Body, Req0),
                    {ok, Req, State}
            end
    end.

%%====================================================================
%% Internal
%%====================================================================

json_headers() ->
    maps:merge(cors_headers(), #{<<"content-type">> => <<"application/json">>}).

cors_headers() ->
    #{<<"access-control-allow-origin">> => <<"*">>,
      <<"access-control-allow-methods">> => <<"GET, POST, PUT, PATCH, DELETE, OPTIONS">>,
      <<"access-control-allow-headers">> => <<"*">>}.
