-module(health_handler).

-export([init/2]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"HEAD">> ->
            Req = cowboy_req:reply(200,
                #{<<"content-type">> => <<"text/plain">>},
                <<>>, Req0),
            {ok, Req, State};
        _ ->
            Req = cowboy_req:reply(200,
                #{<<"content-type">> => <<"text/plain">>},
                <<"ok">>, Req0),
            {ok, Req, State}
    end.
