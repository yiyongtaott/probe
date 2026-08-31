/**
 * FLANDRE_TIAMAT Monitor (D1 Edition)
 * 部署平台: Cloudflare Workers + D1
 *
 * 功能:
 *   - 活动历史记录 + AI 总结
 *   - 设备上报 JSON 解析（window / lan / wifi / battery）
 *   - 在线用户列表（昵称 + IP）、访客 IP 记录
 *
 * 结构:
 *   - 顶部：常量与纯函数工具（标题清洗、鉴权、合并、外部 LLM 调用等）
 *   - 中部：每个 API 一个 handle* 处理函数
 *   - 底部：ROUTES 路由表 + fetch 分发 + scheduled 定时清理
 */

const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS, DELETE",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
};

// D1 表初始化标记（确保 messages 等核心表存在；每个 isolate 仅首个 API 请求消耗一次）
let _dbInit = false;
async function ensureCoreTables(env) {
    if (_dbInit) return;
    _dbInit = true;
    try {
        await env.DB.prepare(
            `CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user TEXT,
                content TEXT,
                timestamp INTEGER,
                session_id TEXT
            )`
        ).run();
        // 无损压缩字典：activity_history 的 window_title 与 lan/wifi/battery 改存字典 id。
        // 表本身用 IF NOT EXISTS 懒建兜底；title_id/vitals_id 列由 migration 0002 添加。
        await env.DB.prepare(
            `CREATE TABLE IF NOT EXISTS dict_titles (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT UNIQUE
            )`
        ).run();
        await env.DB.prepare(
            `CREATE TABLE IF NOT EXISTS dict_vitals (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                lan TEXT, wifi TEXT, battery TEXT,
                UNIQUE(lan, wifi, battery)
            )`
        ).run();
    } catch (e) {
        // 首次初始化可能因并发失败，忽略即可
    }
}

// ─── 字典 intern：同标题/同 vitals 复用一个小整数 id（无损压缩核心）───
// isolate 级缓存：同窗口连续上报时命中缓存 → 0 次 D1 往返，保证写额度不退化。
// 保留(3年/每设备300万行) 远大于 isolate 寿命，故缓存 id 不会被 GC 删除后悬空。
const _titleIdCache = new Map();
const _vitalsIdCache = new Map();
function _cachePut(cache, key, val) {
    if (cache.size > 4000) cache.clear();
    cache.set(key, val);
    return val;
}
async function internTitle(env, title) {
    const t = String(title || "");
    if (!t) return null;
    const hit = _titleIdCache.get(t);
    if (hit) return hit;
    // 一条语句：插入或命中冲突都 RETURNING id，保证返回时该行必定存在
    const r = await env.DB.prepare(
        `INSERT INTO dict_titles (title) VALUES (?)
         ON CONFLICT(title) DO UPDATE SET title=title RETURNING id`
    ).bind(t).first();
    return r ? _cachePut(_titleIdCache, t, r.id) : null;
}
async function internVitals(env, lan, wifi, battery) {
    const L = lan == null ? '' : String(lan);
    const W = wifi == null ? '' : String(wifi);
    const B = battery == null ? '' : String(battery);
    const key = JSON.stringify([L, W, B]);
    const hit = _vitalsIdCache.get(key);
    if (hit) return hit;
    const r = await env.DB.prepare(
        `INSERT INTO dict_vitals (lan, wifi, battery) VALUES (?, ?, ?)
         ON CONFLICT(lan, wifi, battery) DO UPDATE SET lan=lan RETURNING id`
    ).bind(L, W, B).first();
    return r ? _cachePut(_vitalsIdCache, key, r.id) : null;
}

const createResponse = (body, status = 200, contentType = "application/json;charset=UTF-8") => {
    return new Response(body, {
        status,
        headers: { ...corsHeaders, "Content-Type": contentType }
    });
};

const MIN_ACTIVITY_MS = 1500;
const DUP_MERGE_WINDOW_MS = 120000;
const DEFAULT_ACCOUNT = {
    username: "FlandreTiamat",
    password: "13786022334Yyt",
};

const LEADING_GLYPHS = new Set([
    0x231B, 0x23F3, 0x25CC, 0x25D0, 0x25D1, 0x25D2, 0x25D3, 0x25E6, 0x25EF,
    0x2605, 0x2606, 0x2611, 0x2612, 0x2615, 0x263A, 0x263B, 0x26A0, 0x26AA,
    0x26AB, 0x2705, 0x2713, 0x2714, 0x2726, 0x2728, 0x2733, 0x2734,
    0x2747, 0x274C, 0x2753, 0x2754, 0xFFFD,
]);

const LOW_VALUE_TITLES = new Set([
    "play", "pause", "paused", "playing", "speed", "loading", "buffering",
    "播放", "暂停", "倍速中", "加载中",
    "正在加载", "缓冲中", "重播", "点击重试",
    "播放/暂停", "拖动到此处锁定倍速",
    "发送中...", "一键已读",
    "系统桌面",
    "桌面", "program manager", "任务栏 / 文件资源管理器",
    "系统托盘溢出窗口。", "快速设置",
    "音量控制", "新通知", "ultralightprobe",
    "windows 默认锁屏界面",
]);

// 系统状态窗口（手机息屏/锁屏）：允许作为「设备当前状态」展示在面板，
// 但不写入 activity_history、不进入 AI 合并时间线。与 LOW_VALUE_TITLES 分开。
const SYSTEM_STATE_TITLES = new Set([
    "系统息屏", "系统锁屏",
]);

const SHORT_MEANINGFUL_TITLES = new Set([
    "qq",
    "tim",
    "yy",
]);

function stripLeadingGlyphs(value) {
    let title = String(value || "").trim();
    let changed = true;
    while (title && changed) {
        changed = false;
        const cp = title.codePointAt(0);
        const len = cp > 0xFFFF ? 2 : 1;
        if (LEADING_GLYPHS.has(cp) || (cp >= 0x2800 && cp <= 0x28FF) || (cp >= 0x1F300 && cp <= 0x1FAFF)) {
            title = title.slice(len).trimStart();
            changed = true;
        }
    }
    return title;
}

