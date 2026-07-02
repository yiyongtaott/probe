/**
 * 浏览器指纹生成器（用于访客去重）
 * 结合 canvas、屏幕、时区、硬件、WebGL 等特征生成稳定指纹
 * 不收集个人数据，仅用浏览器环境特征做去重
 */

let _cachedFingerprint = null

/**
 * 生成浏览器指纹（SHA-256 hex 字符串）
 * 结果在同一浏览器/设备上稳定，换浏览器或换设备会变化
 */
export async function generateFingerprint() {
  if (_cachedFingerprint) return _cachedFingerprint

  const components = []

  // 1. Canvas 指纹 — 不同显卡/字体渲染结果微妙不同
  try {
    const canvas = document.createElement('canvas')
    const ctx = canvas.getContext('2d')
    canvas.width = 220
    canvas.height = 60
    ctx.textBaseline = 'top'
    ctx.font = '16px "Arial"'
    ctx.fillStyle = '#f60'
    ctx.fillRect(0, 0, 220, 60)
    ctx.fillStyle = '#069'
    ctx.fillText('FLandre.Sys 🔍 probe', 2, 2)
    ctx.fillStyle = 'rgba(102, 204, 0, 0.7)'
    ctx.fillText('FLandre.Sys 🔍 probe', 4, 4)
    ctx.beginPath()
    ctx.arc(180, 30, 20, 0, Math.PI * 2)
    ctx.fill()
    components.push('canvas:' + canvas.toDataURL().slice(0, 256))
  } catch {
    components.push('canvas:err')
  }

  // 2. 屏幕特征
  components.push('scr:' + [
    window.screen.width,
    window.screen.height,
    window.screen.colorDepth,
    window.screen.pixelDepth,
    window.devicePixelRatio || 1,
  ].join(','))

  // 3. 时区
  try {
    components.push('tz:' + Intl.DateTimeFormat().resolvedOptions().timeZone)
  } catch {
    components.push('tz:err')
  }

  // 4. 语言
  components.push('lang:' + (navigator.language || '') + '|' + ((navigator.languages || []).join(',')))

  // 5. 平台
  components.push('plat:' + (navigator.platform || ''))

  // 6. 硬件并发
  components.push('cpu:' + (navigator.hardwareConcurrency || 0))

  // 7. 设备内存
  components.push('mem:' + (navigator.deviceMemory || 0))

  // 8. User-Agent
  components.push('ua:' + (navigator.userAgent || ''))

  // 9. WebGL 渲染器（显卡型号）
  try {
    const gl = document.createElement('canvas').getContext('webgl')
    if (gl) {
      const ext = gl.getExtension('WEBGL_debug_renderer_info')
      if (ext) {
        components.push('gl:' + gl.getParameter(ext.UNMASKED_RENDERER_WEBGL))
      }
    }
  } catch {
    /* ignore */
  }

  // 10. 触摸支持
  components.push('touch:' + ('ontouchstart' in window ? '1' : '0') + ':' + (navigator.maxTouchPoints || 0))

  // 11. 连接类型
  try {
    components.push('net:' + (navigator.connection?.effectiveType || ''))
  } catch {
    /* ignore */
  }

  // 用 SubtleCrypto SHA-256 哈希所有特征
  const str = components.join('||')
  const encoder = new TextEncoder()
  const data = encoder.encode(str)
  const hashBuffer = await crypto.subtle.digest('SHA-256', data)
  const hashArray = Array.from(new Uint8Array(hashBuffer))
  _cachedFingerprint = hashArray.map(b => b.toString(16).padStart(2, '0')).join('')
  return _cachedFingerprint
}
