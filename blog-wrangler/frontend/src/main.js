import { createApp } from 'vue'
import App from './App.vue'
import './styles/custom.css'

// 全局错误捕获：将 Vue 渲染错误显示在页面上，方便定位
const app = createApp(App)

app.config.errorHandler = (err, instance, info) => {
  console.error('[Vue Error]', err, info)
  const fb = document.getElementById('boot-fallback') || document.createElement('div')
  fb.id = 'boot-fallback'
  fb.style.cssText = 'position:fixed;top:0;left:0;right:0;padding:20px;background:#1a1a2e;color:#e74c3c;font-family:monospace;font-size:14px;z-index:99999;white-space:pre-wrap;border-bottom:3px solid #e74c3c'
  fb.textContent = '🛑 Vue Error: ' + (err?.message || String(err)) + '\nInfo: ' + (info || '') + '\n\n查看 DevTools Console (F12) 获取详细信息'
  document.body.prepend(fb)
}

// 全局未捕获 Promise 错误
window.addEventListener('unhandledrejection', (event) => {
  console.error('[Unhandled Rejection]', event.reason)
})

app.mount('#app')

const bootFallback = document.getElementById('boot-fallback')
if (bootFallback) bootFallback.remove()
