# erCPA — Erlang CLI Proxy API

[English](README.md)

基于 Erlang/OTP 重新实现的 CLIProxyAPI —— 统一的 OpenAI 兼容网关，将请求路由到多个 LLM 提供商，具备自动凭证管理、智能重试和基于 CLIPS 专家系统的规则编排。

## 为什么选择 Erlang + CLIPS

| 关注点 | Go (CLIProxyAPI) | Erlang (erCPA) |
|--------|-----------------|----------------|
| 凭证选择 | 4000+ 行 if/else | ~200 条声明式 CLIPS 规则 |
| 并发模型 | 手动 goroutine 生命周期管理 | OTP 监督树，每连接轻量级进程 |
| 分布式 | Redis pub/sub | 原生 Erlang 分布式 |
| 热更新 | 需要重启 | 热代码加载 + CLIPS 规则热重载 |
| 容错隔离 | 共享进程崩溃 | "Let it crash" 进程级隔离 |

## 功能特性

### API 端点
- `/v1/chat/completions` — OpenAI 聊天补全
- `/v1/responses` / `/v1/responses/compact` — Responses API
- `/v1/ws/responses` — WebSocket 流式传输
- `/v1/ws` — WebSocket 中继（提供商代理）
- `/v1/completions` — 旧版文本补全
- `/v1/models` — 模型列表
- `/v1/images/generations` / `/v1/images/edits` — 图片生成
- `/v1/messages/count_tokens` — Token 计数
- `/backend-api/codex/responses` — Codex 兼容别名
- `/healthz` — 健康检查
- `/v0/management/[...]` — 40+ 管理端点

### 提供商支持（8 个执行器）
Claude (Anthropic) · Gemini (Google AI) · Codex (OpenAI) · Vertex AI · Kimi (Moonshot) · Antigravity · AI Studio · OpenAI 兼容（OpenRouter、Ollama、vLLM 等）

### CLIPS 规则引擎（12 个规则文件）
| 规则文件 | 用途 |
|----------|------|
| `selection.clp` | 凭证评分与选择 |
| `cooldown.clp` | HTTP 错误状态转换 |
| `status_rules.clp` | 状态码 → 重试/冷却/降级 + 错误类型 + 认证解绑 |
| `credential_policy.clp` | 每提供商冷却时长与刷新调度 |
| `thinking.clp` | 思考预算/级别归一化 |
| `quota.clp` | 配额超限标记与恢复 |
| `routing.clp` | 模型-提供商匹配 |
| `cloaking_rules.clp` | 请求伪装策略（auto/always/never）|
| `rewrite_rules.clp` | 响应改写（工具名标准化）|
| `client_routing.clp` | 每客户端 API Key 映射 |
| `provider_config.clp` | OAuth 提供商注册 |
| `templates.clp` | 共享 fact 模板定义 |

### 安全特性
- PBKDF2-SHA256 密码哈希（向后兼容明文）
- 常量时间密码比较（防时序攻击）
- ETS 高并发 API Key 验证
- 每 IP 滑动窗口限流
- TLS/HTTPS 支持
- 零宽字符敏感词混淆

### 存储后端
文件（默认）· PostgreSQL · Git 仓库 · S3 兼容对象存储

### 其他特性
- 多提供商格式互译（OpenAI ↔ Claude ↔ Gemini ↔ Codex）
- 扩展思考/推理跨格式转换
- OAuth 登录（Claude、Codex、Google、Kimi、Antigravity）含设备码流程
- 会话亲和性（粘性凭证路由，可配置 TTL）
- 配额降级链（预览模型 → 备用凭证）
- Home/Satellite 分布式模式（Erlang 原生分布）
- 配置热加载（文件系统监听）
- 从配置 API Key 列表自动合成凭证
- AMP 反向代理 + Gemini 桥接
- 响应改写（模型名、工具名、签名注入）
- Claude 内置工具注册表
- 高级请求日志（含首字节延迟 TTFB 追踪）
- 使用统计队列（可配置保留时间）
- 思考块签名缓存（3 小时 TTL）
- 可配置心跳间隔

## 快速开始

```bash
# 编译
rebar3 compile

# 运行
rebar3 shell

# 运行测试（456 个测试）
rebar3 eunit

# 静态分析（0 警告）
rebar3 dialyzer

# 生产发布
rebar3 as prod release
```

服务默认监听 **8317** 端口。

## 配置

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
        {rate_limit_rpm, 0},          %% 每分钟请求限制（0=不限）
        {password, undefined},         %% 访问密码
        {session_affinity_ttl, 3600},  %% 会话亲和性 TTL（秒）
        {tls_enable, false},
        {tls_cert, ""},
        {tls_key, ""}
    ]}
].
```

### 命令行参数

```
--login <provider>     OAuth 登录（claude | codex | google | kimi | antigravity）
--port <port>          覆盖监听端口
--password <pw>        访问密码
--home <node>          连接到 Home 节点（卫星模式）
--config <path>        自定义配置文件路径
--callback-port <port> OAuth 回调端口
--no-browser           跳过自动打开浏览器
--vertex-import <file> 导入 Vertex AI 服务账号 JSON
--local-models         启用本地模型路由
```

### 添加提供商凭证

```bash
# 通过管理 API 添加（示例：MiMo）
curl -X POST http://localhost:8317/v0/management/auth-files \
  -H "Content-Type: application/json" \
  -d '{
    "type": "claude",
    "api_key": "your-api-key",
    "base_url": "https://token-plan-cn.xiaomimimo.com/anthropic",
    "email": "mimo-provider",
    "models": ["mimo-v2.5-pro"]
  }'