function normalizeWindowTitle(value) {
    let title = String(value || "")
        .replace(/[\u0000-\u001F\u007F]/g, " ")
        .replace(/[\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/g, "")
        .replace(/\s+/g, " ")
        .trim();
    title = stripLeadingGlyphs(title);
    title = title
        .replace(/\s+和另外\s*\d+\s*个页面\s*-\s*个人\s*-\s*Microsoft(?:®|™)?\s*Edge$/i, " [Edge]")
        .replace(/\s+-\s*个人\s+-\s*Microsoft(?:®|™)?\s*Edge$/i, " [Edge]")
        .replace(/\s+-\s*Microsoft(?:®|™)?\s*Edge$/i, " [Edge]")
        .replace(/\s+-\s*Google Chrome$/i, " [Chrome]")
        .replace(/\s+-\s*Mozilla Firefox$/i, " [Firefox]")
        .trim();
    return stripLeadingGlyphs(title);
}

function hasLowInformation(title) {
    const compact = String(title || "").trim().toLowerCase().replace(/\s+/g, "");
    if (SHORT_MEANINGFUL_TITLES.has(compact)) return false;
    const chars = Array.from(title || "").filter(ch => /[\p{L}\p{N}]/u.test(ch));
    if (chars.length === 0) return true;
    if (chars.length <= 1) return true;
    return new Set(chars.map(ch => ch.toLowerCase())).size <= 1 && chars.length <= 4;
}

function isNoiseWindowTitle(value) {
    const title = normalizeWindowTitle(value);
    if (!title) return true;
    const lower = title.toLowerCase();
    const compact = lower.replace(/\s+/g, "");
    const lastSegment = lower.split(/\s+-\s+/).pop() || "";
    const lastCompact = lastSegment.replace(/\s+/g, "");

    if (LOW_VALUE_TITLES.has(lower) || LOW_VALUE_TITLES.has(compact)) return true;
    if (LOW_VALUE_TITLES.has(lastSegment) || LOW_VALUE_TITLES.has(lastCompact)) return true;
    if (/^(?:system|系统)\s*[:：]/i.test(title)) return true;
    if (/[:：]\s*(?:msedge|chrome|firefox|explorer|applicationframehost)\.exe\b/i.test(title)) return true;
    if (/[:：]\s*[a-z0-9_.-]+\.exe\b/i.test(title) && title.length <= 80) return true;
    if (/^(?:\d+(?:\.\d+)?x|\d+(?:\.\d+)?倍|倍速)$/.test(compact)) return true;
    if (/(?:倍速中|正在加载|加载中|缓冲中)/.test(title) && title.length <= 20) return true;
    if (/^[\s._\-|/\\:;'"`~!?()[\]{}<>*+=#@$%^&]+$/.test(title)) return true;
    if (hasLowInformation(title)) return true;
    return false;
}

function isSystemStateWindow(value) {
    return SYSTEM_STATE_TITLES.has(normalizeWindowTitle(value));
}

function sanitizeActivityRow(row) {
    if (!row) return null;
    const title = normalizeWindowTitle(row.window_title || row.window || "");
    if (isNoiseWindowTitle(title) || isSystemStateWindow(title)) return null;
    return { ...row, window_title: title, window: title };
}

async function sha256Hex(text) {
    const bytes = new TextEncoder().encode(text);
    const hash = await crypto.subtle.digest("SHA-256", bytes);
    return Array.from(new Uint8Array(hash)).map(b => b.toString(16).padStart(2, "0")).join("");
}

function randomToken() {
    const bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    return Array.from(bytes).map(b => b.toString(16).padStart(2, "0")).join("");
}

// 鉴权相关建表标记（每个 isolate 仅初始化一次，避免每个 auth 请求都重复跑 DDL）
let _authInit = false;
async function ensureAuthSchema(env) {
    if (_authInit) return;
    await env.DB.prepare(
        `CREATE TABLE IF NOT EXISTS user_ai_profiles (
            username TEXT PRIMARY KEY,
            password_hash TEXT NOT NULL,
            provider TEXT DEFAULT 'google',
            base_url TEXT DEFAULT 'https://generativelanguage.googleapis.com/v1beta',
            api_key TEXT DEFAULT '',
            model TEXT DEFAULT 'gemini-1.5-flash',
            updated_at INTEGER
        )`
    ).run();
    await env.DB.prepare(
        `CREATE TABLE IF NOT EXISTS user_sessions (
            token TEXT PRIMARY KEY,
            username TEXT NOT NULL,
            expires_at INTEGER NOT NULL
        )`
    ).run();
    await env.DB.prepare(
        `INSERT OR IGNORE INTO user_ai_profiles
            (username, password_hash, provider, base_url, api_key, model, updated_at)
         VALUES (?, ?, 'google', 'https://generativelanguage.googleapis.com/v1beta', '', 'gemini-1.5-flash', ?)`
    ).bind(DEFAULT_ACCOUNT.username, await sha256Hex(DEFAULT_ACCOUNT.password), Date.now()).run();
    _authInit = true;
}

// ─── 访客统计表懒建（与核心表一起初始化）───
let _visitorInit = false;
async function ensureVisitorSchema(env) {
    if (_visitorInit) return;
    try {
        await env.DB.prepare(
            `CREATE TABLE IF NOT EXISTS visitor_stats (
                visitor_hash   TEXT PRIMARY KEY,
                first_seen     INTEGER NOT NULL,
                last_seen      INTEGER NOT NULL,
                visit_count    INTEGER NOT NULL DEFAULT 1,
                last_ip        TEXT,
                user_agent     TEXT,
                user_name      TEXT,
                last_visit_day TEXT
            )`
        ).run();
        await env.DB.prepare(
            `CREATE TABLE IF NOT EXISTS visitor_daily (
                day             TEXT PRIMARY KEY,
                unique_visitors INTEGER NOT NULL DEFAULT 0,
                total_visits    INTEGER NOT NULL DEFAULT 0
            )`
        ).run();
        await env.DB.prepare(
            `CREATE INDEX IF NOT EXISTS idx_visitor_stats_last_seen ON visitor_stats(last_seen DESC)`
        ).run();
        await env.DB.prepare(
            `CREATE INDEX IF NOT EXISTS idx_visitor_daily_day ON visitor_daily(day DESC)`
        ).run();
    } catch (e) { /* 并发时忽略 */ }
    _visitorInit = true;
}

// 记录访客：按 visitor_hash(IP+指纹) 去重，同一天内同一访客只算一次独立访问
// 但每次心跳都会更新 last_seen 和 visit_count（总访问次数）
async function recordVisitor(env, visitorHash, cfIp, userAgent, userName) {
    const now = Date.now();
    const today = shanghaiDay(now);

    const existing = await env.DB.prepare(
        `SELECT visitor_hash, last_visit_day FROM visitor_stats WHERE visitor_hash = ?`
    ).bind(visitorHash).first();

    if (!existing) {
        // 新访客：插入 visitor_stats + 当日 unique_visitors +1
        await env.DB.prepare(
            `INSERT INTO visitor_stats (visitor_hash, first_seen, last_seen, visit_count, last_ip, user_agent, user_name, last_visit_day)
             VALUES (?, ?, ?, 1, ?, ?, ?, ?)
             ON CONFLICT(visitor_hash) DO UPDATE SET last_seen = excluded.last_seen, visit_count = visit_count + 1,
                 last_ip = excluded.last_ip, user_name = excluded.user_name, last_visit_day = excluded.last_visit_day`
        ).bind(visitorHash, now, now, cfIp, userAgent, userName || null, today).run();
        await env.DB.prepare(
            `INSERT INTO visitor_daily (day, unique_visitors, total_visits) VALUES (?, 1, 1)
             ON CONFLICT(day) DO UPDATE SET total_visits = total_visits + 1`
        ).bind(today).run();
    } else if (existing.last_visit_day !== today) {
        // 跨天回访：visit_count+1, 更新 last_seen, 新的一天 unique_visitors+1
        await env.DB.prepare(
            `UPDATE visitor_stats SET last_seen = ?, visit_count = visit_count + 1,
                 last_ip = ?, user_name = ?, last_visit_day = ?
             WHERE visitor_hash = ?`
        ).bind(now, cfIp, userName || null, today, visitorHash).run();
        await env.DB.prepare(
            `INSERT INTO visitor_daily (day, unique_visitors, total_visits) VALUES (?, 1, 1)
             ON CONFLICT(day) DO UPDATE SET unique_visitors = unique_visitors + 1, total_visits = total_visits + 1`
        ).bind(today).run();
    } else {
        // 同一天内重复访问：visit_count+1（总次数）, 更新 last_seen, 但当天 unique_visitors 不变
        await env.DB.prepare(
            `UPDATE visitor_stats SET last_seen = ?, visit_count = visit_count + 1,
                 last_ip = ?, user_name = ?
             WHERE visitor_hash = ?`
        ).bind(now, cfIp, userName || null, visitorHash).run();
        await env.DB.prepare(
            `INSERT INTO visitor_daily (day, unique_visitors, total_visits) VALUES (?, 0, 1)
             ON CONFLICT(day) DO UPDATE SET total_visits = total_visits + 1`
        ).bind(today).run();
    }
}

// 查询访客统计数据
async function handleVisitorStats(request, env, url) {
    try {
        await ensureVisitorSchema(env);
        const today = shanghaiDay();

        // 总独立访客数 + 总访问次数
        const totalRow = await env.DB.prepare(
            `SELECT COUNT(*) AS total_visitors, COALESCE(SUM(visit_count), 0) AS total_visits FROM visitor_stats`
        ).first();

        // 今日独立访客数 + 今日总访问次数
        const todayRow = await env.DB.prepare(
            `SELECT unique_visitors, total_visits FROM visitor_daily WHERE day = ?`
        ).bind(today).first();

        // 最近 7 天每日统计（用于趋势图）
        const dailyRows = await env.DB.prepare(
            `SELECT day, unique_visitors, total_visits FROM visitor_daily ORDER BY day DESC LIMIT 7`
        ).all();
        const dailyHistory = (dailyRows.results || []).reverse();

        // 最近活跃访客（最近 24 小时内）
        // 按 IP + 用户名聚合：同一个用户多次刷新只算一条，解决「明明同一人却重复显示」的视觉问题
        const recentRows = await env.DB.prepare(
            `SELECT last_ip,
                    COALESCE(NULLIF(user_name, ''), '访客') AS user_name,
                    COUNT(*) AS sessions,
                    SUM(visit_count) AS totalVisits,
                    MAX(last_seen) AS last_seen,
                    MAX(first_seen) AS first_seen
             FROM visitor_stats
             WHERE last_seen > ?
             GROUP BY last_ip, COALESCE(NULLIF(user_name, ''), '访客')
             ORDER BY last_seen DESC
             LIMIT 20`
        ).bind(Date.now() - 86400000).all();
        const recentVisitors = (recentRows.results || []).map(v => ({
            hash: (v.last_ip || 'unknown').replace(/\./g, '') + '_' + (v.user_name || '访客'),
            firstSeen: v.first_seen,
            lastSeen: v.last_seen,
            visitCount: v.totalVisits || v.sessions || 1,
            ip: v.last_ip || 'unknown',
            userName: v.user_name || '访客',
        }));

        return createResponse(JSON.stringify({
            totalVisitors: (totalRow && totalRow.total_visitors) || 0,
            totalVisits: (totalRow && totalRow.total_visits) || 0,
            todayVisitors: (todayRow && todayRow.unique_visitors) || 0,
            todayVisits: (todayRow && todayRow.total_visits) || 0,
            dailyHistory,
            recentVisitors,
        }));
    } catch (err) {
        return createResponse(JSON.stringify({ error: err.message }), 500);
    }
}

function profileFromRow(row) {
    return {
        provider: row.provider || "google",
        baseUrl: row.base_url || "",
        apiKey: row.api_key || "",
        model: row.model || "gemini-1.5-flash",
    };
}

async function authUser(env, request) {
    await ensureAuthSchema(env);
    const header = request.headers.get("Authorization") || "";
    const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
    if (!token) return null;
    const row = await env.DB.prepare(
        `SELECT username FROM user_sessions WHERE token = ? AND expires_at > ?`
    ).bind(token, Date.now()).first();
    return row && row.username ? row.username : null;
}

async function upsertActivityHistory(env, deviceId, parsed, recordedAt) {
    const title = normalizeWindowTitle(parsed.window);
    if (isNoiseWindowTitle(title) || isSystemStateWindow(title)) return { stored: false, reason: "noise" };

    const start = Number(parsed.start) || null;
    const dur = Number(parsed.dur) || (start ? Math.max(0, recordedAt - start) : 0);
    if (dur > 0 && dur < MIN_ACTIVITY_MS) return { stored: false, reason: "short" };

    // 取上一行（标题经字典解析，兼容老的文本列）
    const last = await env.DB.prepare(
        `SELECT ah.id, COALESCE(dt.title, ah.window_title) AS window_title,
                ah.recorded_at, ah.started_at, ah.duration_ms
         FROM activity_history ah LEFT JOIN dict_titles dt ON dt.id = ah.title_id
         WHERE ah.device_id = ?
         ORDER BY ah.recorded_at DESC, ah.id DESC LIMIT 1`
    ).bind(deviceId).first();

    const titleId  = await internTitle(env, title);
    const vitalsId = await internVitals(env, parsed.lan, parsed.wifi, parsed.battery);

    if (last && normalizeWindowTitle(last.window_title) === title &&
        recordedAt >= last.recorded_at && recordedAt - last.recorded_at <= DUP_MERGE_WINDOW_MS) {
        const oldStart = Number(last.started_at) || (Number(last.recorded_at) - (Number(last.duration_ms) || 0));
        const mergedStart = start ? Math.min(oldStart || start, start) : (oldStart || null);
        const mergedDur = mergedStart ? Math.max(0, recordedAt - mergedStart) : (Number(last.duration_ms) || dur || null);
        // 字典化：文本列清空，改存 title_id/vitals_id（新行体积大幅缩小）
        await env.DB.prepare(
            `UPDATE activity_history
             SET window_title = '', title_id = ?, lan = NULL, wifi = NULL, battery = NULL, vitals_id = ?,
                 recorded_at = ?, started_at = ?, duration_ms = ?
             WHERE id = ?`
        ).bind(titleId, vitalsId, recordedAt, mergedStart, mergedDur, last.id).run();
        return { stored: true, merged: true };
    }

    await env.DB.prepare(
        `INSERT INTO activity_history
           (device_id, window_title, title_id, lan, wifi, battery, vitals_id, recorded_at, started_at, duration_ms)
         VALUES (?, '', ?, NULL, NULL, NULL, ?, ?, ?, ?)`
    ).bind(deviceId, titleId, vitalsId, recordedAt, start, dur || null).run();
    return { stored: true, merged: false };
}

// ─── 解析 Probe 上报的 payload（兼容旧的纯文本格式）───
function parseProbePayload(raw) {
    try {
        const obj = JSON.parse(raw);
        return {
            window:    normalizeWindowTitle(obj.window || raw),
            bg_app:    normalizeWindowTitle(obj.bg_app || ''),
            lan:       obj.lan     || 'unknown',
            wifi:      obj.wifi    || 'unknown',
            battery:   obj.battery || 'unknown',
            start:     Number(obj.start) || 0,
            end:       Number(obj.end)   || 0,
            dur:       Number(obj.dur)   || 0,
            keepalive: !!obj.keepalive,
        };
    } catch {
        return {
            window: normalizeWindowTitle(raw),
            bg_app: '',
            lan: 'unknown',
            wifi: 'unknown',
            battery: 'unknown',
            start: 0,
            end: 0,
            dur: 0,
            keepalive: false,
        };
    }
}

// ─── 定时清理（由 Cron Trigger 调用，确定性预算清理，取代早期的 Math.random 抽样）───
async function runCleanup(env) {
    const now = Date.now();
    const DAY = 86400000;
    const KEEP_PER_DEVICE = 3000000;
    const SOFT_ROWS = 8500000;
    const LOW_ROWS = 7500000;
    const FLOOR_DAYS = 1095;
    const DELETE_BUDGET = 80000;
    let budget = DELETE_BUDGET;

    if (budget > 0) {
        const r = await env.DB.prepare(
            `DELETE FROM activity_history WHERE id IN (
                 SELECT id FROM activity_history WHERE recorded_at < ? ORDER BY recorded_at ASC LIMIT ?)`
        ).bind(now - FLOOR_DAYS * DAY, budget).run();
        budget -= (r.meta && r.meta.changes) || 0;
    }

    const devs = await env.DB.prepare(`SELECT DISTINCT device_id FROM activity_history`).all();
    for (const d of (devs.results || [])) {
        if (budget <= 0) break;
        const thr = await env.DB.prepare(
            `SELECT recorded_at AS t FROM activity_history
             WHERE device_id = ?1 ORDER BY recorded_at DESC LIMIT 1 OFFSET ?2`
        ).bind(d.device_id, KEEP_PER_DEVICE).first();
        if (thr && thr.t != null) {
            const r = await env.DB.prepare(
                `DELETE FROM activity_history WHERE id IN (
                     SELECT id FROM activity_history
                     WHERE device_id = ?1 AND recorded_at < ?2 ORDER BY recorded_at ASC LIMIT ?3)`
            ).bind(d.device_id, thr.t, budget).run();
            budget -= (r.meta && r.meta.changes) || 0;
        }
    }

    if (budget > 0) {
        const cntRow = await env.DB.prepare(`SELECT COUNT(*) AS c FROM activity_history`).first();
        let total = (cntRow && cntRow.c) || 0;
        while (total > SOFT_ROWS && budget > 0) {
            const n = Math.min(total - LOW_ROWS, budget, 50000);
            if (n <= 0) break;
            const r = await env.DB.prepare(
                `DELETE FROM activity_history WHERE id IN (
                     SELECT id FROM activity_history ORDER BY recorded_at ASC LIMIT ?)`
            ).bind(n).run();
            const changed = (r.meta && r.meta.changes) || 0;
            if (changed === 0) break;
            total -= changed;
            budget -= changed;
        }
    }

    await env.DB.prepare(
        `DELETE FROM messages WHERE id NOT IN (SELECT id FROM messages ORDER BY timestamp DESC LIMIT 200)`
    ).run();
    await env.DB.prepare(`DELETE FROM online_users WHERE last_seen < ?`).bind(now - 600000).run();
    await env.DB.prepare(
        `DELETE FROM devices WHERE id NOT IN ('desktop','notebook','phone') AND last_seen < ?`
    ).bind(now - DAY).run();

    // 字典 GC：删除不再被任何活动行引用的标题/vitals（防止字典随保留期推移无限增长）
    try {
        await env.DB.prepare(
            `DELETE FROM dict_titles WHERE id NOT IN (SELECT title_id FROM activity_history WHERE title_id IS NOT NULL)`
        ).run();
        await env.DB.prepare(
            `DELETE FROM dict_vitals WHERE id NOT IN (SELECT vitals_id FROM activity_history WHERE vitals_id IS NOT NULL)`
        ).run();
    } catch (e) {
        // 字典表/列可能尚未就绪（migration 未应用），忽略
    }

    // 访客统计 GC：删除超过 365 天未访问的访客记录 + 超过 365 天的每日统计行
    try {
        await env.DB.prepare(
            `DELETE FROM visitor_stats WHERE last_seen < ?`
        ).bind(now - 365 * DAY).run();
        await env.DB.prepare(
            `DELETE FROM visitor_daily WHERE day < ?`
        ).bind(shanghaiDay(now - 365 * DAY)).run();
    } catch (e) {
        // 访客表可能尚未就绪（migration 未应用），忽略
    }
}

function shanghaiDay(ts = Date.now()) {
    return new Date(ts + 8 * 3600000).toISOString().slice(0, 10);
}

// ─── AI 使用计数（按「上海日 + provider」累加），返回今日该 provider 的累计次数 ───
async function bumpUsage(env, provider) {
    const day = shanghaiDay();
    try {
        await env.DB.prepare(
            `INSERT INTO ai_usage (day, provider, count) VALUES (?, ?, 1)
             ON CONFLICT(day, provider) DO UPDATE SET count = count + 1`
        ).bind(day, provider).run();
        const r = await env.DB.prepare(
            "SELECT count FROM ai_usage WHERE day = ? AND provider = ?"
        ).bind(day, provider).first();
        return (r && r.count) || 1;
    } catch { return 0; }
}

// 间隔式会话合并（sessionization）：按 device|title 分组，相邻同键段在
// 间隔 <= gapMs 时合并为一段。比固定 30 分钟时钟网格更贴近真实会话，
// 且把 alt-tab 风暴折叠成「应用累计时长」，段更少、token 更省、时长总和不变。
function mergeSessions(rows, complete, gapMs = 5 * 60 * 1000) {
    // 1) 规整 + 过滤噪声/系统状态，统一成 {device,title,start,end,durMs}
    const prepared = [];
    for (const row of rows || []) {
        const device = row.device_id || row.device || "?";
        const title = normalizeWindowTitle(row.window_title || row.window || "");
        if (isNoiseWindowTitle(title) || isSystemStateWindow(title)) continue;
        const end = Number(row.recorded_at || row.end || 0);
        const rawDur = Number(row.duration_ms || row.durMs || row.dur || 0);
        const start = Number(row.started_at || row.start || (end && rawDur ? end - rawDur : end));
        const durMs = rawDur || Math.max(0, end - start);
        if (!end || !start || durMs <= 0) continue;
        prepared.push({ device, title, start, end, durMs });
    }
    // 2) 按 start 升序，逐条并入「同键最近一段」（间隔 <= gapMs 即合并）
    prepared.sort((a, b) => a.start - b.start || a.end - b.end);
    const lastByKey = new Map();
    const merged = [];
    for (const it of prepared) {
        const key = it.device + "|" + it.title;
        const seg = lastByKey.get(key);
        if (seg && it.start - seg.end <= gapMs) {
            seg.end = Math.max(seg.end, it.end);
            seg.durMs += it.durMs;
            seg.count += 1;
        } else {
            const ns = { device: it.device, window: it.title, start: it.start, end: it.end, durMs: it.durMs, count: 1 };
            merged.push(ns);
            lastByKey.set(key, ns);
        }
    }
    merged.sort((a, b) => a.start - b.start || a.end - b.end);

    // 3) 汇总（口径与改前一致）
    const perApp = {};
    const perDevice = {};
    const buckets = { night: 0, morning: 0, afternoon: 0, evening: 0 };
    for (const seg of merged) {
        perApp[seg.window] = (perApp[seg.window] || 0) + seg.durMs;
        perDevice[seg.device] = (perDevice[seg.device] || 0) + seg.durMs;
        const h = new Date(seg.start + 8 * 3600000).getUTCHours();
        if (h < 5) buckets.night += seg.durMs;
        else if (h < 12) buckets.morning += seg.durMs;
        else if (h < 18) buckets.afternoon += seg.durMs;
        else buckets.evening += seg.durMs;
    }

    return {
        merged,
        rollups: { perApp, perDevice, buckets },
        totalSessions: (rows || []).length,
        complete: !!complete,
    };
}

async function callExternalLLM(provider, baseUrl, apiKey, model, sys, prompt) {
    if (!apiKey) throw new Error('Missing API Key');
    if (provider === 'openai') {
        const url = (baseUrl || 'https://api.openai.com/v1').replace(/\/+$/, '') + '/chat/completions';
        const res = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + apiKey },
            body: JSON.stringify({ model: model || 'gpt-4o-mini',
                messages: [{ role: 'system', content: sys }, { role: 'user', content: prompt }] }),
        });
        const data = await res.json();
        if (!res.ok) throw new Error((data.error && data.error.message) || ('HTTP ' + res.status));
        return (data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content) || '';
    }
    if (provider === 'google') {
        const base = (baseUrl || 'https://generativelanguage.googleapis.com/v1beta').replace(/\/+$/, '');
        const m = model || 'gemini-1.5-flash';
        const url = `${base}/models/${m}:generateContent?key=${encodeURIComponent(apiKey)}`;
        const res = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                systemInstruction: { parts: [{ text: sys }] },
                contents: [{ role: 'user', parts: [{ text: prompt }] }],
            }),
        });
        const data = await res.json();
        if (!res.ok) throw new Error((data.error && data.error.message) || ('HTTP ' + res.status));
        const parts = (data.candidates && data.candidates[0] && data.candidates[0].content && data.candidates[0].content.parts) || [];
        return parts.map(p => p.text || '').join('') || '';
    }
    throw new Error('Unknown provider: ' + provider);
}

