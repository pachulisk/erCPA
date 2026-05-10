-module(cli_proxy_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% Start supervision tree first
    {ok, Pid} = cli_proxy_sup:start_link(),

    %% Register translators after registry is up
    register_translators(),

    %% Start Cowboy HTTP listener
    Port = application:get_env(cli_proxy, port, 8317),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/healthz", health_handler, []},
            {"/v1/chat/completions", openai_handler, []},
            {"/v1/models", models_handler, []}
        ]}
    ]),
    {ok, _} = cowboy:start_clear(http_listener,
        [{port, Port}],
        #{env => #{dispatch => Dispatch}}
    ),

    {ok, Pid}.

stop(_State) ->
    cowboy:stop_listener(http_listener),
    ok.

%% ====================================================================
%% Internal
%% ====================================================================

register_translators() ->
    translator_openai_claude:register(),
    translator_claude_openai:register(),
    translator_openai_gemini:register(),
    translator_gemini_claude:register().
