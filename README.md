# erCPA — Erlang CLI Proxy API

[中文文档](README_CN.md)

An Erlang/OTP reimplementation of CLIProxyAPI — a unified OpenAI-compatible gateway that routes requests across multiple LLM providers with automatic credential management, intelligent retry, and rule-based orchestration via a CLIPS expert system.

## Why Erlang + CLIPS

| Concern | Go (CLIProxyAPI) | Erlang (erCPA) |
|---------|-----------------|----------------|
| Credential selection | 4000+ lines of if/else | ~200 declarative CLIPS rules |
| Concurrency | Manual goroutine lifecycle | OTP supervision trees, per-connection processes |
| Distribution | Redis pub/sub | Native Erlang distribution |
| Hot reload | Restart required | Hot code loading + CLIPS rule reload |
| Fault isolation | Shared process crash | "Let it crash" per-process isolation |

## Features

### API Endpoints
- `/v1/chat/completions` — OpenAI Chat Completions
- `/v1/responses` / `/v1/responses/compact` — Responses API
- `/v1/ws/responses` — WebSocket streaming
- `/v1/ws` — WebSocket relay (provider proxy)
- `/v1/completions` — Legacy text completions
- `/v1/models` — Model listing
- `/v1/images/generations` / `/v1/images/edits` — Image generation
- `/v1/messages/count_tokens` — Token counting
- `/backend-api/codex/responses` — Codex-compatible alias
- `/healthz` — Health check
- `/v0/management/[...]` — 40+ management endpoints

### Providers (8 executors)
Claude (Anthropic) · Gemini (Google AI) · Codex (OpenAI) · Vertex AI · Kimi (Moonshot) · Antigravity · AI Studio · OpenAI-compatible (OpenRouter, Ollama, vLLM, etc.)

### CLIPS Rule Engine (12 rule files)
| Rule File | Purpose |
|-----------|---------|
| `selection.clp` | Credential scoring & selection |
| `cooldown.clp` | State transitions on HTTP errors |
| `status_rules.clp` | Status code → retry/cooldown/fallback + error type + auth unpin |
| `credential_policy.clp` | Per-provider cooldown duration & refresh schedule |
| `thinking.clp` | Thinking budget/level normalization |
| `quota.clp` | Quota exceeded mark & recovery |
| `routing.clp` | Model-provider matching |
| `cloaking_rules.clp` | Request cloaking policy (auto/always/never) |
| `rewrite_rules.clp` | Response rewriting (tool name normalization) |
| `client_routing.clp` | Per-client API key mapping |
| `provider_config.clp` | OAuth provider registry |
| `templates.clp` | Shared fact template definitions |

### Security
- PBKDF2-SHA256 password hashing (backward-compatible with plain text)
- Constant-time password comparison
- API key validation via ETS
- Per-IP sliding window rate limiting
- TLS/HTTPS support
- Request cloaking with zero-width character obfuscation

### Storage Backends
File (default) · PostgreSQL · Git repository · S3-compatible object storage

### Additional
- Multi-provider format translation (OpenAI ↔ Claude ↔ Gemini ↔ Codex)
- Extended thinking / reasoning with cross-format conversion
- OAuth login (Claude, Codex, Google, Kimi, Antigravity) with device code flow
- Session affinity (sticky credential routing with configurable TTL)
- Quota fallback chain (preview model → alternative credential)
- Home/satellite distributed mode via Erlang distribution
- Config hot-reload via filesystem watcher
- Auth synthesis from config API key lists
- AMP reverse proxy with Gemini bridge
- Response rewriting (model name, tool name, signature injection)
- Claude builtin tools registry
- Advanced request logging with TTFB tracking
- Usage statistics queue with configurable retention
- Thinking block signature cache (3h TTL)
- Configurable keepalive intervals

## Quick Start

```bash
# Compile
rebar3 compile

# Run
rebar3 shell

# Run tests (456 tests)
rebar3 eunit

# Dialyzer (0 warnings)
rebar3 dialyzer

# Production release
rebar3 as prod release
```