# 通过配置自动合成（sys.config 中添加 API Key 列表）
# {claude_keys, [<<"sk-ant-xxx">>]}
# {gemini_keys, [<<"AIza...">>]}
```

### 设置密码保护

```bash
# 设置密码（管理 API）
curl -X PUT http://localhost:8317/v0/management/password \
  -H "Content-Type: application/json" -d '"my-secret"'

# 之后请求需带密码
curl http://localhost:8317/v1/chat/completions \
  -H "X-Password: my-secret" \
  -H "Content-Type: application/json" \
  -d '{"model":"mimo-v2.5-pro","messages":[{"role":"user","content":"hello"}]}'
```

### 设置限流

```bash
# 每分钟最多 60 次请求
curl -X PUT http://localhost:8317/v0/management/rate-limit \
  -H "Content-Type: application/json" -d '60'
```

## Docker 部署

```bash
# 构建并启动
docker compose up -d

# 添加凭证（需在容器内部操作，管理 API 仅限 localhost）
docker exec <container> wget -qO- \
  --post-data='{"type":"claude","api_key":"...","base_url":"...","email":"...","models":["..."]}' \
  --header='Content-Type: application/json' \
  http://127.0.0.1:8317/v0/management/auth-files

# 重启以加载新凭证
docker compose restart

# 验证
curl http://localhost:8317/healthz        # 返回 "ok"
curl http://localhost:8317/v1/models      # 返回模型列表
```

Docker 镜像自动通过 GitHub Actions 构建并推送到 GHCR。

## 架构

```
cli_proxy_app (application)
       │
cli_proxy_sup (one_for_one)
  ├── config_loader         — 热加载配置
  ├── signature_cache       — 思考块签名缓存（3h TTL）
  ├── translator_registry   — 格式翻译器分发
  ├── rate_limiter          — 每 IP 滑动窗口限流
  ├── usage_queue           — 统计环形缓冲
  ├── request_logger        — 异步文件日志（含 TTFB）
  ├── clips_engine          — CLIPS 端口（12 个规则文件）
  ├── model_registry        — 模型目录 + 别名/排除
  ├── 8× *_executor         — 提供商 HTTP 执行器
  ├── credential_sup        — 动态凭证进程管理
  ├── conductor             — 请求编排 + CLIPS 集成
  └── config_watcher        — 文件系统热加载
```

### 请求流程

```
客户端请求（OpenAI 格式）
  │
  ▼
openai_handler
  ├── rate_limiter:check(IP)          ← 限流检查
  ├── access_control:authenticate()   ← 密码/Key 认证
  ├── model_registry:resolve_alias()  ← 模型别名解析
  │
  ▼
conductor:execute/4
  ├── CLIPS: 凭证选择（规则评分）
  ├── CLIPS: 状态码分类（重试/冷却/降级）
  ├── translator: OpenAI → Claude/Gemini/Codex
  ├── cloaking: 可选请求伪装
  ├── *_executor: HTTP 请求上游提供商
  ├── response_rewriter: 工具名标准化
  ├── translator: 响应翻译回 OpenAI 格式
  └── 失败时自动重试/配额降级
  │
  ▼
响应（OpenAI 格式）
```

## 测试

```bash
rebar3 eunit              # 456 个测试，0 失败
rebar3 dialyzer           # 0 警告
rebar3 cover --verbose    # 覆盖率报告
```

## CI/CD

| 工作流 | 触发条件 | 步骤 |
|--------|---------|------|
| Test | push/PR 到 main | 编译 → CLIPS 构建 → EUnit → Dialyzer → 覆盖率 → Docker E2E |
| Docker | push main / tag | 构建 → 推送到 GHCR |
| Release | tag v* | 生成 Changelog → 创建 GitHub Release |

## 项目结构

```
apps/
├── cli_proxy/
│   ├── src/
│   │   ├── access/        — 限流、密码认证、API Key
│   │   ├── amp/           — AMP 代理、模型映射、配置
│   │   ├── cache/         — 思考签名缓存
│   │   ├── conductor/     — CLIPS 引擎、凭证选择、请求编排
│   │   ├── config/        — 配置加载、文件监听、凭证自动合成
│   │   ├── executor/      — 8 个提供商 HTTP 执行器
│   │   ├── home/          — 分布式 Home/Satellite 模式
│   │   ├── http/          — Cowboy 处理器、伪装、响应改写
│   │   ├── logging/       — 请求日志、使用统计、日志轮转
│   │   ├── oauth/         — OAuth（5 个提供商）+ 会话注册
│   │   ├── registry/      — 模型注册表 + 别名/排除
│   │   ├── rules/         — Payload 变换规则
│   │   ├── store/         — 文件、PostgreSQL、Git、S3 后端
│   │   ├── translator/    — 9 个格式翻译器 + 内置工具
│   │   └── util/          — SSE 解析器、浏览器、心跳
│   ├── test/              — 456 个 EUnit 测试（51 个测试模块）
│   └── priv/
│       ├── clips/         — 12 个 CLIPS 规则文件
│       └── clips_port     — 编译好的 CLIPS 端口二进制
└── clips_port/            — CLIPS 桥接 C 源码
config/
├── sys.config             — 应用配置
└── vm.args                — BEAM VM 参数
```

## 许可证

私有。
