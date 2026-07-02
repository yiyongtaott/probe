import { ref, computed } from 'vue'
import { API_BASE, generateSessionId } from '../utils/helpers'
import { generateFingerprint } from '../utils/fingerprint'
import { chatState } from './useChat'

const sessionId = ref(localStorage.getItem('fl_session_id') || generateSessionId())
const userName = ref(localStorage.getItem('fl_chat_name') || 'Operator')
const isOnline = ref(false)

// 访客统计状态（单例）
const visitorStats = ref({
  totalVisitors: 0,
  totalVisits: 0,
  todayVisitors: 0,
  todayVisits: 0,
  dailyHistory: [],
  recentVisitors: [],
})

// 缓存的浏览器指纹（异步生成一次）
let _fingerprint = null
// 访客统计刷新节流：首次心跳后立即拉取，之后每 5 分钟刷新一次
let _lastStatsFetch = 0
const STATS_FETCH_INTERVAL = 5 * 60 * 1000
async function getFingerprint() {
  if (!_fingerprint) {
    try { _fingerprint = await generateFingerprint() } catch { _fingerprint = '' }
  }
  return _fingerprint
}

if (!localStorage.getItem('fl_session_id')) {
  localStorage.setItem('fl_session_id', sessionId.value)
}

export function useHeartbeat() {
  const onlineUserList = computed(() => {
    return Object.entries(chatState.onlineUsers.value).map(([sid, u]) => ({
      sessionId: sid,
      userName: u.userName,
      ip: u.ip || 'unknown',
      lastSeen: u.lastSeen,
    })).sort((a, b) => b.lastSeen - a.lastSeen)
  })

  function saveUserName() {
    localStorage.setItem('fl_chat_name', userName.value)
    sendHeartbeat()
  }

  async function sendHeartbeat() {
    try {
      const fp = await getFingerprint()
      const res = await fetch(API_BASE + '/api/heartbeat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ sessionId: sessionId.value, userName: userName.value, fingerprint: fp }),
      })
      if (res.ok) {
        const data = await res.json()
        chatState.onlineCount.value = data.onlineCount
        if (data.onlineUsers) chatState.onlineUsers.value = data.onlineUsers
        isOnline.value = true
        // 首次心跳后立即拉取访客统计；之后每 5 分钟刷新一次（节流，避免每 30s 心跳都拉）
        const now = Date.now()
        if (now - _lastStatsFetch > STATS_FETCH_INTERVAL) {
          _lastStatsFetch = now
          fetchVisitorStats()
        }
      }
    } catch (err) {
      isOnline.value = false
    }
  }

  async function fetchVisitorStats() {
    try {
      const res = await fetch(API_BASE + '/api/visitor-stats')
      if (res.ok) {
        visitorStats.value = await res.json()
      }
    } catch (err) {
      /* 静默失败 */
    }
  }

  return {
    sessionId,
    userName,
    isOnline,
    onlineCount: chatState.onlineCount,
    onlineUserList,
    visitorStats,
    saveUserName,
    sendHeartbeat,
    fetchVisitorStats,
  }
}
