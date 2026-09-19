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
scripts/push.sh              # 本地 → 服务器 SSH 同步（含 *.env）
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

## 镜像与配置同步

生产环境有两类独立变更，流程不同：

| 变更类型 | 典型内容 | 同步方式 |
| --- | --- | --- |
| **部署仓库** | `docker-compose.prod.yml`、脚本、realm JSON、文档 | `./scripts/push.sh` 或服务器 `git pull` |
| **GHCR 应用镜像** | Gateway / Server / Keycloak / ES 新版本 | 改 `.env.prod` 镜像标签 → `$DC pull` → `$DC up` |

二者常一起发生（例如本仓库改了 compose，同时上游发了新 `v*` 镜像），但**镜像升级不自动拉取**——必须显式改标签并 `pull`。

### 1. 同步部署仓库到服务器

**本地开发机（推荐）：**

```bash
# 交互选 SSH Host（~/.ssh/config）与远程目录，默认 ~/knowledge-base-deploy
./scripts/push.sh

# 或指定 Host / 目录
./scripts/push.sh ColoCrossing ~/knowledge-base-deploy
```

脚本通过 SSH 同步整个目录（**含** `*.env`，**不含** `.git/`）。远程无 `rsync` 时自动降级为 tar 流。

**服务器已 clone 仓库时：**

```bash
cd ~/knowledge-base-deploy
git pull
# 若 .env.prod.example 有新增变量，手动合并到 .env.prod / gateway/.env 等
```

> 敏感配置只在服务器本地 `*.env`，不要提交 git。`push.sh` 用于把本地已配好的 env 推到服务器。

### 2. 升级 GHCR 应用镜像

在对应源码仓库查看 Release / 标签说明（是否有 breaking change、是否必须 migrate）：

| 变量（`.env.prod`） | 镜像 | Release 来源 |
| --- | --- | --- |
| `GATEWAY_IMAGE` | `ghcr.io/lennylin-lab/knowledge-base-gateway:v*` | [knowledge-base-gateway Releases](https://github.com/lennylin-lab/knowledge-base-gateway/releases) |
| `SERVER_IMAGE` | `ghcr.io/lennylin-lab/knowledge-base-server:v*` | [knowledge-base-server Releases](https://github.com/lennylin-lab/knowledge-base-server/releases) |
| `ELASTICSEARCH_IMAGE` | `.../elasticsearch:8.17.3-ik` | 同上（Server release 常同发 ES 镜像） |
| `KEYCLOAK_IMAGE` | `ghcr.io/lennylin-lab/knowledge-base-keycloak:v*` | [knowledge-base-keycloak Releases](https://github.com/lennylin-lab/knowledge-base-keycloak/releases) |

**服务器上执行（已设置 `$DC`，见上文）：**

```bash
# 1. 私有 GHCR（每台机器只需 login 一次）
echo "$GITHUB_TOKEN" | docker login ghcr.io -u USERNAME --password-stdin

# 2. 编辑 .env.prod，更新上述 IMAGE 标签（例：v1.3 → v1.4）

# 3. 拉取新镜像
$DC pull

# 4. 滚动升级（migrate job 会先跑，再启长期服务）
$DC up -d

# 5. 若 Server / worker 已在跑，需带上 profile
$DC --profile app up -d server
$DC --profile app --profile queue up -d worker   # 若启用 ARQ
```

**Compose 自动顺序（无需手工拆步）：**

```text
postgres healthy
  ├─► gateway-migrate (one-shot) ──► gateway
  ├─► server-migrate  (one-shot) ──► server / worker（--profile app / queue）
  └─► keycloak（不 re-import realm，除非清空 keycloak DB）
```

Gateway / Server 的 `migrate` job 幂等：已是最新 schema 时 exit 0。`up -d` 会重建 one-shot migrate 容器并再跑一遍，属正常行为。

**Gateway 仅配置变更（无新镜像）：** SQL 导入 catalog 后需 `$DC restart gateway` 加载 registry（见 [gateway/bootstrap-production.md](gateway/bootstrap-production.md)）。纯镜像升级一般不需要，除非 Release 说明要求。

**Keycloak 镜像升级：** 改 `KEYCLOAK_IMAGE` → `$DC pull` → `$DC up -d keycloak`。已有 PostgreSQL 数据**不会**重新 `--import-realm`。仅当 realm JSON / client scope 结构变更且需重导时，才清空 keycloak 库或 volume（见 [keycloak.md](keycloak.md)）。

**Elasticsearch 镜像：** 大版本或 IK 插件变更时才动 `ELASTICSEARCH_IMAGE`；与 API 发版可解耦，按运维窗口单独 `$DC up -d elasticsearch`。

### 3. 升级后验证

```bash
curl -fsS http://127.0.0.1:8091/readyz          # Gateway
curl -fsS http://127.0.0.1:8000/healthz         # Server（--profile app）
docker exec -it $($DC ps -q postgres) psql -U gateway -d gateway -c \
  'SELECT version, dirty FROM schema_migrations;'   # Gateway schema 版本
docker exec -it $($DC ps -q postgres) psql -U kb -d kb -c \
  'SELECT * FROM alembic_version;'                  # Server schema 版本
$DC ps                                            # 各服务 healthy / exited(migrate)
```

### 4. 回滚

1. 将 `.env.prod` 中 IMAGE 标签改回上一 `v*`
2. `$DC pull && $DC up -d`（同样会跑 migrate；是否执行 DB down 由 Release 说明决定，生产 compose **不含**自动 `down`）
3. Keycloak / ES 回滚仅换镜像；Gateway / Server 若新版本已跑 forward migration，回滚镜像前需确认 schema 是否仍兼容旧二进制

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
