<script setup>
import { useSync } from '../composables/useSync'
import { getDeviceName } from '../utils/helpers'

const { displayNodes } = useSync()
</script>

<template>
  <div class="grid grid-cols-1 md:grid-cols-3 gap-8 mb-16">
    <div
      v-for="(node, index) in displayNodes"
      :key="node.id"
      class="terminal-card rounded-2xl p-8 group"
    >
      <div class="connection-line"></div>

      <div class="flex justify-between items-start mb-8">
        <div class="flex items-center gap-4">
          <div
            :class="['p-3 rounded-xl transition-all duration-500',
              node.type === 'desktop'  ? 'bg-blue-500/10 border border-blue-500/20' :
              node.type === 'notebook' ? 'bg-purple-500/10 border border-purple-500/20' :
              node.type === 'phone'    ? 'bg-cyan-500/10 border border-cyan-500/20' :
              node.type === 'baby'     ? 'bg-pink-500/10 border border-pink-500/20' :
              'bg-green-500/10 border border-green-500/20']"
          >
            <!-- Desktop icon -->
            <svg
              v-if="node.type === 'desktop'"
              class="w-8 h-8 text-blue-400"
              fill="none" stroke="currentColor" viewBox="0 0 24 24"
            >
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z" />
            </svg>
            <!-- Notebook icon -->
            <svg
              v-else-if="node.type === 'notebook'"
              class="w-8 h-8 text-purple-400"
              fill="none" stroke="currentColor" viewBox="0 0 24 24"
            >
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M9 17.25v1.007a3 3 0 01-.879 2.122L7.5 21h9l-.621-.621A3 3 0 0115 18.257V17.25m6-12V15a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 15V5.25m18 0A2.25 2.25 0 0018.75 3H5.25A2.25 2.25 0 003 5.25m18 0V12a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 12V5.25" />
            </svg>
            <!-- Phone icon -->
            <svg
              v-else-if="node.type === 'phone'"
              class="w-8 h-8 text-cyan-400"
              fill="none" stroke="currentColor" viewBox="0 0 24 24"
            >
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M10.5 1.5H8.25A2.25 2.25 0 006 3.75v16.5a2.25 2.25 0 002.25 2.25h7.5A2.25 2.25 0 0018 20.25V3.75a2.25 2.25 0 00-2.25-2.25H13.5m-3 0V3h3V1.5m-3 0h3m-3 18.75h3" />
            </svg>
            <!-- Baby phone icon (private/绑定设备) -->
            <svg
              v-else-if="node.type === 'baby'"
              class="w-8 h-8 text-pink-400"
              fill="none" stroke="currentColor" viewBox="0 0 24 24"
            >
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M21 8.25c0-2.485-2.099-4.5-4.688-4.5-1.935 0-3.597 1.126-4.312 2.733-.715-1.607-2.377-2.733-4.313-2.733C5.1 3.75 3 5.765 3 8.25c0 7.22 9 12 9 12s9-4.78 9-12z" />
            </svg>
            <!-- Unknown icon -->
            <svg
              v-else
              class="w-8 h-8 text-green-400"
              fill="none" stroke="currentColor" viewBox="0 0 24 24"
            >
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01" />
            </svg>
          </div>
          <div>
            <div class="text-[10px] font-mono text-slate-500 uppercase tracking-[0.2em]">设备标识</div>
            <h3 class="text-xl font-bold text-white tracking-tight">{{ getDeviceName(node.id) }}</h3>
          </div>
        </div>
        <div class="flex flex-col items-end gap-2">
          <div
            :class="['px-3 py-1 rounded-full text-xs font-bold font-mono border',
              node.isOnline ? 'bg-green-900/30 text-green-400 border-green-500/30' :
              'bg-slate-900/50 text-slate-600 border-slate-700/50']"
          >
            {{ node.isOnline ? '同步中' : '持久化记录' }}
          </div>
          <div
            :class="['w-2 h-2 rounded-full status-dot',
              node.isOnline ? 'bg-green-500 animate-pulse' : 'bg-slate-700']"
          ></div>
        </div>
      </div>

      <div class="space-y-4">
        <div>
          <div class="text-[10px] font-mono text-slate-500 uppercase tracking-widest mb-2">当前活动前台</div>
          <div
            :class="['text-lg font-medium font-mono p-3 rounded-lg break-words whitespace-pre-wrap overflow-y-auto max-h-32',
              node.isOnline ? 'bg-white/5 text-slate-200' : 'bg-slate-900/30 text-slate-600']"
          >
            {{ node.status || '无数据流' }}
          </div>
        </div>

        <div v-if="node.extra && node.isOnline" class="device-meta">
          <span v-if="node.extra.wifi !== 'unknown'" class="device-meta-tag">📶 {{ node.extra.wifi }}</span>
          <span v-if="node.extra.lan !== 'unknown'" class="device-meta-tag">🔌 {{ node.extra.lan }}</span>
          <span v-if="node.extra.battery !== 'unknown' && node.extra.battery !== '未检测到电池'" class="device-meta-tag">🔋 {{ node.extra.battery }}</span>
          <span v-if="node.extra.last_ip !== 'unknown'" class="device-meta-tag">🌐 {{ node.extra.last_ip }}</span>
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
</template>

<style scoped>
.device-meta { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 8px; }
.device-meta-tag {
  font-size: 10px; padding: 2px 7px; border-radius: 4px;
  background: rgba(255,255,255,0.05); color: #64748b; font-family: monospace;
}
</style>
