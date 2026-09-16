# Gateway 容器镜像

本文档仅说明 **knowledge-base-gateway** 的生产镜像来源与镜像内布局。环境变量见 [`gateway/.env.example`](gateway/.env.example)；变量语义见 [`configuration.md`](configuration.md) §3；catalog 初始化见 [`gateway/bootstrap-production.md`](gateway/bootstrap-production.md)。PostgreSQL、Redis 由 [`docker-compose.prod.yml`](docker-compose.prod.yml) 负责。

源码与 CI 定义在 [`knowledge-base-gateway`](https://github.com/lennylin-lab/knowledge-base-gateway) 仓库。

## 镜像坐标

| 项 | 值 |
| --- | --- |
| Registry | `ghcr.io` |
| 镜像名 | `ghcr.io/lennylin-lab/knowledge-base-gateway` |
| 版本标签 | Git 标签 `v*`（例如 `v1.3`），与源码 release 一一对应 |
| 当前推荐标签 | `v1.3` |

推送 `v*` 标签到 `knowledge-base-gateway` 的 `master` 时，[Release workflow](https://github.com/lennylin-lab/knowledge-base-gateway/blob/master/.github/workflows/release.yml) 自动构建并推送上述镜像。**镜像内不包含** API Key、DSN 或其它密钥；所有敏感配置在运行时由部署环境注入。

## 拉取

公开包可直接拉取：

```bash
docker pull ghcr.io/lennylin-lab/knowledge-base-gateway:v1.3
```

若包为私有，需先登录 GHCR（PAT 需 `read:packages`）：

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u USERNAME --password-stdin
docker pull ghcr.io/lennylin-lab/knowledge-base-gateway:v1.3
```

## 镜像内容

多阶段构建（`Dockerfile`）：Go 编译阶段 + Alpine 3.20 运行时，**非 root** 运行（uid/gid `10001`）。

| 路径 | 说明 |
| --- | --- |
| `/app/gateway` | 网关主进程（默认入口） |
| `/app/migrate` | PostgreSQL schema 迁移 CLI |
| `/app/migrations/` | 随镜像打包的 SQL 迁移文件（与源码 `migrations/` 同步） |
| `/etc/ssl/certs/` | CA 证书（上游 OpenAI / Anthropic HTTPS 所需） |

### 进程与端口

| 角色 | 容器内命令 | 说明 |
| --- | --- | --- |
| Gateway | 默认 `ENTRYPOINT ["/app/gateway"]` | 监听 `GATEWAY_ADDR`（默认 `:8080`） |
| Migrate | 覆盖 entrypoint 为 `["/app/migrate"]` | 一次性 job，例如 `up`；迁移目录 `-dir /app/migrations` |
| Admin API | 同一 `gateway` 进程 | 由 `GATEWAY_ADMIN_TOKEN` 启用；默认 `GATEWAY_ADMIN_ADDR=:8081`，应仅在内网暴露 |

同一镜像同时服务 **gateway** 与 **migrate** 两种角色：Compose 中通过 `entrypoint` / `command` 区分，无需单独 migrate 镜像。

### 运行时要求

- 架构：`linux/amd64`（当前 CI 构建目标）
- 用户：固定以 `10001:10001` 运行；编排时勿要求 root
- 配置：通过环境变量或挂载的 env 文件注入（见 `gateway/` 目录，不在此重复列举）

## 版本与回滚

- **升级**：拉取新标签 → 先跑 migrate job → 再滚动 gateway 容器（顺序由根目录 Compose 保证）。
- **回滚**：将镜像标签改回上一版本（如 `v1.2`），重新 pull 并按相同顺序部署；是否需要配套 down 迁移由运维策略决定，生产启动路径不包含自动 `down`。

Package 页面：<https://github.com/lennylin-lab/knowledge-base-gateway/pkgs/container/knowledge-base-gateway>
