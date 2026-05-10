-module(cli_proxy_sup).
-behaviour(supervisor).

%% Root supervisor
%% Tree: cli_proxy_sup (one_for_one)
%%   ├── config_loader
%%   ├── signature_cache
%%   ├── translator_registry
%%   ├── credential_sup (simple_one_for_one)
%%   └── http_sup (to be added when cowboy routes are wired)

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },

    ConfigLoader = #{
        id => config_loader,
        start => {config_loader, start_link, [load_initial_config()]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [config_loader]
    },

    SignatureCache = #{
        id => signature_cache,
        start => {signature_cache, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [signature_cache]
    },

    TranslatorRegistry = #{
        id => translator_registry,
        start => {translator_registry, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [translator_registry]
    },

    CredentialSup = #{
        id => credential_sup,
        start => {credential_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [credential_sup]
    },

    ModelRegistry = #{
        id => model_registry,
        start => {model_registry, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [model_registry]
    },

    Conductor = #{
        id => conductor,
        start => {conductor, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [conductor]
    },

    ChildSpecs = [
        ConfigLoader,
        SignatureCache,
        TranslatorRegistry,
        ModelRegistry,
        CredentialSup,
        Conductor
    ],

    {ok, {SupFlags, ChildSpecs}}.

%%====================================================================
%% Internal
%%====================================================================

load_initial_config() ->
    %% Load from application env (sys.config)
    Env = application:get_all_env(cli_proxy),
    maps:from_list(Env).
