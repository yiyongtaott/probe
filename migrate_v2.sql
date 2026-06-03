-- v2 迁移：对【已有】数据库执行一次（务必在部署新 worker.js 之前跑）。
--   wrangler d1 execute <DB_NAME> --remote --file=./migrate_v2.sql
--
-- 注意：SQLite 的 ALTER TABLE ADD COLUMN 没有 IF NOT EXISTS。
-- 这两条只跑一次；若提示 "duplicate column name" 说明已经加过，忽略即可。
ALTER TABLE activity_history ADD COLUMN started_at  INTEGER;
ALTER TABLE activity_history ADD COLUMN duration_ms INTEGER;

-- 新增 AI 用量表（安全重复执行）。
CREATE TABLE IF NOT EXISTS ai_usage (
  day      TEXT,
  provider TEXT,
  count    INTEGER,
  PRIMARY KEY (day, provider)
);

-- 索引可安全重复执行。
CREATE INDEX IF NOT EXISTS idx_ah_dev_time ON activity_history(device_id, recorded_at);
CREATE INDEX IF NOT EXISTS idx_ah_time     ON activity_history(recorded_at);
CREATE INDEX IF NOT EXISTS idx_msg_time    ON messages(timestamp);
CREATE INDEX IF NOT EXISTS idx_ou_seen     ON online_users(last_seen);
