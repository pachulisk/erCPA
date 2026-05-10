-module(cli_proxy_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    cli_proxy_sup:start_link().

stop(_State) ->
    ok.
