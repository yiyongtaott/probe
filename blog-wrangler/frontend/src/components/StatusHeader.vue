<script setup>
import { chatState } from '../composables/useChat'

function handleLinkClick(event) {
  const url = 'https://yiyongtaott.github.io/.yyt'
  if (event.ctrlKey || event.metaKey) window.open(url, '_blank')
  else window.location.href = url
}
</script>

<template>
  <header class="mb-12 p-6 terminal-card rounded-2xl">
    <div class="flex flex-col md:flex-row justify-between items-start md:items-center gap-6">
      <div>
        <div class="flex items-center gap-3 mb-3">
          <div class="w-3 h-3 bg-green-500 rounded-full status-dot pulse-subtle"></div>
          <span class="text-green-400 text-sm font-mono tracking-widest">系统运行中</span>
          <span class="text-slate-600 text-xs">|</span>
          <span class="text-slate-400 text-sm font-mono">
            控制台 φ
            <a
              id="toMain2"
              href="https://yiyongtaott.github.io/.yyt/"
              class="hover:text-cyan-400 transition"
            >点击返回首页</a>
          </span>
        </div>
        <h1
          class="glitch text-4xl md:text-6xl font-black tracking-tighter text-white"
          data-text="FLΛNDRE_TIAMAT"
        >FLΛNDRE_TIAMAT</h1>
        <p class="text-slate-500 text-sm font-mono mt-3">三端视奸系统</p>
      </div>
      <div class="font-mono text-right">
        <div class="text-xs text-slate-500 uppercase tracking-widest mb-1">最后同步时间</div>
        <div class="text-2xl text-cyan-400 font-bold text-glow">{{ chatState.lastSyncTime.value || '同步中...' }}</div>
        <div class="text-[10px] text-slate-600 mt-2">Host: FLΛNDRE_TIAMAT</div>
      </div>
    </div>
    <div class="flex items-center gap-3" id="toMain">
      <div
        style="cursor: pointer;"
        @click="handleLinkClick"
        class="px-4 py-2 bg-gradient-to-r from-cyan-600/30 to-purple-600/30 border border-cyan-500/50 rounded-lg font-mono text-cyan-300 transition-all duration-300"
      >
        <span class="flex items-center gap-2">
          点击返回首页
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 8l4 4m0 0l-4 4m4-4H3" />
          </svg>
        </span>
      </div>
      <div class="hidden sm:block text-xs text-slate-500 font-mono animate-pulse">[CTRL + CLICK 新标签页打开]</div>
    </div>
  </header>
</template>