// ─── 拉取外部可用模型列表 ───
async function listExternalModels(provider, baseUrl, apiKey) {
    if (!apiKey) throw new Error('Missing API Key');
    if (provider === 'openai') {
        const url = (baseUrl || 'https://api.openai.com/v1').replace(/\/+$/, '') + '/models';
        const res = await fetch(url, { headers: { 'Authorization': 'Bearer ' + apiKey } });
        const data = await res.json();
        if (!res.ok) throw new Error((data.error && data.error.message) || ('HTTP ' + res.status));
        return (data.data || []).map(m => m.id).filter(Boolean).sort();
    }
    if (provider === 'google') {
        const base = (baseUrl || 'https://generativelanguage.googleapis.com/v1beta').replace(/\/+$/, '');
        const res = await fetch(`${base}/models?key=${encodeURIComponent(apiKey)}&pageSize=200`);
        const data = await res.json();
        if (!res.ok) throw new Error((data.error && data.error.message) || ('HTTP ' + res.status));
        return (data.models || []).map(m => (m.name || '').replace(/^models\//, '')).filter(Boolean).sort();
    }
    throw new Error('Unknown provider: ' + provider);
}

// ==========================================
// API 处理函数（每个对应一条路由；逻辑与路由表化前完全一致）
// ==========================================

// [API] 核心：聚合同步接口（Big JSON Mode）
async function handleSync(request, env, url) {
    try {
        const sinceId = parseInt(url.searchParams.get("since") || "0", 10);
        const msgStmt = sinceId > 0
            ? env.DB.prepare("SELECT * FROM messages WHERE id > ? ORDER BY timestamp ASC LIMIT 100").bind(sinceId)
            : env.DB.prepare("SELECT * FROM messages ORDER BY timestamp DESC LIMIT 100");
        const results = await env.DB.batch([
            env.DB.prepare("SELECT * FROM devices"),
            msgStmt,
            env.DB.prepare("SELECT * FROM online_users WHERE last_seen > ?").bind(Date.now() - 300000)
        ]);

        const devicesRaw  = results[0].results;
        const messagesRaw = results[1].results;
        const onlineRaw   = results[2].results;

        const deviceData = { devices: {}, times: {}, lastSeen: {}, extra: {} };
        devicesRaw.forEach(d => {
            let status = d.status || '系统在线';
            if (String(status).trim().toLowerCase() === 'online') status = '系统在线';
            deviceData.devices[d.id]  = status;
            deviceData.times[d.id]    = d.updated_at;
            deviceData.lastSeen[d.id] = d.last_seen;
            deviceData.extra[d.id] = {
                lan:     d.lan     || 'unknown',
                wifi:    d.wifi    || 'unknown',
                battery: d.battery || 'unknown',
                last_ip: d.last_ip || 'unknown',
            };
        });

        const chatHistory = messagesRaw.map(m => ({
            id:        m.id,
            user:      m.user,
            message:   m.content,
            timestamp: m.timestamp,
            sessionId: m.session_id
        }));

        // 需求3：在线用户列表，含昵称和 IP
        const onlineUsers = {};
        onlineRaw.forEach(u => {
            onlineUsers[u.session_id] = {
                userName: u.user_name,
                lastSeen: u.last_seen,
                ip:       u.ip || 'unknown',
            };
        });

        return createResponse(JSON.stringify({
            deviceData,
            chatHistory,
            onlineCount: onlineRaw.length,
            onlineUsers
        }));

    } catch (err) {
        return createResponse(JSON.stringify({ error: err.message }), 500);
    }
}

// [API] 批量落库：离线队列重发用，body 为已切好的会话数组，一次 DB.batch() 落库
async function ingestReportBatch(env, deviceId, entries, now, timeStr, cfIp) {
    const stmts = [];
    let lastVitals = null;
    let lastStatus = null;
    for (const raw of entries) {
        const parsed = parseProbePayload(typeof raw === "string" ? raw : JSON.stringify(raw));
        lastVitals = parsed;
        const title = normalizeWindowTitle(parsed.window);
        if (isNoiseWindowTitle(title) || isSystemStateWindow(title)) continue;
        const start = Number(parsed.start) || null;
        const recordedAt = parsed.end || now;
        const dur = Number(parsed.dur) || (start ? Math.max(0, recordedAt - start) : 0);
        if (dur > 0 && dur < MIN_ACTIVITY_MS) continue;
        const titleId  = await internTitle(env, title);
        const vitalsId = await internVitals(env, parsed.lan, parsed.wifi, parsed.battery);
        lastStatus = title;
        stmts.push(env.DB.prepare(
            `INSERT INTO activity_history
               (device_id, window_title, title_id, lan, wifi, battery, vitals_id, recorded_at, started_at, duration_ms)
             VALUES (?, '', ?, NULL, NULL, NULL, ?, ?, ?, ?)`
        ).bind(deviceId, titleId, vitalsId, recordedAt, start, dur || null));
    }
    // devices 行用最后一条刷新一次（与单条上报口径一致）
    const v = lastVitals || { lan: "unknown", wifi: "unknown", battery: "unknown" };
    stmts.push(env.DB.prepare(
        `INSERT INTO devices (id, status, last_seen, updated_at, last_ip, lan, wifi, battery)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
         status=CASE WHEN ? IS NULL THEN COALESCE(NULLIF(devices.status, 'online'), '系统在线') ELSE excluded.status END,
         last_seen=excluded.last_seen, updated_at=excluded.updated_at, last_ip=excluded.last_ip,
         lan=CASE WHEN excluded.lan='unknown' THEN devices.lan ELSE excluded.lan END, wifi=CASE WHEN excluded.wifi='unknown' THEN devices.wifi ELSE excluded.wifi END, battery=CASE WHEN excluded.battery='unknown' THEN devices.battery ELSE excluded.battery END`
    ).bind(deviceId, lastStatus || '系统在线', now, timeStr, cfIp, v.lan, v.wifi, v.battery, lastStatus));
    if (stmts.length) await env.DB.batch(stmts);
}

// [API] 设备上报：POST /api/report/{device_id}（body 为单对象或会话数组）
async function handleReport(request, env, url) {
    try {
        const deviceId = url.pathname.split("/").pop().toLowerCase();
        if (!deviceId) return createResponse("Invalid ID", 400);

        const rawBody = await request.text();
        const now     = Date.now();
        const timeStr = new Date().toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai', hour12: false });
        const cfIp    = request.headers.get("CF-Connecting-IP") || "unknown";

        // 批量上报（离线队列重发）：body 为 JSON 数组 → 一次性落库
        let arr = null;
        try { const j = JSON.parse(rawBody); if (Array.isArray(j)) arr = j; } catch {}
        if (arr) {
            await ingestReportBatch(env, deviceId, arr, now, timeStr, cfIp);
            return createResponse("OK", 200, "text/plain");
        }

        const parsed  = parseProbePayload(rawBody);
        // 系统状态窗口（息屏/锁屏）现可作为设备状态显示；噪声标题仍置 null
        let statusTitle = isNoiseWindowTitle(parsed.window) ? null : parsed.window;
        // QQ/TIM 后台可见窗口：把 bg_app 附加到设备状态显示
        const bgApp = parsed.bg_app || '';
        if (bgApp && !isNoiseWindowTitle(bgApp)) {
            const fgLabel = statusTitle || '系统在线';
            statusTitle = fgLabel + ' \u2502 QQ: ' + bgApp;
        }

        // 实时设备行：每次上报（含 keepalive）都刷新，保证在线状态与当前活动新鲜
        await env.DB.prepare(
            `INSERT INTO devices (id, status, last_seen, updated_at, last_ip, lan, wifi, battery)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(id) DO UPDATE SET
             status=CASE
                 WHEN ? IS NULL THEN COALESCE(NULLIF(devices.status, 'online'), '系统在线')
                 ELSE excluded.status
             END,
             last_seen=excluded.last_seen,
             updated_at=excluded.updated_at, last_ip=excluded.last_ip,
             lan=CASE WHEN excluded.lan='unknown' THEN devices.lan ELSE excluded.lan END, wifi=CASE WHEN excluded.wifi='unknown' THEN devices.wifi ELSE excluded.wifi END, battery=CASE WHEN excluded.battery='unknown' THEN devices.battery ELSE excluded.battery END`
        ).bind(deviceId, statusTitle || '系统在线', now, timeStr, cfIp,
            parsed.lan, parsed.wifi, parsed.battery, statusTitle).run();

        if (!parsed.keepalive) {
            const recordedAt = parsed.end || now;
            await upsertActivityHistory(env, deviceId, parsed, recordedAt);
        }

        return createResponse("OK", 200, "text/plain");
    } catch (err) {
        return createResponse("Error: " + err.message, 500);
    }
}

// [API] 活动历史：keyset 分页，单次请求返回一页
async function handleHistory(request, env, url) {
    try {
        const deviceId  = url.searchParams.get("device");   // all 或逗号分隔的 id
        const startTime = parseInt(url.searchParams.get("start") || "0");
        const endTime   = parseInt(url.searchParams.get("end")   || String(Date.now()));
        // Keyset pagination: one bounded page per request.
        const pageSize  = Math.min(Math.max(parseInt(url.searchParams.get("pageSize") || "80"), 1), 200);
        const fetchLimit = Math.min(pageSize * 4 + 1, 800);
        const cursorTs  = parseInt(url.searchParams.get("cursorTs") || "0");
        const cursorId  = parseInt(url.searchParams.get("cursorId") || "0");

        const where = [];
        const binds = [];
        const devs = (deviceId || "all").split(",").map(s => s.trim()).filter(Boolean);
        if (devs.length && !devs.includes("all")) {
            where.push(`ah.device_id IN (${devs.map(() => "?").join(",")})`);
            binds.push(...devs);
        }
        where.push("ah.recorded_at BETWEEN ? AND ?"); binds.push(startTime, endTime);
        if (cursorTs > 0) { where.push("(ah.recorded_at < ? OR (ah.recorded_at = ? AND ah.id < ?))"); binds.push(cursorTs, cursorTs, cursorId); }

        // 字典解析：新行经 dict_titles/dict_vitals，老行回退自身文本列（COALESCE）
        const sql = `SELECT ah.id, ah.device_id,
                            COALESCE(dt.title, ah.window_title) AS window_title,
                            COALESCE(dv.lan, ah.lan)         AS lan,
                            COALESCE(dv.wifi, ah.wifi)       AS wifi,
                            COALESCE(dv.battery, ah.battery) AS battery,
                            ah.recorded_at, ah.started_at, ah.duration_ms
                     FROM activity_history ah
                     LEFT JOIN dict_titles dt ON dt.id = ah.title_id
                     LEFT JOIN dict_vitals dv ON dv.id = ah.vitals_id
                     WHERE ${where.join(" AND ")}
                     ORDER BY ah.recorded_at DESC, ah.id DESC LIMIT ?`;
        binds.push(fetchLimit);
        const rows = (await env.DB.prepare(sql).bind(...binds).all()).results || [];

        const history = [];
        let consumed = null;
        let consumedIndex = -1;
        for (let i = 0; i < rows.length; i++) {
            const row = rows[i];
            consumed = row;
            consumedIndex = i;
            const clean = sanitizeActivityRow(row);
            if (clean) history.push(clean);
            if (history.length >= pageSize) break;
        }
        const stoppedEarly = consumedIndex >= 0 && consumedIndex < rows.length - 1;
        const done = !stoppedEarly && rows.length < fetchLimit;
        const nextTs = (!done && consumed) ? consumed.recorded_at : null;
        const nextId = (!done && consumed) ? consumed.id : null;
        return createResponse(JSON.stringify({ history, done, nextTs, nextId, pageSize }));
    } catch (err) {
        return createResponse(JSON.stringify({ error: err.message }), 500);
    }
}

// [API] 发送聊天消息
async function handleChat(request, env, url) {
    try {
        const { user, message, sessionId } = await request.json();
        const now = Date.now();

        await env.DB.prepare(
            "INSERT INTO messages (user, content, timestamp, session_id) VALUES (?, ?, ?, ?)"
        ).bind(user || "匿名", message, now, sessionId).run();

        return createResponse(JSON.stringify({ success: true }));
    } catch (err) {
        return createResponse(JSON.stringify({ success: false, error: err.message }), 500);
    }
}

// [API] 用户心跳（需求3：保存 IP，返回含 IP 的在线列表 + 访客统计）
async function handleHeartbeat(request, env, url) {
    try {
        const { sessionId, userName, fingerprint } = await request.json();
        const now   = Date.now();
        const cfIp  = request.headers.get("CF-Connecting-IP") || "unknown";
        const ua    = request.headers.get("User-Agent") || "";

        await env.DB.prepare(
            `INSERT INTO online_users (session_id, user_name, last_seen, ip)
             VALUES (?, ?, ?, ?)
             ON CONFLICT(session_id) DO UPDATE SET
             last_seen=excluded.last_seen, user_name=excluded.user_name, ip=excluded.ip`
        ).bind(sessionId, userName || "匿名", now, cfIp).run();

        // 访客统计：IP + 浏览器指纹组合哈希做去重
        if (fingerprint) {
            await ensureVisitorSchema(env);
            const visitorHash = await sha256Hex(cfIp + '|' + fingerprint);
            await recordVisitor(env, visitorHash, cfIp, ua.slice(0, 500), userName || null);
        }

        const onlineRows = await env.DB.prepare(
            "SELECT session_id, user_name, last_seen, ip FROM online_users WHERE last_seen > ?"
        ).bind(now - 300000).all();

        const onlineUsers = {};
        onlineRows.results.forEach(u => {
            onlineUsers[u.session_id] = {
                userName: u.user_name,
                lastSeen: u.last_seen,
                ip:       u.ip || 'unknown',
            };
        });

        return createResponse(JSON.stringify({
            success: true,
            onlineCount: onlineRows.results.length,
            onlineUsers
        }));
    } catch (err) {
        return createResponse(JSON.stringify({ success: false, error: err.message }), 500);
    }
}

// [API] AI 总结：provider = cf(默认) / openai / google；统一计数
async function handleAiSummary(request, env, url) {
    try {
        const body     = await request.json();
        const provider = (body.provider || 'cf').toLowerCase();
        const prompt   = body.prompt || '';
        const sys = 'You are an objective personal activity analyst. Use only the provided timeline and rollups, ignore obvious noise, do not speculate about private motives, and answer in concise Chinese bullets.';
        let summary = '';
        if (provider === 'cf') {
            const model = body.model || '@cf/qwen/qwen2.5-coder-32b-instruct';
            const msgs  = [{ role: 'system', content: sys }, { role: 'user', content: prompt }];
            try {
                const result = await env.AI.run(model, { messages: msgs, max_tokens: 2000 });
                summary = result.response || '';
            } catch (e) {
                // 所选 CF 模型不可用时回退到确定可用的 llama-3.1-8b-instruct
                const fb = await env.AI.run('@cf/meta/llama-3.1-8b-instruct', { messages: msgs, max_tokens: 2000 });
                summary = (fb.response || '') + '\n\n(note: selected CF model ' + model + ' was unavailable; fell back to llama-3.1-8b-instruct)';
            }
        } else {
            summary = await callExternalLLM(provider, body.baseUrl, body.apiKey, body.model, sys, prompt);
        }

        const used = await bumpUsage(env, provider);
        return createResponse(JSON.stringify({ summary, provider, usedToday: used }));
    } catch (err) {
        return createResponse(JSON.stringify({ summary: 'AI analysis failed: ' + err.message, error: err.message }), 500);
    }
}

// [API] AI 合并数据：服务端无损合并区间内所有会话 + 汇总（给 AI 用，完整不截断）
async function handleAiData(request, env, url) {
    try {
        const devParam  = (url.searchParams.get("devices") || "all").toLowerCase();
        const startTime = parseInt(url.searchParams.get("start") || "0");
        const endTime   = parseInt(url.searchParams.get("end")   || String(Date.now()));
        const SAFETY    = 100000;   // 安全上限(远超正常用量)；命中则 complete=false 触发前端 map-reduce

        let sql, binds;
        if (devParam && devParam !== "all") {
            const devs = devParam.split(",").map(s => s.trim()).filter(Boolean);
            const ph = devs.map(() => "?").join(",");
            sql = `SELECT ah.device_id, COALESCE(dt.title, ah.window_title) AS window_title,
                          ah.recorded_at, ah.started_at, ah.duration_ms
                   FROM activity_history ah LEFT JOIN dict_titles dt ON dt.id = ah.title_id
                   WHERE ah.device_id IN (${ph}) AND ah.recorded_at BETWEEN ? AND ?
                   ORDER BY ah.recorded_at ASC LIMIT ?`;
            binds = [...devs, startTime, endTime, SAFETY + 1];
        } else {
            sql = `SELECT ah.device_id, COALESCE(dt.title, ah.window_title) AS window_title,
                          ah.recorded_at, ah.started_at, ah.duration_ms
                   FROM activity_history ah LEFT JOIN dict_titles dt ON dt.id = ah.title_id
                   WHERE ah.recorded_at BETWEEN ? AND ?
                   ORDER BY ah.recorded_at ASC LIMIT ?`;
            binds = [startTime, endTime, SAFETY + 1];
        }
        const rows = (await env.DB.prepare(sql).bind(...binds).all()).results || [];
        const complete = rows.length <= SAFETY;
        if (!complete) rows.length = SAFETY;
        const cleanRows = rows.map(sanitizeActivityRow).filter(Boolean);

        return createResponse(JSON.stringify(mergeSessions(cleanRows, complete)));
    } catch (err) {
        return createResponse(JSON.stringify({ error: err.message }), 500);
    }
}

// [API] 今日 AI 用量
async function handleAiUsage(request, env, url) {
    try {
        const day = shanghaiDay();
        const rows = (await env.DB.prepare(
            "SELECT provider, count FROM ai_usage WHERE day = ?"
        ).bind(day).all()).results || [];
        const usage = {};
        rows.forEach(r => { usage[r.provider] = r.count; });
        return createResponse(JSON.stringify({ day, usage }));
    } catch (err) {
        return createResponse(JSON.stringify({ day: shanghaiDay(), usage: {} }));
    }
}

// [API] 列出外部 provider 可用模型
async function handleModels(request, env, url) {
    try {
        const { provider, baseUrl, apiKey } = await request.json();
        const models = await listExternalModels((provider || '').toLowerCase(), baseUrl, apiKey);
        return createResponse(JSON.stringify({ models }));
    } catch (err) {
        return createResponse(JSON.stringify({ models: [], error: err.message }), 500);
    }
}

// [API] 可选登录：用于记住外部 AI 配置
async function handleLogin(request, env, url) {
    try {
        await ensureAuthSchema(env);
        const { username, password } = await request.json();
        const row = await env.DB.prepare(
            `SELECT * FROM user_ai_profiles WHERE username = ?`
        ).bind(username || "").first();
        if (!row || row.password_hash !== await sha256Hex(password || "")) {
            return createResponse(JSON.stringify({ error: "Invalid username or password" }), 401);
        }
        const token = randomToken();
        const expiresAt = Date.now() + 30 * 86400000;
        await env.DB.prepare(
            `INSERT INTO user_sessions (token, username, expires_at) VALUES (?, ?, ?)`
        ).bind(token, row.username, expiresAt).run();
        return createResponse(JSON.stringify({
            token,
            username: row.username,
            profile: profileFromRow(row),
            expiresAt,
        }));
    } catch (err) {
        return createResponse(JSON.stringify({ error: err.message }), 500);
    }
}

// [API] 退出登录
async function handleLogout(request, env, url) {
    try {
        await ensureAuthSchema(env);
        const header = request.headers.get("Authorization") || "";
        const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
        if (token) await env.DB.prepare(`DELETE FROM user_sessions WHERE token = ?`).bind(token).run();
        return createResponse(JSON.stringify({ success: true }));
    } catch (err) {
        return createResponse(JSON.stringify({ success: false, error: err.message }), 500);
    }
}

// [API] 读取当前用户的 AI 配置
async function handleGetAiConfig(request, env, url) {
    try {
        const username = await authUser(env, request);
        if (!username) return createResponse(JSON.stringify({ error: "Unauthorized" }), 401);
        const row = await env.DB.prepare(
            `SELECT * FROM user_ai_profiles WHERE username = ?`
        ).bind(username).first();
        return createResponse(JSON.stringify({ username, profile: profileFromRow(row) }));
    } catch (err) {
        return createResponse(JSON.stringify({ error: err.message }), 500);
    }
}

// [API] 保存当前用户的 AI 配置
async function handlePostAiConfig(request, env, url) {
    try {
        const username = await authUser(env, request);
        if (!username) return createResponse(JSON.stringify({ error: "Unauthorized" }), 401);
        const body = await request.json();
        const provider = (body.provider || "google").toLowerCase();
        const baseUrl = String(body.baseUrl || "");
        const apiKey = String(body.apiKey || "");
        const model = String(body.model || (provider === "google" ? "gemini-1.5-flash" : ""));
        await env.DB.prepare(
            `UPDATE user_ai_profiles
             SET provider = ?, base_url = ?, api_key = ?, model = ?, updated_at = ?
             WHERE username = ?`
        ).bind(provider, baseUrl, apiKey, model, Date.now(), username).run();
        return createResponse(JSON.stringify({
            success: true,
            username,
            profile: { provider, baseUrl, apiKey, model },
        }));
    } catch (err) {
        return createResponse(JSON.stringify({ success: false, error: err.message }), 500);
    }
}

// [API] 删除单个设备：DELETE /api/device/{id}
async function handleDeleteDevice(request, env, url) {
    const deviceId = url.pathname.split("/").pop().toLowerCase();
    await env.DB.prepare("DELETE FROM devices WHERE id = ?").bind(deviceId).run();
    return createResponse(JSON.stringify({ success: true, message: "Deleted " + deviceId }));
}

// [API] 删除全部设备
async function handleDeleteDevices(request, env, url) {
    await env.DB.prepare("DELETE FROM devices").run();
    return createResponse(JSON.stringify({ success: true, message: "All cleared" }));
}

// ==========================================
// 路由表 + 分发
// ==========================================

// 精确匹配路由（key = "METHOD pathname"）
const ROUTES = {
    "GET /api/sync":            handleSync,
    "GET /api/history":         handleHistory,
    "POST /api/chat":           handleChat,
    "POST /api/heartbeat":      handleHeartbeat,
    "GET /api/visitor-stats":   handleVisitorStats,
    "POST /api/ai-summary":     handleAiSummary,
    "GET /api/ai-data":         handleAiData,
    "GET /api/ai-usage":        handleAiUsage,
    "POST /api/models":         handleModels,
    "POST /api/auth/login":     handleLogin,
    "POST /api/auth/logout":    handleLogout,
    "GET /api/user/ai-config":  handleGetAiConfig,
    "POST /api/user/ai-config": handlePostAiConfig,
    "DELETE /api/devices":      handleDeleteDevices,
};

export default {
    async fetch(request, env, ctx) {
        const url = new URL(request.url);
        const method = request.method;
        const pathname = url.pathname;

        if (method === "OPTIONS") {
            return new Response(null, { headers: corsHeaders });
        }

        // SEO 静态文件：在 Assets 回落前拦截，确保返回正确的 Content-Type。
        // 否则 wrangler 的 not_found_handling:"single-page-application" 会把
        // robots.txt / sitemap.xml 回落为 index.html（text/html），被搜索引擎拒收。
        if (method === "GET" && pathname === "/robots.txt") {
            return new Response(
                "User-agent: *\nAllow: /\n\nSitemap: https://flandretiamat.dpdns.org/sitemap.xml\n",
                { status: 200, headers: { "Content-Type": "text/plain; charset=UTF-8", "Cache-Control": "public, max-age=86400" } }
            );
        }
        if (method === "GET" && pathname === "/sitemap.xml") {
            const today = new Date().toISOString().slice(0, 10);
            const xml =
                '<?xml version="1.0" encoding="UTF-8"?>\n' +
                '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' +
                '  <url>\n' +
                '    <loc>https://flandretiamat.dpdns.org/</loc>\n' +
                '    <lastmod>' + today + '</lastmod>\n' +
                '    <changefreq>daily</changefreq>\n' +
                '    <priority>1.0</priority>\n' +
                '  </url>\n' +
                '</urlset>\n';
            return new Response(xml, {
                status: 200,
                headers: { "Content-Type": "application/xml; charset=UTF-8", "Cache-Control": "public, max-age=86400" }
            });
        }

        // 仅 API 路由需要 D1；静态资源请求直接走 Assets，不必初始化表
        if (pathname.startsWith("/api/")) {
            await ensureCoreTables(env);

            // 前缀路由（带路径参数），先于精确表匹配；与 "/api/devices" 互不冲突
            if (method === "POST" && pathname.startsWith("/api/report/")) return handleReport(request, env, url);
            if (method === "DELETE" && pathname.startsWith("/api/device/")) return handleDeleteDevice(request, env, url);

            const handler = ROUTES[method + " " + pathname];
            if (handler) return handler(request, env, url);
        }

        // 非 API 路由交给 Cloudflare Assets 系统处理（SPA 单页应用）
        return env.ASSETS.fetch(request);
    },

    async scheduled(event, env, ctx) {
        await runCleanup(env);
    },
};
