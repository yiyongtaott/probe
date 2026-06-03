/**
 * FLANDRE_TIAMAT Monitor (D1 Edition)
 * 部署平台: Cloudflare Workers + D1
 *
 * 新增功能:
 *   需求2 - 活动历史记录 + AI 总结
 *   需求3 - 设备上报 JSON 解析（window/lan/wifi/battery）
 *   需求4 - 在线用户列表（昵称 + IP）+ 访客 IP 记录
 */

const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS, DELETE",
    "Access-Control-Allow-Headers": "Content-Type",
};

const createResponse = (body, status = 200, contentType = "application/json") => {
    return new Response(body, {
        status,
        headers: { ...corsHeaders, "Content-Type": contentType }
    });
};

// ─── 解析 Probe 上报的 payload（兼容旧纯文本格式）───────────────────────────
function parseProbePayload(raw) {
    try {
        const obj = JSON.parse(raw);
        return {
            window:    obj.window  || raw,
            lan:       obj.lan     || 'unknown',
            wifi:      obj.wifi    || 'unknown',
            battery:   obj.battery || 'unknown',
            start:     Number(obj.start) || 0,   // 会话开始 (epoch ms)
            end:       Number(obj.end)   || 0,   // 会话结束 (epoch ms)
            dur:       Number(obj.dur)   || 0,   // 时长 ms
            keepalive: !!obj.keepalive,          // true = 仅刷新在线状态
        };
    } catch {
        // 旧版纯文本上报兼容
        return { window: raw, lan: 'unknown', wifi: 'unknown', battery: 'unknown',
                 start: 0, end: 0, dur: 0, keepalive: false };
    }
}

// ── 定时清理（Cron Trigger 调用，确定性，取代原来的 Math.random 清理）──────────
async function runCleanup(env) {
    const now = Date.now();
    const DAY = 86400000;

    // activity_history 三层保留策略（数值见方案；都可调）
    const KEEP_PER_DEVICE = 3000000;   // 每设备硬上限（~1.2GB/设备，防单设备失控）
    const SOFT_ROWS       = 8500000;   // 全局高水位（~3.4GB / ~68% of 5GB）：开始删最老
    const LOW_ROWS        = 7500000;   // 删到此低水位停手（~3.0GB）
    const FLOOR_DAYS      = 1095;      // 3 年时间兜底
    const DELETE_BUDGET   = 80000;     // 单次运行最多删多少行（护“写 10万/天”额度）
    let budget = DELETE_BUDGET;

    // 1) 时间兜底（走 idx_ah_time）
    if (budget > 0) {
        const r = await env.DB.prepare(
            `DELETE FROM activity_history WHERE id IN (
                 SELECT id FROM activity_history WHERE recorded_at < ? ORDER BY recorded_at ASC LIMIT ?)`
        ).bind(now - FLOOR_DAYS * DAY, budget).run();
        budget -= (r.meta && r.meta.changes) || 0;
    }

    // 2) 每设备只保留最新 N 条（走 idx_ah_dev_time，用 OFFSET 定位阈值时间）
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

    // 3) 全局高水位：超阈值就按时间升序删最老，直到低于低水位（分批，受预算约束）
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
            total -= changed; budget -= changed;
        }
    }

    // 次要表（都很小，确定性清理）
    await env.DB.prepare(
        `DELETE FROM messages WHERE id NOT IN (SELECT id FROM messages ORDER BY timestamp DESC LIMIT 200)`
    ).run();
    await env.DB.prepare(`DELETE FROM online_users WHERE last_seen < ?`).bind(now - 600000).run();
    await env.DB.prepare(
        `DELETE FROM devices WHERE id NOT IN ('desktop','notebook','phone') AND last_seen < ?`
    ).bind(now - DAY).run();
}

// ── 上海日期 (YYYY-MM-DD) ───────────────────────────────────────────────────
function shanghaiDay(ts = Date.now()) {
    return new Date(ts + 8 * 3600000).toISOString().slice(0, 10);
}

// ── AI 使用计次（按 上海日 + provider），返回今日该 provider 的累计次数 ──────
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
function mergeSessions(rows, complete) {
    // 【保留功能】噪声窗口：这些只是切换动画/工具栏，不代表有效活动
    const NOISE_RE = [
        /^任务栏[\s/／]/,
        /^系统: /,
        /^任务切换$/,
        /^系统托盘/,
        /^快速设置$/,
        /^正在选择同类型窗口$/,
        /^UWP 应用框架$/,
        /^开始菜单/,
        /^Windows 搜索$/,
        /^任务视图/,
        /^桌面$/,
    ];
    const NOISE_MAX_MS = 5000;  // 停留 >= 5s 的不视为噪声（用户真的在看）

    // 【保留功能】浏览器标题归一化：提取当前激活标签页的名称
    function normTitle(t) {
        if (!t) return '';
        const m1 = t.match(/^(.+?)\s+和另外\s*\d+\s*个页面/);
        if (m1) return m1[1].trim() + ' [Edge]';
        const m2 = t.match(/^(.+?)\s+-\s+个人\s+-\s+Microsoft/i);
        if (m2) return m2[1].trim() + ' [Edge]';
        return t;
    }

    function isNoise(title, dur) {
        if (dur > NOISE_MAX_MS) return false;   // 久了就不算噪声
        return NOISE_RE.some(re => re.test(title));
    }

    // 【保留功能】按设备分组（rows 已按 recorded_at ASC 排序）
    const byDev = {};
    for (const r of rows) {
        const dev = r.device_id || '?';
        if (!byDev[dev]) byDev[dev] = [];
        byDev[dev].push(r);
    }

    const allSegs = [];
    const THIRTY_MINUTES_MS = 30 * 60 * 1000;

    for (const [dev, devRows] of Object.entries(byDev)) {
        // 为了实现30分钟内同窗口不论断续都合并，我们维护一个当前30分钟内的“窗口映射表”
        // Key 结构: windowName
        let activeBucketId = null;
        let bucketSegments = {}; // 用于临时存储当前30分钟格子里的所有合并段

        // 内部辅助函数：当跨越30分钟边界或遍历结束时，把当前格子里的所有合并段提交
        function flushBucket() {
            for (const seg of Object.values(bucketSegments)) {
                seg._bridgeMs = 0; // 提交前重置噪声桥接内部状态
                allSegs.push(seg);
            }
            bucketSegments = {};
        }

        for (const r of devRows) {
            const end   = r.recorded_at || 0;
            const dur   = (r.duration_ms != null) ? r.duration_ms : 0;
            const start = (r.started_at  != null) ? r.started_at  : (end - dur);
            const norm  = normTitle(r.window_title || '');
            const noise = isNoise(norm, dur);

            // 【新融入：30分钟对齐逻辑】
            const currentBucketId = Math.floor(start / THIRTY_MINUTES_MS);
            if (activeBucketId !== currentBucketId) {
                flushBucket();
                activeBucketId = currentBucketId;
            }

            // 处理噪声
            if (noise) {
                // 【保留功能】噪声挂起：如果这30分钟内有任何活动段，都为其追加桥接时长
                for (const seg of Object.values(bucketSegments)) {
                    seg._bridgeMs = (seg._bridgeMs || 0) + dur;
                }
                continue;
            }

            // 【核心重构：30分钟内断续合并】
            if (bucketSegments[norm]) {
                // 如果30分钟内，同一个设备上已经出现过该窗口（不论是不是连续相邻的）
                const existing = bucketSegments[norm];
                existing.end = Math.max(existing.end, end);
                existing.start = Math.min(existing.start, start);
                existing.durMs += dur + (existing._bridgeMs || 0); // 延伸时长并入噪声桥接
                existing._bridgeMs = 0; // 清空桥接以便后续噪声继续使用
                existing.count += 1;    // 【保留功能】原汁原味的累加计次
            } else {
                // 如果是这30分钟内第一次出现这个窗口，则创建新合并段
                bucketSegments[norm] = {
                    device: dev,
                    window: norm,
                    origWindow: r.window_title || '',
                    start,
                    end,
                    durMs: dur,
                    _bridgeMs: 0,
                    count: 1,
                };
            }
        }
        // 遍历完当前设备的所有行后，记得冲刷最后一个时间格子
        flushBucket();
    }

    // 【保留功能】多设备时按时间重新排序
    allSegs.sort((a, b) => a.start - b.start || a.end - b.end);

    // 【保留功能】构建最终输出，与你原有的前端、图表、以及AI总结所需的结构体完全无缝兼容
    const timeline = [];
    const perApp = {}, perDevice = {};
    const buckets = { night: 0, morning: 0, afternoon: 0, evening: 0 };

    for (const seg of allSegs) {
        timeline.push({
            device: seg.device,
            window: seg.window || seg.origWindow,
            start:  seg.start,
            end:    seg.end,
            durMs:  seg.durMs,
            count:  seg.count,
        });

        const appKey = seg.window || seg.origWindow;
        perApp[appKey]        = (perApp[appKey]        || 0) + seg.durMs;
        perDevice[seg.device] = (perDevice[seg.device] || 0) + seg.durMs;

        // 【保留功能】上海时区时间分桶统计逻辑（傍晚、上午等）
        const h = new Date(seg.start + 8 * 3600000).getUTCHours();
        if      (h <  5) buckets.night     += seg.durMs;
        else if (h < 12) buckets.morning   += seg.durMs;
        else if (h < 18) buckets.afternoon += seg.durMs;
        else             buckets.evening   += seg.durMs;
    }

    return {
        merged: timeline,
        rollups: { perApp, perDevice, buckets },
        totalSessions: rows.length,
        complete: !!complete,
    };
}

