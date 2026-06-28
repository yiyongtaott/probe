<script setup>
import { useHeartbeat } from '../composables/useHeartbeat'

const { onlineCount, onlineUserList, sessionId } = useHeartbeat()
</script>

<template>
  <div class="terminal-card rounded-2xl p-6 mb-8">
    <div class="flex items-center justify-between mb-4">
      <div class="flex items-center gap-2">
        <div class="w-2 h-2 rounded-full bg-green-500 animate-pulse"></div>
        <span class="text-xs font-bold text-slate-400 uppercase tracking-widest">
          在线访客 ({{ onlineCount }})
        </span>
      </div>
      <span class="text-[10px] text-slate-600 font-mono">5分钟内活跃</span>
    </div>
    <div class="online-panel">
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
  </div>
</template>

<style scoped>
.online-panel {
  background: rgba(10,10,20,0.8); border: 1px solid rgba(14,165,233,0.2);
  border-radius: 8px; padding: 10px; font-size: 11px;
}
.online-row {
  display: flex; justify-content: space-between; align-items: center;
  padding: 3px 0; border-bottom: 1px solid rgba(255,255,255,0.04);
}
.online-row:last-child { border-bottom: none; }
</style>
