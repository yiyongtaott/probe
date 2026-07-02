-- 0003 访客统计表
-- visitor_stats: 每个唯一访客一行（按 IP+浏览器指纹 哈希去重）
-- visitor_daily: 每日聚合统计（独立访客数 + 总访问次数）

CREATE TABLE IF NOT EXISTS visitor_stats (
    visitor_hash   TEXT PRIMARY KEY,
    first_seen     INTEGER NOT NULL,
    last_seen      INTEGER NOT NULL,
    visit_count    INTEGER NOT NULL DEFAULT 1,
    last_ip        TEXT,
    user_agent     TEXT,
    user_name      TEXT,
    last_visit_day TEXT
);

CREATE TABLE IF NOT EXISTS visitor_daily (
    day             TEXT PRIMARY KEY,
    unique_visitors INTEGER NOT NULL DEFAULT 0,
    total_visits    INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_visitor_stats_last_seen ON visitor_stats(last_seen DESC);
CREATE INDEX IF NOT EXISTS idx_visitor_daily_day ON visitor_daily(day DESC);
