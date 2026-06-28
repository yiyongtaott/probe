import { ref, computed, nextTick } from 'vue'
import { formatTime, formatInitLogTime, getCurrentTime, API_BASE, getDeviceName } from '../utils/helpers'

// ── 模块级状态（单例）──
const chatInput = ref('')
const chatMessages = ref([])
const realtimeMessages = ref([])
const hasNewMessages = ref(false)
const newMessageCount = ref(0)
const userScrolledUp = ref(false)
// lastMsgId 每次页面加载从 0 开始：
// 刷新后 = 0 → 全量拉取最新 100 条（按时间戳降序）；之后增量拉取并更新为最新 id
const lastMsgId = ref(0)

// syncAllData 互斥锁：防止并发竞态（定时器 vs 发消息后立即同步）
let _syncing = false
const rawData = ref({ devices: {}, times: {}, lastSeen: {}, extra: {} })
const rawDataTimes = ref({})
const lastSyncTime = ref('')
const onlineCount = ref(1)
const onlineUsers = ref({})

const initLogs = [
  { time: '22:29:52.023', tag: 'SYS',    msg: 'Initializing F&L. Sys Response...',               class: 'log-sys'  },
  { time: '22:29:52.324', tag: 'L-SYS',  msg: 'Daemon thread started. ((守护线程已启动))',          class: 'log-auth' },
  { time: '22:29:52.425', tag: 'SYS',    msg: 'Mounting user volume: /wonderland/FlandreTiamat',  class: 'log-sys'  },
  { time: '22:29:52.824', tag: 'AUTH',   msg: 'Identity Verified. Welcome, Operator.',            class: 'log-auth' },
  { time: '22:29:53.224', tag: 'L-PROTO',msg: 'Link established. The observer (L) is active.',    class: 'log-auth' },
  { time: '22:29:53.525', tag: 'CHAT',   msg: '用户 Operator 加入群聊',                            class: 'log-net'  },
  { time: '22:29:54.026', tag: 'CHAT',   msg: '群聊功能已激活，输入消息后按Enter发送',               class: 'log-sys'  },
]

// ── 日志容器 ref（由 LogTerminal 在 onMounted 时注册，用于自动滚底）──
const logContainerRef = ref(null)

// ── 单例 computed（一个 computed，所有组件共享）──
const combinedMessages = computed(() => {
  // 设备消息的稳定 id 在入队时分配（见 addRealtimeMessage），避免每次重算 key 变化导致整片重渲染
  const deviceMsgs = realtimeMessages.value.map(msg => ({ ...msg, type: 'device' }))
  // 去重：按 chat 消息 id 去重，防止并发导致同一条消息被追加两次
  const seenChatIds = new Set()
  const dedupedChatMsgs = []
  const sortedChatMsgs = [...chatMessages.value]
    .sort((a, b) => (b.timestamp || 0) - (a.timestamp || 0))
    .slice(0, 50)
  for (const msg of sortedChatMsgs) {
    if (msg.id != null && seenChatIds.has(msg.id)) continue
    if (msg.id != null) seenChatIds.add(msg.id)
    dedupedChatMsgs.push({
      ...msg,
      type: 'chat',
      timestamp: msg.timestamp,
    })
  }
  return [...deviceMsgs, ...dedupedChatMsgs]
    .sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0))
    .slice(-100)
})

