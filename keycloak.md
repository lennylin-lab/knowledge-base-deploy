# Keycloak 容器镜像

本文档仅说明 **knowledge-base-keycloak** 的生产镜像来源与镜像内布局。环境变量见 [`keycloak/.env.example`](keycloak/.env.example)；realm 导入与 bootstrap 见 [`keycloak/`](keycloak/) 目录；变量语义见 [`configuration.md`](configuration.md) §2。PostgreSQL 与反向代理由本仓库 [`docker-compose.prod.yml`](docker-compose.prod.yml) 负责。

源码与 CI 定义在 [`knowledge-base-keycloak`](https://github.com/lennylin-lab/knowledge-base-keycloak) 仓库。

## 镜像坐标

| 项 | 值 |
| --- | --- |
| Registry | `ghcr.io` |
| 镜像名 | `ghcr.io/lennylin-lab/knowledge-base-keycloak` |
| 版本标签 | Git 标签 `v*`（例如 `v1.0.0`），与源码 release 一一对应 |
| 当前推荐标签 | `v1.0.0` |

推送 `v*` 标签到 `knowledge-base-keycloak` 的 `master` 时，[Release workflow](https://github.com/lennylin-lab/knowledge-base-keycloak/blob/master/.github/workflows/release.yml) 自动构建并推送上述镜像，同时创建 GitHub Release。**镜像内不包含** 管理员密码、Turnstile 密钥、数据库 DSN 或 realm 用户数据；敏感配置与 `import/cybervem-realm.json` 由 [`keycloak/`](keycloak/) 在运行时挂载 / 注入。

## 拉取

公开包可直接拉取：

```bash
docker pull ghcr.io/lennylin-lab/knowledge-base-keycloak:v1.0.0
```

若包为私有，需先登录 GHCR（PAT 需 `read:packages`）：

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u USERNAME --password-stdin
docker pull ghcr.io/lennylin-lab/knowledge-base-keycloak:v1.0.0
```

## 镜像内容

多阶段构建（`Dockerfile`）：Keycloak **26.0** + [Cloudflare Turnstile SPI](https://github.com/zymlabs/keycloak-cloudflare-turnstile-provider)（`kc.sh build`）+ 自定义 **`kb`** 主题。

| 路径 | 说明 |
| --- | --- |
| `/opt/keycloak/` | Keycloak Quarkus 发行版（含预编译 SPI） |
| `/opt/keycloak/providers/` | zymlabs Turnstile provider JAR |
| `/opt/keycloak/themes/kb/` | 登录主题（`parent=cloudflare-turnstile`）与 Admin 主题（`parent=keycloak.v2`），含 favicon |

Realm、client、CSP 细节、Turnstile browser flow 绑定 **不在镜像内**；首次空库启动时由编排挂载 `keycloak/import/cybervem-realm.json`（`--import-realm`）。该 JSON **必须**包含标准 OIDC client scopes（`basic` 含 `sub` mapper、`profile`、`email` 等）；仅自定义 `kb-api-audience` 会导致 import 警告且 token 无 `sub`。`keycloak/client-scopes-standard.json` 供 bootstrap 脚本补建；导入后运行 `--profile bootstrap up keycloak-post-import`（或 `post-import.sh`）完成 scope 修复、Turnstile 与主题配置。

### 进程与端口

| 角色 | 典型启动方式 | 说明 |
| --- | --- | --- |
| Keycloak | `start --import-realm --proxy-headers=xforwarded ...` | HTTP **8080**；健康检查 `GET /health/ready` 在管理口 **9000**（`KC_HEALTH_ENABLED=true`） |
| Postgres | 独立 `keycloak-db` 服务 | 持久化 realm / 用户 / Turnstile 配置；DSN 由 `KC_DB_*` 注入 |

生产建议：在 `keycloak/.env` 设置 `KEYCLOAK_HOSTNAME=auth.cybervem.com`（compose 映射为 `KC_HOSTNAME`），TLS 与 `X-Forwarded-*` 由前置 nginx / Cloudflare 终止；Keycloak 容器仅内网暴露 8080。

### 运行时要求

- 基础镜像：`quay.io/keycloak/keycloak:26.0`
- 数据库：PostgreSQL（Keycloak 官方支持版本）
- 配置：通过环境变量注入（见 [`keycloak/.env.example`](keycloak/.env.example)）
- OIDC Issuer（导入后）：`https://auth.cybervem.com/realms/CyberVem`
- Turnstile widget 域名：`auth.cybervem.com`

### 部署顺序（与本目录协作）

1. 设置 `KEYCLOAK_IMAGE` 并 `docker pull`
2. 启动 Keycloak（挂载 `keycloak/import/`；**空库**首次启动自动 import realm）
3. 执行 `./keycloak/scripts/post-import.sh`（主题绑定、CSP、Turnstile flow）
4. Admin Console 手动创建用户；在 server 数据库写入 `users.subject` 与 membership

## 版本与回滚

- **升级**：拉取新 `v*` 标签 → 滚动 Keycloak 容器（已有 PostgreSQL 数据**不会**重新 import realm）。
- **回滚**：将 `KEYCLOAK_IMAGE` 改回上一 `v*` 标签，重新 pull 并 up；数据库 schema 通常向前兼容，无需镜像侧 migrate。
- **重置 realm 导入**：仅在新空库或清空 keycloak DB volume 后，`--import-realm` 才会再次生效。

Package 页面：<https://github.com/lennylin-lab/knowledge-base-keycloak/pkgs/container/knowledge-base-keycloak>
