# Fix Plan 6 — erCPA vs CLIProxyAPI 第三轮功能缺口补全

## 目标

补全第三轮对比中发现的剩余差异。
排除 Go 特有项 (TUI/pprof/UTLS/SDK/Device Profile)。

---

## Phase 1: 小端点 + 配置项 (7 tasks)

- **H01** HEAD /healthz — health_handler 支持 HEAD 方法
- **H02** PATCH /api-keys — 管理端点部分更新
- **H03** config.yaml — GET/PUT/PATCH /v0/management/config.yaml
- **H04** commercial-mode — 配置项 + 中间件跳过逻辑
- **H05** auth-auto-refresh-workers — 可配置刷新 worker 数
- **H06** panel 配置扩展 — disable-auto-update-panel + panel-github-repository
- **H07** session-affinity 开关 — 独立于 TTL 的 enable/disable toggle

## Phase 2: 缺失翻译器 (11 pairs)

- **H08** claude → codex
- **H09** openai → codex
- **H10** antigravity → gemini
- **H11** gemini → antigravity
- **H12** codex → antigravity
- **H13** codex → gemini_cli
- **H14** antigravity → codex
- **H15** antigravity → gemini_cli
- **H16** gemini_cli → gemini
- **H17** gemini_cli → codex
- **H18** gemini_cli → antigravity

## Phase 3: Codex WebSocket Executor

- **H19** codex_ws_executor — Codex WebSocket 实时双向执行器
- **H20** conductor 集成 — codex_ws routing + supervisor 注册

## Phase 4: AMP 扩展路由

- **H21** AMP Provider 路由 — /api/provider/:provider/v1/* 动态转发
- **H22** AMP 管理代理 — /api/internal/*, /api/user/* 等代理到上游
- **H23** AMP 根路由 — /threads, /docs, /settings, RSS feeds

---

## 不实现项

| 项目 | 原因 |
|------|------|
| TUI (Bubbletea) | Go 特有框架 |
| SDK 嵌入 | Go 特有 |
| pprof | Go 特有 |
| UTLS client | Go 特有 TLS 指纹库 |
| Claude Device Profile | executor 内部细节 |
