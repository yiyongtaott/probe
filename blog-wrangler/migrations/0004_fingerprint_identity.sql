-- 0004: use browser fingerprint as the visitor identity, independent of IP
ALTER TABLE visitor_stats ADD COLUMN fingerprint TEXT;
CREATE INDEX IF NOT EXISTS idx_visitor_stats_fingerprint ON visitor_stats(fingerprint);
