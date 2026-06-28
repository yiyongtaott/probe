/** @type {import('tailwindcss').Config} */
export default {
  content: [
    './index.html',
    './src/**/*.{vue,js}',
  ],
  // 不覆盖核心插件 —— 只用 Tailwind 的 utility classes
  corePlugins: {
    preflight: true,
  },
}
