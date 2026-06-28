# FLANDRE TIAMAT Monitor — blog worker

## 项目概述

Cloudflare Workers 项目，承载 FLANDRE_TIAMAT Monitor 的 API 与前端。
Worker 提供全部 API，并通过 `assets` 绑定托管 Vue3 单页应用（SPA）。

## 代码结构

```
worker.js                 # 入口壳（54B），仅 re-export src/worker-core.js
src/worker-core.js        # 唯一后端文件：常量/工具函数 → handle* 处理函数
                          #   → ROUTES 路由表 + fetch 分发；非 API 请求回落 env.ASSETS
                          #   → scheduled() 跑 runCleanup 定时清理
frontend/                 # Vue3 SPA 源码（components + composables）
  └─ npx vite build  →  frontend/dist/   # 构建产物（gitignored），由 assets 绑定提供
```

- 路由用 `ROUTES`（`"METHOD /path"` 精确匹配）+ 前缀路由（`/api/report/:id`、`/api/device/:id`）分发；新增端点在 `src/worker-core.js` 加 `handle*` 函数并注册到 `ROUTES`。
- 前端改动**必须** `vite build` 重建 `dist` 才会随 `wrangler deploy` 上线。
- 旧的“内嵌单页”方案（`src/frontend/`、`src/pages.js`、`src/vendor/`）已于 2026-06-19 删除，勿复活。

## 绑定资源

| 类型 | 绑定名 | 资源 | ID |
|------|--------|------|----|
| **KV** | `CHAT_KV` | MY_MESSAGE_STORE | `5aeaad...4b537` |
| **KV** | `DEVICE_KV` | MY_MESSAGE_STORE | `5aeaad...4b537` |
| **D1** | `DB` | flandre-db | `89375f...d0048` |
| **AI** | `AI` | Workers AI (catalog) | — |

> KV 命名空间 `MY_MESSAGE_STORE` 当前为空（历史原因保留了绑定但暂无数据）。
> `CHAT_KV` 和 `DEVICE_KV` 指向同一个 KV 命名空间。

## D1 数据库（9张表）

- `devices` — 设备状态
- `activity_history` — 活跃历史记录（`window_title`/`lan`/`wifi`/`battery` 已字典化为 `title_id`/`vitals_id`，新行文本列写空、读时 COALESCE 回退）
- `messages` — 聊天消息
- `online_users` — 在线用户
- `ai_usage` — AI 用量统计
- `user_ai_profiles` — 登录账号的 AI 配置（provider/base_url/api_key/model）
- `user_sessions` — 登录 token 会话
- `dict_titles` — 窗口标题字典（无损压缩；`runCleanup` 每日 GC 无引用项）
- `dict_vitals` — lan/wifi/battery 字典（无损压缩；同上 GC）

> `messages`、`user_ai_profiles`、`user_sessions`、`dict_titles`、`dict_vitals` 由 Worker 运行时 `CREATE TABLE IF NOT EXISTS` 懒建；`activity_history` 的 `title_id`/`vitals_id` 列由 `migrations/0002_dict_compression.sql` 添加（该迁移同时删除 2 个冗余索引）。
> AI 总结的会话合并为**间隔式**（`mergeSessions`/前端 `regap`，相邻同 `device|title` 段按 GAP 合并）；`/api/report/{id}` 兼容**单对象或 JSON 数组**（数组走 `ingestReportBatch` + `DB.batch()`）。

## 线上部署信息

- **Worker 名称**: `blog`
- **域名**: `https://blog.yiyongtao.workers.dev`
- **子域名**: 已启用
- **Cron 触发器**: `17 3 * * *`（每天 3:17 UTC 执行清理）
- **无自定义 route**（纯 workers.dev）
- **无 secrets**
- **Compatibility Date**: `2026-06-15`（见 wrangler.jsonc；启用 `nodejs_compat`）

## 本地开发

前端依赖（首次）：

```bash
cd frontend && npm install && cd ..
```

两种本地方式：

