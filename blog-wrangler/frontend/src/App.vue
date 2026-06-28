<script setup>
import { onMounted, onBeforeUnmount } from 'vue'
import StatusHeader from './components/StatusHeader.vue'
import DeviceCards from './components/DeviceCards.vue'
import OnlineUsers from './components/OnlineUsers.vue'
import LogTerminal from './components/LogTerminal.vue'
import HistoryPanel from './components/HistoryPanel.vue'

import { chatState } from './composables/useChat'
import { useHeartbeat } from './composables/useHeartbeat'
import { useHistory } from './composables/useHistory'
import { useAuth } from './composables/useAuth'
import { useAi } from './composables/useAi'

const hb = useHeartbeat()
const history = useHistory()
const auth = useAuth()
const ai = useAi()

let syncTimer, heartbeatTimer

onMounted(() => {
  // 开机日志序列由 useChat 的静态 initLogs 渲染，这里不再重复推送
  chatState.syncAllData()
  syncTimer = setInterval(() => chatState.syncAllData(), 10000)

  hb.sendHeartbeat()
  heartbeatTimer = setInterval(() => hb.sendHeartbeat(), 30000)

  history.loadHistory()
  auth.restoreLogin(ai)
})

onBeforeUnmount(() => {
  clearInterval(syncTimer)
  clearInterval(heartbeatTimer)
})
</script>

<template>
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

  <div id="app" class="min-h-screen p-4 md:p-8 fade-in" v-cloak>
    <div class="max-w-6xl mx-auto">
      <StatusHeader />
      <DeviceCards />
      <OnlineUsers />
      <LogTerminal />
      <HistoryPanel />

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
</template>
