<script setup>
import { useHistory } from '../composables/useHistory'
import { useAi } from '../composables/useAi'
import { useAuth } from '../composables/useAuth'
import { getDeviceName, fmtHistoryDuration } from '../utils/helpers'

const history = useHistory()
const ai = useAi()
const auth = useAuth()

// ── 桥接：加载历史 → 准备 AI 数据 ──
async function loadAndPrepare(reset = true) {
  const hd = history.historyDevices.value.join(',')
  // 临时保存当前设备列表，避免路由切换时的竞态
  const devs = [...history.historyDevices.value]
  await history.loadHistory(reset)
  if (reset && devs.length > 0) {
    await ai.prepareAiData(devs, history.historyQueryStart.value, history.historyQueryEnd.value)
  }
}

async function loadNextPage() {
  history.historyCursorStack.value.push(history.historyCursor.value)
  history.historyCursor.value = history.historyNextCursor.value
  history.historyPage.value += 1
  await history.loadHistory(false)
}

async function loadPrevPage() {
  if (history.historyCursorStack.value.length === 0) return
  history.historyCursor.value = history.historyCursorStack.value.pop() || null
  history.historyPage.value = Math.max(1, history.historyPage.value - 1)
  await history.loadHistory(false)
}

// ── 认证 ──
function doLogin() {
  auth.login(ai)
}

function doLogout() {
  auth.logout()
}

// ── AI 配置 ──
function handleProviderChange() {
  ai.onProviderChange()
}

function handleSaveConfig() {
  ai.saveAiConfig(auth.authToken.value)
}

// ── 获取模型列表 ──
function doFetchModels() {
  ai.fetchModels()
}
</script>

