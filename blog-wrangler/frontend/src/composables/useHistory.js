import { ref } from 'vue'
import { API_BASE, fmtHistoryDuration, BABY_DEVICE_ID, DEFAULT_PUBLIC_DEVICES } from '../utils/helpers'
import { authHeaders } from './useAuth'

// 已登录（本地已有 token）时默认把私有设备（宝宝手机）一并选中
function defaultHistoryDevices() {
  const base = [...DEFAULT_PUBLIC_DEVICES]
  if (localStorage.getItem('fl_auth_token')) base.push(BABY_DEVICE_ID)
  return base
}

const historyPanelOpen = ref(true)
const historyDevices = ref(defaultHistoryDevices())
const historyRange = ref('86400000')
const historyRows = ref([])
const historyLoading = ref(false)
const historyPageSize = ref(80)
const historyCursor = ref(null)
const historyNextCursor = ref(null)
const historyCursorStack = ref([])
const historyPage = ref(1)
const historyDone = ref(true)
const historyQueryStart = ref(0)
const historyQueryEnd = ref(0)

export function useHistory() {
  async function loadHistory(reset = true) {
    if (historyDevices.value.length === 0) return
    if (reset !== false) {
      historyQueryEnd.value = Date.now()
      historyQueryStart.value = historyQueryEnd.value - parseInt(historyRange.value, 10)
      historyCursor.value = null
      historyNextCursor.value = null
      historyCursorStack.value = []
      historyPage.value = 1
      historyDone.value = true
    }
    historyLoading.value = true
    try {
      const params = new URLSearchParams({
        device: historyDevices.value.join(','),
        start: String(historyQueryStart.value),
        end: String(historyQueryEnd.value),
        pageSize: String(historyPageSize.value),
      })
      if (historyCursor.value) {
        params.set('cursorTs', String(historyCursor.value.ts))
        params.set('cursorId', String(historyCursor.value.id))
      }
      const res = await fetch(API_BASE + '/api/history?' + params.toString(), { headers: authHeaders() })
      if (!res.ok) throw new Error('HTTP ' + res.status)
      const data = await res.json()
      historyRows.value = data.history || []
      historyDone.value = !!data.done
      historyNextCursor.value = data.nextTs ? { ts: data.nextTs, id: data.nextId || 0 } : null
      return data
    } catch (e) {
      console.error('loadHistory error:', e)
      historyRows.value = []
      return null
    } finally {
      historyLoading.value = false
    }
  }

  return {
    historyPanelOpen,
    historyDevices,
    historyRange,
    historyRows,
    historyLoading,
    historyPageSize,
    historyCursor,
    historyNextCursor,
    historyCursorStack,
    historyPage,
    historyDone,
    historyQueryStart,
    historyQueryEnd,
    loadHistory,
    fmtHistoryDuration,
  }
}
