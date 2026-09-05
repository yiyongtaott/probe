import { ref } from 'vue'
import { API_BASE, BABY_DEVICE_ID } from '../utils/helpers'

const authUser = ref(localStorage.getItem('fl_auth_user') || 'FlandreTiamat')
const authPass = ref('')
const authToken = ref(localStorage.getItem('fl_auth_token') || '')
const authName = ref(localStorage.getItem('fl_auth_name') || '')
const authDevice = ref(localStorage.getItem('fl_auth_device') || '')
const authLoading = ref(false)
const authStatus = ref('')

// ── 模块级共享：其他 composable / 组件直接使用，避免重复定义 ──
export function authHeaders() {
  return authToken.value ? { Authorization: 'Bearer ' + authToken.value } : {}
}

export function isLoggedIn() {
  return !!authToken.value
}

export function authState() {
  return { authToken, authName, authDevice }
}

export function useAuth() {
  function applyDevice(device) {
    const name = (device && (device.name || device.id)) || BABY_DEVICE_ID
    authDevice.value = name
    localStorage.setItem('fl_auth_device', name)
  }

  function applyAiProfile(profile, aiComposable) {
    if (!profile || !aiComposable) return
    aiComposable.aiProvider.value = profile.provider || aiComposable.aiProvider.value
    aiComposable.aiBaseUrl.value = profile.baseUrl || aiComposable.aiBaseUrl.value
    aiComposable.aiApiKey.value = profile.apiKey || ''
    aiComposable.aiModel.value = profile.model || aiComposable.aiModel.value
    aiComposable.saveAiConfig()
    if (aiComposable.aiMergedData.value) {
      aiComposable.buildPrompt(aiComposable.aiMergedData.value.devices || [])
    }
  }

  async function restoreLogin(aiComposable) {
    if (!authToken.value) return
    try {
      const res = await fetch(API_BASE + '/api/user/ai-config', { headers: authHeaders() })
      if (!res.ok) throw new Error('登录已过期')
      const data = await res.json()
      authName.value = data.username || ''
      localStorage.setItem('fl_auth_name', authName.value)
      if (data.device) applyDevice(data.device)
      if (aiComposable) applyAiProfile(data.profile, aiComposable)
      authStatus.value = '已恢复账号配置'
    } catch (e) {
      authToken.value = ''
      authName.value = ''
      authDevice.value = ''
      localStorage.removeItem('fl_auth_token')
      localStorage.removeItem('fl_auth_name')
      localStorage.removeItem('fl_auth_device')
      authStatus.value = '登录已过期'
    }
  }

  async function login(aiComposable) {
    authLoading.value = true
    authStatus.value = ''
    try {
      const res = await fetch(API_BASE + '/api/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: authUser.value, password: authPass.value }),
      })
      const data = await res.json()
      if (!res.ok) throw new Error(data.error || '登录失败')
      authToken.value = data.token
      authName.value = data.username
      authPass.value = ''
      localStorage.setItem('fl_auth_token', authToken.value)
      localStorage.setItem('fl_auth_user', authUser.value)
      localStorage.setItem('fl_auth_name', authName.value)
      if (data.device) applyDevice(data.device)
      if (aiComposable) applyAiProfile(data.profile, aiComposable)
      authStatus.value = '已加载账号配置'
    } catch (e) {
      authStatus.value = '登录失败：' + e.message
    } finally {
      authLoading.value = false
    }
  }

  async function logout() {
    try {
      await fetch(API_BASE + '/api/auth/logout', { method: 'POST', headers: authHeaders() })
    } catch (e) { /* ignore */ }
    authToken.value = ''
    authName.value = ''
    authDevice.value = ''
    localStorage.removeItem('fl_auth_token')
    localStorage.removeItem('fl_auth_name')
    localStorage.removeItem('fl_auth_device')
    authStatus.value = '已退出，将使用本机配置'
  }

  return {
    authUser,
    authPass,
    authToken,
    authName,
    authDevice,
    authLoading,
    authStatus,
    authHeaders,
    applyAiProfile,
    restoreLogin,
    login,
    logout,
  }
}
