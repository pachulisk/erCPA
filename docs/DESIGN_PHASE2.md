# erCPA Phase 2 Design — Remaining Feature Gaps

## Overview

erCPA 已实现 CLIProxyAPI 的绝大部分功能。本阶段补齐剩余 10 个差异项。
其中 4 个使用 CLIPS 规则引擎实现以增强可配置性，6 个使用纯 Erlang 实现。

## CLIPS 实现的功能（4 个）

### P01: Cloaking/伪装策略

**CLIPS 规则**: `priv/clips/cloaking_rules.clp`
- 匹配 User-Agent 决定是否伪装
- 定义伪装模式: auto / always / never
- 敏感词列表作为 CLIPS facts，可热加载

**Erlang 执行**: `apps/cli_proxy/src/http/cloaking.erl`
- 生成伪造 User ID: `user_[64hex]_account_[UUID]_session_[UUID]`
- Zero-width space (U+200B) 混淆敏感词
- Header 注入 (User-Agent, x-api-key)

### P03: Response Rewriting

**CLIPS 规则**: `priv/clips/rewrite_rules.clp`
- Model name 改写规则 (mapped model → original)
- Tool name 标准化规则 (bash→Bash, read→Read, grep→Grep)
- Signature 注入规则 (thinking/tool_use blocks)

**Erlang 执行**: `apps/cli_proxy/src/http/response_rewriter.erl`
- 非流式: 完整 buffer → 改写 → flush
- 流式: 逐 SSE event 改写
- 2MB 安全上限

### P04: Per-Client API Key Mapping

**CLIPS facts**: 在 `priv/clips/client_routing.clp`
```clp
(deftemplate client-key-mapping
  (slot client-key (type STRING))
  (slot upstream-key (type STRING))
  (slot provider (type STRING) (default "*")))
```
- conductor 在选择凭证前查询 CLIPS 获取上游 key
- 支持 per-provider 粒度映射

### P09: Request Idempotency

- 扩展 `signature_cache.erl`，基于 Idempotency-Key header 缓存响应
- CLIPS 规则决定哪些端点启用去重

## Erlang 实现的功能（6 个）

### P02: Builtin Tools Registry
- `apps/cli_proxy/src/translator/builtin_tools.erl`
- 默认工具集: web_search, code_execution, text_editor, computer
- 增强请求: 检测 tools 数组中的 type 字段

### P05: AMP 反向代理
- `apps/cli_proxy/src/amp/amp_proxy.erl`
- 反向代理到 ampcode.com (hackney 转发)
- 路由: /api/internal/*, /api/provider/:provider/v1/*
- Gemini bridge: 路径转换

### P06: Claude Code Instructions
- `apps/cli_proxy/priv/claude_code_instructions.txt`
- cloaking.erl 负责注入到 system messages
- cache_control: ephemeral, ttl 1h

### P07: Device Code OAuth
- 修改 `oauth_codex.erl`: 添加 device code 端点
- 修改 `oauth_kimi.erl`: 添加 device code 端点
- oauth_session.erl 的 provider_module 已支持分发

### P08: Redis Usage Queue
- `apps/cli_proxy/src/logging/usage_queue.erl`: ETS 环形缓冲 + TTL 清理
- `apps/cli_proxy/src/http/resp_handler.erl`: RESP 协议 (LPOP/RPOP/AUTH)

### P10: Advanced Keepalive Config
- 修改 `stream_keepalive.erl`: 从 config 读取 keepalive_seconds
- 区分 stream/non-stream 间隔

## 跳过的功能（5 个）

| 功能 | 原因 |
|------|------|
| Pprof | Erlang 有 recon + observer 原生替代 |
| Brotli | 极少见场景，zlib 足够 |
| Commercial Mode | 无商业化需求 |
| Config Diff | config_watcher 已覆盖基础场景 |
| TUI | erCPA 使用 HTTP API + Web UI |