```bash
# 方式 A：先构建前端，再用 wrangler 同时跑 API + 静态资源
cd frontend && npx vite build && cd ..
npx wrangler dev                 # 本地 dist 由 ASSETS 提供，API 走本地

# 方式 B：前端热更新（vite dev）+ wrangler dev 提供 API
npx wrangler dev                 # 终端1：API 在 http://localhost:8787
cd frontend && npx vite          # 终端2：前端在 http://localhost:5173，/api 已代理到 8787

# 本地用远程 D1（需要网络）
npx wrangler dev --remote

# 用本地 D1（先导入数据）
npx wrangler d1 execute flandre-db --local --file ./flandre-db.sql
```

部署：

```bash
cd frontend && npx vite build && cd ..   # 1) 重建前端产物
npx wrangler deploy --keep-vars          # 2) 仅部署 blog worker，保留线上环境变量
```

> 上报端（C Probe / Flutter）默认上报地址在各自客户端代码里配置，线上为 `https://flandretiamat.dpdns.org`；Worker 本身不持有该地址。

## 项目文件

| 文件 | 说明 |
|------|------|
| `worker.js` | 入口壳，仅 re-export `src/worker-core.js` |
| `src/worker-core.js` | 后端全部逻辑（API 路由表 + handler + 定时清理） |
| `frontend/` | Vue3 SPA 源码；`vite build` → `frontend/dist/` |
| `wrangler.jsonc` | Wrangler 配置（main / assets / 绑定 / cron） |
| `migrations/` | D1 迁移文件（仅 `wrangler d1 migrations apply` 执行；`deploy` 不执行） |
| `flandre-db.sql` | D1 全量导出（schema + 数据） |
| `README.md` | 本文件 |

## 获取 KV 数据（如需）

```bash
# 列出所有 key
npx wrangler kv key list --namespace-id 5aeaad048a124d6d910383392d14b537

# 查看某个 key 的值
npx wrangler kv key get --namespace-id 5aeaad048a124d6d910383392d14b537 "<key_name>"
```

## 线上日志

```bash
npx wrangler tail blog
```

## 线上溯源（超时/异常问题）

### D1 数据一致性校验

```sql
-- 检查 activity_history 表的重复设备名
-- 对比 C probe 和 Flutter APK 的 device_id 是否一致
SELECT device_id, 
       COUNT(DISTINCT strftime('%Y-%m-%d', recorded_at/1000, 'unixepoch')) as active_days,
       MAX(recorded_at) as last_record
FROM activity_history 
GROUP BY device_id
ORDER BY last_record DESC;

-- 检查 activity_history 中的会话长度异常
-- 搜索 session 时长 < 30s 或 > 12h 的异常记录
SELECT id, device_id, 
       CASE
         WHEN dur < 30000 THEN '短会话'
         WHEN dur > 43200000 THEN '超长会话'
       END as 异常类型,
       recorded_at,
       dur/1000 as 时长秒数
FROM activity_history
WHERE dur < 30000 OR dur > 43200000
ORDER BY recorded_at DESC;
```

### 前端耗时排查

Worker 的 UI 页面（单页 SPA）中的 API 请求耗时可以在浏览器 Network 面板检查，候选慢查询：

```sql
-- 检查 devices 表是否索引命中
SELECT id, last_seen FROM devices ORDER BY last_seen DESC LIMIT 10;
```

```sql
-- 检查 activity_history 表某设备某天的记录数（排查上报重复问题）
SELECT device_id, 
       strftime('%Y-%m-%d', recorded_at/1000, 'unixepoch') as day,
       COUNT(*) as records
FROM activity_history
WHERE recorded_at > 1780454400000  -- 最近若干小时，按需调整
GROUP BY device_id, day
HAVING records > 100
ORDER BY records DESC;
```

### 新增 API 端点检查

在 `src/worker-core.js` 加 `handle*` 函数并注册到 `ROUTES`（或前缀路由），同时确认前端 `frontend/src/composables/*` 里的调用路径一致。
