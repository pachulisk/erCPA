# Fix Plan 7 — erCPA vs CLIProxyAPI 第四轮细节缺口补全

## 目标

补全最后 5 个行为细节级别差异，将 API 对齐度从 ~98% 推至 ~100%。

---

## Phase 1: WebSocket 升级路径兼容

- **I01** GET /v1/responses WS 升级 — responses_handler 支持 GET→WebSocket 升级，委托 responses_ws_handler
- **I02** GET /backend-api/codex/responses WS 升级 — 同上，Codex 别名路径

## Phase 2: /v1/models User-Agent 路由

- **I03** models_handler UA 路由 — 检测 User-Agent，claude-cli 返回 Claude 格式，其他返回 OpenAI 格式

## Phase 3: Codex WS 协议细节

- **I04** Codex WS 请求头补全 — OpenAI-Beta、x-codex-beta-features、x-client-request-id 等
- **I05** Mac OS session_id — User-Agent 检测 + session_id header 自动注入

---

## 不实现项

| 项目 | 原因 |
|------|------|
| TUI | Go 特有 |
| pprof | Go 特有 |
| SDK | Go 特有 |
| UTLS | Go 特有 |
| Device Profile | executor 内部细节 |
