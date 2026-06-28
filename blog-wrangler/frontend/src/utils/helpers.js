/**
 * 格式化时间戳为本地时间字符串 (yyyy/mm/dd HH:mm:ss)
 */
export function formatTime(timestamp) {
  if (!timestamp) return ''
  const date = new Date(timestamp)
  const y = date.getFullYear()
  const m = String(date.getMonth() + 1).padStart(2, '0')
  const d = String(date.getDate()).padStart(2, '0')
  const h = String(date.getHours()).padStart(2, '0')
  const mi = String(date.getMinutes()).padStart(2, '0')
  const s = String(date.getSeconds()).padStart(2, '0')
  return `${y}/${m}/${d} ${h}:${mi}:${s}`
}

/**
 * 为初始化日志生成时间（用今天日期 + 固定时间字符串）
 */
export function formatInitLogTime(timeStr) {
  const today = new Date()
  const y = today.getFullYear()
  const m = String(today.getMonth() + 1).padStart(2, '0')
  const d = String(today.getDate()).padStart(2, '0')
  return `${y}/${m}/${d} ${timeStr}`
}

/**
 * 获取当前格式化时间
 */
export function getCurrentTime() {
  return formatTime(Date.now())
}

/**
 * 格式化持续时长 (ms → 可读字符串)
 */
export function fmtDuration(ms) {
  ms = ms || 0
  const s = Math.round(ms / 1000)
  if (s < 60) return s + 's'
  const m = Math.round(s / 60)
  if (m < 60) return m + 'm'
  const h = Math.floor(m / 60)
  return h + 'h' + (m % 60) + 'm'
}

/**
 * 格式化历史记录中的持续时长（中文）
 */
export function fmtHistoryDuration(row) {
  if (!row) return '持续 0 秒'
  let ms = Number(row.duration_ms || 0)
  if (!ms && row.started_at && row.recorded_at) {
    ms = Math.max(0, Number(row.recorded_at) - Number(row.started_at))
  }
  const totalSeconds = Math.max(0, Math.round(ms / 1000))
  if (totalSeconds < 60) return '持续 ' + totalSeconds + ' 秒'
  const minutes = Math.floor(totalSeconds / 60)
  const seconds = totalSeconds % 60
  if (minutes < 60) return seconds ? ('持续 ' + minutes + ' 分 ' + seconds + ' 秒') : ('持续 ' + minutes + ' 分钟')
  const hours = Math.floor(minutes / 60)
  const remainMinutes = minutes % 60
  return remainMinutes ? ('持续 ' + hours + ' 小时 ' + remainMinutes + ' 分钟') : ('持续 ' + hours + ' 小时')
}

/**
 * 设备名称映射
 */
export function getDeviceName(id) {
  const map = { desktop: '台式电脑', notebook: '笔记本电脑', phone: '手机' }
  return map[id] || (id && id.length > 10 ? id.substring(0, 8) + '...' : id || '未知')
}

/**
 * 设备代号（单字，用于 AI prompt 紧凑表示）
 */
export function devCode(id) {
  return ({ desktop: '台', notebook: '笔', phone: '机' })[id] || id
}

/**
 * 随机生成 session ID
 */
export function generateSessionId() {
  return 'sess_' + Date.now() + '_' + Math.random().toString(36).substring(2, 11)
}

export const API_BASE = window.location.origin
