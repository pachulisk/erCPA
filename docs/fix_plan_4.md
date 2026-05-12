# Fix Plan 4 — erCPA vs CLIProxyAPI 功能缺口补全

## 目标

对齐 CLIProxyAPI (Go) 的功能，补全 erCPA (Erlang) 的缺口。
排除不适用的 Go 特有特性（pprof、SDK 嵌入、TUI/Bubbletea），
聚焦在 HTTP 端点、管理 API、基础设施三个层面。

---

## Phase 1: OAuth 补全 (2 endpoints)

- **F01** kimi-auth-url — 添加 Kimi OAuth URL 管理端点
- **F02** antigravity-auth-url — 添加 Antigravity OAuth URL 管理端点

## Phase 2: 状态查询端点 (4 endpoints)

- **F03** get-auth-status — OAuth 会话状态查询
- **F04** quota — 当前配额/冷却状态查询
- **F05** usage-statistics-enabled — 使用统计开关
- **F06** usage-queue — 使用统计队列查询

## Phase 3: 日志管理端点 (4 endpoints)

- **F07** request-error-logs — 错误日志列表
- **F08** request-error-logs/:name — 下载特定错误日志
- **F09** request-log-by-id — 按 ID 查询请求日志
- **F10** DELETE /logs — 清除日志

## Phase 4: 凭证/模型管理端点 (5 endpoints)

- **F11** auth-files/download — 凭证文件下载
- **F12** auth-files/models — 按凭证列出可用模型
- **F13** model-definitions/:channel — 按通道查模型定义
- **F14** oauth-excluded-models — OAuth 排除模型管理
- **F15** oauth-model-alias — OAuth 模型别名管理

## Phase 5: 测试/调试端点 (1 endpoint)

- **F16** api-call — 用指定凭据测试 API 调用

## Phase 6: AMP 补全 (2 endpoints)

- **F17** ampcode/upstream-api-key — 单 key GET/PUT/DELETE
- **F18** ampcode/restrict-management-to-localhost

## Phase 7: API 路由补全 (4 routes)

- **F19** Root `/` — 返回可用端点列表
- **F20** `/v1/messages` — Claude Messages API 原生格式
- **F21** `/v1beta/models` — Gemini 原生模型列表
- **F22** `/v1beta/models/*action` — Gemini 原生 generate/stream

## Phase 8: Session Affinity 增强

- **F23** 多 Session Key 提取 — 支持 X-Session-ID, X-Client-Request-Id, metadata.user_id, conversation_id

## Phase 9: 基础设施

- **F24** disable-cooling 配置项
- **F25** remote-management 细粒度控制 (secret-key, allow-remote, disable-control-panel)

---

## 不实现项（Go 特有 / 超大工程）

| 项目 | 原因 |
|------|------|
| TUI (Bubbletea) | Go 特有 UI 框架，Erlang 有 observer |
| pprof | Go 特有，Erlang 用 fprof/eprof |
| SDK 嵌入 | Go 特有，Erlang 用 release 包含 |
| .env 自动加载 | sys.config + 环境变量已覆盖 |
| Web 管理面板 | 独立前端项目，不在本批次 |
| config.yaml | erCPA 使用 sys.config，不需要 YAML |
| bootstrap retries | 已有 retry 机制，差异小 |
