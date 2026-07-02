<script setup>
import { useHeartbeat } from '../composables/useHeartbeat'

const { onlineCount, onlineUserList, sessionId, visitorStats } = useHeartbeat()

function fmtNum(n) {
  return String(n || 0).padStart(2, '0')
}

// 趋势图：找到最大值用于柱高比例
function barHeight(val) {
  const max = Math.max(...(visitorStats.value.dailyHistory || []).map(d => d.unique_visitors || 0), 1)
  return Math.max(2, Math.round((val / max) * 100)) + '%'
}

function dayLabel(day) {
  return day ? day.slice(5) : ''
}

function timeAgo(ts) {
  if (!ts) return ''
  const diff = Date.now() - ts
  if (diff < 60000) return '刚刚'
  if (diff < 3600000) return Math.floor(diff / 60000) + '分钟前'
  if (diff < 86400000) return Math.floor(diff / 3600000) + '小时前'
  return Math.floor(diff / 86400000) + '天前'
}
</script>

<template>
  <div class="terminal-card rounded-2xl p-6 mb-8">
    <!-- 统计卡片 -->
    <div class="grid grid-cols-2 md:grid-cols-4 gap-3 mb-6">
      <div class="stat-card">
        <div class="stat-value text-cyan-400">{{ fmtNum(visitorStats.totalVisitors) }}</div>
        <div class="stat-label">总独立访客</div>
      </div>
      <div class="stat-card">
        <div class="stat-value text-purple-400">{{ fmtNum(visitorStats.totalVisits) }}</div>
        <div class="stat-label">总访问次数</div>
      </div>
      <div class="stat-card">
        <div class="stat-value text-green-400">{{ fmtNum(visitorStats.todayVisitors) }}</div>
        <div class="stat-label">今日访客</div>
      </div>
      <div class="stat-card">
        <div class="stat-value text-pink-400">{{ fmtNum(visitorStats.todayVisits) }}</div>
        <div class="stat-label">今日访问</div>
      </div>
    </div>

    <!-- 7天趋势 -->
    <div v-if="visitorStats.dailyHistory && visitorStats.dailyHistory.length" class="mb-6">
      <div class="flex items-center gap-2 mb-3">
        <span class="text-[10px] font-bold text-slate-500 uppercase tracking-widest">近7天访客趋势</span>
      </div>
      <div class="trend-chart">
        <div
          v-for="d in visitorStats.dailyHistory"
          :key="d.day"
          class="trend-bar-group"
        >
          <div class="trend-bar-wrapper">
            <div
              class="trend-bar"
              :style="{ height: barHeight(d.unique_visitors) }"
              :title="d.day + ': ' + d.unique_visitors + ' 访客, ' + d.total_visits + ' 次访问'"
            >
              <span class="trend-bar-count">{{ d.unique_visitors || 0 }}</span>
            </div>
          </div>
          <span class="trend-bar-label">{{ dayLabel(d.day) }}</span>
        </div>
      </div>
    </div>

    <!-- 在线访客 -->
    <div class="flex items-center justify-between mb-3">
      <div class="flex items-center gap-2">
        <div class="w-2 h-2 rounded-full bg-green-500 animate-pulse"></div>
        <span class="text-xs font-bold text-slate-400 uppercase tracking-widest">
          在线访客 ({{ onlineCount }})
        </span>
      </div>
      <span class="text-[10px] text-slate-600 font-mono">5分钟内活跃</span>
    </div>
    <div class="online-panel mb-4">
      <div
        v-if="onlineUserList.length === 0"
        class="text-slate-600 text-xs text-center py-2"
      >暂无在线用户</div>
      <div
        v-for="u in onlineUserList"
        :key="u.sessionId"
        class="online-row"
      >
        <div class="flex items-center gap-2">
          <div class="w-1.5 h-1.5 rounded-full bg-green-400"></div>
          <span class="text-cyan-300 font-mono">{{ u.userName }}</span>
          <span
            v-if="u.sessionId === sessionId"
            class="text-[9px] text-slate-600"
          >(你)</span>
        </div>
        <span class="text-slate-600 font-mono text-[10px]">{{ u.ip }}</span>
      </div>
    </div>

    <!-- 最近活跃访客 -->
    <div v-if="visitorStats.recentVisitors && visitorStats.recentVisitors.length">
      <div class="flex items-center gap-2 mb-3">
        <span class="text-[10px] font-bold text-slate-500 uppercase tracking-widest">最近活跃访客 (24h)</span>
      </div>
      <div class="recent-panel">
        <div
          v-for="v in visitorStats.recentVisitors.slice(0, 10)"
          :key="v.hash"
          class="recent-row"
        >
          <div class="flex items-center gap-2">
            <div class="w-1.5 h-1.5 rounded-full bg-cyan-500/60"></div>
            <span class="text-slate-400 font-mono text-[10px]">{{ v.userName || '访客' }}</span>
            <span class="text-slate-700 font-mono text-[9px]">#{{ v.hash }}</span>
          </div>
          <div class="flex items-center gap-3">
            <span class="text-slate-600 font-mono text-[10px]">×{{ v.visitCount }}</span>
            <span class="text-slate-600 font-mono text-[10px]">{{ v.ip }}</span>
            <span class="text-slate-700 font-mono text-[9px]">{{ timeAgo(v.lastSeen) }}</span>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.stat-card {
  background: rgba(10, 10, 20, 0.8);
  border: 1px solid rgba(139, 92, 246, 0.15);
  border-radius: 8px;
  padding: 12px 10px;
  text-align: center;
  transition: all 0.3s ease;
}
.stat-card:hover {
  border-color: rgba(139, 92, 246, 0.4);
  box-shadow: 0 0 20px rgba(139, 92, 246, 0.15);
}
.stat-value {
  font-size: 1.75rem;
  font-weight: 800;
  font-family: 'SF Mono', 'Courier New', monospace;
  text-shadow: 0 0 15px currentColor;
  line-height: 1.2;
}
.stat-label {
  font-size: 0.625rem;
  color: #64748b;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  margin-top: 4px;
}
.trend-chart {
  display: flex;
  align-items: flex-end;
  gap: 4px;
  height: 60px;
  padding: 0 4px;
}
.trend-bar-group {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
}
.trend-bar-wrapper {
  flex: 1;
  display: flex;
  align-items: flex-end;
  width: 100%;
}
.trend-bar {
  width: 100%;
  min-height: 2px;
  background: linear-gradient(180deg, #22d3ee 0%, #0ea5e9 100%);
  border-radius: 3px 3px 0 0;
  position: relative;
  transition: all 0.4s ease;
  opacity: 0.7;
}
.trend-bar:hover {
  opacity: 1;
  box-shadow: 0 0 12px rgba(34, 211, 238, 0.5);
}
.trend-bar-count {
  position: absolute;
  top: -16px;
  left: 50%;
  transform: translateX(-50%);
  font-size: 9px;
  color: #22d3ee;
  font-family: 'SF Mono', monospace;
}
.trend-bar-label {
  font-size: 8px;
  color: #475569;
  font-family: 'SF Mono', monospace;
}
.online-panel {
  background: rgba(10, 10, 20, 0.8);
  border: 1px solid rgba(14, 165, 233, 0.2);
  border-radius: 8px;
  padding: 10px;
  font-size: 11px;
}
.online-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 3px 0;
  border-bottom: 1px solid rgba(255, 255, 255, 0.04);
}
.online-row:last-child {
  border-bottom: none;
}
.recent-panel {
  background: rgba(10, 10, 20, 0.6);
  border: 1px solid rgba(139, 92, 246, 0.1);
  border-radius: 8px;
  padding: 10px;
}
.recent-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 4px 0;
  border-bottom: 1px solid rgba(255, 255, 255, 0.03);
}
.recent-row:last-child {
  border-bottom: none;
}
</style>