<template>
  <div class="history-panel mt-8">
    <div class="flex items-center justify-between mb-4">
      <span class="text-sm font-bold text-purple-300 uppercase tracking-widest">[ 活动历史 ]</span>
      <button
        @click="history.historyPanelOpen.value = !history.historyPanelOpen.value"
        class="text-xs text-slate-500 hover:text-slate-300 transition px-3 py-1 border border-slate-700 rounded font-mono"
      >
        {{ history.historyPanelOpen.value ? '收起 ▲' : '展开 ▼' }}
      </button>
    </div>

    <div v-if="history.historyPanelOpen.value">
      <!-- ── 筛选控件 ── -->
      <div class="flex flex-wrap gap-3 mb-4 items-end">
        <div>
          <div class="text-[10px] text-slate-500 mb-1 uppercase tracking-widest">设备</div>
          <div class="flex gap-2">
            <label
              v-for="d in ['desktop','notebook','phone']"
              :key="d"
              class="flex items-center gap-1 text-xs font-mono cursor-pointer"
            >
              <input type="checkbox" :value="d" v-model="history.historyDevices.value" class="accent-purple-500" />
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
          <select
            v-model="history.historyRange.value"
            class="bg-black/40 border border-slate-700 text-slate-300 rounded px-2 py-1 text-xs font-mono"
          >
            <option value="3600000">最近 1 小时</option>
            <option value="21600000">最近 6 小时</option>
            <option value="86400000">最近 24 小时</option>
            <option value="604800000">最近 7 天</option>
            <option value="2592000000">最近 30 天</option>
          </select>
        </div>
        <div>
          <div class="text-[10px] text-slate-500 mb-1 uppercase tracking-widest">每页</div>
          <select
            v-model="history.historyPageSize.value"
            class="bg-black/40 border border-slate-700 text-slate-300 rounded px-2 py-1 text-xs font-mono"
          >
            <option :value="40">40</option>
            <option :value="80">80</option>
            <option :value="120">120</option>
            <option :value="200">200</option>
          </select>
        </div>
        <button
          @click="loadAndPrepare(true)"
          class="px-4 py-1 text-xs bg-purple-900/40 text-purple-300 border border-purple-700/30 rounded font-mono hover:bg-purple-800/50 transition"
        >查询</button>
        <button
          @click="ai.openAiSummary()"
          :disabled="ai.aiLoading.value || !ai.aiPrompt.value || history.historyDevices.value.length === 0"
          class="px-4 py-1 text-xs bg-gradient-to-r from-purple-900/40 to-pink-900/40 text-pink-300 border border-pink-700/30 rounded font-mono hover:from-purple-800/50 transition disabled:opacity-40"
        >
          {{ ai.aiLoading.value ? 'AI 分析中...' : '✨ AI 总结' }}
        </button>
        <span
          v-if="ai.mergedInfo.value"
          :class="['text-[10px] font-mono self-center',
            ai.aiForced.value ? 'text-rose-400' : (ai.aiBucketMin.value > 5 ? 'text-amber-400' : 'text-slate-500')]"
        >{{ ai.mergedInfo.value }}</span>
        <span class="text-[10px] text-cyan-600 font-mono self-center">
          今日AI已用: {{ ai.aiUsageToday.value[ai.aiProvider.value] || 0 }} 次
          <span v-if="ai.aiProvider.value==='cf'"> · CF免费~1万neurons/天</span>
        </span>
      </div>

      <!-- ── AI 账号记忆 ── -->
      <div
        class="flex flex-wrap gap-3 mb-4 items-end p-3 rounded-lg"
        style="background: rgba(14,165,233,0.04); border:1px solid rgba(14,165,233,0.15);"
      >
        <template v-if="auth.authToken.value">
          <div>
            <div class="text-[10px] text-slate-500 mb-1 uppercase tracking-widest">账号记忆</div>
            <div class="text-xs text-cyan-300 font-mono">
              已登录：{{ auth.authName.value || auth.authUser.value }}
            </div>
          </div>
          <button
            @click="doLogout"
            class="px-3 py-1 text-xs bg-slate-900/60 text-slate-300 border border-slate-700 rounded font-mono hover:bg-slate-800 transition"
          >退出</button>
        </template>
        <template v-else>
          <div>
            <div class="text-[10px] text-slate-500 mb-1 uppercase tracking-widest">账号</div>
            <input
              v-model="auth.authUser.value"
              class="bg-black/40 border border-slate-700 text-slate-300 rounded px-2 py-1 text-xs font-mono"
              style="width:160px;"
            />
          </div>
          <div>
            <div class="text-[10px] text-slate-500 mb-1 uppercase tracking-widest">密码</div>
            <input
              v-model="auth.authPass.value"
              type="password"
              @keyup.enter="doLogin"
              class="bg-black/40 border border-slate-700 text-slate-300 rounded px-2 py-1 text-xs font-mono"
              style="width:190px;"
            />
          </div>
          <button
            @click="doLogin"
            :disabled="auth.authLoading.value"
            class="px-3 py-1 text-xs bg-cyan-900/40 text-cyan-300 border border-cyan-700/30 rounded font-mono hover:bg-cyan-800/50 transition disabled:opacity-40"
          >
            {{ auth.authLoading.value ? '登录中...' : '登录记忆配置' }}
          </button>
          <span class="text-[10px] text-slate-600 font-mono self-center">不登录时仅保存在本机</span>
        </template>
        <span
          v-if="auth.authStatus.value"
          :class="['text-[10px] font-mono self-center',
            auth.authStatus.value.indexOf('失败') >= 0 ? 'text-rose-400' : 'text-cyan-500']"
        >{{ auth.authStatus.value }}</span>
      </div>

      <!-- ── AI 模型配置 ── -->
      <div
        class="flex flex-wrap gap-3 mb-4 items-end p-3 rounded-lg"
        style="background: rgba(139,92,246,0.04); border:1px solid rgba(139,92,246,0.15);"
      >
        <div>
          <div class="text-[10px] text-slate-500 mb-1 uppercase tracking-widest">AI 提供方</div>
          <select
            v-model="ai.aiProvider.value"
            @change="handleProviderChange"
            class="bg-black/40 border border-slate-700 text-slate-300 rounded px-2 py-1 text-xs font-mono"
          >
            <option value="cf">CF 自带 (免费)</option>
            <option value="openai">OpenAI 协议</option>
            <option value="google">Google 协议</option>
          </select>
        </div>
        <div v-if="ai.aiProvider.value === 'cf'">
          <div class="text-[10px] text-slate-500 mb-1 uppercase tracking-widest">CF 模型</div>
          <select
            v-model="ai.aiModel.value"
            @change="handleSaveConfig"
            class="bg-black/40 border border-slate-700 text-slate-300 rounded px-2 py-1 text-xs font-mono"
          >
            <option value="@cf/qwen/qwen2.5-coder-32b-instruct">qwen2.5-coder-32b (默认)</option>
            <option value="@cf/meta/llama-3.1-8b-instruct">llama-3.1-8b-instruct (稳)</option>
            <option value="@cf/qwen/qwq-32b">qwq-32b (推理)</option>
          </select>
          <div
            class="text-[10px] text-slate-600 mt-1"
            style="max-width:320px;"
          >免费约 1万 neurons/天，够每天几十~上百次中等总结；单次建议 &lt; 60 KB（约 2万 token），超出会自动加大合并粒度（30分钟→最长6小时）压缩，仍超限则强制总结。模型不存在会自动回退 llama-3.1-8b。</div>
        </div>
        <template v-if="ai.aiProvider.value !== 'cf'">
          <div>
            <div class="text-[10px] text-slate-500 mb-1 uppercase tracking-widest">Base URL</div>
            <input
              v-model="ai.aiBaseUrl.value"
              @change="handleSaveConfig"
              :placeholder="ai.aiProvider.value==='openai' ? 'https://api.openai.com/v1' : 'https://generativelanguage.googleapis.com/v1beta'"
              class="bg-black/40 border border-slate-700 text-slate-300 rounded px-2 py-1 text-xs font-mono"
              style="width:260px;"
            />
          </div>
          <div>
            <div class="text-[10px] text-slate-500 mb-1 uppercase tracking-widest">API Key</div>
            <input
              v-model="ai.aiApiKey.value"
              @change="handleSaveConfig"
              type="password"
              placeholder="sk-..."
              class="bg-black/40 border border-slate-700 text-slate-300 rounded px-2 py-1 text-xs font-mono"
              style="width:200px;"
            />
          </div>
          <div>
            <div class="text-[10px] text-slate-500 mb-1 uppercase tracking-widest">模型</div>
            <div class="flex gap-1">
              <input
                v-model="ai.aiModel.value"
                @change="handleSaveConfig"
                list="ai-model-list"
                placeholder="模型名"
                class="bg-black/40 border border-slate-700 text-slate-300 rounded px-2 py-1 text-xs font-mono"
                style="width:200px;"
              />
              <datalist id="ai-model-list">
                <option v-for="m in ai.aiModelList.value" :key="m" :value="m" />
              </datalist>
              <button
                @click="doFetchModels"
                :disabled="ai.aiModelsLoading.value"
                class="px-2 py-1 text-xs bg-slate-800 text-slate-300 border border-slate-600 rounded font-mono hover:bg-slate-700 disabled:opacity-40"
              >
                {{ ai.aiModelsLoading.value ? '...' : '获取模型' }}
              </button>
            </div>
          </div>
        </template>
      </div>

      <!-- ── AI 总结结果 ── -->
      <div v-if="ai.aiSummary.value" class="ai-summary-box mb-4">
        <div class="text-[10px] text-purple-500 mb-2 uppercase tracking-widest">[ AI Analysis Result ]</div>
        {{ ai.aiSummary.value }}
      </div>

      <!-- ── 历史表格 ── -->
      <div
        v-if="history.historyLoading.value"
        class="text-slate-600 text-xs text-center py-4"
      >加载中...</div>
      <div
        v-else-if="history.historyRows.value.length === 0"
        class="text-slate-700 text-xs text-center py-4"
      >暂无历史记录，点击「查询」加载</div>
      <div v-else class="overflow-x-auto max-h-72 overflow-y-auto">
        <table class="history-table">
          <thead>
            <tr>
              <th>时间</th>
              <th>设备</th>
              <th>活动窗口</th>
              <th>持续</th>
              <th>WiFi</th>
              <th>局域网 IP</th>
              <th>电量</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="row in history.historyRows.value" :key="row.id">
              <td class="text-slate-600 whitespace-nowrap">{{ row.recorded_at ? new Date(row.recorded_at).toLocaleString('zh-CN', { hour12: false }) : '' }}</td>
              <td>
                <span :class="{
                  'text-blue-400': row.device_id==='desktop',
                  'text-purple-400': row.device_id==='notebook',
                  'text-cyan-400': row.device_id==='phone',
                  'text-slate-400': !['desktop','notebook','phone'].includes(row.device_id)
                }">{{ getDeviceName(row.device_id) }}</span>
              </td>
              <td class="text-slate-300 max-w-xs truncate" :title="row.window_title">{{ row.window_title }}</td>
              <td class="text-slate-500 whitespace-nowrap">{{ fmtHistoryDuration(row) }}</td>
              <td class="text-slate-500">{{ row.wifi || '-' }}</td>
              <td class="text-slate-500">{{ row.lan || '-' }}</td>
              <td class="text-slate-500">{{ row.battery || '-' }}</td>
            </tr>
          </tbody>
        </table>
        <div class="flex items-center justify-between gap-3 mt-2 text-[10px] font-mono text-slate-600">
          <button
            @click="loadPrevPage"
            :disabled="history.historyLoading.value || history.historyCursorStack.value.length === 0"
            class="px-3 py-1 border border-slate-800 rounded hover:text-slate-300 hover:border-slate-600 disabled:opacity-30 disabled:hover:text-slate-600 disabled:hover:border-slate-800"
          >上一页</button>
          <span>第 {{ history.historyPage.value }} 页 · 本页 {{ history.historyRows.value.length }} 条</span>
          <button
            @click="loadNextPage"
            :disabled="history.historyLoading.value || history.historyDone.value || !history.historyNextCursor.value"
            class="px-3 py-1 border border-slate-800 rounded hover:text-slate-300 hover:border-slate-600 disabled:opacity-30 disabled:hover:text-slate-600 disabled:hover:border-slate-800"
          >下一页</button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.history-panel {
  background: rgba(10,10,20,0.9); border: 1px solid rgba(139,92,246,0.25);
  border-radius: 10px; padding: 16px; margin-top: 2rem;
}
.history-table { width: 100%; border-collapse: collapse; font-size: 11px; }
.history-table th {
  color: #64748b; font-weight: 600; padding: 6px 8px; text-align: left;
  border-bottom: 1px solid rgba(255,255,255,0.07);
}
.history-table td {
  padding: 5px 8px; color: #94a3b8;
  border-bottom: 1px solid rgba(255,255,255,0.03);
}
.history-table tr:hover td { background: rgba(255,255,255,0.02); }
.ai-summary-box {
  background: rgba(139,92,246,0.05); border: 1px solid rgba(139,92,246,0.3);
  border-radius: 8px; padding: 14px; margin-top: 12px;
  color: #c4b5fd; font-size: 13px; line-height: 1.7; white-space: pre-wrap;
  max-height: 300px; overflow-y: auto;
}
</style>