Server starts on port **8317** by default.

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
        {rate_limit_rpm, 0},
        {password, undefined},
        {session_affinity_ttl, 3600},
        {tls_enable, false},
        {tls_cert, ""},
        {tls_key, ""}
    ]}
].
```

### CLI Flags

```
--login <provider>     OAuth login (claude | codex | google | kimi | antigravity)
--port <port>          Override listen port
--password <pw>        Access password
--home <node>          Connect to home node (satellite mode)
--config <path>        Custom config file path
--callback-port <port> OAuth callback port
--no-browser           Skip auto-opening browser for OAuth
--vertex-import <file> Import Vertex AI service account JSON
--local-models         Enable local model routing
```

### Add a Provider

```bash
curl -X POST http://localhost:8317/v0/management/auth-files \
  -H "Content-Type: application/json" \
  -d '{"type":"claude","api_key":"sk-...","base_url":"https://api.anthropic.com","email":"my-key","models":["claude-sonnet-4-20250514"]}'
```

## Docker

```bash
# Build and run
docker compose up -d

# Add credential (from inside container)
docker exec <container> wget -qO- --post-data='...' \
  --header='Content-Type: application/json' \
  http://127.0.0.1:8317/v0/management/auth-files

# Health check
curl http://localhost:8317/healthz
```

## Architecture

```
cli_proxy_app (application)
       │
cli_proxy_sup (one_for_one)
  ├── config_loader         — Hot-reloading config
  ├── signature_cache       — Thinking block signature cache (3h TTL)
  ├── translator_registry   — Format translator dispatch
  ├── rate_limiter          — Per-IP sliding window
  ├── usage_queue           — Statistics ring buffer
  ├── request_logger        — Async file logging with TTFB
  ├── clips_engine          — CLIPS port (12 rule files)
  ├── model_registry        — Model catalog with aliases/exclusions
  ├── 8× *_executor         — Provider HTTP execution
  ├── credential_sup        — Dynamic per-credential processes
  ├── conductor             — Request orchestration + CLIPS integration
  └── config_watcher        — Filesystem hot-reload
```

### Request Flow

```
Client (OpenAI format)
  │
  ▼
openai_handler
  ├── rate_limiter:check(IP)
  ├── access_control:authenticate(Req)
  ├── model_registry:resolve_alias(Model)
  │
  ▼
conductor:execute/4
  ├── CLIPS: select credential (rule-based scoring)
  ├── CLIPS: classify status (retry/cooldown/fallback)
  ├── translator: OpenAI → Claude/Gemini/Codex
  ├── cloaking: maybe disguise request
  ├── *_executor: HTTP to upstream provider
  ├── response_rewriter: normalize tool names
  ├── translator: response back to OpenAI format
  └── retry/quota fallback on failure
  │
  ▼
Response (OpenAI format)
```

## Testing

```bash
rebar3 eunit              # 456 tests, 0 failures
rebar3 dialyzer           # 0 warnings
rebar3 cover --verbose    # Coverage report
```

## CI/CD

| Workflow | Trigger | Steps |
|----------|---------|-------|
| Test | push/PR to main | Compile → CLIPS build → EUnit → Dialyzer → Coverage → Docker E2E |
| Docker | push main / tag | Build → Push to GHCR |
| Release | tag v* | Changelog → GitHub Release |

## Project Structure

```
apps/
├── cli_proxy/
│   ├── src/
│   │   ├── access/        — Rate limiting, password auth, API keys
│   │   ├── amp/           — AMP proxy, model mapper, config
│   │   ├── cache/         — Thinking signature cache
│   │   ├── conductor/     — CLIPS engine, credential selection, orchestration
│   │   ├── config/        — Config loader, file watcher, auth synthesizer
│   │   ├── executor/      — 8 provider HTTP executors
│   │   ├── home/          — Distributed home/satellite mode
│   │   ├── http/          — Cowboy handlers, cloaking, response rewriter
│   │   ├── logging/       — Request logger, usage queue, log rotator
│   │   ├── oauth/         — OAuth per provider (5) + session registry
│   │   ├── registry/      — Model registry with aliases/exclusions
│   │   ├── rules/         — Payload transformation rules
│   │   ├── store/         — File, PostgreSQL, Git, S3 backends
│   │   ├── translator/    — 9 format translators + builtin tools
│   │   └── util/          — SSE parser, browser, keepalive
│   ├── test/              — 456 EUnit tests (51 test modules)
│   └── priv/
│       ├── clips/         — 12 CLIPS rule files
│       └── clips_port     — Compiled CLIPS port binary
└── clips_port/            — C source for CLIPS bridge
config/
├── sys.config             — Application config
└── vm.args                — BEAM VM flags
```

## License

Private.