// ── 同步所有数据（互斥锁防并发竞态）──
async function syncAllData() {
  if (_syncing) return
  _syncing = true
  try {
    const since = lastMsgId.value || 0
    const res = await fetch(API_BASE + '/api/sync?since=' + since)
    if (res.ok) {
      const megaData = await res.json()

      // 设备数据
      const newData = megaData.deviceData
      Object.keys(newData.times || {}).forEach(did => {
        if (newData.times[did] !== rawDataTimes.value[did]) {
          const dName = getDeviceName(did)
          const dStatus = newData.devices[did] || ''
          const displayStatus = dStatus.length > 40 ? dStatus.substring(0, 40) + '...' : dStatus
          addRealtimeMessage({
            tag: 'NET',
            msg: 'Data packet from [' + dName + ']: ' + displayStatus,
            deviceId: did,
            timestamp: Date.now(),
          })
        }
      })
      rawData.value = newData
      rawDataTimes.value = { ...(newData.times || {}) }

      // 聊天消息：首次全量，之后增量追加
      const incoming = megaData.chatHistory || []
      if (since === 0) {
        chatMessages.value = incoming
      } else if (incoming.length) {
        chatMessages.value = [...chatMessages.value, ...incoming]
        if (chatMessages.value.length > 300) chatMessages.value = chatMessages.value.slice(-300)
      }
      if (incoming.length) {
        lastMsgId.value = Math.max(lastMsgId.value, ...incoming.map(m => m.id || 0))
        // 增量消息的滚动/提示逻辑
        if (since > 0) {
          const c = logContainerRef.value
          if (!isAtBottom(c) || userScrolledUp.value) {
            hasNewMessages.value = true
            newMessageCount.value += incoming.length
          } else {
            nextTick(() => { scrollToBottom(c) })
          }
        } else {
          // 首次加载自动滚底
          nextTick(() => { scrollToBottom(logContainerRef.value) })
        }
      }

      // 在线用户
      onlineCount.value = megaData.onlineCount
      onlineUsers.value = megaData.onlineUsers || {}

      lastSyncTime.value = formatTime(Date.now())
    }
  } catch (e) {
    console.warn('[sync] lost, retrying', e)
  } finally {
    _syncing = false
  }
}

// ── 发送消息 ──
async function sendChatMessage(userName, sessionId, isOnline) {
  if (!chatInput.value.trim() || !isOnline) return
  const message = chatInput.value.trim()
  chatInput.value = ''
  try {
    const res = await fetch(API_BASE + '/api/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ user: userName, message, sessionId })
    })
    if (res.ok) await syncAllData()
  } catch (err) {
    console.warn('[chat] 消息发送失败', err)
  }
}

// 设备实时消息入队：在此分配稳定且唯一的 id（用于列表 :key，避免重渲染抖动）
let _rtSeq = 0
function addRealtimeMessage(messageData) {
  realtimeMessages.value.push({ ...messageData, id: 'dev_' + (++_rtSeq) })
  if (realtimeMessages.value.length > 100) realtimeMessages.value.shift()
}

function isAtBottom(container) {
  if (!container) return true
  return container.scrollHeight - (container.scrollTop + container.clientHeight) <= 50
}

function scrollToBottom(container) {
  if (container) {
    container.scrollTop = container.scrollHeight
    hasNewMessages.value = false
    newMessageCount.value = 0
    userScrolledUp.value = false
  }
}

function handleScroll(container) {
  if (!isAtBottom(container)) {
    userScrolledUp.value = true
  } else {
    userScrolledUp.value = false
    hasNewMessages.value = false
    newMessageCount.value = 0
  }
}

function getMessageClass(msg, sessionId) {
  if (msg.type === 'device') return 'log-net'
  if (msg.sessionId === sessionId) return 'log-chat-self'
  if (msg.user === '系统') return 'log-sys'
  return 'log-chat'
}

// ── 导出单例对象（所有组件共享同一个状态和方法）──
export const chatState = {
  // 状态
  chatInput,
  chatMessages,
  combinedMessages,
  realtimeMessages,
  initLogs,
  hasNewMessages,
  newMessageCount,
  userScrolledUp,
  lastMsgId,
  rawData,
  lastSyncTime,
  onlineCount,
  onlineUsers,
  logContainerRef,
  // 方法
  syncAllData,
  sendChatMessage,
  addRealtimeMessage,
  isAtBottom,
  scrollToBottom,
  handleScroll,
  getMessageClass,
  formatTime,
  formatInitLogTime,
  getCurrentTime,
  getDeviceName,
}
