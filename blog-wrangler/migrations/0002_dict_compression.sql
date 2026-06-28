-- 0002 字典化无损压缩 + 删除冗余索引
-- window_title 与 (lan,wifi,battery) 改存字典 id；新行文本列写空，读时 COALESCE 回退。
-- 老行 title_id/vitals_id 为 NULL，继续用自身文本列 —— 零迁移共存、可回滚。

-- 1) 删除 2 个与 DESC 索引重复的冗余索引（释放索引空间；现有查询都走 idx_history_* 那对）
DROP INDEX IF EXISTS idx_ah_dev_time;   -- 与 idx_history_device_time(device_id, recorded_at DESC) 重复
DROP INDEX IF EXISTS idx_ah_time;       -- 与 idx_history_time(recorded_at DESC) 重复

-- 2) 字典表（低基数复用一个小整数 id）
CREATE TABLE IF NOT EXISTS dict_titles (
    id    INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT UNIQUE
);
CREATE TABLE IF NOT EXISTS dict_vitals (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    lan     TEXT,
    wifi    TEXT,
    battery TEXT,
    UNIQUE(lan, wifi, battery)
);

-- 3) activity_history 增加字典外键列（SQLite ADD COLUMN 为瞬时操作，不重建表、不动存量数据）
ALTER TABLE activity_history ADD COLUMN title_id  INTEGER;
ALTER TABLE activity_history ADD COLUMN vitals_id INTEGER;

-- 4) 供每日字典 GC 的反连接 + 读取 JOIN 使用
CREATE INDEX IF NOT EXISTS idx_ah_title_id ON activity_history(title_id);
