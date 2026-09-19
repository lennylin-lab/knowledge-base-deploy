# Server 容器镜像

本文档仅说明 **knowledge-base-server** 的生产镜像来源与镜像内布局。环境变量见 [`server/.env.example`](server/.env.example)；变量语义与联调说明见 [`configuration.md`](configuration.md) §4。PostgreSQL、Redis、Elasticsearch 由本仓库 [`docker-compose.prod.yml`](docker-compose.prod.yml) 负责。

源码与 CI 定义在 [`knowledge-base-server`](https://github.com/lennylin-lab/knowledge-base-server) 仓库。

## 镜像坐标

| 组件 | Registry | 镜像名 | 版本标签 |
| --- | --- | --- | --- |
| API（FastAPI） | `ghcr.io` | `ghcr.io/lennylin-lab/knowledge-base-server` | Git 标签 `v*`（例如 `v0.1.0`），与源码 release 一一对应 |
| Elasticsearch（含 IK 插件） | `ghcr.io` | `ghcr.io/lennylin-lab/knowledge-base-server/elasticsearch` | 固定 `8.17.3-ik`（与 ES 版本锁定；插件版本变更时 CI 会更新此标签） |

推送 `v*` 标签到 `knowledge-base-server` 的 `main` 时，[Release workflow](https://github.com/lennylin-lab/knowledge-base-server/blob/main/.github/workflows/release.yml) 自动构建并推送上述两个镜像。**镜像内不包含** API Key、DSN 或其它密钥；所有敏感配置在运行时由部署环境注入。

## 拉取

公开包可直接拉取：

```bash
docker pull ghcr.io/lennylin-lab/knowledge-base-server:v0.1.0
docker pull ghcr.io/lennylin-lab/knowledge-base-server/elasticsearch:8.17.3-ik
```

若包为私有，需先登录 GHCR（PAT 需 `read:packages`）：

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u USERNAME --password-stdin
docker pull ghcr.io/lennylin-lab/knowledge-base-server:v0.1.0
docker pull ghcr.io/lennylin-lab/knowledge-base-server/elasticsearch:8.17.3-ik
```

---

## API 镜像

多阶段构建（`Dockerfile`）：`uv` 安装 Python 依赖 + `python:3.12-slim-bookworm` 运行时，以 **非 root** 用户 `nobody` 运行。

| 路径 | 说明 |
| --- | --- |
| `/app/.venv/` | 运行时 Python 依赖（`uv sync --frozen --no-dev`） |
| `/app/src/` | 应用源码（`PYTHONPATH=/app/src`） |
| `/app/alembic/` | Alembic 迁移脚本 |
| `/app/alembic.ini` | Alembic 配置（数据库 URL 由运行时 `KB_DATABASE_URL` 注入） |

依赖通过 `PYTHONPATH` 加载源码，镜像内不执行 hatchling 打包；升级镜像即升级应用代码与迁移脚本。

### 进程与端口

| 角色 | 容器内命令 | 说明 |
| --- | --- | --- |
| API | 默认 `uvicorn app.main:app --host 0.0.0.0 --port 8000` | 监听 **8000**；健康检查 `GET /healthz`（compose 用 Python urllib，镜像内无 curl） |
| Migrate | 覆盖 command 为 `alembic upgrade head` | 一次性 job；DSN 来自 `KB_DATABASE_URL` |
| Worker | 覆盖 command 为 `python -m app.cli worker` | ARQ 索引 worker；无 HTTP 探活；需 `KB_REDIS_URL`（见 `server/` 配置） |
| Reindex | 覆盖 command 为 `python -m app.cli reindex` | 补偿性全量重索引；按需手动触发 |

同一 API 镜像同时服务 **api**、**migrate**、**worker**、**reindex** 等角色：Compose 中通过 `command` / `entrypoint` 区分，无需单独镜像。

### 运行时要求

- Python：3.12（镜像内已包含）
- 用户：固定以 `nobody` 运行；编排时勿要求 root
- 配置：通过环境变量或挂载的 env 文件注入（见 `server/` 目录，不在此重复列举）
- 连通性：需能访问根目录 Compose 提供的 PostgreSQL、Elasticsearch；启用 ARQ 时需 Redis

---

## Elasticsearch 镜像

基于 `docker.elastic.co/elasticsearch/elasticsearch:8.17.3`，构建时预装 **analysis-ik** 中文分词插件（版本与 ES 锁定）。

| 项 | 说明 |
| --- | --- |
| 基础版本 | Elasticsearch **8.17.3** |
| 插件 | `analysis-ik`（CI 从 infinilabs release 拉取 zip 后本地安装） |
| 默认端口 | **9200** |
| 索引名 | 由 API 侧 `KB_ES_INDEX` 控制（默认 `kb_documents`） |

### 运行时要求

- **Linux 宿主机**：`vm.max_map_count >= 262144`（根目录 Compose 或运维文档中统一说明）
- 数据目录需持久化 volume；mapping / analyzer 变更后需按 `server/` 运维流程触发 API 侧重索引
- 安全：开发 compose 默认关闭 xpack security；生产 TLS / 认证由根目录编排与 `server/` 配置决定

---

## 版本与回滚

- **升级 API**：拉取新 `v*` 标签 → 先跑 migrate job → 再滚动 API 容器（顺序由根目录 Compose 保证）。
- **升级 ES 镜像**：仅在 ES 大版本或 IK 插件变更时更新 `8.17.3-ik` 标签；通常与 API release 解耦，按运维窗口单独替换。
- **回滚 API**：将镜像标签改回上一 `v*` 版本，重新 pull 并按相同顺序部署；数据库 down 迁移是否执行由运维策略决定，生产启动路径不包含自动 `down`。
- **回滚 ES**：改回上一 ES 镜像标签；若 mapping 不兼容，需配合 API 侧重索引。

Package 页面：

- API：<https://github.com/lennylin-lab/knowledge-base-server/pkgs/container/knowledge-base-server>
- Elasticsearch：<https://github.com/lennylin-lab/knowledge-base-server/pkgs/container/knowledge-base-server%2Felasticsearch>
