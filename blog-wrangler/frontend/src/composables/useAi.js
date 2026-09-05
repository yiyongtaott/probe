import { ref } from 'vue'
import { API_BASE, fmtDuration, devCode, getDeviceName } from '../utils/helpers'
import { authHeaders } from './useAuth'

const aiLoading = ref(false)
const aiSummary = ref('')
const mergedInfo = ref('')
const aiMergedData = ref(null)
const aiPrompt = ref('')
const aiForced = ref(false)
const aiBucketMin = ref(5)
const aiUsageToday = ref({})
const aiProvider = ref(localStorage.getItem('fl_ai_provider') || 'cf')
const aiModel = ref(localStorage.getItem('fl_ai_model') || '@cf/qwen/qwen2.5-coder-32b-instruct')
const aiBaseUrl = ref(localStorage.getItem('fl_ai_baseurl') || '')
const aiApiKey = ref(localStorage.getItem('fl_ai_key') || '')
const aiModelList = ref([])
const aiModelsLoading = ref(false)

export function useAi() {
  // ── 从服务端拉取设备合并数据 ──
  async function fetchAiData(devs, start, end) {
    try {
      const res = await fetch(
        `${API_BASE}/api/ai-data?devices=${encodeURIComponent(devs)}&start=${start}&end=${end}`,
        { headers: authHeaders() }
      )
      if (!res.ok) return null
      return await res.json()
    } catch {
      return null
    }
  }

  // ── 查询后拉取合并数据并构造 prompt ──
  async function prepareAiData(historyDevices, start, end) {
    aiMergedData.value = null
    aiPrompt.value = ''
    aiForced.value = false
    mergedInfo.value = ''
    if (!historyDevices || historyDevices.length === 0) return
    const devs = historyDevices.join(',')
    const data = await fetchAiData(devs, start, end)
    if (!data || !data.merged) {
      mergedInfo.value = '（获取合并数据失败）'
      return
    }
    aiMergedData.value = {
      merged: data.merged,
      rollups: data.rollups,
      totalSessions: data.totalSessions,
      complete: data.complete,
      devices: [...historyDevices],
    }
    buildPrompt(historyDevices)
  }

  // ── 自适应压缩 + 构造最终 prompt（服务端已按 5min 间隔合并，过大则增大间隔再合并）──
  function buildPrompt(hDevices) {
    const base = aiMergedData.value
    if (!base) {
      aiPrompt.value = ''
      mergedInfo.value = ''
      return
    }
    const limitKB = aiProvider.value === 'cf' ? 60 : 300
    const limit = limitKB * 1024
    const gapSteps = [5, 10, 20, 30, 60, 120, 240]   // 合并间隔(分钟)，从服务端粒度起逐级放大
    aiForced.value = false
    let chosen = null

    for (const gap of gapSteps) {
      const merged = gap === 5 ? base.merged : regap(base.merged, gap * 60000)
      const prompt = buildPromptFromMerged(merged, base.rollups, hDevices)
      const bytes = new Blob([prompt]).size
      chosen = { gap, merged, prompt, bytes }
      if (bytes <= limit) break
    }
    if (chosen.bytes > limit) aiForced.value = true

    aiPrompt.value = chosen.prompt
    aiBucketMin.value = chosen.gap

    const kb = (chosen.bytes / 1024).toFixed(1)
    let info = '合并 ' + chosen.merged.length + ' 段 / 原始 ' + (base.totalSessions || 0) + ' 条 · ' + kb + ' KB'
    if (!base.complete) info += ' · 超安全上限'
    if (aiForced.value) {
      info += ' · ⚠数据量过大，放大到4小时间隔仍超 ' + limitKB + 'KB，将强制总结'
    } else if (chosen.gap > 5) {
      info += ' · ⚠数据量较大，已自动按' + bucketLabel(chosen.gap) + '间隔合并压缩'
    }
    mergedInfo.value = info
  }

  // ── 把服务端已合并的段按更大间隔二次合并（间隔式，与服务端 mergeSessions 口径一致）──
  function regap(merged, gapMs) {
    const sorted = [...merged].sort((a, b) => (a.start || 0) - (b.start || 0))
    const lastByKey = {}
    const out = []
    for (const seg of sorted) {
      const key = seg.device + '|' + (seg.window || '')
      const e = lastByKey[key]
      if (e && (seg.start || 0) - e.end <= gapMs) {
        e.end = Math.max(e.end, seg.end)
        e.durMs += seg.durMs || 0
        e.count += seg.count || 0
      } else {
        const ns = {
          device: seg.device, window: seg.window,
          start: seg.start, end: seg.end,
          durMs: seg.durMs || 0, count: seg.count || 0,
        }
        out.push(ns)
        lastByKey[key] = ns
      }
    }
    return out.sort((a, b) => (a.start || 0) - (b.start || 0))
  }

  function bucketLabel(min) {
    return (min % 60 === 0) ? (min / 60) + '小时' : min + '分钟'
  }

  // ── 紧凑时间线 ──
  function buildTimelineText(merged) {
    if (!merged || merged.length === 0) return ''
    const TITLE_MAX = 100
    const sorted = [...merged].sort((a, b) => a.start - b.start)
    let txt = ''
    let lastDay = ''
    for (const it of sorted) {
      const d = new Date((it.start || 0) + 8 * 3600000)
      const day = d.getUTCFullYear() + '/' +
        String(d.getUTCMonth() + 1).padStart(2, '0') + '/' +
        String(d.getUTCDate()).padStart(2, '0')
      if (day !== lastDay) { txt += '\n■' + day + '\n'; lastDay = day }
      const hh = String(d.getUTCHours()).padStart(2, '0')
      const mi = String(d.getUTCMinutes()).padStart(2, '0')
      const dur = fmtDuration(it.durMs || (it.end - it.start))
      let w = it.window || ''
      if (w.length > TITLE_MAX) w = w.slice(0, TITLE_MAX) + '…'
      txt += hh + ':' + mi + ' ' + dur + ' ' + devCode(it.device) + ' ' + w + '\n'
    }
    return txt
  }

  // ── 紧凑 prompt ──
  function buildPromptFromMerged(merged, rollups, hDevices) {
    const devLegend = hDevices.map(d => devCode(d) + '=' + getDeviceName(d)).join(' ')
    const deviceNames = hDevices.map(d => getDeviceName(d)).join('、')
    const cap = (s, n) => (s && s.length > n) ? s.slice(0, n) + '…' : (s || '')
    const fmtRoll = (obj) =>
      Object.entries(obj || {})
        .sort((a, b) => b[1] - a[1])
        .slice(0, 15)
        .map(([k, v]) => cap(k, 60) + ':' + fmtDuration(v))
        .join('；')
    const b = (rollups && rollups.buckets) || {}
    const bucketLine =
      '上午' + fmtDuration(b.morning) +
      '/下午' + fmtDuration(b.afternoon) +
      '/晚上' + fmtDuration(b.evening) +
      '/凌晨' + fmtDuration(b.night)

    return (
      '以下是用户在【一段时间】内于 ' + deviceNames + ' 的完整活动时间线。\n' +
      '格式：按天分组(■日期)，每行「时:分 时长 设备 窗口」；设备代号 ' + devLegend + '。\n' +
      buildTimelineText(merged) +
      '\n【时段汇总(上海)】' + bucketLine +
      '\n【应用/窗口Top】' + fmtRoll(rollups && rollups.perApp) +
      '\n【设备汇总】' + fmtRoll(rollups && rollups.perDevice) +
      '\n\n请基于以上完整数据，用中文分点总结（结合具体时间与窗口，不要笼统）：\n' +
      '1. 时间主要花在哪（各类活动大致占比）；\n' +
      '2. 上午、下午、晚上分别在做什么；\n' +
      '3. 一共做了哪几个主要任务（按窗口/项目归纳）；\n' +
      '4. 晚上大约几点睡（最后一段活动结束、之后长时间无活动即视为入睡）；\n' +
      '5. 白天哪些时段在偷偷摸鱼（工作时段出现的娱乐/视频/社交类窗口）。'
    )
  }

  // ── 调用 AI 总结 ──
  async function openAiSummary() {
    if (aiLoading.value) return
    if (!aiPrompt.value) {
      aiSummary.value = '（暂无可总结的数据，请先点击「查询」）'
      return
    }
    aiLoading.value = true
    aiSummary.value = aiForced.value ? '⚠ 数据压缩失败，正在强制总结中…' : ''
    try {
      const summary = await callAi(aiPrompt.value)
      const note = aiForced.value ? '⚠ 数据量过大，压缩后仍超限，已强制总结：\n\n' : ''
      aiSummary.value = note + (summary || '（未能获取总结）')
    } catch (e) {
      aiSummary.value = '（AI 接口请求失败: ' + e.message + '）'
    } finally {
      aiLoading.value = false
      fetchAiUsage()
    }
  }

  async function callAi(prompt) {
    const body = { prompt, provider: aiProvider.value, model: aiModel.value }
    if (aiProvider.value !== 'cf') {
      body.baseUrl = aiBaseUrl.value
      body.apiKey = aiApiKey.value
    }
    const res = await fetch(API_BASE + '/api/ai-summary', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    const data = await res.json()
    if (data.usedToday != null) {
      aiUsageToday.value = { ...aiUsageToday.value, [aiProvider.value]: data.usedToday }
    }
    return data.summary || ''
  }

  async function fetchAiUsage() {
    try {
      const res = await fetch(API_BASE + '/api/ai-usage')
      if (res.ok) {
        const d = await res.json()
        aiUsageToday.value = d.usage || {}
      }
    } catch (e) { /* ignore */ }
  }

  // ── 模型配置管理 ──
  function saveAiConfig(authToken) {
    localStorage.setItem('fl_ai_provider', aiProvider.value)
    localStorage.setItem('fl_ai_model', aiModel.value)
    localStorage.setItem('fl_ai_baseurl', aiBaseUrl.value)
    localStorage.setItem('fl_ai_key', aiApiKey.value)
    if (!authToken) return
    fetch(API_BASE + '/api/user/ai-config', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Bearer ' + authToken,
      },
      body: JSON.stringify({
        provider: aiProvider.value,
        baseUrl: aiBaseUrl.value,
        apiKey: aiApiKey.value,
        model: aiModel.value,
      }),
    }).catch(() => { /* ignore sync errors */ })
  }

  function onProviderChange() {
    if (aiProvider.value === 'cf' && !aiModel.value.startsWith('@cf/')) {
      aiModel.value = '@cf/qwen/qwen2.5-coder-32b-instruct'
    }
    if (aiProvider.value === 'openai' && aiModel.value.startsWith('@cf/')) {
      aiModel.value = 'gpt-4o-mini'
    }
    if (aiProvider.value === 'google' && aiModel.value.startsWith('@cf/')) {
      aiModel.value = 'gemini-1.5-flash'
    }
    aiModelList.value = []
    saveAiConfig()
    if (aiMergedData.value) {
      buildPrompt(aiMergedData.value.devices || [])
    }
  }

  async function fetchModels() {
    if (aiProvider.value === 'cf') return
    if (!aiApiKey.value) { alert('请先填写 API Key'); return }
    aiModelsLoading.value = true
    try {
      const res = await fetch(API_BASE + '/api/models', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          provider: aiProvider.value,
          baseUrl: aiBaseUrl.value,
          apiKey: aiApiKey.value,
        }),
      })
      const d = await res.json()
      if (d.error) alert('获取模型失败: ' + d.error)
      aiModelList.value = d.models || []
      if (aiModelList.value.length && !aiModelList.value.includes(aiModel.value)) {
        aiModel.value = aiModelList.value[0]
      }
      saveAiConfig()
    } catch (e) {
      alert('获取模型失败: ' + e.message)
    } finally {
      aiModelsLoading.value = false
    }
  }

  return {
    aiLoading,
    aiSummary,
    mergedInfo,
    aiMergedData,
    aiPrompt,
    aiForced,
    aiBucketMin,
    aiUsageToday,
    aiProvider,
    aiModel,
    aiBaseUrl,
    aiApiKey,
    aiModelList,
    aiModelsLoading,
    prepareAiData,
    buildPrompt,
    openAiSummary,
    fetchAiUsage,
    saveAiConfig,
    onProviderChange,
    fetchModels,
    fmtDuration,
    devCode,
    getDeviceName,
  }
}
