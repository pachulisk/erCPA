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

            %% Legacy completions + token counting
            {"/v1/completions", completions_handler, []},
            {"/v1/messages/count_tokens", count_tokens_handler, []},

            %% Image generation
            {"/v1/images/generations", images_handler, []},
            {"/v1/images/edits", images_handler, []},

            %% Responses API
            {"/v1/responses", responses_handler, []},
            {"/v1/responses/compact", responses_compact_handler, []},

            %% Responses API WebSocket (upgrade)
            {"/v1/ws/responses", responses_ws_handler, []},

            %% WebSocket relay (provider proxy)
            {"/v1/ws", ws_relay_handler, []},

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
    {ok, _} = start_listener(Port, Dispatch),

    {ok, Pid}.

stop(_State) ->
    _ = cowboy:stop_listener(http_listener),
    _ = cowboy:stop_listener(https_listener),
    ok.

%% ====================================================================
%% Internal
%% ====================================================================

start_listener(Port, Dispatch) ->
    case application:get_env(cli_proxy, tls_enable, false) of
        true ->
            CertFile = application:get_env(cli_proxy, tls_cert, ""),
            KeyFile = application:get_env(cli_proxy, tls_key, ""),
            cowboy:start_tls(https_listener,
                [{port, Port},
                 {certfile, CertFile},
                 {keyfile, KeyFile}],
                #{env => #{dispatch => Dispatch}});
        false ->
            cowboy:start_clear(http_listener,
                [{port, Port}],
                #{env => #{dispatch => Dispatch}})
    end.

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
    {ok, Creds} = file_store:load_all(),
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
    end, Creds),
    %% Synthesize credentials from config API key lists
    auth_synthesizer:synthesize().
