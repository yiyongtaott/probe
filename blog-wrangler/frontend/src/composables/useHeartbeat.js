import { ref, computed } from 'vue'
import { API_BASE, generateSessionId } from '../utils/helpers'
import { chatState } from './useChat'

const sessionId = ref(localStorage.getItem('fl_session_id') || generateSessionId())
const userName = ref(localStorage.getItem('fl_chat_name') || 'Operator')
const isOnline = ref(false)

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
      const res = await fetch(API_BASE + '/api/heartbeat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ sessionId: sessionId.value, userName: userName.value }),
      })
      if (res.ok) {
        const data = await res.json()
        chatState.onlineCount.value = data.onlineCount
        if (data.onlineUsers) chatState.onlineUsers.value = data.onlineUsers
        isOnline.value = true
      }
    } catch (err) {
      isOnline.value = false
    }
  }

  return {
    sessionId,
    userName,
    isOnline,
    onlineCount: chatState.onlineCount,
    onlineUserList,
    saveUserName,
    sendHeartbeat,
  }
}
