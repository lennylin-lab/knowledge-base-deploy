# Knowledge Base 环境变量与联调配置指南

本文档汇总 Knowledge Base 各组件的环境变量、认证边界与推荐联调方式。适用于**本仓库生产部署**与各源码仓库**本地开发**的配置核对。

编排与首次部署流程见 [README.md](README.md)。镜像说明见 [gateway.md](gateway.md)、[server.md](server.md)、[keycloak.md](keycloak.md)。

**组件与源码仓库：**

| 仓库 | 职责 | 本仓库配置 |
| --- | --- | --- |
| [knowledge-base-keycloak](https://github.com/lennylin-lab/knowledge-base-keycloak) | OIDC（Keycloak 26 + Turnstile SPI） | [`keycloak/.env.example`](keycloak/.env.example) |
| [knowledge-base-gateway](https://github.com/lennylin-lab/knowledge-base-gateway) | 大模型网关 | [`gateway/.env.example`](gateway/.env.example) |
| [knowledge-base-server](https://github.com/lennylin-lab/knowledge-base-server) | 业务 API（RAG、检索、租户 RBAC） | [`server/.env.example`](server/.env.example) |
| [knowledge-base-flutter](https://github.com/lennylin-lab/knowledge-base-flutter) | 前端（OIDC 编译期配置） | — |
| **本仓库** | 统一 Compose、`docker-compose.prod.yml` | [`.env.prod.example`](.env.prod.example) |

**本仓库 env 分工：** `.env.prod` 只管公共基础设施（PostgreSQL 三库账号、GHCR 镜像）；各组件密钥与业务项在 `gateway/`、`server/`、`keycloak/` 下的 `.env`。启动时需合并四个文件（见 [README.md](README.md)）。

各源码仓库本地开发时 `.env` **互相独立**；**进程环境变量优先于 `.env` 文件**。

---

## 1. 总体架构

```text
浏览器 / Flutter 客户端
    │  Authorization: Bearer <用户 OIDC access token>（启用 OIDC 时）
    ▼
knowledge-base-server（KB_*）
    │  文档 / 会话 / RAG / 租户 RBAC
    │
    ├── KB_OIDC_* ──────────► knowledge-base-keycloak（issuer / JWKS）
    ├── KB_EMBEDDING_* ─────► Gateway POST /v1/embeddings
    └── KB_CHAT_* ──────────► Gateway POST /v1/chat/completions
                                  │
                                  ▼
                        knowledge-base-gateway（GATEWAY_*）
                                  │
                                  ▼
                        OpenAI / Anthropic / fake 上游
```

### 1.1 配置边界（务必遵守）

| 职责 | 配置位置 | 说明 |
| --- | --- | --- |
| 用户登录 / 业务 API 鉴权 | server 的 `KB_OIDC_*` | Keycloak 等 IdP 签发 token，server 验签 |
| server → Gateway 调用 | server 的 `KB_CHAT_*` / `KB_EMBEDDING_*` | 填 **Gateway API Key**，不是上游 provider key |
| 上游 LLM 密钥 | Gateway 的 `OPENAI_*` / `ANTHROPIC_*` | **永远不要**写到 server |
| Gateway 业务 key 管理 | Gateway Admin API + PostgreSQL | 数据库模式下通过 admin 接口 mint key |
| PostgreSQL / Redis | 见部署模式 | **本仓库统一编排：** 单 PG 三库 + 单 Redis（key 前缀 `gw:*` / `kb:c1:*` 隔离）。**各仓库独立 compose 开发：** 不同实例/端口，勿混用 DSN |

### 1.2 端口对照

**本仓库 `docker-compose.prod.yml`（绑定 `127.0.0.1`，仅应用端口暴露）：**

| 服务 | 默认宿主机端口 | 容器内 | 配置变量 |
| --- | --- | --- | --- |
| Gateway 公开 API | `8091` | `:8080` | `GATEWAY_HOST_PORT`（`gateway/.env`） |
| Gateway Admin API | `8092` | `:8081` | `GATEWAY_ADMIN_HOST_PORT` |
| Server API | `8000` | `:8000` | `SERVER_HOST_PORT`（`server/.env`） |
| Keycloak | `8080` | `:8080` | `KEYCLOAK_HOST_PORT`（`keycloak/.env`） |
| PostgreSQL / Redis / ES | *不暴露* | 容器网络 | — |

**各源码仓库独立 compose 开发（参考）：**

| 服务 | 默认端口 | 所属项目 |
| --- | --- | --- |
| server API | `8000` | knowledge-base-server |
| server PostgreSQL / ES / Redis | `5432` / `9200` / `6379` | server compose |
| Keycloak dev | `8180` | knowledge-base-keycloak |
| Gateway 公开 / Admin | `8091` / `8092`（或 go run `:8080` / `:8081`） | knowledge-base-gateway |
| Gateway 专用 PG / Redis | `5433` / `6381` | gateway compose |

---

## 2. knowledge-base-keycloak

**本仓库：** [`keycloak/.env.example`](keycloak/.env.example) → `keycloak/.env`；编排见根目录 [`docker-compose.prod.yml`](docker-compose.prod.yml)。  
**源码仓库本地 dev：** 各仓库根目录 `.env.example` → `.env`，独立 `docker-compose.yml`。

本仓库含 `keycloak/import/cybervem-realm.json` 与 `keycloak/scripts/`（Turnstile bootstrap）。首次**空 keycloak 库**启动时 `--import-realm` 自动导入；导入后运行 bootstrap（见 [README.md](README.md) §3）。

### 2.1 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `KEYCLOAK_ADMIN` | `admin` | Admin Console 管理员用户名（仅 dev） |
| `KEYCLOAK_ADMIN_PASSWORD` | `admin` | Admin Console 密码（仅 dev） |

**本仓库：** Turnstile 密钥配置在 `keycloak/.env`（`TURNSTILE_SITE_KEY` / `TURNSTILE_SECRET_KEY`），由 `--profile bootstrap` 或 `keycloak/scripts/post-import.sh` 写入认证流。  
**源码仓库 dev：** 通常在 Admin Console 手动绑定；CSP 可运行 `./scripts/configure-turnstile-csp.sh`。

### 2.2 启动

```bash
cd knowledge-base-keycloak
cp .env.example .env   # 可选
docker compose up -d --build
```

- Admin Console：<http://localhost:8180>
- Issuer（realm 名为 `kb` 时）：`http://localhost:8180/realms/kb`

### 2.3 Admin Console 最小配置建议

| 项 | 建议值 | 说明 |
| --- | --- | --- |
| Realm | `kb` | 与 `KB_OIDC_ISSUER` 路径一致 |
| Client | `kb-web` | Flutter 默认 client id |
| Access Token `aud` | `kb-api` | 与 `KB_OIDC_AUDIENCE` 一致 |
| Redirect URI | 按平台 | Web: `{origin}/auth/callback`；Native: `http://localhost:8182/auth/callback` |

### 2.4 生产镜像

```bash
docker build -t ghcr.io/<org>/kb-keycloak:26.0 .
docker push ghcr.io/<org>/kb-keycloak:26.0
```

在本仓库 [`.env.prod`](.env.prod.example) 中设置 `KEYCLOAK_IMAGE=...`。详见 [keycloak.md](keycloak.md) 与 [Keycloak README](https://github.com/lennylin-lab/knowledge-base-keycloak/blob/master/README.md)。

---

## 3. knowledge-base-gateway

**本仓库：** [`gateway/.env.example`](gateway/.env.example) → `gateway/.env`（DSN / Redis 由 compose 注入）。  
**代码定义：** [`internal/config/config.go`](https://github.com/lennylin-lab/knowledge-base-gateway/blob/master/internal/config/config.go)

Gateway 有两种运行模式，由 **`GATEWAY_DATABASE_URL` 是否设置** 决定：

| 模式 | 条件 | 配置来源 |
| --- | --- | --- |
| **开发模式** | `GATEWAY_DATABASE_URL` 未设置 | 内存存储；必须配置 `GATEWAY_API_KEYS` + `GATEWAY_MODELS` |
| **生产/Compose 模式** | `GATEWAY_DATABASE_URL` 已设置 | PostgreSQL 为权威；key/catalog/policy 来自数据库 |

### 3.1 基础服务

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `GATEWAY_ADDR` | `:8080` | 公开 API 监听地址（chat / responses / embeddings / models） |
| `GATEWAY_MAX_RETRIES` | `2` | 输出前网络/429/5xx 重试次数（0–10） |
| `GATEWAY_RATE_PER_MINUTE` | `120` | 每 subject 每分钟请求数 |

请求限制（代码常量，不可 env 配置）：body 1 MiB、最多 64 条消息、每条 32k 字符。

### 3.2 开发模式专用

| 变量 | 格式 | 说明 |
| --- | --- | --- |
| `GATEWAY_PROVIDER` | `fake` / `openai` / `anthropic` | 本地 dev 默认 provider；**数据库模式下被忽略** |
| `GATEWAY_API_KEYS` | `id:subject:plaintext-key`（逗号分隔） | 开发用 API key 列表 |
| `GATEWAY_MODELS` | `公开名:provider:上游模型`（逗号分隔） | 开发用模型 catalog |
| `GATEWAY_DEFAULT_MODELS` | `subject:chat模型[:embedding模型]` | 开发模式 subject 默认模型 |

**fake provider 最快联调示例：**

```dotenv
GATEWAY_ADDR=:8080
GATEWAY_PROVIDER=fake
GATEWAY_API_KEYS=kb-local:kb-server:sk-kb-local
GATEWAY_MODELS=gateway-echo:fake:echo-model
GATEWAY_DEFAULT_MODELS=kb-server:gateway-echo
GATEWAY_ADMIN_TOKEN=dev-admin-token
```

### 3.3 上游 Provider 密钥（仅 Gateway 进程）

| 变量 | 说明 |
| --- | --- |
| `OPENAI_API_KEY` | OpenAI 兼容 provider 默认 key |
| `OPENAI_BASE_URL` | 默认 `https://api.openai.com/v1` |
| `ANTHROPIC_API_KEY` | Anthropic provider 默认 key |
| `ANTHROPIC_BASE_URL` | 默认 `https://api.anthropic.com` |
| `<KIND>_API_KEY__<PROVIDER_NAME>` | 按 provider 行覆盖（见下） |

**Per-provider 凭证规则：**

每个 enabled 的 `providers` 行优先读 `<KIND>_API_KEY__<PROVIDER_NAME>`（provider 名大写，非字母数字变 `_`），未设置则回退到 kind 级 key。

```dotenv
OPENAI_API_KEY=sk-fallback...
OPENAI_API_KEY__CHAT=sk-chat-only...
OPENAI_API_KEY__OPENAI_EMBED=sk-embed-only...
ANTHROPIC_API_KEY__EU_CLAUDE=sk-eu...
```

### 3.4 生产模式（PostgreSQL + Redis）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `GATEWAY_DATABASE_URL` | 空 | PostgreSQL DSN；设置后进入数据库模式 |
| `GATEWAY_LIMITS_MODE` | `local` | `local`（单进程 dev）或 `redis`（分布式） |
| `GATEWAY_REDIS_ADDR` | `127.0.0.1:6379` | Redis 地址（`limits_mode=redis` 时） |
| `GATEWAY_ADMIN_TOKEN` | 空 | Admin API Bearer token；空 = 禁用 admin |
| `GATEWAY_ADMIN_ADDR` | `:8081` | Admin API 监听地址（**仅内网**） |
| `GATEWAY_ALLOW_INSECURE_BASE_URLS` | `false` | dev only：允许 `http://` 和 loopback provider URL |

**Compose 容器内最小环境：**

```dotenv
GATEWAY_DATABASE_URL=postgres://gateway:gateway-local-throwaway@postgres:5432/gateway?sslmode=disable
GATEWAY_LIMITS_MODE=redis
GATEWAY_REDIS_ADDR=redis:6379
GATEWAY_ADMIN_TOKEN=smoke-admin-throwaway
OPENAI_API_KEY=sk-...
OPENAI_BASE_URL=https://api.openai.com/v1
```

> **Compose 注意（gateway 独立 compose）：** 根目录 `.env` 只用于 `${...}` 插值；只有 `environment:` 段列出的变量才会传入容器。  
> **本仓库：** `gateway/.env` 通过 `env_file` 注入容器；同时需 `--env-file gateway/.env` 供 compose 插值（如宿主机端口）。

### 3.5 协议开关（v1.2 / v1.3）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `GATEWAY_RESPONSES_ENABLED` | `true` | 设 `false` 关闭 `/v1/responses` |
| `GATEWAY_EMBEDDINGS_ENABLED` | `true` | 设 `false` 关闭 `/v1/embeddings` |

### 3.6 Compose 宿主机端口（docker compose 插值用）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `GATEWAY_HOST_PORT` | `8091` | Gateway 公开 API 宿主机端口 |
| `GATEWAY_ADMIN_HOST_PORT` | `8092` | Admin API 宿主机端口（仅 loopback） |
| `GATEWAY_ADMIN_TOKEN` | `smoke-admin-throwaway` | Admin token（本地 throwaway） |
| `POSTGRES_HOST_PORT` | `5433` | Gateway PostgreSQL 宿主机端口 |
| `REDIS_HOST_PORT` | `6381` | Gateway Redis 宿主机端口 |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | `gateway` / `gateway-local-throwaway` / `gateway` | Gateway 专用 PG 凭据 |
| `GATEWAY_IMAGE` | `kb-gateway:local` | 镜像 tag |

### 3.7 Migration CLI

```bash
go run ./cmd/migrate up          # 从 .env 读 GATEWAY_DATABASE_URL
go run ./cmd/migrate -dsn "..." up   # 显式 DSN 优先
go run ./cmd/migrate version
```

### 3.8 Admin API（mint Gateway key）

迁移 seed 的 subject 为 **`subject_default`**（不是 `kb-server`）。`CreateKey` 不会自动创建 subject；对不存在的 subject mint key 会返回 `500 key_create_failed`。

**本仓库推荐：** 先跑 [`gateway/scripts/bootstrap-fake.sh`](gateway/scripts/bootstrap-fake.sh)（fake）或按 [`gateway/bootstrap-production.md`](gateway/bootstrap-production.md) 初始化 catalog，再 mint key。

```bash
# 从 gateway/.env 读取（勿硬编码 smoke-admin-throwaway）
set -a && source gateway/.env && set +a
export GATEWAY_ADMIN_URL=http://127.0.0.1:${GATEWAY_ADMIN_HOST_PORT:-8092}
export GATEWAY_SUBJECT=subject_default

curl -s -X POST "$GATEWAY_ADMIN_URL/admin/policies/${GATEWAY_SUBJECT}/default-model" \
  -H "Authorization: Bearer $GATEWAY_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"model":"gateway-echo","kind":"chat"}'

curl -s -X POST "$GATEWAY_ADMIN_URL/admin/policies/${GATEWAY_SUBJECT}/default-model" \
  -H "Authorization: Bearer $GATEWAY_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"model":"gateway-echo","kind":"embedding"}'

curl -s -X POST "$GATEWAY_ADMIN_URL/admin/keys" \
  -H "Authorization: Bearer $GATEWAY_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"subject\":\"${GATEWAY_SUBJECT}\",\"expires_in_hours\":8760}"
# 响应 key → server/.env 的 KB_CHAT_API_KEY / KB_EMBEDDING_API_KEY
```

生产 embedding 模型（如 `qwen3-embedding`，1536 维）须 **先** 存在于 catalog 与 `access_policies`，且 `KB_EMBEDDING_DIM` 与 catalog `embedding_dim` 一致。

---

## 4. knowledge-base-server

**本仓库：** [`server/.env.example`](server/.env.example) → `server/.env`（`KB_DATABASE_URL` / ES / Redis 由 compose 注入）。  
**代码定义：** [`src/app/core/config.py`](https://github.com/lennylin-lab/knowledge-base-server/blob/main/src/app/core/config.py)  
**前缀：** 所有变量以 `KB_` 开头

### 4.1 数据存储

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `KB_DATABASE_URL` | `postgresql+asyncpg://kb:kb@localhost:5432/kb` | PostgreSQL（含 pgvector） |
| `KB_ELASTICSEARCH_URL` | `http://localhost:9200` | Elasticsearch 地址 |

### 4.2 HTTP / CORS

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `KB_CORS_ORIGINS` | `[]`（空 = 禁用 CORS） | 浏览器跨域白名单；本地前端可设 `["*"]` 或 `["http://localhost:5173"]` |

### 4.3 LLM：Embedding（向量）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `KB_EMBEDDING_BASE_URL` | `https://api.openai.com/v1` | OpenAI 兼容 API 根地址，**必须停在 `/v1`** |
| `KB_EMBEDDING_API_KEY` | 空 | 走 Gateway 时填 **Gateway key** |
| `KB_EMBEDDING_MODEL` | `text-embedding-3-small` | Gateway catalog 公开模型名 |
| `KB_EMBEDDING_DIM` | 空（v1.3 优先发现） | 向量维度兜底；**必须与 pgvector 列宽一致（1536）** |

**v1.3 推荐（embedding 也走 Gateway）：**

```dotenv
KB_EMBEDDING_BASE_URL=http://127.0.0.1:8091/v1
KB_EMBEDDING_API_KEY=<gateway-api-key>
KB_EMBEDDING_MODEL=<gateway-公开模型名>
KB_EMBEDDING_DIM=1536
```

> catalog 须声明 `embeddings: true` 与 `embedding_dim`；详见 [gateway-v1.3-integration.md](https://github.com/lennylin-lab/knowledge-base-server/blob/main/docs/gateway-v1.3-integration.md)。

### 4.4 LLM：Chat（对话 / Agent）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `KB_CHAT_BASE_URL` | `https://api.openai.com/v1` | Gateway OpenAI 兼容根地址 |
| `KB_CHAT_API_KEY` | 空 | **Gateway service key** |
| `KB_CHAT_MODEL` | 空（v1.3 可选） | Gateway 公开模型名；未设置时由 Gateway 按 subject 默认模型回填 |
| `KB_CHAT_HISTORY_TOKEN_BUDGET` | `2000` | 多轮历史 token 预算 |
| `KB_CHAT_HISTORY_MAX_TURN_FRACTION` | `0.5` | 单轮最大占比；`>= 1.0` 关闭截断 |
| `KB_CHAT_QUERY_REWRITE_ENABLED` | `true` | 追问改写 |
| `KB_CHAT_REWRITE_HISTORY_TURNS` | `3` | 改写使用的最近轮数 |
| `KB_CHAT_ROLLING_SUMMARY_ENABLED` | `true` | 滚动历史摘要 |
| `KB_CHAT_SUMMARY_MAX_TOKENS` | `400` | 摘要 token 上限 |
| `KB_CHAT_SOURCES_CARRY_ENABLED` | `true` | 追问携带上一轮 sources |

**联调 Gateway：**

```dotenv
KB_CHAT_BASE_URL=http://127.0.0.1:8091/v1   # go run 模式用 :8080
KB_CHAT_API_KEY=<gateway-api-key>
# KB_CHAT_MODEL=gateway-echo   # 可选
```

不要写成 `.../v1/chat/completions`，OpenAI SDK 会自动追加路径。

### 4.5 MCP 扩展

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `KB_MCP_CONFIG_PATH` | `mcp.json` | MCP 配置文件路径；文件不存在则禁用 |

### 4.6 索引队列（ARQ + Redis）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `KB_REDIS_URL` | 空 | 空 = 进程内后台索引；设 `redis://localhost:6379` 并运行 `python -m app.cli worker` |
| `KB_INDEX_JOB_MAX_TRIES` | `3` | 索引任务重试次数 |
| `KB_INDEX_JOB_RETRY_MIN_DELAY_S` | `5` | 首次重试延迟（指数退避） |

### 4.7 缓存（Redis，可选）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `KB_CACHE_ENABLED` | `true` | 总开关；**实际生效 = true 且 KB_REDIS_URL 非空** |
| `KB_CACHE_EMBEDDING_TTL_S` | `2592000` | embedding 缓存 TTL（30 天） |
| `KB_CACHE_SUMMARY_TTL_S` | `0` | 摘要缓存 TTL |
| `KB_CACHE_ASSOCIATION_TTL_S` | `600` | 关联推荐缓存 TTL |
| `KB_CACHE_SEARCH_TTL_S` | `60` | 搜索结果缓存 TTL |

### 4.8 检索质量门控（Hybrid Search）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `KB_SEARCH_BM25_MIN_SCORE` | `0.0` | BM25 绝对分下限（`0.0` = 禁用） |
| `KB_SEARCH_BM25_MIN_COVERAGE` | `70%` | BM25 词项覆盖率；空字符串 = 禁用 |
| `KB_SEARCH_VECTOR_MAX_DISTANCE` | `0.45` | 向量 cosine 距离上限 |
| `KB_SEARCH_VECTOR_RESCUE_MARGIN` | `0.15` | 向量 rescue 窗口 |
| `KB_SEARCH_VECTOR_RESCUE_MAX_DISTANCE` | `0.85` | rescue 硬上限 |
| `KB_SEARCH_VECTOR_RESCUE_TRIGGER_MAX_DISTANCE` | `0.62` | rescue 触发条件 |
| `KB_SEARCH_RRF_MIN_RELATIVE` | `0.35` | RRF 相对分过滤 |
| `KB_SEARCH_MAX_QUERY_LENGTH` | `256` | 查询长度截断 |

> v1.3：Gateway catalog 的 `retrieval_profile` 可覆盖上述阈值；env 为 Gateway 不可用时的兜底。

### 4.9 可观测性

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `KB_LOG_LEVEL` | `INFO` | 日志级别 |
| `KB_LOG_FORMAT` | `console` | `console` 或 `json` |

---

## 5. 认证与身份（server 侧）

认证分 **三条独立路径**，互不替代。

### 5.1 用户 OIDC 鉴权（业务 API）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `KB_OIDC_ISSUER` | 空 | **空 = OIDC 关闭**（单用户兼容模式，不做 RBAC） |
| `KB_OIDC_AUDIENCE` | 空 | 期望的 token `aud`；空 = 不校验 audience |
| `KB_OIDC_JWKS_URL` | 空 | JWKS 地址；空 = 从 `{issuer}/.well-known/openid-configuration` 发现 |
| `KB_OIDC_ALGORITHMS` | `["RS256"]` | 允许的签名算法 |
| `KB_OIDC_LEEWAY_SECONDS` | `30` | 时钟偏差容忍 |
| `KB_OIDC_JWKS_CACHE_TTL_S` | `300` | JWKS 缓存刷新间隔 |
| `KB_OIDC_HTTP_TIMEOUT_S` | `5.0` | OIDC/JWKS HTTP 超时 |

**本地 Keycloak（独立项目）：**

```dotenv
KB_OIDC_ISSUER=http://localhost:8180/realms/kb
KB_OIDC_AUDIENCE=kb-api
```

**启用 OIDC 流程：**

1. 启动 `knowledge-base-keycloak`，在 Admin Console 配置 realm / client / 用户。
2. `uv run alembic upgrade head` 确保租户表存在。
3. 在 server 数据库登记用户的 OIDC `sub`：

   ```sql
   INSERT INTO users (subject, email, display_name)
   VALUES ('<oidc-sub>', '<email>', '<display name>');

   INSERT INTO tenant_memberships (tenant_id, user_id, role)
   SELECT t.id, u.id, 'editor'
   FROM tenants t, users u
   WHERE t.slug = 'default' AND u.subject = '<oidc-sub>';
   ```

4. 设置 `KB_OIDC_ISSUER` / `KB_OIDC_AUDIENCE` 并重启 server。

**RBAC 角色矩阵**（`tenant_memberships.role`）：

| 角色 | 读文档/会话 | 写文档 | Chat / Writing | 创建/应用 Operations |
| --- | --- | --- | --- | --- |
| `tenant_admin` | yes | yes | yes | yes |
| `editor` | yes | yes | yes | yes |
| `member` | yes | no | yes | 创建 yes / 应用 no |
| `viewer` | yes | no | no | no |

详见 [identity-tenants.md](https://github.com/lennylin-lab/knowledge-base-server/blob/main/docs/identity-tenants.md)。

### 5.2 服务账号（内部路由）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `KB_SERVICE_ACCOUNT_KEY` | 空 | 内部 health/operations 等路由的 Bearer key；空 = 全部拒绝 |
| `KB_SERVICE_ACCOUNT_SUBJECT` | `service-account` | 审计用 subject 名 |

### 5.3 租户

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `KB_TENANT_DEFAULT_SLUG` | `default` | 默认租户 slug |
| `KB_TENANT_DEFAULT_NAME` | `Default tenant` | 默认租户显示名 |

### 5.4 与 Gateway 认证的关系

- `KB_CHAT_API_KEY` / `KB_EMBEDDING_API_KEY`：**仅用于 server 调用 Gateway**，不代表用户身份。
- 用户访问 `/api/v1/*` 需要 OIDC token（启用 OIDC 后）。
- Gateway 的 model policy、quota、限流在 Gateway 侧配置，与 server RBAC 无关。

---

## 6. knowledge-base-flutter（OIDC 编译配置）

Flutter 不使用 `.env` ，通过 **`--dart-define`** 或运行时 `SharedPreferences` 覆盖：

| dart-define | 默认 | 说明 |
| --- | --- | --- |
| `OIDC_ISSUER` | 空 | 空 = 兼容模式（无登录门） |
| `OIDC_CLIENT_ID` | `kb-web` | Keycloak client id |
| `OIDC_REDIRECT_URI` | 按平台 | Web: `{origin}/auth/callback`；Native: `http://localhost:8182/auth/callback` |
| `OIDC_SCOPES` | `openid` | OIDC scope |

**本地 dev 示例：**

```bash
flutter run \
  --dart-define=OIDC_ISSUER=http://localhost:8180/realms/kb \
  --dart-define=OIDC_CLIENT_ID=kb-web
```

`OIDC_ISSUER` 必须与 server 的 `KB_OIDC_ISSUER` 一致（同一 realm）。

---

## 7. 网络访问注意

### 7.1 本仓库统一编排（`docker-compose.prod.yml`）

所有服务在**同一 Docker 网络**内，容器间用**服务名**通信：

| 调用方 | Keycloak Issuer（OIDC） | Gateway API |
| --- | --- | --- |
| `server` / `worker` 容器 | `https://<公网域名>/realms/CyberVem`（`KB_OIDC_ISSUER`） | `http://gateway:8080/v1`（`KB_CHAT_BASE_URL` / `KB_EMBEDDING_BASE_URL`） |
| 宿主机 curl / 反向代理 | `http://127.0.0.1:8080` | `http://127.0.0.1:8091/v1` |

PostgreSQL、Redis、Elasticsearch **无宿主机端口**，仅 `postgres` / `redis` / `elasticsearch` 主机名可达。

### 7.2 各源码仓库独立 compose（本地开发）

各 compose **默认不在同一 Docker 网络**：

| 调用方 | Keycloak 地址 | Gateway 地址 |
| --- | --- | --- |
| server 进程在宿主机（`uvicorn`） | `http://localhost:8180/realms/kb` | `http://127.0.0.1:8091/v1` |
| server 跑在容器内 | `http://host.docker.internal:8180/realms/kb` | `http://host.docker.internal:8091/v1` |

Linux 容器访问宿主机服务时，在 compose 中加：

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

---

## 8. 推荐联调配置

### 8.1 场景 A：最快验证（fake Gateway + server 兼容模式）

**Gateway `.env`：**

```dotenv
GATEWAY_ADDR=:8080
GATEWAY_PROVIDER=fake
GATEWAY_API_KEYS=kb-local:kb-server:sk-kb-local
GATEWAY_MODELS=gateway-echo:fake:echo-model
GATEWAY_DEFAULT_MODELS=kb-server:gateway-echo
GATEWAY_ADMIN_TOKEN=dev-admin-token
```

**Server `.env`：**

```dotenv
KB_DATABASE_URL=postgresql+asyncpg://kb:kb@localhost:5432/kb
KB_ELASTICSEARCH_URL=http://localhost:9200
KB_CORS_ORIGINS=["*"]

KB_CHAT_BASE_URL=http://127.0.0.1:8080/v1
KB_CHAT_API_KEY=sk-kb-local

KB_EMBEDDING_BASE_URL=https://api.openai.com/v1
KB_EMBEDDING_API_KEY=sk-your-openai-key
KB_EMBEDDING_MODEL=text-embedding-3-small
KB_EMBEDDING_DIM=1536
```

**启动顺序：**

```bash
cd knowledge-base-server && docker compose up -d
cd knowledge-base-gateway && go run ./cmd/gateway
cd knowledge-base-server && uv run alembic upgrade head && uv run uvicorn app.main:app --reload
```

### 8.2 场景 B：Compose Gateway（数据库模式）+ server

```bash
# Gateway
cd knowledge-base-gateway
cp docker-compose.yml.example docker-compose.yml
docker compose up -d --build

# Mint key（见 §3.8）

# Server
cd knowledge-base-server
docker compose up -d
uv run alembic upgrade head
```

**Server `.env`（LLM 相关）：**

```dotenv
KB_CHAT_BASE_URL=http://127.0.0.1:8091/v1
KB_CHAT_API_KEY=<minted-gateway-key>

KB_EMBEDDING_BASE_URL=http://127.0.0.1:8091/v1
KB_EMBEDDING_API_KEY=<minted-gateway-key>
KB_EMBEDDING_MODEL=<catalog-中声明-embeddings-的公开模型>
KB_EMBEDDING_DIM=1536
```

### 8.3 场景 C：完整本地栈（Keycloak + Gateway + server + OIDC）

```bash
# 1. Keycloak
cd knowledge-base-keycloak && docker compose up -d --build
# → Admin Console 配置 realm kb、client kb-web、用户

# 2. Gateway
cd knowledge-base-gateway && docker compose up -d --build
# → mint Gateway key、设置 default model

# 3. Server
cd knowledge-base-server
docker compose up -d
uv run alembic upgrade head
# → 登记用户 subject（§5.1 SQL）
uv run uvicorn app.main:app --reload
```

**Server `.env` 追加：**

```dotenv
KB_OIDC_ISSUER=http://localhost:8180/realms/kb
KB_OIDC_AUDIENCE=kb-api
```

**Flutter：**

```bash
flutter run --dart-define=OIDC_ISSUER=http://localhost:8180/realms/kb
```

---

## 9. 生产部署（本仓库）

使用 [`.env.prod.example`](.env.prod.example) → `.env.prod` 与 [`docker-compose.prod.yml`](docker-compose.prod.yml) 统一编排。完整步骤见 [README.md](README.md)。

**已上线后的同步与镜像升级**（部署仓库 push / `git pull`、GHCR 标签 bump、`pull` + `up`、分组件注意点、验证与回滚）见 [README.md § 镜像与配置同步](README.md#镜像与配置同步)。

**env 文件分工：**

| 文件 | 变量示例 | 说明 |
| --- | --- | --- |
| `.env.prod` | `GATEWAY_IMAGE`, `SERVER_IMAGE`, `KEYCLOAK_IMAGE`, `ELASTICSEARCH_IMAGE` | GHCR 镜像 |
| `.env.prod` | `POSTGRES_*`, `GATEWAY_DB_*`, `KB_DB_*`, `KEYCLOAK_DB_*` | 共享 PG 与三库账号 |
| `gateway/.env` | `GATEWAY_ADMIN_TOKEN`, `OPENAI_API_KEY*`, `GATEWAY_HOST_PORT` | Gateway 密钥与端口 |
| `server/.env` | `KB_CHAT_*`, `KB_EMBEDDING_*`, `KB_OIDC_*`, `SERVER_HOST_PORT` | Server 业务与 OIDC |
| `keycloak/.env` | `KEYCLOAK_HOSTNAME`, `KEYCLOAK_ADMIN_*`, `TURNSTILE_*` | Keycloak 与 bootstrap |

**Compose 注入（勿在 `server/.env` 重复）：** `GATEWAY_DATABASE_URL`、`GATEWAY_REDIS_ADDR`、`KB_DATABASE_URL`、`KB_ELASTICSEARCH_URL`、`KB_REDIS_URL`、`KB_CHAT_BASE_URL`、`KB_EMBEDDING_BASE_URL`（后两者默认 `http://gateway:8080/v1`）。

密码含 `/ ? # @ :` 等 URI 保留字符时，在 `.env.prod` 设置完整 `GATEWAY_DATABASE_URL` / `KB_DATABASE_URL`（URL 编码密码），见 [`.env.prod.example`](.env.prod.example)。

**分阶段启动：**

```bash
# 1) 基础设施 + Gateway（无 Server）
docker compose ... up -d

# 2) Gateway bootstrap → 更新 server/.env
./gateway/scripts/bootstrap-fake.sh          # fake
# 或 gateway/bootstrap-production.md          # 生产

# 3) Server
docker compose ... --profile app up -d server
```

Gateway 业务初始化详见 [`gateway/bootstrap-production.md`](gateway/bootstrap-production.md)。

**生产 OIDC 示例（`server/.env`）：**

```dotenv
KB_OIDC_ISSUER=https://auth.example.com/realms/CyberVem
KB_OIDC_AUDIENCE=kb-api
KB_CHAT_BASE_URL=http://gateway:8080/v1
KB_CHAT_API_KEY=<minted-via-admin-api>
```

**Keycloak 公网域名（`keycloak/.env`）：** `KEYCLOAK_HOSTNAME=auth.example.com`；反向代理需转发 `X-Forwarded-*`。

---

## 10. Gateway 错误码速查

| HTTP | 典型 code | 处理建议 |
| --- | --- | --- |
| 400 | `invalid_request`, `upstream_rejected_request` | 修正请求体或模型参数 |
| 401 | `invalid_api_key`, `api_key_expired`, `api_key_revoked` | 轮换 Gateway key；不要重试原请求 |
| 403 | `model_not_allowed` | 检查公开模型名与 subject policy |
| 429 | `rate_limit_exceeded`, `quota_exceeded` | 按 `Retry-After` 退避 |
| 503 | `upstream_unavailable`, `limiter_unavailable` | 网络/上游恢复后退避重试 |
| 504 | `upstream_timeout` | 可按退避策略重试 |

---

## 11. 常见配置错误

| 现象 | 原因 |
| --- | --- |
| 401 on Gateway | `KB_CHAT_API_KEY` 填成了 OpenAI key，或 key 已过期/撤销 |
| 403 `model_not_allowed` | `KB_CHAT_MODEL` 不是 catalog 公开名，或 subject 无 grant |
| 503 `chat_unavailable` | server 未读到 `KB_CHAT_API_KEY`（`.env` 路径/前缀错误） |
| embedding 502 / 500 | catalog 未声明 `embeddings`，或 `embedding_dim` 与 pgvector 不一致 |
| `/readyz` 503 | Gateway PG/Redis 未就绪，或 enabled provider 缺密钥 |
| server 401 但 token 有效 | `KB_OIDC_ISSUER`/`AUDIENCE` 与 IdP 不一致，或用户 subject 未入库 |
| Redis DSN 写错 | 本仓库 compose 已注入 `redis://redis:6379`；勿改成宿主机地址 |
| Keycloak 连不上（独立 dev） | server compose 不含 Keycloak，需单独启动 keycloak 仓库 |
| Keycloak 连不上（本仓库） | 检查 `KB_OIDC_ISSUER` 公网 URL 与 `KEYCLOAK_HOSTNAME` 一致 |

---

## 12. 启动检查清单

### Keycloak

- [ ] `$DC up -d` 后 Keycloak healthy（`/health/ready` 在容器内 **9000** 管理口；或 `curl http://127.0.0.1:8080/realms/CyberVem`）
- [ ] 首次：`$DC --profile bootstrap up keycloak-post-import` 完成
- [ ] Admin Console 创建用户；`aud` 与 `KB_OIDC_AUDIENCE` 一致

### Gateway

- [ ] 开发模式：`GATEWAY_API_KEYS` + `GATEWAY_MODELS` 已配置
- [ ] 数据库模式：`GATEWAY_DATABASE_URL` + migration 已执行 + Redis（若 `limits_mode=redis`）
- [ ] 真实 provider 密钥已在容器/进程环境中注入
- [ ] Admin token 已设置（需要 mint key 时）
- [ ] `curl http://127.0.0.1:8091/healthz` 和 `/readyz` 均 200

### Server

- [ ] `KB_DATABASE_URL` + ES 可达，migration 已跑
- [ ] `KB_CHAT_BASE_URL` / `KB_EMBEDDING_BASE_URL` 指向 Gateway `/v1` 根（compose 默认注入）
- [ ] `KB_CHAT_API_KEY` 为有效 Gateway key
- [ ] embedding 路径与 chat 策略一致（直连 provider 或都走 Gateway）
- [ ] 若启用 OIDC：`KB_OIDC_ISSUER` + 用户 subject 已入库 + `KB_OIDC_AUDIENCE` 正确

---

## 13. 延伸阅读

| 文档 | 链接 |
| --- | --- |
| 本仓库部署 | [README.md](README.md) |
| Gateway 镜像 | [gateway.md](gateway.md) |
| Server 镜像 | [server.md](server.md) |
| Keycloak 镜像 | [keycloak.md](keycloak.md) |
| Gateway 联调（v1.1） | [gateway-integration.md](https://github.com/lennylin-lab/knowledge-base-server/blob/main/docs/gateway-integration.md) |
| Gateway v1.2 | [gateway-v1.2-integration.md](https://github.com/lennylin-lab/knowledge-base-server/blob/main/docs/gateway-v1.2-integration.md) |
| Gateway v1.3 | [gateway-v1.3-integration.md](https://github.com/lennylin-lab/knowledge-base-server/blob/main/docs/gateway-v1.3-integration.md) |
| 身份与租户 RBAC | [identity-tenants.md](https://github.com/lennylin-lab/knowledge-base-server/blob/main/docs/identity-tenants.md) |
| Gateway 源码 README | [knowledge-base-gateway](https://github.com/lennylin-lab/knowledge-base-gateway/blob/master/README.md) |
| Keycloak 源码 README | [knowledge-base-keycloak](https://github.com/lennylin-lab/knowledge-base-keycloak/blob/master/README.md) |
