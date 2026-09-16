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
    ├── Elasticsearch                              └── Redis (限流 / quota)
    ├── Redis (ARQ 队列 / 缓存)
    └── OIDC ──► keycloak :8080
                      └── PostgreSQL (keycloak)
```

**共享基础设施（单实例）：**

- **PostgreSQL**（`pgvector/pgvector:pg16`）：三个逻辑库 `gateway` / `kb` / `keycloak`
- **Redis**：Gateway 限流与 Server 队列/缓存共用（key 前缀 `gw:*` / `kb:c1:*` 隔离）
- **Elasticsearch**（含 IK 插件）：仅 Server 使用

PostgreSQL、Redis、Elasticsearch **不映射宿主机端口**，仅容器网络内可达。应用端口绑定 `127.0.0.1`，供本机反向代理转发。

## 目录结构

```text
docker-compose.prod.yml      # 统一编排
.env.prod.example            # 公共基础设施与镜像坐标
gateway/.env.example         # Gateway 运行时密钥
server/.env.example          # Server 业务配置
keycloak/.env.example        # Keycloak 与 Turnstile
keycloak/import/             # Realm JSON（首次空库自动导入）
keycloak/scripts/            # 导入后配置与 bootstrap
docker/postgres/init/        # 首次启动创建三库 + pgvector
```

## 前置条件

- Docker Engine + Compose v2
- Linux 宿主机（Elasticsearch）：

  ```bash
  sudo sysctl -w vm.max_map_count=262144
  # 持久化：/etc/sysctl.d/99-elasticsearch.conf
  ```

- 私有 GHCR 包需先登录：

  ```bash
  echo "$GITHUB_TOKEN" | docker login ghcr.io -u USERNAME --password-stdin
  ```

## 首次部署

### 1. 准备环境变量

```bash
cp .env.prod.example .env.prod && chmod 600 .env.prod
cp gateway/.env.example gateway/.env
cp server/.env.example server/.env
cp keycloak/.env.example keycloak/.env
```

编辑各文件中的密码与域名。变量职责：

| 文件 | 内容 |
| --- | --- |
| `.env.prod` | PG 超级用户、三库账号、GHCR 镜像标签 |
| `gateway/.env` | Admin Token、上游 LLM 密钥、宿主机端口 |
| `server/.env` | Gateway 联调 key、OIDC、CORS、ES heap |
| `keycloak/.env` | Hostname、管理员、Turnstile、宿主机端口 |

Compose 需合并四个 env 文件（插值与容器环境）：

```bash
export DC="docker compose \
  --env-file .env.prod \
  --env-file gateway/.env \
  --env-file server/.env \
  --env-file keycloak/.env \
  -f docker-compose.prod.yml"
```

### 2. 拉取并启动

```bash
$DC pull
$DC up -d
```

启动顺序（由 `depends_on` 保证）：

```text
postgres ─┬─ gateway-migrate → gateway (/readyz)
          ├─ server-migrate  → server
          └─ keycloak (--import-realm，仅空 keycloak 库)
redis / elasticsearch ──► gateway, server
```

### 3. Keycloak 导入后配置（首次）

空 keycloak 库首次启动会自动导入 `keycloak/import/cybervem-realm.json`。随后执行 bootstrap（主题、CSP、Turnstile 单页登录）：

```bash
$DC --profile bootstrap up keycloak-post-import
```

或在宿主机（Keycloak 已运行）：

```bash
cd keycloak && ./scripts/post-import.sh
```

之后在 Admin Console 手动创建用户，并在 server 数据库关联 OIDC `sub`（见 server 文档）。

### 4. 为 Server mint Gateway Key

1. 在 `gateway/.env` 设置 `GATEWAY_ADMIN_TOKEN`
2. 通过 Admin API（默认 `http://127.0.0.1:8092`）为 server subject mint API key
3. 将 key 写入 `server/.env` 的 `KB_CHAT_API_KEY` 与 `KB_EMBEDDING_API_KEY`
4. 重启 server：`$DC up -d server`

首次验证可设 `KB_CHAT_MODEL=gateway-echo`（gateway 迁移 seed 的 fake 模型）。

### 5. 健康检查

```bash
curl -fsS http://127.0.0.1:8091/readyz   # gateway
curl -fsS http://127.0.0.1:8000/healthz  # server
curl -fsS http://127.0.0.1:8080/health/ready  # keycloak
```

## 可选：ARQ 索引 Worker

Compose 已为 server 注入 `KB_REDIS_URL=redis://redis:6379`。启用独立 worker 处理索引队列：

```bash
$DC --profile queue up -d worker
```

不启用时，索引在 server 进程内以 BackgroundTasks 运行。

## 默认端口（127.0.0.1）

| 服务 | 变量 | 默认 |
| --- | --- | --- |
| Gateway API | `GATEWAY_HOST_PORT` | 8091 |
| Gateway Admin | `GATEWAY_ADMIN_HOST_PORT` | 8092 |
| Server API | `SERVER_HOST_PORT` | 8000 |
| Keycloak | `KEYCLOAK_HOST_PORT` | 8080 |

## 升级

1. 在 `.env.prod` 更新镜像标签（如 `GATEWAY_IMAGE=...:v1.4`）
2. `$DC pull`
3. `$DC up -d`（migrate job 会先执行，再滚动应用容器）

各组件回滚策略见对应 `*.md` 文档。数据库 `down` 迁移不在生产启动路径中。

## 重置 Keycloak Realm 导入

`--import-realm` 仅在 **keycloak 库为空** 时生效。重新导入需清空 keycloak 数据（例如删除 postgres volume 后重建，或手动 drop `keycloak` 库）。

## 安全说明

- 上游 LLM 密钥只配置在 `gateway/.env`，**不要**写入 server
- Server 的 `KB_CHAT_API_KEY` 是 Gateway 签发的 service key，不是 OpenAI key
- 所有 `*.env` 已列入 `.gitignore`，勿提交密钥
- 生产 TLS 与 `X-Forwarded-*` 由前置 nginx / Cloudflare 终止；Keycloak 使用 `--proxy-headers=xforwarded`

## 延伸阅读

- [环境变量与联调配置指南](configuration.md)
- [Gateway 镜像说明](gateway.md)
- [Server 镜像说明](server.md)
- [Keycloak 镜像说明](keycloak.md)
