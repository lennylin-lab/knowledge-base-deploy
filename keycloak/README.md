# Keycloak 生产部署（CyberVem）

本目录是 **Keycloak 专用** 生产编排，边界止于 `auth.cybervem.com`。不包含 server、gateway、nginx 等其余服务。

镜像来源与 dev 仓库 `knowledge-base-keycloak` 相同（KC 26 + Turnstile SPI + `kb` 主题）。

## 生产域名约定

| 项 | 值 |
| --- | --- |
| Keycloak / OIDC Issuer | `https://auth.cybervem.com/realms/CyberVem` |
| Realm | `CyberVem` |
| 前端 | `https://www.cybervem.com` |
| 后端 API | `https://api.cybervem.com`（验 JWT 时 issuer 仍指向 auth） |
| Client | `kb-web`（Flutter PKCE） |
| Access Token `aud` | `kb-api`（与 server `KB_OIDC_AUDIENCE` 一致） |

下游需自行配置（本目录不改）：

```dotenv
# knowledge-base-server
KB_OIDC_ISSUER=https://auth.cybervem.com/realms/CyberVem
KB_OIDC_AUDIENCE=kb-api

# knowledge-base-flutter build
OIDC_ISSUER=https://auth.cybervem.com/realms/CyberVem
OIDC_CLIENT_ID=kb-web
```

## 部署流程（四步）

### 1. Cloudflare Turnstile

在 [Cloudflare Turnstile](https://dash.cloudflare.com/?to=/:account/turnstile) 创建 widget。

**Hostname 填什么？** → **`auth.cybervem.com`**

Turnstile 渲染在 Keycloak 登录页，该页面由 `auth.cybervem.com` 提供。当前架构下 **不需要** 为 `www.cybervem.com` 单独申请 widget（除非以后在前端页面嵌入 Turnstile）。

可选：若需本地/预发联调，在同一 widget 中追加 `localhost` 或 `staging-auth.cybervem.com`。

### 2. 准备环境变量

```bash
cd knowledge-base-deploy/keycloak
cp .env.example .env
# 填写 KEYCLOAK_ADMIN_PASSWORD、KEYCLOAK_DB_PASSWORD、TURNSTILE_* 
```

### 3. 启动（首次自动导入 realm）

```bash
docker compose up -d --build
```

首次启动且数据库卷为空时，会导入 `import/cybervem-realm.json`：

- Realm `CyberVem`
- Clients `kb-web`、`kb-api`
- Client scope `kb-api-audience`（token 带 `aud=kb-api`）
- CSP（Turnstile 所需）
- **不含用户**（由你手动创建）

Keycloak 仅 `expose:8080`，应对内网/反代暴露；TLS 与 `X-Forwarded-*` 由前置 nginx 或 Cloudflare 终止。

### 4. 导入后配置（Turnstile 单页登录 + 主题）

```bash
./scripts/post-import.sh
```

脚本会：

1. 设置 `CyberVem` 与 `master` 的 login/admin theme = `kb`
2. 写入 realm 级 CSP（与 import 一致，可重复执行）
3. 复制 browser flow → `browser-turnstile`，在 **forms 子 flow** 内仅保留 Turnstile（Custom Theme 单页登录），并绑定 realm

### 5. 手动创建用户

Admin Console → realm **CyberVem** → **Users** → 创建账号。

然后在 server 数据库写入 `users.subject` 与 `tenant_memberships`（见 `knowledge-base-server/docs/identity-tenants.md`）。

## 验证

```bash
# 健康检查（经反代或 docker exec 内网访问）
curl -fsS https://auth.cybervem.com/health/ready

# Issuer
curl -fsS https://auth.cybervem.com/realms/CyberVem/.well-known/openid-configuration | jq .issuer

# CSP 应包含 challenges.cloudflare.com
curl -sI "https://auth.cybervem.com/realms/CyberVem/protocol/openid-connect/auth?client_id=kb-web&redirect_uri=https%3A%2F%2Fwww.cybervem.com%2Fauth%2Fcallback&response_type=code&scope=openid" | grep -i content-security
```

登录页应 **单页** 同时显示用户名/密码与 Turnstile widget。

## 目录结构

```text
Dockerfile
docker-compose.yml
.env.example
import/cybervem-realm.json   # 首次导入（无用户）
assets/favicon.svg
themes/kb/
scripts/
  post-import.sh              # 一键：主题 + CSP + Turnstile flow
  configure-turnstile-csp.sh
  configure-kb-themes.sh
  configure-turnstile-login.py
  build-theme-icons.sh
```

## 常见问题

**Turnstile widget 空白**  
检查 realm CSP 是否允许 `challenges.cloudflare.com`；widget 域名是否为 `auth.cybervem.com`；是否已运行 `post-import.sh`。

**两页登录 / 无密码框**  
Browser flow 结构错误。不要 Turnstile 在 flow 顶层 Required；forms 子 flow 内不要保留单独的 Username Password Form（单页方案由 Custom Theme 提供表单）。

**重新导入 realm**  
`--import-realm` 仅在空库首次启动生效。要重置需删除 volume `keycloakdb` 后重新 `docker compose up`（会清空 Keycloak 数据）。

**镜像推送**  

```bash
docker build -t ghcr.io/<org>/kb-keycloak:26.0 .
docker push ghcr.io/<org>/kb-keycloak:26.0
# .env: KEYCLOAK_IMAGE=ghcr.io/<org>/kb-keycloak:26.0
```
