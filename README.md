# erCPA — Erlang CLI Proxy API

An Erlang/OTP reimplementation of CLIProxyAPI, providing a unified OpenAI-compatible gateway that routes requests across multiple LLM providers (Claude, Gemini, Codex, Vertex AI, Kimi, etc.) with automatic credential management, intelligent retry, and rule-based request orchestration via CLIPS.

## Why Erlang + CLIPS

- **CLIPS rule engine** replaces thousands of lines of imperative credential selection logic with ~200 declarative rules
- **OTP supervision trees** provide fault isolation, automatic restart, and per-connection lightweight processes
- **Erlang distribution** enables satellite-home topology without external coordination (Redis, etc.)
- **Hot code reload** for config changes without dropping connections

## Features

- OpenAI Chat Completions API (`/v1/chat/completions`)
- OpenAI Responses API (`/v1/responses`, `/v1/responses/compact`)
- WebSocket streaming (`/v1/ws/responses`)
- Codex-compatible endpoints (`/backend-api/codex/responses`)
- Multi-provider translation (Claude <-> OpenAI <-> Gemini <-> Codex)
- OAuth login flows (Claude, Codex, Google, Kimi, Antigravity)
- Vertex AI service account import
- CLIPS-based credential selection with cooldown and quota awareness
- Extended thinking / reasoning support
- SSE streaming with keepalive
- Request logging and usage tracking
- File-based auth store with hot-reload via `fs` watcher
- Health endpoint (`/healthz`)
- Management API (`/v0/management/`)

## Requirements

- Erlang/OTP 27+
- rebar3
- (Optional) CLIPS 6.4 library — for rule-based credential selection

## Quick Start

```bash
# Compile
rebar3 compile

# Run in shell mode
rebar3 shell

# Run tests (313 tests)
rebar3 eunit

# Build production release
rebar3 as prod release
```

The server starts on port **8317** by default.

## Configuration

### `config/sys.config`

```erlang
[
    {cli_proxy, [
        {host, "0.0.0.0"},
        {port, 8317},
        {auth_dir, "~/.cli-proxy-api/"},
        {debug, false},
        {request_retry, 3},
        {max_retry_credentials, 0},
        {max_retry_interval, 0}
    ]}
].
```

### CLI Flags

```
--login <provider>     OAuth login (claude | codex | google | kimi | antigravity)
--port <port>          Override listen port
--config <path>        Custom config file path
--password <pw>        Access password
--home <node>          Connect to home node (satellite mode)
--callback-port <port> OAuth callback port
--no-browser           Skip auto-opening browser for OAuth
--vertex-import <file> Import Vertex AI service account JSON
--local-models         Enable local model routing
```

## Docker

```bash
# Build and run
docker compose up -d

# Exposed ports:
#   8317  — Main API
#   8085  — (reserved)
#   1455  — (reserved)
#   54545 — (reserved)
```

## Architecture

```
cli_proxy_app (application)
       │
cli_proxy_sup (one_for_one)
  ├── config_loader        — Hot-reloading config from sys.config + file watchers
  ├── signature_cache      — Deduplication cache for request signatures
  ├── translator_registry  — Maps (source_format, target_format) -> translator module
  ├── model_registry       — Model name -> provider + capabilities mapping
  ├── credential_sup       — Dynamic supervisor for per-credential processes
  └── conductor            — Request orchestration: select credential -> translate -> execute -> retry
```

### Key Modules

| Module | Purpose |
|--------|---------|
| `conductor` | Orchestrates credential selection, translation, execution, retry |
| `clips_engine` | CLIPS port interface (gen_server wrapping external C process) |
| `translator_*` | Bidirectional format translators (OpenAI<->Claude, etc.) |
| `*_executor` | Provider-specific HTTP execution (Claude, Gemini, Codex, Vertex, Kimi) |
| `oauth_session` | OAuth flow state machine |
| `config_watcher` | File-system watcher for credential/config hot-reload |
| `home_client` | Erlang distribution client for satellite-home topology |

### Request Flow

```
Client (OpenAI format)
  │
  ▼
openai_handler / responses_handler
  │
  ▼
conductor:execute/4
  ├── clips_engine: select credential (rule-based)
  ├── translator: source_format -> target_format
  ├── *_executor: HTTP call to upstream provider
  └── (retry on failure with next credential)
  │
  ▼
Response (translated back to source format)
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/v1/chat/completions` | OpenAI Chat Completions |
| POST | `/v1/responses` | Responses API |
| POST | `/v1/responses/compact` | Responses API (compact format) |
| WS | `/v1/ws/responses` | WebSocket streaming |
| GET | `/v1/models` | List available models |
| GET | `/healthz` | Health check |
| * | `/v0/management/[...]` | Management API |
| POST | `/backend-api/codex/responses` | Codex-compatible alias |

## Testing

```bash
# All tests
rebar3 eunit

# With coverage
rebar3 eunit --cover
rebar3 cover

# Specific test module
rebar3 eunit --module=conductor_tests
```

## Project Structure

```
apps/
├── cli_proxy/
│   ├── src/
│   │   ├── access/        — Access control & auth
│   │   ├── amp/           — AMP protocol support
│   │   ├── cache/         — Signature cache
│   │   ├── conductor/     — Credential selection & CLIPS
│   │   ├── config/        — Config loader & file watcher
│   │   ├── executor/      — Provider HTTP executors
│   │   ├── home/          — Home node client
│   │   ├── http/          — Cowboy HTTP handlers
│   │   ├── logging/       — Usage & request logging
│   │   ├── oauth/         — OAuth flows per provider
│   │   ├── registry/      — Model registry
│   │   ├── rules/         — Payload validation rules
│   │   ├── store/         — Auth token persistence
│   │   ├── translator/    — Format translators
│   │   └── util/          — SSE parser, browser, keepalive
│   └── test/              — EUnit tests (313 tests)
└── clips_port/            — C port program for CLIPS engine
config/
├── sys.config             — Application config
└── vm.args                — BEAM VM flags
```

## License

Private.
