import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  // 开发时代理 /api → wrangler dev (localhost:8787)
  server: {
    proxy: {
      '/api': {
        target: 'http://localhost:8787',
        changeOrigin: true,
      },
    },
  },
  // 构建产物到 dist/
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
})
