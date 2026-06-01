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
            window:  obj.window  || raw,
            lan:     obj.lan     || 'unknown',
            wifi:    obj.wifi    || 'unknown',
            battery: obj.battery || 'unknown',
        };
    } catch {
        // 旧版纯文本上报兼容
        return { window: raw, lan: 'unknown', wifi: 'unknown', battery: 'unknown' };
    }
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
            // 5% 概率清理 24 小时前的非白名单设备
            if (Math.random() < 0.05) {
                const oneDayAgo = Date.now() - 86400000;
                ctx.waitUntil(
                    env.DB.prepare(
                        `DELETE FROM devices
                         WHERE id NOT IN ('desktop', 'notebook', 'phone')
                           AND last_seen < ?`
                    ).bind(oneDayAgo).run()
                );
            }
            try {
                const results = await env.DB.batch([
                    env.DB.prepare("SELECT * FROM devices"),
                    env.DB.prepare("SELECT * FROM messages ORDER BY timestamp ASC LIMIT 100"),
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

        // [API] 上报设备数据（需求3：解析 JSON payload）
        if (request.method === "POST" && url.pathname.startsWith("/api/report/")) {
            try {
                const deviceId = url.pathname.split("/").pop().toLowerCase();
                if (!deviceId) return createResponse("Invalid ID", 400);

                const rawBody = await request.text();
                const parsed  = parseProbePayload(rawBody);
                const now     = Date.now();
                const timeStr = new Date().toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai', hour12: false });
                const cfIp    = request.headers.get("CF-Connecting-IP") || "unknown";

                // 更新设备状态（status 字段存 window 标题，保持兼容）
                await env.DB.prepare(
                    `INSERT INTO devices (id, status, last_seen, updated_at, last_ip, lan, wifi, battery)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                     ON CONFLICT(id) DO UPDATE SET
                     status=excluded.status, last_seen=excluded.last_seen,
                     updated_at=excluded.updated_at, last_ip=excluded.last_ip,
                     lan=excluded.lan, wifi=excluded.wifi, battery=excluded.battery`
                ).bind(deviceId, parsed.window, now, timeStr, cfIp,
                    parsed.lan, parsed.wifi, parsed.battery).run();

                // 需求2：写入活动历史
                await env.DB.prepare(
                    `INSERT INTO activity_history (device_id, window_title, lan, wifi, battery, recorded_at)
                     VALUES (?, ?, ?, ?, ?, ?)`
                ).bind(deviceId, parsed.window, parsed.lan, parsed.wifi, parsed.battery, now).run();

                // 5% 概率清理超过 30 天的历史，防膨胀
                if (Math.random() < 0.05) {
                    ctx.waitUntil(
                        env.DB.prepare(
                            `DELETE FROM activity_history WHERE recorded_at < ?`
                        ).bind(now - 30 * 86400000).run()
                    );
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
                const limit     = Math.min(parseInt(url.searchParams.get("limit") || "500"), 1000);

                let stmt;
                if (deviceId && deviceId !== "all") {
                    stmt = env.DB.prepare(
                        `SELECT * FROM activity_history
                         WHERE device_id = ? AND recorded_at BETWEEN ? AND ?
                         ORDER BY recorded_at DESC LIMIT ?`
                    ).bind(deviceId, startTime, endTime, limit);
                } else {
                    stmt = env.DB.prepare(
                        `SELECT * FROM activity_history
                         WHERE recorded_at BETWEEN ? AND ?
                         ORDER BY recorded_at DESC LIMIT ?`
                    ).bind(startTime, endTime, limit);
                }

                const rows = await stmt.all();
                return createResponse(JSON.stringify({ history: rows.results }));
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

                if (Math.random() < 0.1) {
                    await env.DB.prepare("DELETE FROM messages WHERE id NOT IN (SELECT id FROM messages ORDER BY timestamp DESC LIMIT 200)").run();
                }

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

                if (Math.random() < 0.1) {
                    await env.DB.prepare("DELETE FROM online_users WHERE last_seen < ?").bind(now - 600000).run();
                }

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

        // [API] AI 总结（使用 CF Workers AI 免费额度）
        if (request.method === "POST" && url.pathname === "/api/ai-summary") {
            try {
                const { prompt } = await request.json();
                const result = await env.AI.run('@cf/meta/llama-3.1-8b-instruct', {
                    messages: [
                        { role: 'system', content: '你是一个简洁的个人活动分析助手，用中文回答，控制在200字以内。' },
                        { role: 'user',   content: prompt }
                    ],
                    max_tokens: 400,
                });
                return createResponse(JSON.stringify({ summary: result.response || '' }));
            } catch (err) {
                return createResponse(JSON.stringify({ summary: '（AI 分析失败: ' + err.message + '）' }), 500);
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
                                :disabled="historyRows.length === 0 || aiLoading"
                                class="px-4 py-1 text-xs bg-gradient-to-r from-purple-900/40 to-pink-900/40 text-pink-300 border border-pink-700/30 rounded font-mono hover:from-purple-800/50 transition disabled:opacity-40">
                            {{ aiLoading ? 'AI 分析中...' : '✨ AI 总结' }}
                        </button>
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
                // 需求2：历史面板状态
                historyPanelOpen: false,
                historyDevices: ['desktop', 'notebook', 'phone'],
                historyRange: '86400000',
                historyRows: [],
                historyLoading: false,
                aiLoading: false,
                aiSummary: '',
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
                    const res = await fetch(API_BASE + '/api/sync');
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

                        // 2. 聊天
                        const messages = megaData.chatHistory;
                        const oldCount = this.chatMessages.length;
                        this.chatMessages = messages;
                        if (messages.length > oldCount) {
                            const cnt = messages.length - oldCount;
                            if (!this.isAtBottom() || this.userScrolledUp) {
                                this.hasNewMessages = true; this.newMessageCount += cnt;
                            } else {
                                this.\$nextTick(() => { this.scrollToBottom(); });
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

            // ── 需求2：历史记录加载 ───────────────────────────────────────────
            async loadHistory() {
                if (this.historyDevices.length === 0) return;
                this.historyLoading = true;
                this.historyRows = [];
                this.aiSummary = '';
                try {
                    const end   = Date.now();
                    const start = end - parseInt(this.historyRange);
                    const allRows = [];

                    // 分别查每个选中的设备，合并后排序
                    await Promise.all(this.historyDevices.map(async (dev) => {
                        const res = await fetch(
                            \`\${API_BASE}/api/history?device=\${dev}&start=\${start}&end=\${end}&limit=300\`
                        );
                        if (res.ok) {
                            const data = await res.json();
                            allRows.push(...(data.history || []));
                        }
                    }));

                    // 按时间倒序
                    allRows.sort((a, b) => b.recorded_at - a.recorded_at);
                    this.historyRows = allRows;
                } catch (e) {
                    console.error('loadHistory error:', e);
                } finally {
                    this.historyLoading = false;
                }
            },

            // ── 需求2：AI 总结 ────────────────────────────────────────────────
            async openAiSummary() {
                if (this.historyRows.length === 0 || this.aiLoading) return;
                this.aiLoading  = true;
                this.aiSummary  = '';

                // 构建提示词：把历史记录压缩成文本
                const lines = this.historyRows.slice(0, 200).map(r => {
                    const t = this.formatChatTime(r.recorded_at);
                    return \`[\${t}] [\${this.getDeviceName(r.device_id)}] \${r.window_title}\`;
                }).join('\\n');

                const deviceNames = this.historyDevices.map(d => this.getDeviceName(d)).join('、');
                const rangeLabel  = { '3600000':'1小时','21600000':'6小时','86400000':'24小时','604800000':'7天','2592000000':'30天' }[this.historyRange] || '一段时间';

                const prompt = \`以下是用户在\${rangeLabel}内，\${deviceNames}上的活动窗口记录（时间 / 设备 / 窗口标题）：

\${lines}

请简洁地总结：
1. 这段时间主要在做什么（工作、学习、娱乐？各占比如何）
2. 各设备的使用侧重
3. 有没有值得注意的使用规律或建议

使用中文，语气轻松，控制在200字以内。\`;

                try {
                    const res = await fetch(\`\${API_BASE}/api/ai-summary\`, {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ prompt })
                    });
                    const data = await res.json();
                    const text = data.summary || '';
                    this.aiSummary = text || '（未能获取总结，请检查 API 连接）';
                } catch (e) {
                    this.aiSummary = '（AI 接口请求失败: ' + e.message + '）';
                } finally {
                    this.aiLoading = false;
                }
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
            this.syncInterval = setInterval(() => this.syncAllData(), 5000);

            this.sendHeartbeat();
            this.heartbeatInterval = setInterval(() => this.sendHeartbeat(), 30000);

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