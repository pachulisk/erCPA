# Fix Plan 5 — erCPA vs CLIProxyAPI 第二轮功能缺口补全

## 目标

对齐 CLIProxyAPI 剩余功能差异，聚焦可实现项。
排除 Go 特有 (TUI/pprof)、独立前端工程 (Web 管理面板)、AMP 扩展路由（scope 过大）。

---

## Phase 1: Management PATCH/DELETE 批量补全

批量为 provider key 端点添加 PUT/PATCH/DELETE，
为配置端点添加 PATCH，为列表端点添加 DELETE。

- **G01** provider-key CRUD 完整化 — claude/codex/gemini/vertex/openai-compat 添加 PUT/PATCH/DELETE
- **G02** config PATCH 批量 — debug, logging-to-file, request-log 等 14 个端点添加 PATCH
- **G03** list DELETE 补全 — api-keys, oauth-excluded-models, oauth-model-alias 添加 DELETE
- **G04** ampcode PATCH/DELETE — upstream-url, upstream-api-keys, model-mappings 等添加 PATCH/DELETE

## Phase 2: 缺失管理端点

- **G05** GET /logs — 通用日志文件列表
- **G06** GET /ampcode — 返回完整 Amp 配置对象
- **G07** POST /oauth-callback — 管理 API 内 OAuth 回调

## Phase 3: 配置项补全

- **G08** antigravity-credits 降级 — quota-exceeded.antigravity-credits 配置 + conductor 支持
- **G09** header-defaults — claude-header-defaults / codex-header-defaults 配置
- **G10** signature-bypass-strict — antigravity-signature-bypass-strict 配置
- **G11** payload raw 规则 — payload.default-raw / override-raw 支持

## Phase 4: Keep-alive 端点

- **G12** keep-alive — GET /keep-alive 心跳端点

## Phase 5: Codex ↔ Gemini 翻译器

- **G13** translator_codex_gemini — Codex → Gemini 格式翻译
- **G14** translator_gemini_codex — Gemini → Codex 格式翻译

## Phase 6: Antigravity 翻译器

- **G15** translator_antigravity_claude — Antigravity → Claude
- **G16** translator_claude_antigravity — Claude → Antigravity
- **G17** translator_antigravity_openai — Antigravity → OpenAI
- **G18** translator_openai_antigravity — OpenAI → Antigravity

## Phase 7: Gemini CLI 支持

- **G19** gemini_cli_executor — Gemini CLI 内部协议执行器
- **G20** /v1internal:method 路由 — Gemini CLI handler + 路由注册
- **G21** translator_gemini_cli_claude — Gemini CLI → Claude 翻译
- **G22** translator_claude_gemini_cli — Claude → Gemini CLI 翻译
- **G23** translator_gemini_cli_openai — Gemini CLI → OpenAI 翻译
- **G24** translator_openai_gemini_cli — OpenAI → Gemini CLI 翻译

---

## 不实现项

| 项目 | 原因 |
|------|------|
| TUI (Bubbletea) | Go 特有框架 |
| Web 管理面板 | 独立前端工程 |
| pprof | Go 特有，Erlang 用 observer/fprof |
| AMP 扩展路由 | /api/provider/*, /api/internal 等 scope 过大 |
| config.yaml | erCPA 使用 sys.config |
| commercial-mode | 低优先级运营特性 |
| auth-auto-refresh-workers | Erlang 进程模型天然支持 |