// ── 外部 LLM 调用（OpenAI 协议 / Google 协议）经 worker 代理 ─────────────────
async function callExternalLLM(provider, baseUrl, apiKey, model, sys, prompt) {
    if (!apiKey) throw new Error('缺少 API Key');
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
    throw new Error('未知 provider: ' + provider);
}

// ── 拉取外部可用模型列表 ─────────────────────────────────────────────────────
async function listExternalModels(provider, baseUrl, apiKey) {
    if (!apiKey) throw new Error('缺少 API Key');
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
    throw new Error('未知 provider: ' + provider);
}

export default {
    async fetch(request, env, ctx) {
        const url = new URL(request.url);

        if (request.method === "OPTIONS") {
            return new Response(null, { headers: corsHeaders });
        }

        // [功能] 源码获取
        if (url.searchParams.get("get_source") === "1") {
            return new Response(htmlTemplate, {
                headers: { ...corsHeaders, "Content-Type": "text/plain;charset=UTF-8" }
            });
        }

        // ==========================================
        // D1 数据库 业务逻辑区
        // ==========================================

        // [API] 核心：聚合同步接口 (Big JSON Mode)
        if (request.method === "GET" && url.pathname === "/api/sync") {
            try {
                // 增量拉取消息：前端带 ?since=<最大id> 时只取更新的消息，省读额度
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
                    deviceData.devices[d.id]  = d.status;
                    deviceData.times[d.id]    = d.updated_at;
                    deviceData.lastSeen[d.id] = d.last_seen;
                    // 需求3：把扩展字段透传给前端
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

                // 需求4：在线用户列表，含昵称和 IP
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

        // [API] 上报设备数据（v2：会话化，window/lan/wifi/battery + start/end/dur）
        if (request.method === "POST" && url.pathname.startsWith("/api/report/")) {
            try {
                const deviceId = url.pathname.split("/").pop().toLowerCase();
                if (!deviceId) return createResponse("Invalid ID", 400);

                const rawBody = await request.text();
                const parsed  = parseProbePayload(rawBody);
                const now     = Date.now();
                const timeStr = new Date().toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai', hour12: false });
                const cfIp    = request.headers.get("CF-Connecting-IP") || "unknown";

                // 实时设备行：每次上报（含 keepalive）都刷新，保证在线状态与当前活动新鲜
                await env.DB.prepare(
                    `INSERT INTO devices (id, status, last_seen, updated_at, last_ip, lan, wifi, battery)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                     ON CONFLICT(id) DO UPDATE SET
                     status=excluded.status, last_seen=excluded.last_seen,
                     updated_at=excluded.updated_at, last_ip=excluded.last_ip,
                     lan=excluded.lan, wifi=excluded.wifi, battery=excluded.battery`
                ).bind(deviceId, parsed.window, now, timeStr, cfIp,
                    parsed.lan, parsed.wifi, parsed.battery).run();

                // keepalive = 仅刷新在线状态，不写历史（不增长存储）
                if (!parsed.keepalive) {
                    // 会话历史：recorded_at = 会话结束时刻；带起始时间与时长
                    const recordedAt = parsed.end || now;
                    await env.DB.prepare(
                        `INSERT INTO activity_history
                           (device_id, window_title, lan, wifi, battery, recorded_at, started_at, duration_ms)
                         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
                    ).bind(deviceId, parsed.window, parsed.lan, parsed.wifi, parsed.battery,
                           recordedAt, parsed.start || null, parsed.dur || null).run();
                }

                return createResponse("OK", 200, "text/plain");
            } catch (err) {
                return createResponse("Error: " + err.message, 500);
            }
        }

        // [API] 需求2：查询活动历史
        if (request.method === "GET" && url.pathname === "/api/history") {
            try {
                const deviceId  = url.searchParams.get("device");   // 可为 all
                const startTime = parseInt(url.searchParams.get("start") || "0");
                const endTime   = parseInt(url.searchParams.get("end")   || String(Date.now()));
                // 键集分页(keyset)：按 (recorded_at,id) 倒序，无强制总量上限。
                // 前端循环带 cursorTs/cursorId 翻页直到 done，即可无损取全。
                const pageSize  = Math.min(Math.max(parseInt(url.searchParams.get("pageSize") || "2000"), 1), 5000);
                const cursorTs  = parseInt(url.searchParams.get("cursorTs") || "0");
                const cursorId  = parseInt(url.searchParams.get("cursorId") || "0");

                const where = [];
                const binds = [];
                if (deviceId && deviceId !== "all") { where.push("device_id = ?"); binds.push(deviceId); }
                where.push("recorded_at BETWEEN ? AND ?"); binds.push(startTime, endTime);
                if (cursorTs > 0) { where.push("(recorded_at < ? OR (recorded_at = ? AND id < ?))"); binds.push(cursorTs, cursorTs, cursorId); }

                const sql = `SELECT * FROM activity_history WHERE ${where.join(" AND ")}
                             ORDER BY recorded_at DESC, id DESC LIMIT ?`;
                binds.push(pageSize + 1);
                const rows = (await env.DB.prepare(sql).bind(...binds).all()).results || [];

                let done = true, nextTs = null, nextId = null;
                if (rows.length > pageSize) {
                    done = false;
                    rows.length = pageSize;
                    const last = rows[rows.length - 1];
                    nextTs = last.recorded_at; nextId = last.id;
                }
                return createResponse(JSON.stringify({ history: rows, done, nextTs, nextId }));
            } catch (err) {
                return createResponse(JSON.stringify({ error: err.message }), 500);
            }
        }

        // [API] 发送聊天消息
        if (request.method === "POST" && url.pathname === "/api/chat") {
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

        // [API] 用户心跳（需求4：保存 IP，返回含 IP 的在线列表）
        if (request.method === "POST" && url.pathname === "/api/heartbeat") {
            try {
                const { sessionId, userName } = await request.json();
                const now   = Date.now();
                const cfIp  = request.headers.get("CF-Connecting-IP") || "unknown";

                await env.DB.prepare(
                    `INSERT INTO online_users (session_id, user_name, last_seen, ip)
                     VALUES (?, ?, ?, ?)
                     ON CONFLICT(session_id) DO UPDATE SET
                     last_seen=excluded.last_seen, user_name=excluded.user_name, ip=excluded.ip`
                ).bind(sessionId, userName || "匿名", now, cfIp).run();

                // 返回含 IP 的在线用户列表（需求4）
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

        // [API] AI 总结：provider = cf(默认) / openai / google；统一计次
        if (request.method === "POST" && url.pathname === "/api/ai-summary") {
            try {
                const body     = await request.json();
                const provider = (body.provider || 'cf').toLowerCase();
                const prompt   = body.prompt || '';
                const sys      = '你是客观、细致的个人活动分析助手，用中文回答。';

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
                        summary = (fb.response || '') + '\n\n（注：CF 模型「' + model + '」不可用，已回退 llama-3.1-8b-instruct）';
                    }
                } else {
                    summary = await callExternalLLM(provider, body.baseUrl, body.apiKey, body.model, sys, prompt);
                }

                const used = await bumpUsage(env, provider);
                return createResponse(JSON.stringify({ summary, provider, usedToday: used }));
            } catch (err) {
                return createResponse(JSON.stringify({ summary: '（AI 分析失败: ' + err.message + '）', error: err.message }), 500);
            }
        }

        // [API] AI 合并数据：服务端无损合并区间内所有会话 + 汇总（给 AI 用，完整不截断）
        if (request.method === "GET" && url.pathname === "/api/ai-data") {
            try {
                const devParam  = (url.searchParams.get("devices") || "all").toLowerCase();
                const startTime = parseInt(url.searchParams.get("start") || "0");
                const endTime   = parseInt(url.searchParams.get("end")   || String(Date.now()));
                const SAFETY    = 100000;   // 安全上限(远超正常用量)；命中则 complete=false 触发前端 map-reduce

                let sql, binds;
                if (devParam && devParam !== "all") {
                    const devs = devParam.split(",").map(s => s.trim()).filter(Boolean);
                    const ph = devs.map(() => "?").join(",");
                    sql = `SELECT device_id, window_title, recorded_at, started_at, duration_ms
                           FROM activity_history
                           WHERE device_id IN (${ph}) AND recorded_at BETWEEN ? AND ?
                           ORDER BY recorded_at ASC LIMIT ?`;
                    binds = [...devs, startTime, endTime, SAFETY + 1];
                } else {
                    sql = `SELECT device_id, window_title, recorded_at, started_at, duration_ms
                           FROM activity_history
                           WHERE recorded_at BETWEEN ? AND ?
                           ORDER BY recorded_at ASC LIMIT ?`;
                    binds = [startTime, endTime, SAFETY + 1];
                }
                const rows = (await env.DB.prepare(sql).bind(...binds).all()).results || [];
                const complete = rows.length <= SAFETY;
                if (!complete) rows.length = SAFETY;

                return createResponse(JSON.stringify(mergeSessions(rows, complete)));
            } catch (err) {
                return createResponse(JSON.stringify({ error: err.message }), 500);
            }
        }

        // [API] 今日 AI 使用次数（按 provider）
        if (request.method === "GET" && url.pathname === "/api/ai-usage") {
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

        // [API] 拉取 OpenAI / Google 协议的可用模型列表（经 worker 代理，避开 CORS）
        if (request.method === "POST" && url.pathname === "/api/models") {
            try {
                const { provider, baseUrl, apiKey } = await request.json();
                const models = await listExternalModels((provider || '').toLowerCase(), baseUrl, apiKey);
                return createResponse(JSON.stringify({ models }));
            } catch (err) {
                return createResponse(JSON.stringify({ models: [], error: err.message }), 500);
            }
        }

        // [API] 删除设备
        if (request.method === "DELETE" && url.pathname.startsWith("/api/device/")) {
            const deviceId = url.pathname.split("/").pop().toLowerCase();
            await env.DB.prepare("DELETE FROM devices WHERE id = ?").bind(deviceId).run();
            return createResponse(JSON.stringify({ success: true, message: "Deleted " + deviceId }));
        }

        // [API] 清空所有
        if (request.method === "DELETE" && url.pathname === "/api/devices") {
            await env.DB.prepare("DELETE FROM devices").run();
            return createResponse(JSON.stringify({ success: true, message: "All cleared" }));
        }

        // [页面] 渲染首页
        if (request.method === "GET" && url.pathname === "/") {
            return new Response(htmlTemplate, {
                headers: { "Content-Type": "text/html;charset=UTF-8" },
            });
        }

        return new Response("Not Found", { status: 404 });
    },

    // Cron Trigger：每天定时确定性清理（见 wrangler.toml 的 crons）
    async scheduled(event, env, ctx) {
        await runCleanup(env);
    },
};

// ==========================================
// 前端 HTML 模板
// ==========================================
const htmlTemplate = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>FLandre.Sys</title>
    <link rel="icon" href="https://cdnjs.cloudflare.com/ajax/libs/twemoji/14.0.2/svg/1f50d.svg" type="image/svg+xml">
    <script src="https://cdn.jsdelivr.net/npm/vue@3.4.27/dist/vue.global.js"></script>
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        #toMain {
            -webkit-text-size-adjust: 100%;
            tab-size: 4;
            font-feature-settings: normal;
            font-variation-settings: normal;
            -webkit-tap-highlight-color: transparent;
            --neon-blue: #0ea5e9;
            --neon-purple: #8b5cf6;
            --neon-pink: #ec4899;
            --neon-cyan: #22d3ee;
            --grid-color: rgba(139, 92, 246, 0.03);
            font-family: 'SF Mono', 'Courier New', monospace;
            line-height: inherit;
            color: inherit;
            box-sizing: border-box;
            border-width: 0;
            border-style: solid;
            border-color: #e5e7eb;
            display: flex;
            align-items: center;
            gap: 0.75rem;
        }
        :root { 
            --neon-blue: #0ea5e9; 
            --neon-purple: #8b5cf6; 
            --grid-color: rgba(139, 92, 246, 0.03); 
        }
        body { 
            background: #0a0a0f; 
            color: #e2e8f0; 
            font-family: 'SF Mono', 'Courier New', monospace; 
            overflow-x: hidden; 
        }
        .scan-line { 
            position: fixed; top: 0; left: 0; width: 100%; height: 4px; 
            background: linear-gradient(90deg, transparent, var(--neon-blue), transparent); 
            z-index: 9999; animation: scan 3s linear infinite; 
            box-shadow: 0 0 15px var(--neon-blue); 
        }
        @keyframes scan { 0% { transform: translateY(0); } 100% { transform: translateY(100vh); } }
        .circuit-bg { position: fixed; top: 0; left: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.15; pointer-events: none; }
        .circuit-path { fill: none; stroke: url(#neonGradient); stroke-width: 1; stroke-dasharray: 5, 5; stroke-opacity: 0.4; }
        .terminal-card { 
            background: rgba(15, 15, 25, 0.75); backdrop-filter: blur(15px); 
            border: 1px solid rgba(139, 92, 246, 0.15); position: relative; 
            transition: all 0.4s cubic-bezier(0.4, 0, 0.2, 1); overflow: hidden; 
        }
        .terminal-card:hover { 
            border-color: rgba(139, 92, 246, 0.6); 
            box-shadow: 0 0 40px rgba(139, 92, 246, 0.25); 
            transform: translateY(-3px); 
        }
        .status-dot { box-shadow: 0 0 15px currentColor; filter: brightness(1.3); }
        .connection-line { 
            content: ''; position: absolute; top: 50%; left: -10%; width: 120%; height: 1px; 
            background: linear-gradient(90deg, transparent, var(--neon-purple), transparent); 
            opacity: 0; transition: opacity 0.5s; 
        }
        .terminal-card:hover .connection-line { opacity: 0.3; }
        .text-glow { text-shadow: 0 0 15px currentColor; }
        @keyframes pulse-subtle { 0%, 100% { opacity: 0.7; } 50% { opacity: 1; } }
        .pulse-subtle { animation: pulse-subtle 2s ease-in-out infinite; }
        .fade-in { animation: fadeIn 0.8s ease-out; }
        @keyframes fadeIn { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: translateY(0); } }
        .log-terminal-container { margin-top: 2rem; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 1rem; }
        .log-terminal { 
            background: #050508; border: 1px solid #334155; border-radius: 6px; 
            padding: 12px; height: 200px; overflow-y: auto; font-size: 12px; 
            line-height: 1.6; box-shadow: inset 0 0 20px rgba(0,0,0,0.8); 
        }
        .log-line { display: flex; gap: 8px; margin-bottom: 4px; border-left: 2px solid transparent; padding-left: 6px; }
        .log-line:hover { background: rgba(255,255,255,0.03); }
        .log-time { color: #64748b; min-width: 140px; }
        .log-tag { font-weight: bold; min-width: 60px; }
        .log-sys  { color: #94a3b8; border-left-color: #475569; }
        .log-auth { color: #c084fc; border-left-color: #a855f7; }
        .log-net  { color: #38bdf8; border-left-color: #0ea5e9; }
        .log-warn { color: #f43f5e; border-left-color: #e11d48; }
        .log-chat { color: #10b981; border-left-color: #10b981; }
        .log-chat-self { color: #38bdf8; border-left-color: #0ea5e9; }
        /* 在线用户列表 */
        .online-panel {
            background: rgba(10,10,20,0.8); border: 1px solid rgba(14,165,233,0.2);
            border-radius: 8px; padding: 10px; font-size: 11px;
        }
        .online-row { display: flex; justify-content: space-between; align-items: center; padding: 3px 0; border-bottom: 1px solid rgba(255,255,255,0.04); }
        .online-row:last-child { border-bottom: none; }
        /* 历史面板 */
        .history-panel {
            background: rgba(10,10,20,0.9); border: 1px solid rgba(139,92,246,0.25);
            border-radius: 10px; padding: 16px; margin-top: 2rem;
        }
        .history-table { width: 100%; border-collapse: collapse; font-size: 11px; }
        .history-table th { color: #64748b; font-weight: 600; padding: 6px 8px; text-align: left; border-bottom: 1px solid rgba(255,255,255,0.07); }
        .history-table td { padding: 5px 8px; color: #94a3b8; border-bottom: 1px solid rgba(255,255,255,0.03); }
        .history-table tr:hover td { background: rgba(255,255,255,0.02); }
        /* AI 总结面板 */
        .ai-summary-box {
            background: rgba(139,92,246,0.05); border: 1px solid rgba(139,92,246,0.3);
            border-radius: 8px; padding: 14px; margin-top: 12px;
            color: #c4b5fd; font-size: 13px; line-height: 1.7; white-space: pre-wrap;
            max-height: 300px; overflow-y: auto;
        }
        /* 设备扩展信息 */
        .device-meta { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 8px; }
        .device-meta-tag { 
            font-size: 10px; padding: 2px 7px; border-radius: 4px; 
            background: rgba(255,255,255,0.05); color: #64748b; font-mono: true;
        }
        ::-webkit-scrollbar { width: 6px; height: 6px; }
        ::-webkit-scrollbar-track { background: #0f172a; }
        ::-webkit-scrollbar-thumb { background: #334155; border-radius: 3px; }
        ::-webkit-scrollbar-thumb:hover { background: #475569; }
        .glitch {
            position: relative;
        }
        .glitch::before, .glitch::after {
            content: attr(data-text);
            position: absolute; top: 0; left: 0; width: 100%; height: 100%;
        }
        .glitch::before { color: #0ea5e9; animation: glitch1 3s infinite; clip-path: polygon(0 0, 100% 0, 100% 35%, 0 35%); }
        .glitch::after  { color: #8b5cf6; animation: glitch2 3s infinite; clip-path: polygon(0 65%, 100% 65%, 100% 100%, 0 100%); }
        @keyframes glitch1 { 0%,90%,100%{transform:translate(0)} 92%{transform:translate(-2px,-1px)} 95%{transform:translate(2px,1px)} }
        @keyframes glitch2 { 0%,90%,100%{transform:translate(0)} 93%{transform:translate(2px,1px)} 96%{transform:translate(-2px,-1px)} }
    </style>
</head>
<body>
    <div class="scan-line"></div>

    <svg class="circuit-bg" width="100%" height="100%">
        <defs>
            <linearGradient id="neonGradient" x1="0%" y1="0%" x2="100%" y2="100%">
                <stop offset="0%" style="stop-color: var(--neon-blue); stop-opacity:0.5" />
                <stop offset="100%" style="stop-color: var(--neon-purple); stop-opacity:0.5" />
            </linearGradient>
            <pattern id="circuitGrid" width="80" height="80" patternUnits="userSpaceOnUse">
                <path d="M 80 0 L 0 0 0 80" fill="none" stroke="var(--grid-color)" stroke-width="1.5"/>
            </pattern>
        </defs>
        <rect width="100%" height="100%" fill="url(#circuitGrid)" />
        <path class="circuit-path" d="M -100 200 Q 300 100 500 400 T 900 100" />
        <path class="circuit-path" d="M 1200 50 Q 800 300 400 100 T -100 500" />
    </svg>

    <div id="app" class="min-h-screen p-4 md:p-8 fade-in">
        <div class="max-w-6xl mx-auto">

            <!-- ── Header ── -->
            <header class="mb-12 p-6 terminal-card rounded-2xl">
                <div class="flex flex-col md:flex-row justify-between items-start md:items-center gap-6">
                    <div>
                        <div class="flex items-center gap-3 mb-3">
                            <div class="w-3 h-3 bg-green-500 rounded-full status-dot pulse-subtle"></div>
                            <span class="text-green-400 text-sm font-mono tracking-widest">系统运行中</span>
                            <span class="text-slate-600 text-xs">|</span>
                            <span class="text-slate-400 text-sm font-mono">控制台 φ  <a id='toMain2' href='https://yiyongtaott.github.io/.yyt/'>点击返回首页</a></span>
                        </div>
                        <h1 class="glitch text-4xl md:text-6xl font-black tracking-tighter text-white" data-text="FLΛNDRE_TIAMAT">FLΛNDRE_TIAMAT</h1>
                        <p class="text-slate-500 text-sm font-mono mt-3">三端视奸系统</p>
                    </div>
                    <div class="font-mono text-right">
                        <div class="text-xs text-slate-500 uppercase tracking-widest mb-1">最后同步时间</div>
                        <div class="text-2xl text-cyan-400 font-bold text-glow">{{ lastSyncTime || '同步中...' }}</div>
                        <div class="text-[10px] text-slate-600 mt-2">Host: FLΛNDRE_TIAMAT</div>
                    </div>
                </div>
                <div class="flex items-center gap-3" id='toMain'>
                    <div style="cursor: pointer;" @click="handleLinkClick"
                         class="px-4 py-2 bg-gradient-to-r from-cyan-600/30 to-purple-600/30 border border-cyan-500/50 rounded-lg font-mono text-cyan-300 transition-all duration-300">
                        <span class="flex items-center gap-2">点击返回首页
                            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 8l4 4m0 0l-4 4m4-4H3"></path>
                            </svg>
                        </span>
                    </div>
                    <div class="hidden sm:block text-xs text-slate-500 font-mono animate-pulse">[CTRL + CLICK 新标签页打开]</div>
                </div>
            </header>

            <!-- ── 设备卡片 ── -->
            <div class="grid grid-cols-1 md:grid-cols-3 gap-8 mb-16">
                <div v-for="(node, index) in displayNodes" :key="node.id" class="terminal-card rounded-2xl p-8 group">
                    <div class="connection-line"></div>

                    <div class="flex justify-between items-start mb-8">
                        <div class="flex items-center gap-4">
                            <div :class="['p-3 rounded-xl transition-all duration-500', 
                                node.type === 'desktop'  ? 'bg-blue-500/10 border border-blue-500/20' :
                                node.type === 'notebook' ? 'bg-purple-500/10 border border-purple-500/20' :
                                node.type === 'phone'    ? 'bg-cyan-500/10 border border-cyan-500/20' :
                                'bg-green-500/10 border border-green-500/20']">
                                <svg v-if="node.type === 'desktop'" class="w-8 h-8 text-blue-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z" />
                                </svg>
                                <svg v-else-if="node.type === 'notebook'" class="w-8 h-8 text-purple-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M9 17.25v1.007a3 3 0 01-.879 2.122L7.5 21h9l-.621-.621A3 3 0 0115 18.257V17.25m6-12V15a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 15V5.25m18 0A2.25 2.25 0 0018.75 3H5.25A2.25 2.25 0 003 5.25m18 0V12a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 12V5.25" />
                                </svg>
                                <svg v-else-if="node.type === 'phone'" class="w-8 h-8 text-cyan-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M10.5 1.5H8.25A2.25 2.25 0 006 3.75v16.5a2.25 2.25 0 002.25 2.25h7.5A2.25 2.25 0 0018 20.25V3.75a2.25 2.25 0 00-2.25-2.25H13.5m-3 0V3h3V1.5m-3 0h3m-3 18.75h3" />
                                </svg>
                                <svg v-else class="w-8 h-8 text-green-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01" />
                                </svg>
                            </div>
                            <div>
                                <div class="text-[10px] font-mono text-slate-500 uppercase tracking-[0.2em]">设备标识</div>
                                <h3 class="text-xl font-bold text-white tracking-tight">{{ getDeviceName(node.id) }}</h3>
                            </div>
                        </div>
                        <div class="flex flex-col items-end gap-2">
                            <div :class="['px-3 py-1 rounded-full text-xs font-bold font-mono border',
                                node.isOnline ? 'bg-green-900/30 text-green-400 border-green-500/30' : 
                                'bg-slate-900/50 text-slate-600 border-slate-700/50']">
                                {{ node.isOnline ? '同步中' : '持久化记录' }}
                            </div>
                            <div :class="['w-2 h-2 rounded-full status-dot', 
                                node.isOnline ? 'bg-green-500 animate-pulse' : 'bg-slate-700']"></div>
                        </div>
                    </div>

                    <div class="space-y-4">
                        <div>
                            <div class="text-[10px] font-mono text-slate-500 uppercase tracking-widest mb-2">当前活动前台</div>
                            <div :class="['text-lg font-medium font-mono p-3 rounded-lg break-words whitespace-pre-wrap overflow-y-auto max-h-32', 
                                node.isOnline ? 'bg-white/5 text-slate-200' : 'bg-slate-900/30 text-slate-600']">
                                {{ node.status || '无数据流' }}
                            </div>
                        </div>

                        <!-- 需求3：扩展设备信息标签 -->
                        <div v-if="node.extra && node.isOnline" class="device-meta">
                            <span v-if="node.extra.wifi !== 'unknown'" class="device-meta-tag">
                                📶 {{ node.extra.wifi }}
                            </span>
                            <span v-if="node.extra.lan !== 'unknown'" class="device-meta-tag">
                                🔌 {{ node.extra.lan }}
                            </span>
                            <span v-if="node.extra.battery !== 'unknown' && node.extra.battery !== '未检测到电池'" class="device-meta-tag">
                                🔋 {{ node.extra.battery }}
                            </span>
                            <span v-if="node.extra.last_ip !== 'unknown'" class="device-meta-tag">
                                🌐 {{ node.extra.last_ip }}
                            </span>
                        </div>

                        <div class="pt-4 border-t border-white/5">
                            <div class="text-[10px] font-mono text-slate-500 uppercase tracking-widest mb-2">最后响应时间</div>
                            <div class="flex justify-between items-center">
                                <span class="text-sm text-slate-400 font-mono">{{ node.lastUpdate || '从未响应' }}</span>
                                <span :class="['text-xs font-mono', node.isOnline ? 'text-cyan-400' : 'text-slate-700']">
                                    {{ node.isOnline ? '加密连接' : '连接中断' }}
                                </span>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <!-- ── 在线用户列表（需求4）── -->
            <div class="terminal-card rounded-2xl p-6 mb-8">
                <div class="flex items-center justify-between mb-4">
                    <div class="flex items-center gap-2">
                        <div class="online-dot w-2 h-2 rounded-full bg-green-500 animate-pulse"></div>
                        <span class="text-xs font-bold text-slate-400 uppercase tracking-widest">在线访客 ({{ onlineCount }})</span>
                    </div>
                    <span class="text-[10px] text-slate-600 font-mono">5分钟内活跃</span>
                </div>
                <div class="online-panel">
                    <div v-if="onlineUserList.length === 0" class="text-slate-600 text-xs text-center py-2">暂无在线用户</div>
                    <div v-for="u in onlineUserList" :key="u.sessionId" class="online-row">
                        <div class="flex items-center gap-2">
                            <div class="w-1.5 h-1.5 rounded-full bg-green-400"></div>
                            <span class="text-cyan-300 font-mono">{{ u.userName }}</span>
                            <span v-if="u.sessionId === sessionId" class="text-[9px] text-slate-600">(你)</span>
                        </div>
                        <span class="text-slate-600 font-mono text-[10px]">{{ u.ip }}</span>
                    </div>
                </div>
            </div>

            <!-- ── 日志终端 ── -->
            <div class="log-terminal-container">
                <div class="flex items-center justify-between mb-2 px-1">
                    <div class="flex items-center gap-2">
                        <span class="text-xs font-bold text-slate-500 uppercase tracking-widest">[F&L. Sys] RESPONSE OUTPUT</span>
                    </div>
                    <div class="flex items-center gap-3">
                        <button v-if="hasNewMessages" 
                                @click="scrollToBottom"
                                class="px-3 py-1 text-xs bg-purple-900/30 text-purple-300 border border-purple-700/30 rounded hover:bg-purple-800/40 transition flex items-center gap-1">
                            <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 14l-7 7m0 0l-7-7m7 7V3"></path>
                            </svg>
                            新消息({{ newMessageCount }})
                        </button>
                        <input type="text" 
                               class="px-2 py-1 text-xs bg-black/30 border border-slate-700 rounded font-mono w-24" 
                               placeholder="昵称" 
                               v-model="userName" 
                               @change="saveUserName">
                        <button @click="sendTestMessage" class="px-3 py-1 text-xs bg-cyan-900/30 text-cyan-400 border border-cyan-700/30 rounded hover:bg-cyan-800/40 transition">
                            测试
                        </button>
                    </div>
                </div>
                
                <div class="log-terminal" ref="logContainer" @scroll="handleScroll" style="height: 220px;">
                    <div v-for="(log, idx) in initLogs" :key="'init-log-' + idx" :class="['log-line', log.class]">
                        <span class="log-time font-mono text-[10px]">{{ formatInitLogTime(log.time) }}</span>
                        <span class="log-tag font-mono text-[10px]">[{{ log.tag }}]</span>
                        <span class="log-msg flex-grow truncate">{{ log.msg }}</span>
                    </div>
                    <div v-if="combinedMessages.length > 0" class="log-line log-sys">
                        <span class="log-time font-mono text-[10px]">{{ getCurrentFormattedTime() }}</span>
                        <span class="log-tag font-mono text-[10px]">[SYS]</span>
                        <span class="log-msg flex-grow truncate">=== 实时消息流 ===</span>
                    </div>
                    <div v-for="item in combinedMessages" :key="item.id" :class="['log-line', getMessageClass(item)]">
                        <span class="log-time font-mono text-[10px]">{{ formatChatTime(item.timestamp) }}</span>
                        <span class="log-tag font-mono text-[10px]">
                            <span v-if="item.type === 'device'">[{{ item.tag }}]</span>
                            <span v-else>[{{ item.user.substring(0, 30) }}]</span>
                        </span>
                        <span class="log-msg flex-grow truncate">
                            <span v-if="item.type === 'device'">{{ item.msg }}</span>
                            <span v-else>{{ item.message }}</span>
                        </span>
                    </div>
                    <div class="animate-pulse text-purple-500 font-bold mt-1">_</div>
                </div>

                <div class="mt-3 flex gap-2">
                    <input type="text" 
                           class="flex-grow px-3 py-2 text-sm bg-black/40 border border-slate-700 rounded font-mono text-slate-300 focus:outline-none focus:border-cyan-500/50 focus:ring-1 focus:ring-cyan-500/30"
                           v-model="chatInput" 
                           placeholder="输入消息 (按Enter发送)" 
                           @keyup="handleKeyUp"
                           :disabled="!isOnline">
                    <button class="px-4 py-2 text-sm bg-gradient-to-r from-cyan-900/40 to-purple-900/40 text-cyan-300 border border-cyan-700/30 rounded font-mono hover:from-cyan-800/50 hover:to-purple-800/50 transition"
                            @click="sendChatMessage"
                            :disabled="!isOnline || !chatInput.trim()">
                        发送
                    </button>
                </div>
            </div>

            <!-- ── 需求2：活动历史记录面板 ── -->
            <div class="history-panel mt-8">
                <div class="flex items-center justify-between mb-4">
                    <span class="text-sm font-bold text-purple-300 uppercase tracking-widest">[ 活动历史 ]</span>
                    <button @click="historyPanelOpen = !historyPanelOpen"
                            class="text-xs text-slate-500 hover:text-slate-300 transition px-3 py-1 border border-slate-700 rounded font-mono">
                        {{ historyPanelOpen ? '收起 ▲' : '展开 ▼' }}
                    </button>
                </div>

                <div v-if="historyPanelOpen">
                    <!-- 筛选控件 -->
                    <div class="flex flex-wrap gap-3 mb-4 items-end">
                        <div>
                            <div class="text-[10px] text-slate-500 mb-1 uppercase tracking-widest">设备</div>
                            <div class="flex gap-2">
                                <label v-for="d in ['desktop','notebook','phone']" :key="d"
                                       class="flex items-center gap-1 text-xs font-mono cursor-pointer">
                                    <input type="checkbox" :value="d" v-model="historyDevices"
                                           class="accent-purple-500">
                                    <span :class="{
                                        'text-blue-400': d==='desktop',
                                        'text-purple-400': d==='notebook',
                                        'text-cyan-400': d==='phone'
                                    }">{{ getDeviceName(d) }}</span>
                                </label>
                            </div>
                        </div>
                        <div>
                            <div class="text-[10px] text-slate-500 mb-1 uppercase tracking-widest">时间范围</div>
                            <select v-model="historyRange"
                                    class="bg-black/40 border border-slate-700 text-slate-300 rounded px-2 py-1 text-xs font-mono">
                                <option value="3600000">最近 1 小时</option>
                                <option value="21600000">最近 6 小时</option>
                                <option value="86400000">最近 24 小时</option>
                                <option value="604800000">最近 7 天</option>
                                <option value="2592000000">最近 30 天</option>
                            </select>
                        </div>
                        <button @click="loadHistory"
                                class="px-4 py-1 text-xs bg-purple-900/40 text-purple-300 border border-purple-700/30 rounded font-mono hover:bg-purple-800/50 transition">
                            查询
                        </button>
                        <button @click="openAiSummary"
                                :disabled="aiLoading || historyDevices.length === 0"
                                class="px-4 py-1 text-xs bg-gradient-to-r from-purple-900/40 to-pink-900/40 text-pink-300 border border-pink-700/30 rounded font-mono hover:from-purple-800/50 transition disabled:opacity-40">
                            {{ aiLoading ? 'AI 分析中...' : '✨ AI 总结' }}
                        </button>
                        <span v-if="mergedInfo" class="text-[10px] text-slate-500 font-mono self-center">{{ mergedInfo }}</span>
                        <span class="text-[10px] text-cyan-600 font-mono self-center">今日AI已用: {{ aiUsageToday[aiProvider] || 0 }} 次<span v-if="aiProvider==='cf'"> · CF免费~1万neurons/天</span></span>
                    </div>

                    <!-- AI 模型配置（E5/E6）-->
                    <div class="flex flex-wrap gap-3 mb-4 items-end p-3 rounded-lg" style="background: rgba(139,92,246,0.04); border:1px solid rgba(139,92,246,0.15);">
                        <div>
                            <div class="text-[10px] text-slate-500 mb-1 uppercase tracking-widest">AI 提供方</div>
                            <select v-model="aiProvider" @change="onProviderChange"
                                    class="bg-black/40 border border-slate-700 text-slate-300 rounded px-2 py-1 text-xs font-mono">
                                <option value="cf">CF 自带 (免费)</option>
                                <option value="openai">OpenAI 协议</option>
                                <option value="google">Google 协议</option>
                            </select>
                        </div>
                        <div v-if="aiProvider === 'cf'">
                            <div class="text-[10px] text-slate-500 mb-1 uppercase tracking-widest">CF 模型</div>
                            <select v-model="aiModel" @change="saveAiConfig"
                                    class="bg-black/40 border border-slate-700 text-slate-300 rounded px-2 py-1 text-xs font-mono">
                                <option value="@cf/qwen/qwen2.5-coder-32b-instruct">qwen2.5-coder-32b (默认)</option>
                                <option value="@cf/meta/llama-3.1-8b-instruct">llama-3.1-8b-instruct (稳)</option>
                                <option value="@cf/qwen/qwq-32b">qwq-32b (推理)</option>
                            </select>
                            <div class="text-[10px] text-slate-600 mt-1" style="max-width:320px;">免费约 1万 neurons/天，够每天几十~上百次中等总结；单次建议 &lt; ~2万 token（约6万字符），超出会自动逐日总结。模型不存在会自动回退 llama-3.1-8b。</div>
                        </div>
                        <template v-if="aiProvider !== 'cf'">
                            <div>
                                <div class="text-[10px] text-slate-500 mb-1 uppercase tracking-widest">Base URL</div>
                                <input v-model="aiBaseUrl" @change="saveAiConfig" :placeholder="aiProvider==='openai' ? 'https://api.openai.com/v1' : 'https://generativelanguage.googleapis.com/v1beta'"
                                       class="bg-black/40 border border-slate-700 text-slate-300 rounded px-2 py-1 text-xs font-mono" style="width:260px;">
                            </div>
                            <div>
                                <div class="text-[10px] text-slate-500 mb-1 uppercase tracking-widest">API Key</div>
                                <input v-model="aiApiKey" @change="saveAiConfig" type="password" placeholder="sk-..."
                                       class="bg-black/40 border border-slate-700 text-slate-300 rounded px-2 py-1 text-xs font-mono" style="width:200px;">
                            </div>
                            <div>
                                <div class="text-[10px] text-slate-500 mb-1 uppercase tracking-widest">模型</div>
                                <div class="flex gap-1">
                                    <input v-model="aiModel" @change="saveAiConfig" list="ai-model-list" placeholder="模型名"
                                           class="bg-black/40 border border-slate-700 text-slate-300 rounded px-2 py-1 text-xs font-mono" style="width:200px;">
                                    <datalist id="ai-model-list">
                                        <option v-for="m in aiModelList" :key="m" :value="m"></option>
                                    </datalist>
                                    <button @click="fetchModels" :disabled="aiModelsLoading"
                                            class="px-2 py-1 text-xs bg-slate-800 text-slate-300 border border-slate-600 rounded font-mono hover:bg-slate-700 disabled:opacity-40">
                                        {{ aiModelsLoading ? '...' : '获取模型' }}
                                    </button>
                                </div>
                            </div>
                        </template>
                    </div>

                    <!-- AI 总结结果 -->
                    <div v-if="aiSummary" class="ai-summary-box mb-4">
                        <div class="text-[10px] text-purple-500 mb-2 uppercase tracking-widest">[ AI Analysis Result ]</div>
                        {{ aiSummary }}
                    </div>

                    <!-- 历史表格 -->
                    <div v-if="historyLoading" class="text-slate-600 text-xs text-center py-4">加载中...</div>
                    <div v-else-if="historyRows.length === 0" class="text-slate-700 text-xs text-center py-4">暂无历史记录，点击「查询」加载</div>
                    <div v-else class="overflow-x-auto max-h-72 overflow-y-auto">
                        <table class="history-table">
                            <thead>
                                <tr>
                                    <th>时间</th>
                                    <th>设备</th>
                                    <th>活动窗口</th>
                                    <th>WiFi</th>
                                    <th>局域网 IP</th>
                                    <th>电量</th>
                                </tr>
                            </thead>
                            <tbody>
                                <tr v-for="row in historyRows" :key="row.id">
                                    <td class="text-slate-600 whitespace-nowrap">{{ formatChatTime(row.recorded_at) }}</td>
                                    <td>
                                        <span :class="{
                                            'text-blue-400': row.device_id==='desktop',
                                            'text-purple-400': row.device_id==='notebook',
                                            'text-cyan-400': row.device_id==='phone',
                                            'text-slate-400': !['desktop','notebook','phone'].includes(row.device_id)
                                        }">{{ getDeviceName(row.device_id) }}</span>
                                    </td>
                                    <td class="text-slate-300 max-w-xs truncate" :title="row.window_title">{{ row.window_title }}</td>
                                    <td class="text-slate-500">{{ row.wifi || '-' }}</td>
                                    <td class="text-slate-500">{{ row.lan || '-' }}</td>
                                    <td class="text-slate-500">{{ row.battery || '-' }}</td>
                                </tr>
                            </tbody>
                        </table>
                        <div class="text-[10px] text-slate-700 mt-2 text-right">共 {{ historyRows.length }} 条记录</div>
                    </div>
                </div>
            </div>

            <footer class="py-8 border-t border-white/5 text-center font-mono text-sm text-slate-600">
                <div class="flex flex-col md:flex-row justify-between items-center gap-4 mb-4">
                    <p class="text-xs tracking-widest">神经连接协议 v4.9.5_7</p>
                    <p class="text-xs text-cyan-500/60 pulse-subtle">数据流已加密</p>
                    <p class="text-xs tracking-widest">建立于: 2026-01-10</p>
                </div>
                <p class="text-[10px] text-slate-700">本终端提供跨设备信息流的可视化呈现</p>
            </footer>
        </div>
    </div>

    <script>
    const API_BASE = (
        window.location.hostname.endsWith('cloudflare.dev') || 
        window.location.hostname.endsWith('workers.dev') ||
        window.location.hostname.endsWith('dpdns.org')
    ) ? window.location.origin 
      : 'http://9.3.0.1.9.1.0.0.0.7.4.0.1.0.0.2.ip6.arpa';

    const app = Vue.createApp({
        data() {
            return {
                rawData: { devices: {}, times: {}, lastSeen: {}, extra: {} },
                lastSyncTime: '',
                logs: [],
                lastDeviceTimestamps: {},
                chatMessages: [],
                chatInput: '',
                userName: localStorage.getItem('fl_chat_name') || 'Operator',
                sessionId: localStorage.getItem('fl_session_id') || ('sess_' + Date.now() + '_' + Math.random().toString(36).substr(2,9)),
                onlineCount: 1,
                onlineUsers: {},   // { sessionId: { userName, ip, lastSeen } }
                isOnline: false,
                realtimeMessages: [],
                initLogs: [
                    { time: '22:29:52.023', tag: 'SYS',    msg: 'Initializing F&L. Sys Response...',               class: 'log-sys'  },
                    { time: '22:29:52.324', tag: 'L-SYS',  msg: 'Daemon thread started. ((守护线程已启动))',          class: 'log-auth' },
                    { time: '22:29:52.425', tag: 'SYS',    msg: 'Mounting user volume: /wonderland/FlandreTiamat',  class: 'log-sys'  },
                    { time: '22:29:52.824', tag: 'AUTH',   msg: 'Identity Verified. Welcome, Operator.',            class: 'log-auth' },
                    { time: '22:29:53.224', tag: 'L-PROTO',msg: 'Link established. The observer (L) is active.',    class: 'log-auth' },
                    { time: '22:29:53.525', tag: 'CHAT',   msg: '用户 Operator 加入群聊',                            class: 'log-net'  },
                    { time: '22:29:54.026', tag: 'CHAT',   msg: '群聊功能已激活，输入消息后按Enter发送',               class: 'log-sys'  }
                ],
                hasNewMessages: false,
                newMessageCount: 0,
                userScrolledUp: false,
                DEFAULT_NODES: [
                    { id: 'desktop',  type: 'desktop'  },
                    { id: 'notebook', type: 'notebook' },
                    { id: 'phone',    type: 'phone'    }
                ],
                // 需求2：历史面板状态（默认展开 + 自动查 24h）
                historyPanelOpen: true,
                historyDevices: ['desktop', 'notebook', 'phone'],
                historyRange: '86400000',
                historyRows: [],
                historyLoading: false,
                aiLoading: false,
                aiSummary: '',
                aiComplete: true,
                mergedInfo: '',
                aiUsageToday: {},
                aiProvider: localStorage.getItem('fl_ai_provider') || 'cf',
                aiModel:    localStorage.getItem('fl_ai_model')    || '@cf/qwen/qwen2.5-coder-32b-instruct',
                aiBaseUrl:  localStorage.getItem('fl_ai_baseurl')  || '',
                aiApiKey:   localStorage.getItem('fl_ai_key')      || '',
                aiModelList: [],
                aiModelsLoading: false,
                lastMsgId: 0,
            };
        },

        computed: {
            displayNodes() {
                const now = Date.now();
                const nodes = [];
                const defaultIds = this.DEFAULT_NODES.map(n => n.id);

                this.DEFAULT_NODES.forEach(def => {
                    const deviceId    = def.id;
                    const lastSeenTs  = this.rawData.lastSeen[deviceId] || 0;
                    let   statusText  = this.rawData.devices[deviceId]  || '系统离线';
                    const extra       = this.rawData.extra[deviceId]    || {};

                    if (statusText.includes('http')) {
                        try { const u = new URL(statusText); statusText = 'Browsing: ' + u.hostname; } catch(e) {}
                    }

                    nodes.push({ 
                        ...def, status: statusText, extra,
                        isOnline:   (now - lastSeenTs) < 600000,
                        lastUpdate: this.rawData.times[deviceId] || ''
                    });
                });

                Object.keys(this.rawData.devices).forEach(deviceId => {
                    if (defaultIds.includes(deviceId)) return;
                    const lastSeenTs = this.rawData.lastSeen[deviceId] || 0;
                    if ((now - lastSeenTs) < 259200000) {
                        let statusText = this.rawData.devices[deviceId] || 'Online';
                        if (statusText.includes('http')) {
                            try { const u = new URL(statusText); statusText = 'Browsing: ' + u.hostname; } catch(e) {}
                        }
                        nodes.push({
                            id: deviceId, type: 'unknown',
                            status: statusText,
                            extra:  this.rawData.extra[deviceId] || {},
                            isOnline:   (now - lastSeenTs) < 600000,
                            lastUpdate: this.rawData.times[deviceId] || ''
                        });
                    }
                });

                return nodes;
            },

            // 需求4：在线用户数组（含 IP）
            onlineUserList() {
                return Object.entries(this.onlineUsers).map(([sid, u]) => ({
                    sessionId: sid,
                    userName:  u.userName,
                    ip:        u.ip || 'unknown',
                    lastSeen:  u.lastSeen,
                })).sort((a, b) => b.lastSeen - a.lastSeen);
            },

            combinedMessages() {
                const deviceMsgs = this.realtimeMessages.map(msg => ({
                    ...msg,
                    id:   'dev_' + msg.timestamp + '_' + Math.random().toString(36).substr(2,9),
                    type: 'device'
                }));
                const chatMsgs = this.chatMessages.slice(-50).map(msg => ({
                    ...msg, type: 'chat', timestamp: msg.timestamp
                }));
                return [...deviceMsgs, ...chatMsgs]
                    .sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0))
                    .slice(-100);
            }
        },

        methods: {
            handleLinkClick(event) {
                const url = 'https://yiyongtaott.github.io/.yyt';
                if (event.ctrlKey || event.metaKey) window.open(url, '_blank');
                else window.location.href = url;
            },

            getDeviceName(id) {
                const map = { 'desktop': '台式电脑', 'notebook': '笔记本电脑', 'phone': '手机' };
                return map[id] || (id.length > 10 ? id.substring(0, 8) + '...' : id);
            },

            formatChatTime(timestamp) {
                if (!timestamp) return '';
                const date = new Date(timestamp);
                const y = date.getFullYear();
                const m = String(date.getMonth()+1).padStart(2,'0');
                const d = String(date.getDate()).padStart(2,'0');
                const h = String(date.getHours()).padStart(2,'0');
                const mi= String(date.getMinutes()).padStart(2,'0');
                const s = String(date.getSeconds()).padStart(2,'0');
                return \`\${y}/\${m}/\${d} \${h}:\${mi}:\${s}\`;
            },

            formatInitLogTime(timeStr) {
                const today = new Date();
                const y = today.getFullYear();
                const m = String(today.getMonth()+1).padStart(2,'0');
                const d = String(today.getDate()).padStart(2,'0');
                return \`\${y}/\${m}/\${d} \${timeStr}\`;
            },

            getCurrentFormattedTime() {
                return this.formatChatTime(Date.now());
            },

            isAtBottom() {
                const c = this.\$refs.logContainer;
                if (!c) return true;
                return c.scrollHeight - (c.scrollTop + c.clientHeight) <= 50;
            },

            scrollToBottom() {
                const c = this.\$refs.logContainer;
                if (c) { c.scrollTop = c.scrollHeight; this.hasNewMessages = false; this.newMessageCount = 0; this.userScrolledUp = false; }
            },

            handleScroll() {
                if (!this.isAtBottom()) { this.userScrolledUp = true; }
                else { this.userScrolledUp = false; this.hasNewMessages = false; this.newMessageCount = 0; }
            },

            addLog(tag, msg, type = 'sys') {
                const classMap = { 'sys':'log-sys','auth':'log-auth','net':'log-net','warn':'log-warn','chat':'log-chat' };
                this.logs.push({ time: this.getCurrentFormattedTime(), tag, msg, class: classMap[type] || 'log-sys' });
                if (this.logs.length > 50) this.logs.shift();
            },

            addRealtimeMessage(messageData) {
                this.realtimeMessages.push(messageData);
                if (this.realtimeMessages.length > 100) this.realtimeMessages.shift();
                if (!this.isAtBottom() || this.userScrolledUp) {
                    this.hasNewMessages = true; this.newMessageCount += 1;
                } else {
                    this.\$nextTick(() => { this.scrollToBottom(); });
                }
            },

            async syncAllData() {
                try {
                    const since = this.lastMsgId || 0;
                    const res = await fetch(API_BASE + '/api/sync?since=' + since);
                    if (res.ok) {
                        const megaData = await res.json();

                        // 1. 设备数据（含 extra 字段，需求3）
                        const newData = megaData.deviceData;
                        Object.keys(newData.times || {}).forEach(did => {
                            if (newData.times[did] !== this.lastDeviceTimestamps[did]) {
                                const dName  = this.getDeviceName(did);
                                const dStatus = newData.devices[did] || '';
                                const displayStatus = dStatus.length > 40 ? dStatus.substring(0,40)+'...' : dStatus;
                                this.addRealtimeMessage({
                                    type: 'device', tag: 'NET',
                                    msg: 'Data packet from ['+dName+']: '+displayStatus,
                                    deviceId: did, timestamp: Date.now()
                                });
                            }
                        });
                        this.rawData = newData;
                        this.lastDeviceTimestamps = { ...(newData.times || {}) };

                        // 2. 聊天（增量：since>0 只追加新消息，省读额度）
                        const incoming = megaData.chatHistory || [];
                        if (since === 0) {
                            this.chatMessages = incoming;
                        } else if (incoming.length) {
                            this.chatMessages = [...this.chatMessages, ...incoming];
                            if (this.chatMessages.length > 300) this.chatMessages = this.chatMessages.slice(-300);
                        }
                        if (incoming.length) {
                            this.lastMsgId = Math.max(this.lastMsgId, ...incoming.map(m => m.id || 0));
                            if (since > 0) {
                                if (!this.isAtBottom() || this.userScrolledUp) {
                                    this.hasNewMessages = true; this.newMessageCount += incoming.length;
                                } else {
                                    this.\$nextTick(() => { this.scrollToBottom(); });
                                }
                            }
                        }

                        // 3. 在线用户（需求4）
                        this.onlineCount = megaData.onlineCount;
                        this.onlineUsers = megaData.onlineUsers || {};

                        this.lastSyncTime = new Date().toLocaleTimeString('zh-CN');
                    }
                } catch (e) {
                    this.addLog('ERR', 'Sync lost. Retrying...', 'warn');
                }
            },

            generateSessionId() {
                const id = 'sess_' + Date.now() + '_' + Math.random().toString(36).substr(2,9);
                localStorage.setItem('fl_session_id', id);
                return id;
            },

            saveUserName() {
                localStorage.setItem('fl_chat_name', this.userName);
                this.sendHeartbeat();
                this.addLog('AUTH', \`用户身份更新: \${this.userName}\`, 'auth');
            },

            async sendHeartbeat() {
                try {
                    const res = await fetch(API_BASE + '/api/heartbeat', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ sessionId: this.sessionId, userName: this.userName })
                    });
                    if (res.ok) {
                        const data = await res.json();
                        this.onlineCount = data.onlineCount;
                        // 需求4：心跳也同步在线用户列表
                        if (data.onlineUsers) this.onlineUsers = data.onlineUsers;
                        this.isOnline = true;
                    }
                } catch (err) {
                    console.error('Heartbeat failed:', err);
                    this.isOnline = false;
                }
            },

            async sendChatMessage() {
                if (!this.chatInput.trim() || !this.isOnline) return;
                const message = this.chatInput.trim();
                this.chatInput = '';
                try {
                    const res = await fetch(API_BASE + '/api/chat', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ user: this.userName, message, sessionId: this.sessionId })
                    });
                    if (res.ok) await this.syncAllData();
                } catch (err) {
                    this.addLog('ERR', '消息发送失败', 'warn');
                }
            },

            handleKeyUp(event) {
                if (event.key === 'Enter') this.sendChatMessage();
            },

            sendTestMessage() {
                this.chatInput = '测试消息 ' + new Date().toLocaleTimeString('zh-CN', { hour12: false });
                this.sendChatMessage();
            },

            getMessageClass(msg) {
                if (msg.type === 'device') return 'log-net';
                if (msg.sessionId === this.sessionId) return 'log-chat-self';
                if (msg.user === '系统') return 'log-sys';
                return 'log-chat';
            },

            // ── 需求2：历史记录加载（keyset 翻页拉全，无强制 limit）──────────
            async loadHistory() {
                if (this.historyDevices.length === 0) return;
                this.historyLoading = true;
                this.historyRows = [];
                this.aiSummary = '';
                try {
                    const end   = Date.now();
                    const start = end - parseInt(this.historyRange);
                    const allRows = [];

                    // 每个设备翻页到 done，完整取回（不截断）
                    await Promise.all(this.historyDevices.map(async (dev) => {
                        let cursorTs = 0, cursorId = 0, guard = 0;
                        for (;;) {
                            let u = \`\${API_BASE}/api/history?device=\${dev}&start=\${start}&end=\${end}&pageSize=5000\`;
                            if (cursorTs > 0) u += \`&cursorTs=\${cursorTs}&cursorId=\${cursorId}\`;
                            const res = await fetch(u);
                            if (!res.ok) break;
                            const data = await res.json();
                            allRows.push(...(data.history || []));
                            if (data.done || !data.nextTs || ++guard > 2000) break;
                            cursorTs = data.nextTs; cursorId = data.nextId;
                        }
                    }));

                    allRows.sort((a, b) => b.recorded_at - a.recorded_at);
                    this.historyRows = allRows;
                } catch (e) {
                    console.error('loadHistory error:', e);
                } finally {
                    this.historyLoading = false;
                }
            },

            // ── 需求2：AI 总结（发送完整合并数据，绝不截断）──────────────────
            async openAiSummary() {
                if (this.aiLoading || this.historyDevices.length === 0) return;
                this.aiLoading = true;
                this.aiSummary = '';
                this.mergedInfo = '';
                try {
                    const end   = Date.now();
                    const start = end - parseInt(this.historyRange);
                    const devs  = this.historyDevices.join(',');
                    const data  = await this.fetchAiData(devs, start, end);
                    if (!data || !data.merged) { this.aiSummary = '（获取合并数据失败）'; return; }
                    this.aiComplete = data.complete;

                    const deviceNames = this.historyDevices.map(d => this.getDeviceName(d)).join('、');
                    const rangeLabel  = { '3600000':'1小时','21600000':'6小时','86400000':'24小时','604800000':'7天','2592000000':'30天' }[this.historyRange] || '一段时间';
                    const prompt = this.buildPrompt(rangeLabel, deviceNames, this.buildTimelineText(data.merged), data.rollups);
                    const bytes  = new Blob([prompt]).size;
                    const threshold = this.aiProvider === 'cf' ? 60000 : 300000;
                    this.mergedInfo = '合并 ' + data.merged.length + ' 段 / 原始 ' + data.totalSessions + ' 条 · ' + (bytes/1024).toFixed(1) + ' KB' + (data.complete ? '' : ' · 超安全上限');

                    let summary;
                    if (data.complete && bytes <= threshold) {
                        summary = await this.callAi(prompt);
                    } else {
                        this.mergedInfo += ' · 逐日总结(map-reduce)';
                        summary = await this.mapReduceSummary(devs, start, end, deviceNames);
                    }
                    this.aiSummary = summary || '（未能获取总结）';
                } catch (e) {
                    this.aiSummary = '（AI 接口请求失败: ' + e.message + '）';
                } finally {
                    this.aiLoading = false;
                    this.fetchAiUsage();
                }
            },

            async fetchAiData(devs, start, end) {
                try {
                    const res = await fetch(\`\${API_BASE}/api/ai-data?devices=\${encodeURIComponent(devs)}&start=\${start}&end=\${end}\`);
                    if (!res.ok) return null;
                    return await res.json();
                } catch { return null; }
            },

            fmtDur(ms) {
                ms = ms || 0;
                const s = Math.round(ms / 1000);
                if (s < 60) return s + 's';
                const m = Math.round(s / 60);
                if (m < 60) return m + 'm';
                const h = Math.floor(m / 60);
                return h + 'h' + (m % 60) + 'm';
            },

// ─── 优化后的 Timeline 文本生成器 ───
buildTimelineText(merged) {
    if (!merged || merged.length === 0) return '';

    let promptText = '';
    let lastHeader = ''; // 用于记录上一次的小标题： "YYYY/MM/DD HH点"

    // 1. 确保时间线是按时间正序排列
    const sortedTimeline = [...merged].sort((a, b) => a.start - b.start);

    sortedTimeline.forEach(item => {
        // 使用与后端相同的上海时区偏移（加 8 小时），确保时间绝对准确
        const startDate = new Date(item.start + 8 * 3600000); 
        
        // 提取年/月/日 和 小时
        const year = startDate.getUTCFullYear();
        const month = String(startDate.getUTCMonth() + 1).padStart(2, '0');
        const day = String(startDate.getUTCDate()).padStart(2, '0');
        const hour = String(startDate.getUTCHours()).padStart(2, '0');
        
        // 提取行内所需要的分钟和秒
        const min = String(startDate.getUTCMinutes()).padStart(2, '0');
        const sec = String(startDate.getUTCSeconds()).padStart(2, '0');

        const currentHeader = '\\n■ ' + year + '/' + month + '/' + day + ' ' + hour + '点\\n';

        // 如果跨时或跨天，另起一行小标题
        if (currentHeader !== lastHeader) {
            promptText += currentHeader;
            lastHeader = currentHeader;
        }

        // 3. 提取持续时间（沿用你的 fmtDur 方法）
        const durStr = this.fmtDur(item.durMs || (item.end - item.start));

        // 4. 用单引号加号兼容风格拼装行内容
        promptText += '  ' + min + ':' + sec + ' (' + durStr + ') [' + this.getDeviceName(item.device) + '] ' + item.window + '\\n';
    });

    return promptText;
},

// ─── 优化后的 Prompt 框架拼装 ───
buildPrompt(rangeLabel, deviceNames, timelineText, rollups) {
    const fmtRoll = (obj) => Object.entries(obj || {}).sort((a,b)=>b[1]-a[1]).slice(0,15).map(([k,v]) => k + ': ' + this.fmtDur(v)).join('；');
    const b = (rollups && rollups.buckets) || {};
    const bucketLine = '上午 ' + this.fmtDur(b.morning) + ' / 下午 ' + this.fmtDur(b.afternoon) + ' / 晚上 ' + this.fmtDur(b.evening) + ' / 凌晨 ' + this.fmtDur(b.night);
    
    // 修改了第一句的括号提示，使之与新的数据格式完全匹配，不误导 AI
    return '以下是用户在【' + rangeLabel + '】内，在 ' + deviceNames + ' 上的完整活动时间线（按时间顺序，大标题为小时段，行内仅展示：分:秒 (时长) [设备] 窗口标题）：\\\\n'
        + timelineText
        + '\\\\n\\\\n【按时段汇总(上海时间)】' + bucketLine
        + '\\\\n【按应用/窗口汇总】' + fmtRoll(rollups && rollups.perApp)
        + '\\\\n【按设备汇总】' + fmtRoll(rollups && rollups.perDevice)
        + '\\\\n\\\\n请基于以上完整数据，用中文分点总结（要结合具体时间与窗口，不要笼统）：\\\\n'
        + '1. 这段时间我把时间主要花在了哪里（各类活动大致占比）；\\\\n'
        + '2. 上午、下午、晚上分别在做什么；\\\\n'
        + '3. 一共做了哪几个主要任务（按窗口/项目归纳）；\\\\n'
        + '4. 晚上大约几点睡的（最后一段活动结束、之后长时间无活动即视为入睡）；\\\\n'
        + '5. 白天哪些时段在偷偷摸鱼（工作时段里出现的娱乐/视频/社交类窗口）。';
},

            async callAi(prompt) {
                const body = { prompt, provider: this.aiProvider, model: this.aiModel };
                if (this.aiProvider !== 'cf') { body.baseUrl = this.aiBaseUrl; body.apiKey = this.aiApiKey; }
                const res = await fetch(\`\${API_BASE}/api/ai-summary\`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(body)
                });
                const data = await res.json();
                if (data.usedToday != null) this.aiUsageToday = { ...this.aiUsageToday, [this.aiProvider]: data.usedToday };
                return data.summary || '';
            },

            async mapReduceSummary(devs, start, end, deviceNames) {
                const DAY = 86400000;
                const dayResults = [];
                for (let s = start; s < end; s += DAY) {
                    const e = Math.min(s + DAY, end);
                    const d = await this.fetchAiData(devs, s, e);
                    if (!d || !d.merged || d.merged.length === 0) continue;
                    const dayLabel = this.formatChatTime(s).slice(0, 10);
                    const p = '这是 ' + deviceNames + ' 在 ' + dayLabel + ' 一天的活动时间线（开始-结束 时长 设备 窗口）：\\n\\n'
                        + this.buildTimelineText(d.merged)
                        + '\\n\\n请用2-4句话客观概述这一天：主要任务、上午/下午/晚上侧重、几点睡、白天是否摸鱼。';
                    const sum = await this.callAi(p);
                    dayResults.push('【' + dayLabel + '】' + sum);
                }
                if (dayResults.length === 0) return '（该时间段无活动数据）';
                const finalPrompt = '以下是逐日活动小结：\\n\\n' + dayResults.join('\\n\\n')
                    + '\\n\\n请综合这些天给出整体总结：\\n1) 时间主要花在哪、各类占比；\\n2) 上午/下午/晚上规律；\\n3) 一共做了哪几个主要任务；\\n4) 通常几点睡；\\n5) 白天哪些时段摸鱼。\\n用中文，分点清晰。';
                return await this.callAi(finalPrompt);
            },

            async fetchAiUsage() {
                try {
                    const res = await fetch(\`\${API_BASE}/api/ai-usage\`);
                    if (res.ok) { const d = await res.json(); this.aiUsageToday = d.usage || {}; }
                } catch (e) {}
            },

            async fetchModels() {
                if (this.aiProvider === 'cf') return;
                if (!this.aiApiKey) { alert('请先填写 API Key'); return; }
                this.aiModelsLoading = true;
                try {
                    const res = await fetch(\`\${API_BASE}/api/models\`, {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ provider: this.aiProvider, baseUrl: this.aiBaseUrl, apiKey: this.aiApiKey })
                    });
                    const d = await res.json();
                    if (d.error) alert('获取模型失败: ' + d.error);
                    this.aiModelList = d.models || [];
                    if (this.aiModelList.length && !this.aiModelList.includes(this.aiModel)) this.aiModel = this.aiModelList[0];
                    this.saveAiConfig();
                } catch (e) { alert('获取模型失败: ' + e.message); }
                finally { this.aiModelsLoading = false; }
            },

            saveAiConfig() {
                localStorage.setItem('fl_ai_provider', this.aiProvider);
                localStorage.setItem('fl_ai_model', this.aiModel);
                localStorage.setItem('fl_ai_baseurl', this.aiBaseUrl);
                localStorage.setItem('fl_ai_key', this.aiApiKey);
            },

            onProviderChange() {
                if (this.aiProvider === 'cf' && !this.aiModel.startsWith('@cf/')) this.aiModel = '@cf/qwen/qwen2.5-coder-32b-instruct';
                if (this.aiProvider === 'openai' && this.aiModel.startsWith('@cf/')) this.aiModel = 'gpt-4o-mini';
                if (this.aiProvider === 'google' && this.aiModel.startsWith('@cf/')) this.aiModel = 'gemini-1.5-flash';
                this.aiModelList = [];
                this.saveAiConfig();
            },
        },

        mounted() {
            this.addLog('SYS', 'Initializing F&L. Sys Response...', 'sys');
            setTimeout(() => this.addLog('L-SYS', 'Daemon thread started. ((守护线程已启动))', 'auth'), 300);
            setTimeout(() => this.addLog('SYS', 'Mounting user volume: /wonderland/FlandreTiamat', 'sys'), 400);
            setTimeout(() => this.addLog('AUTH', 'Identity Verified. Welcome, Operator.', 'auth'), 800);
            setTimeout(() => this.addLog('L-PROTO', 'Link established. The observer (L) is active.', 'auth'), 1200);

            // session 持久化
            if (!localStorage.getItem('fl_session_id')) {
                localStorage.setItem('fl_session_id', this.sessionId);
            }

            this.syncAllData();
            this.syncInterval = setInterval(() => this.syncAllData(), 10000);

            this.sendHeartbeat();
            this.heartbeatInterval = setInterval(() => this.sendHeartbeat(), 30000);

            // E1：历史面板默认展开并自动查最近 24h；E4：拉取今日 AI 用量
            this.loadHistory();
            this.fetchAiUsage();

            setTimeout(() => {
                this.addLog('CHAT', \`用户 \${this.userName} 加入群聊\`, 'net');
            }, 1500);
            setTimeout(() => {
                this.addLog('CHAT', '群聊功能已激活，输入消息后按Enter发送', 'sys');
                this.\$nextTick(() => { this.scrollToBottom(); });
            }, 2000);
        },

        beforeUnmount() {
            if (this.syncInterval)      clearInterval(this.syncInterval);
            if (this.heartbeatInterval) clearInterval(this.heartbeatInterval);
        }
    });

    app.mount('#app');
    </script>
</body>
</html>`;