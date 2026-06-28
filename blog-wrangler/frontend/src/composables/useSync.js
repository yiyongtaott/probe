import { computed } from 'vue'
import { chatState } from './useChat'

const DEFAULT_NODES = [
  { id: 'desktop', type: 'desktop' },
  { id: 'notebook', type: 'notebook' },
  { id: 'phone', type: 'phone' },
]

export function useSync() {
  const displayNodes = computed(() => {
    const now = Date.now()
    const nodes = []
    const rawData = chatState.rawData.value
    const defaultIds = DEFAULT_NODES.map(n => n.id)

    DEFAULT_NODES.forEach(def => {
      const deviceId = def.id
      const lastSeenTs = rawData.lastSeen[deviceId] || 0
      let statusText = rawData.devices[deviceId] || '系统离线'
      const extra = rawData.extra[deviceId] || {}

      if (statusText.includes('http')) {
        try { const u = new URL(statusText); statusText = 'Browsing: ' + u.hostname } catch (e) { /* ignore */ }
      }

      nodes.push({
        ...def,
        status: statusText,
        extra,
        isOnline: (now - lastSeenTs) < 600000,
        lastUpdate: rawData.times[deviceId] || '',
      })
    })

    Object.keys(rawData.devices).forEach(deviceId => {
      if (defaultIds.includes(deviceId)) return
      const lastSeenTs = rawData.lastSeen[deviceId] || 0
      if ((now - lastSeenTs) < 259200000) {
        let statusText = rawData.devices[deviceId] || '系统在线'
        if (statusText.includes('http')) {
          try { const u = new URL(statusText); statusText = 'Browsing: ' + u.hostname } catch (e) { /* ignore */ }
        }
        nodes.push({
          id: deviceId,
          type: 'unknown',
          status: statusText,
          extra: rawData.extra[deviceId] || {},
          isOnline: (now - lastSeenTs) < 600000,
          lastUpdate: rawData.times[deviceId] || '',
        })
      }
    })

    return nodes
  })

  return { displayNodes, rawData: chatState.rawData, getDeviceName: chatState.getDeviceName }
}
