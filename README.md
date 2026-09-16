# knowledge-base-deploy

Knowledge Base 生产环境统一 Docker Compose 编排。拉取 [GHCR](https://github.com/lennylin-lab) release 镜像，**不本地 build**。

| 组件 | 源码仓库 |
| --- | --- |
| Gateway | [knowledge-base-gateway](https://github.com/lennylin-lab/knowledge-base-gateway) |
| Server | [knowledge-base-server](https://github.com/lennylin-lab/knowledge-base-server) |
| Keycloak | [knowledge-base-keycloak](https://github.com/lennylin-lab/knowledge-base-keycloak) |

镜像布局见 [`gateway.md`](gateway.md)、[`server.md`](server.md)、[`keycloak.md`](keycloak.md)；环境变量全集见 [`configuration.md`](configuration.md)。

## 架构

```text
浏览器 / Flutter
    │  Bearer OIDC token（可选）
    ▼
server :8000 ── KB_CHAT_* / KB_EMBEDDING_* ──► gateway :8080
    │                                              │
    ├── PostgreSQL (kb, pgvector)                  ├── PostgreSQL (gateway)
    ├── Elasticsearch                              └── Redis (限流 / quota, AOF)
    ├── Redis (ARQ 队列 / 缓存)
    └── OIDC ──► keycloak :8080
                      └── PostgreSQL (keycloak)
```

**共享基础设施（单实例）：**

- **PostgreSQL**（`pgvector/pgvector:pg16`）：三个逻辑库 `gateway` / `kb` / `keycloak`
- **Redis**：Gateway 限流/quota 与 Server 队列/缓存共用（key 前缀 `gw:*` / `kb:c1:*` 隔离；**AOF 持久化**保留配额计数）
- **Elasticsearch**（含 IK 插件）：仅 Server 使用

PostgreSQL、Redis、Elasticsearch **不映射宿主机端口**。应用端口绑定 `127.0.0.1`。

## 目录结构

```text
docker-compose.prod.yml      # 统一编排
.env.prod.example            # 公共基础设施与镜像坐标
gateway/.env.example         # Gateway 运行时密钥
gateway/scripts/bootstrap-fake.sh   # fake 联调一键 bootstrap
gateway/bootstrap-production.md     # 生产 catalog 迁移 / 初始化
server/.env.example          # Server 业务配置（--profile app）
keycloak/.env.example        # Keycloak 与 Turnstile
```

## 前置条件

- Docker Engine + Compose v2
- Linux：`sudo sysctl -w vm.max_map_count=262144`
- 私有 GHCR：`echo "$GITHUB_TOKEN" | docker login ghcr.io -u USERNAME --password-stdin`

## 首次部署

### 1. 准备环境变量

```bash
cp .env.prod.example .env.prod && chmod 600 .env.prod
cp gateway/.env.example gateway/.env
cp server/.env.example server/.env
cp keycloak/.env.example keycloak/.env
```

| 文件 | 内容 |
| --- | --- |
| `.env.prod` | PG 三库账号、GHCR 镜像；可选 `GATEWAY_DATABASE_URL` / `KB_DATABASE_URL`（密码含特殊字符时 URL 编码） |
| `gateway/.env` | `GATEWAY_ADMIN_TOKEN`、上游 LLM 密钥 |
| `server/.env` | mint 后的 Gateway service key、模型名、OIDC |
| `keycloak/.env` | Hostname、Turnstile |

```bash
export DC="docker compose \
  --env-file .env.prod \
  --env-file gateway/.env \
  --env-file server/.env \
  --env-file keycloak/.env \
  -f docker-compose.prod.yml"
```

### 2. 启动基础设施 + Gateway（**不含 Server**）

```bash
$DC pull
$DC up -d
```

默认 `up` 启动 postgres、redis、elasticsearch、gateway（含 migrate）、keycloak。**不**启动 `server`（`--profile app`）。

确认 Gateway：

```bash
curl -fsS http://127.0.0.1:8091/readyz
```

### 3. Gateway 业务 bootstrap

**fake 联调（256 维，验证编排）：**

```bash
./gateway/scripts/bootstrap-fake.sh
# 按输出更新 server/.env
```

**生产 / 从独立 kb-gateway 栈迁移：** 见 [`gateway/bootstrap-production.md`](gateway/bootstrap-production.md)。

### 4. Keycloak bootstrap（首次）

```bash
$DC --profile bootstrap up keycloak-post-import
```

Admin Console 创建用户；在 server 库登记 OIDC `sub`（见 [configuration.md](configuration.md) §5）。

### 5. 启动 Server

```bash
$DC --profile app up -d server
curl -fsS http://127.0.0.1:8000/healthz
```

可选 ARQ worker：`$DC --profile app --profile queue up -d worker`

## 默认端口（127.0.0.1）

| 服务 | 变量 | 默认 |
| --- | --- | --- |
| Gateway API | `GATEWAY_HOST_PORT` | 8091 |
| Gateway Admin | `GATEWAY_ADMIN_HOST_PORT` | 8092 |
| Server API | `SERVER_HOST_PORT` | 8000 |
| Keycloak | `KEYCLOAK_HOST_PORT` | 8080 |

## 升级

1. 更新 `.env.prod` 镜像标签 → `$DC pull` → `$DC up -d`（migrate job 先执行）

## Redis 与配额

Gateway 日/月 token 配额在 Redis。`redis-data` 卷 + AOF；`docker compose down` **不**删卷时配额保留。删卷后配额从 0 重计（审计在 PostgreSQL，不自动恢复配额计数）。

## 安全说明

- 上游 LLM 密钥只在 `gateway/.env`
- `KB_CHAT_API_KEY` 是 Gateway 签发的 service key
- 勿提交 `*.env`

## 延伸阅读

- [环境变量与联调配置指南](configuration.md)
- [Gateway 生产 bootstrap](gateway/bootstrap-production.md)
- [Gateway / Server / Keycloak 镜像说明](gateway.md)
