<script setup>
import { ref, onMounted } from 'vue'
import { chatState } from '../composables/useChat'
import { useHeartbeat } from '../composables/useHeartbeat'

const hb = useHeartbeat()
const logContainer = ref(null)

onMounted(() => {
  // 注册容器 ref 到 chatState，供 syncAllData 自动滚底
  chatState.logContainerRef.value = logContainer.value
})

function handleScroll() { chatState.handleScroll(logContainer.value) }
function scrollToBottom() { chatState.scrollToBottom(logContainer.value) }
function saveUserName() { hb.saveUserName() }
async function handleSend() { await chatState.sendChatMessage(hb.userName.value, hb.sessionId.value, hb.isOnline.value) }
function handleKeyUp(event) { if (event.key === 'Enter') handleSend() }
function sendTestMessage() {
  chatState.chatInput.value = '测试消息 ' + new Date().toLocaleTimeString('zh-CN', { hour12: false })
  handleSend()
}
function msgClass(item) { return chatState.getMessageClass(item, hb.sessionId.value) }
</script>

<template>
  <div class="log-terminal-container">
    <div class="flex items-center justify-between mb-2 px-1">
      <div class="flex items-center gap-2">
        <span class="text-xs font-bold text-slate-500 uppercase tracking-widest">[F&L. Sys] RESPONSE OUTPUT</span>
        <span class="text-[9px] text-slate-700 font-mono ml-2">msgs={{ chatState.chatMessages.value.length }} comb={{ chatState.combinedMessages.value.length }} sync={{ chatState.lastMsgId.value }}</span>
      </div>
      <div class="flex items-center gap-3">
        <button v-if="chatState.hasNewMessages.value"
          @click="scrollToBottom"
          class="px-3 py-1 text-xs bg-purple-900/30 text-purple-300 border border-purple-700/30 rounded hover:bg-purple-800/40 transition flex items-center gap-1">
          <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 14l-7 7m0 0l-7-7m7 7V3" />
          </svg>
          新消息({{ chatState.newMessageCount.value }})
        </button>
        <input type="text"
          class="px-2 py-1 text-xs bg-black/30 border border-slate-700 rounded font-mono w-24"
          placeholder="昵称" v-model="hb.userName.value" @change="saveUserName" />
        <button @click="sendTestMessage"
          class="px-3 py-1 text-xs bg-cyan-900/30 text-cyan-400 border border-cyan-700/30 rounded hover:bg-cyan-800/40 transition">测试</button>
      </div>
    </div>

    <div class="log-terminal" ref="logContainer" @scroll="handleScroll" style="height: 220px;">
      <div v-for="(log, idx) in chatState.initLogs" :key="'init-log-' + idx" :class="['log-line', log.class]">
        <span class="log-time font-mono text-[10px]">{{ chatState.formatInitLogTime(log.time) }}</span>
        <span class="log-tag font-mono text-[10px]">[{{ log.tag }}]</span>
        <span class="log-msg flex-grow truncate">{{ log.msg }}</span>
      </div>
      <div v-if="chatState.combinedMessages.value.length > 0" class="log-line log-sys">
        <span class="log-time font-mono text-[10px]">{{ chatState.getCurrentTime() }}</span>
        <span class="log-tag font-mono text-[10px]">[SYS]</span>
        <span class="log-msg flex-grow truncate">=== 实时消息流 ===</span>
      </div>
      <div v-for="item in chatState.combinedMessages.value" :key="item.id" :class="['log-line', msgClass(item)]">
        <span class="log-time font-mono text-[10px]">{{ chatState.formatTime(item.timestamp) }}</span>
        <span class="log-tag font-mono text-[10px]">
          <span v-if="item.type === 'device'">[{{ item.tag }}]</span>
          <span v-else>[{{ item.user?.substring(0, 30) }}]</span>
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
        v-model="chatState.chatInput.value"
        placeholder="输入消息 (按Enter发送)" @keyup="handleKeyUp"
        :disabled="!hb.isOnline.value" />
      <button
        class="px-4 py-2 text-sm bg-gradient-to-r from-cyan-900/40 to-purple-900/40 text-cyan-300 border border-cyan-700/30 rounded font-mono hover:from-cyan-800/50 hover:to-purple-800/50 transition"
        @click="handleSend" :disabled="!hb.isOnline.value || !chatState.chatInput.value.trim()">发送</button>
    </div>
  </div>
</template>

<style scoped>
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
</style>
