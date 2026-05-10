%% Configuration record definitions for cli_proxy
%% Based on DESIGN.md Configuration section

-record(tls_config, {
    enable = false :: boolean(),
    cert :: binary() | undefined,
    key :: binary() | undefined
}).

-record(home_config, {
    enabled = false :: boolean(),
    node :: atom() | undefined
}).

-record(remote_mgmt_config, {
    allow_remote = false :: boolean(),
    secret_key :: binary() | undefined,
    disable_control_panel = false :: boolean(),
    disable_auto_update_panel = false :: boolean(),
    panel_github_repository = <<"https://github.com/router-for-me/Cli-Proxy-API-Management-Center">> :: binary()
}).

-record(quota_exceeded_config, {
    switch_project = false :: boolean(),
    switch_preview_model = false :: boolean(),
    antigravity_credits = false :: boolean()
}).

-record(routing_config, {
    strategy = <<"round-robin">> :: binary(),  %% <<"round-robin">> | <<"fill-first">>
    session_affinity = false :: boolean(),
    session_affinity_ttl = <<"1h">> :: binary()
}).

-record(gemini_key, {
    api_key :: binary(),
    priority = 0 :: integer(),
    prefix = <<>> :: binary(),
    base_url :: binary() | undefined,
    proxy_url :: binary() | undefined,
    models = [] :: [map()],
    headers = #{} :: map(),
    excluded_models = [] :: [binary()],
    disable_cooling = false :: boolean()
}).

-record(claude_key, {
    api_key :: binary(),
    priority = 0 :: integer(),
    prefix = <<>> :: binary(),
    base_url :: binary() | undefined,
    proxy_url :: binary() | undefined,
    models = [] :: [map()],
    headers = #{} :: map(),
    excluded_models = [] :: [binary()],
    disable_cooling = false :: boolean()
}).

-record(codex_key, {
    api_key :: binary(),
    priority = 0 :: integer(),
    prefix = <<>> :: binary(),
    base_url :: binary() | undefined,
    websockets = false :: boolean(),
    proxy_url :: binary() | undefined,
    models = [] :: [map()],
    headers = #{} :: map(),
    excluded_models = [] :: [binary()],
    disable_cooling = false :: boolean()
}).

-record(openai_compat, {
    api_key :: binary(),
    priority = 0 :: integer(),
    prefix = <<>> :: binary(),
    base_url :: binary(),
    proxy_url :: binary() | undefined,
    models = [] :: [map()],
    headers = #{} :: map(),
    excluded_models = [] :: [binary()],
    disable_cooling = false :: boolean()
}).

-record(vertex_key, {
    service_account :: map(),
    project_id :: binary(),
    email :: binary() | undefined,
    location :: binary() | undefined,
    prefix = <<>> :: binary()
}).

-record(ampcode_config, {
    upstream_url :: binary() | undefined,
    upstream_api_key :: binary() | undefined,
    upstream_api_keys = [] :: [map()],
    restrict_management_to_localhost = false :: boolean(),
    model_mappings = [] :: [map()],
    force_model_mappings = false :: boolean()
}).

-record(payload_rule, {
    models = [] :: [map()],
    params = #{} :: map()
}).

-record(payload_filter_rule, {
    models = [] :: [map()],
    params = [] :: [binary()]
}).

-record(payload_config, {
    default = [] :: [#payload_rule{}],
    default_raw = [] :: [#payload_rule{}],
    override = [] :: [#payload_rule{}],
    override_raw = [] :: [#payload_rule{}],
    filter = [] :: [#payload_filter_rule{}]
}).

-record(config, {
    %% Network
    host = "0.0.0.0" :: string(),
    port :: pos_integer(),
    tls :: #tls_config{} | undefined,

    %% Home control plane
    home :: #home_config{} | undefined,

    %% Remote management
    remote_management = #remote_mgmt_config{} :: #remote_mgmt_config{},

    %% Auth
    auth_dir = "~/.cli-proxy-api/" :: string(),

    %% Debug & logging
    debug = false :: boolean(),
    logging_to_file = false :: boolean(),
    logs_max_total_size_mb = 0 :: non_neg_integer(),
    error_logs_max_files = 10 :: pos_integer(),
    request_log = false :: boolean(),

    %% Usage
    usage_statistics_enabled = false :: boolean(),

    %% Retry
    request_retry = 3 :: non_neg_integer(),
    max_retry_credentials = 0 :: non_neg_integer(),
    max_retry_interval = 0 :: non_neg_integer(),

    %% Quota
    quota_exceeded = #quota_exceeded_config{} :: #quota_exceeded_config{},

    %% Routing
    routing = #routing_config{} :: #routing_config{},

    %% WebSocket
    ws_auth = false :: boolean(),

    %% Provider keys
    gemini_keys = [] :: [#gemini_key{}],
    claude_keys = [] :: [#claude_key{}],
    codex_keys = [] :: [#codex_key{}],
    openai_compat = [] :: [#openai_compat{}],
    vertex_keys = [] :: [#vertex_key{}],

    %% Model management
    oauth_excluded_models = #{} :: #{atom() => [binary()]},
    oauth_model_alias = #{} :: #{atom() => [map()]},

    %% Payload rules
    payload :: #payload_config{} | undefined,

    %% Proxy
    proxy_url :: binary() | undefined,

    %% Cooling
    disable_cooling = false :: boolean(),

    %% Image generation
    disable_image_generation = <<"off">> :: binary(),

    %% Amp CLI
    ampcode :: #ampcode_config{} | undefined,

    %% Signature cache
    antigravity_signature_cache_enabled = true :: boolean(),

    %% API keys
    api_keys = [] :: [binary()]
}).

%% Auth file record
-record(auth_file, {
    id :: binary(),
    provider :: atom(),
    filename :: binary(),
    disabled = false :: boolean(),
    metadata = #{} :: map(),
    attributes = #{} :: map(),
    created_at :: integer(),
    updated_at :: integer(),
    last_refreshed_at :: integer() | undefined
}).

%% Model info record
-record(model_info, {
    id :: binary(),
    provider :: binary(),
    display_name :: binary() | undefined,
    context_length :: integer() | undefined,
    max_completion_tokens :: integer() | undefined,
    thinking :: map() | undefined,
    user_defined = false :: boolean()
}).
