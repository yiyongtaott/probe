-- FLANDRE_TIAMAT — Cloudflare D1 schema (reconstructed from worker.js + v2 会话字段/索引)
-- 全新数据库：直接整文件执行。
--   wrangler d1 execute <DB_NAME> --remote --file=./schema.sql
-- 已有数据库：CREATE TABLE IF NOT EXISTS 是 no-op；新列请改用 migrate_v2.sql。

CREATE TABLE IF NOT EXISTS devices (
  id          TEXT PRIMARY KEY,
  status      TEXT,
  last_seen   INTEGER,
  updated_at  TEXT,
  last_ip     TEXT,
  lan         TEXT,
  wifi        TEXT,
  battery     TEXT
);

CREATE TABLE IF NOT EXISTS messages (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  user        TEXT,
  content     TEXT,
  timestamp   INTEGER,
  session_id  TEXT
);

CREATE TABLE IF NOT EXISTS online_users (
  session_id  TEXT PRIMARY KEY,
  user_name   TEXT,
  last_seen   INTEGER,
  ip          TEXT
);

CREATE TABLE IF NOT EXISTS activity_history (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id    TEXT,
  window_title TEXT,
  lan          TEXT,
  wifi         TEXT,
  battery      TEXT,
  recorded_at  INTEGER,   -- 会话结束时刻 (epoch ms)；旧行 = 上报时刻
  started_at   INTEGER,   -- 会话开始时刻 (epoch ms)；旧行为 NULL
  duration_ms  INTEGER    -- 会话时长 ms；旧行为 NULL
);

CREATE TABLE IF NOT EXISTS ai_usage (
  day      TEXT,
  provider TEXT,
  count    INTEGER,
  PRIMARY KEY (day, provider)
);

-- 索引：历史查询 / 清理 / 读额度 的命门（缺了会全表扫描）。
CREATE INDEX IF NOT EXISTS idx_ah_dev_time ON activity_history(device_id, recorded_at);
CREATE INDEX IF NOT EXISTS idx_ah_time     ON activity_history(recorded_at);
CREATE INDEX IF NOT EXISTS idx_msg_time    ON messages(timestamp);
CREATE INDEX IF NOT EXISTS idx_ou_seen     ON online_users(last_seen);
