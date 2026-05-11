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

    ClipsEngine = #{
        id => clips_engine,
        start => {clips_engine, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [clips_engine]
    },

    Executors = [#{
        id => Mod,
        start => {Mod, start_link, [#{}]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [Mod]
    } || Mod <- [claude_executor, openai_compat_executor, gemini_executor,
                 codex_executor, vertex_executor, aistudio_executor,
                 antigravity_executor, kimi_executor]],

    ConfigWatcher = #{
        id => config_watcher,
        start => {config_watcher, start_link, [auth_dir()]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [config_watcher]
    },

    RateLimiter = #{
        id => rate_limiter,
        start => {rate_limiter, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [rate_limiter]
    },

    UsageQueue = #{
        id => usage_queue,
        start => {usage_queue, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [usage_queue]
    },

    RequestLogger = #{
        id => request_logger,
        start => {request_logger, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [request_logger]
    },

    ChildSpecs = [
        ConfigLoader,
        SignatureCache,
        TranslatorRegistry,
        RateLimiter,
        UsageQueue,
        RequestLogger,
        ClipsEngine,
        ModelRegistry
    ] ++ Executors ++ [
        CredentialSup,
        Conductor,
        ConfigWatcher
    ],

    {ok, {SupFlags, ChildSpecs}}.

%%====================================================================
%% Internal
%%====================================================================

load_initial_config() ->
    %% Load from application env (sys.config)
    Env = application:get_all_env(cli_proxy),
    maps:from_list(Env).

auth_dir() ->
    Dir = application:get_env(cli_proxy, auth_dir, "~/.cli-proxy-api/"),
    expand_home(Dir).

expand_home("~/" ++ Rest) ->
    Home = os:getenv("HOME", "/tmp"),
    filename:join(Home, Rest);
expand_home(Path) ->
    Path.
