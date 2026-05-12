-module(keepalive_handler).

%% Simple keepalive endpoint: returns {"status": "ok"} with 200

-export([init/2]).

init(Req0, State) ->
    Req = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>,
          <<"access-control-allow-origin">> => <<"*">>},
        <<"{\"status\":\"ok\"}">>, Req0),
    {ok, Req, State}.
