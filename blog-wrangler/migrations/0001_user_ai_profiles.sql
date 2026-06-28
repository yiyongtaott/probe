CREATE TABLE IF NOT EXISTS user_ai_profiles (
    username TEXT PRIMARY KEY,
    password_hash TEXT NOT NULL,
    provider TEXT DEFAULT 'google',
    base_url TEXT DEFAULT 'https://generativelanguage.googleapis.com/v1beta',
    api_key TEXT DEFAULT '',
    model TEXT DEFAULT 'gemini-1.5-flash',
    updated_at INTEGER
);

CREATE TABLE IF NOT EXISTS user_sessions (
    token TEXT PRIMARY KEY,
    username TEXT NOT NULL,
    expires_at INTEGER NOT NULL
);
