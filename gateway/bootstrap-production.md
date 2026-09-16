# Gateway 生产业务配置（全新部署 / 从独立栈迁移）

Schema 迁移（`gateway-migrate`）只 seed **fake** provider 与 `gateway-echo`（embedding 维度 **256**）。真实 chat/embedding 模型、路由与授权 **不会**因设置 `OPENAI_API_KEY` 而自动出现；Admin API 也 **不能** 创建 provider/catalog 行（只读 + enable/disable + default-model + mint key）。

## 路径 A：从独立 `kb-gateway` 栈迁移（推荐）

在旧栈仍运行时导出 gateway 库（仅数据，不含 role）：

```bash
pg_dump -h 127.0.0.1 -p 5433 -U gateway -d gateway \
  --data-only \
  --table=tenants --table=subjects --table=providers \
  --table=model_catalog --table=model_routes --table=access_policies \
  > gateway-data.sql
```

> `api_keys` 表存的是哈希，**无法**还原明文；迁移后在 Admin API **重新 mint** service key 给 server。

停旧栈，启动本仓库基础设施 + Gateway（`$DC up -d`，不含 `--profile app`），确认 `/readyz` 200 后导入：

```bash
psql "postgres://gateway:${GATEWAY_DB_PASSWORD}@127.0.0.1:5432/gateway?sslmode=disable" \
  -f gateway-data.sql
```

若统一栈 PostgreSQL 未暴露宿主机端口，通过 compose 网络导入：

```bash
$DC exec -T postgres psql -U gateway -d gateway < gateway-data.sql
```

**刷新运行时：** provider/catalog 在 Gateway **进程启动时**加载。导入 SQL 后执行：

```bash
$DC restart gateway
```

验证 catalog 与 subject 授权：

```bash
curl -fsS -H "Authorization: Bearer $GATEWAY_ADMIN_TOKEN" \
  http://127.0.0.1:8092/admin/models
curl -fsS -H "Authorization: Bearer $GATEWAY_ADMIN_TOKEN" \
  "http://127.0.0.1:8092/admin/policies?subject=<your-subject>"
```

为 server subject mint key（见 [configuration.md](../configuration.md) §3.8），将 `KB_EMBEDDING_MODEL` / `KB_EMBEDDING_DIM` 与 catalog 中 **embeddings 声明** 对齐（生产常见 1536，与 pgvector 列宽一致）。

## 路径 B：全新生产部署（手工 SQL）

1. 完成 `$DC up -d`（Gateway `/readyz` 200），在 `gateway/.env` 配置上游 `OPENAI_API_KEY*`。
2. 用只读事务参考现有环境或运维文档，向 `providers`、`model_catalog`、`model_routes`、`access_policies` 插入行（需自行维护 `config_version` / capabilities JSON）。
3. `$DC restart gateway`
4. Admin API 设置 subject 默认 chat/embedding 模型并 mint key。
5. 配置 `server/.env` 后 `$DC --profile app up -d server`。

**切勿**在未授权的情况下把 `KB_EMBEDDING_DIM` 设为与 catalog `embedding_dim` 不一致的值。

## 路径 C：fake 联调（256 维）

仅验证编排与 Server 启动，**不能**替代生产 1536 维向量配置：

```bash
./gateway/scripts/bootstrap-fake.sh
# 按脚本输出更新 server/.env，然后 --profile app up -d server
```

## 故障恢复说明（Redis 配额）

Gateway 日/月 token 配额计数在 Redis（`gw:quota:*`）。本仓库 Redis 启用 AOF 持久化；`docker compose down` **不**删除 `redis-data` 卷时配额保留。删除卷或 AOF 损坏时配额从 0 重新累计，PostgreSQL 审计表不自动回填配额计数。
