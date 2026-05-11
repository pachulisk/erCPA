-module(cli_proxy_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% Start supervision tree first
    {ok, Pid} = cli_proxy_sup:start_link(),

    %% Register translators after registry is up
    register_translators(),

    %% Load existing credentials from auth directory
    load_existing_credentials(),

    %% Start Cowboy HTTP listener
    Port = application:get_env(cli_proxy, port, 8317),
    Dispatch = cowboy_router:compile([
        {'_', [
            %% Health
            {"/healthz", health_handler, []},

            %% OpenAI compatible
            {"/v1/chat/completions", openai_handler, []},
            {"/v1/models", models_handler, []},

            %% Responses API
            {"/v1/responses", responses_handler, []},
            {"/v1/responses/compact", responses_compact_handler, []},

            %% Responses API WebSocket (upgrade)
            {"/v1/ws/responses", responses_ws_handler, []},

            %% Codex direct aliases
            {"/backend-api/codex/responses", responses_handler, []},
            {"/backend-api/codex/responses/compact", responses_compact_handler, []},

            %% Management API
            {"/v0/management/[...]", management_handler, []},

            %% OAuth callbacks
            {"/anthropic/callback", oauth_callback_handler, []},
            {"/codex/callback", oauth_callback_handler, []},
            {"/google/callback", oauth_callback_handler, []},
            {"/antigravity/callback", oauth_callback_handler, []}
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
    translator_gemini_openai:register(),
    translator_gemini_claude:register(),
    translator_claude_gemini:register(),
    translator_codex_claude:register(),
    translator_codex_openai:register(),
    translator_openai_responses_claude:register().

load_existing_credentials() ->
    case file_store:load_all() of
        {ok, Creds} ->
            lists:foreach(fun(#{id := Id, provider := Provider, metadata := Meta} = C) ->
                case maps:get(disabled, C, false) of
                    true -> ok;
                    false ->
                        credential_sup:start_credential(#{
                            id => Id,
                            provider => Provider,
                            metadata => Meta
                        })
                end
            end, Creds);
        {error, _} ->
            ok
    end.
