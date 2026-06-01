package com.flandre;

import com.sun.jna.Native;
import com.sun.jna.platform.win32.User32;
import com.sun.jna.platform.win32.WinDef.HWND;
import com.sun.jna.platform.win32.Kernel32;
import com.sun.jna.platform.win32.WinBase;
import com.sun.jna.ptr.IntByReference;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Enumeration;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

public class UltraLightProbe {
    private static final String SERVER_URL = "http://9.3.0.1.9.1.0.0.0.7.4.0.1.0.0.2.ip6.arpa/api/report/";
    private static final String DEVICE_ID = "notebook";

    // ── 缓存字段（每 5 分钟刷新一次，避免高频系统调用）──
    private static volatile String cachedLanIp   = "unknown";
    private static volatile String cachedWifiSsid = "unknown";
    private static volatile String cachedBattery = "unknown";
    private static volatile long   cacheTimestamp = 0;
    private static final long      CACHE_TTL_MS   = 5 * 60 * 1000; // 5 分钟

    public static void main(String[] args) {
        System.out.println("Probe 启动成功，正在监控中...");

        // 后台定时刷新慢速信息（不阻塞主循环）
        ScheduledExecutorService scheduler = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "probe-cache-refresher");
            t.setDaemon(true);
            return t;
        });
        scheduler.scheduleAtFixedRate(UltraLightProbe::refreshSlowCache, 0, 5, TimeUnit.MINUTES);

        String lastPayload = "";
        int    forceCount  = 0;

        while (true) {
            try {
                forceCount++;
                String windowTitle = getActiveWindowTitle();
                String payload = buildPayload(windowTitle);

                // 状态变化 或 每 30 分钟强制上报一次
                if (!payload.equals(lastPayload) || forceCount > 20 * 30) {
                    forceCount = 0;
                    sendData(payload);
                    lastPayload = payload;
                    System.out.println("已发送: " + payload);
                }

                Thread.sleep(3000);
            } catch (Exception e) {
                System.err.println("发生错误: " + e.getMessage());
            }
        }
    }

    // ── 构建 JSON payload ─────────────────────────────────────────────────────
    private static String buildPayload(String windowTitle) {
        // 读缓存（主线程只做轻量操作）
        String lanIp    = cachedLanIp;
        String wifi     = cachedWifiSsid;
        String battery  = cachedBattery;

        // 简单 JSON 拼接，不引入额外依赖
        String title = windowTitle.replace("\\", "\\\\").replace("\"", "\\\"");
        wifi    = wifi.replace("\\", "\\\\").replace("\"", "\\\"");
        return String.format(
                "{\"window\":\"%s\",\"lan\":\"%s\",\"wifi\":\"%s\",\"battery\":\"%s\"}",
                title, lanIp, wifi, battery
        );
    }

    // ── 窗口标题检测（修复 Win+Tab / 任务栏悬停问题）────────────────────────
    private static String getActiveWindowTitle() {
        HWND hwnd = User32.INSTANCE.GetForegroundWindow();
        if (hwnd == null) return "桌面";

        char[] windowText = new char[512];
        int len = User32.INSTANCE.GetWindowText(hwnd, windowText, 512);

        // 有实际文本内容
        if (len > 0) {
            String title = new String(windowText, 0, len).trim();
            if (!title.isEmpty()) return title;
        }

        // 标题为空时：尝试通过进程名识别系统界面
        // 获取该窗口所属进程 ID
        IntByReference pidRef = new IntByReference();
        User32.INSTANCE.GetWindowThreadProcessId(hwnd, pidRef);
        int pid = pidRef.getValue();
        String processName = getProcessName(pid);

        // 根据进程名映射到友好名称
        if (processName != null) {
            String lp = processName.toLowerCase();
            if (lp.contains("explorer"))     return "任务栏 / 文件资源管理器";
            if (lp.contains("searchhost") ||
                    lp.contains("searchui"))     return "Windows 搜索";
            if (lp.contains("taskview") ||
                    lp.contains("multitasking")) return "任务视图 (Win+Tab)";
            if (lp.contains("shellexperiencehost")) return "开始菜单 / 操作中心";
            if (lp.contains("applicationframehost")) return "UWP 应用框架";
            if (lp.contains("winstore"))     return "Microsoft Store";
            if (lp.contains("lockapp"))      return "锁屏界面";
            if (!processName.isEmpty())      return "系统: " + processName;
        }

        // 最终保底
        return "正在选择同类型窗口";
    }

    /** 通过 PID 获取进程名（仅取 exe 文件名，不读完整路径，开销极小） */
    private static String getProcessName(int pid) {
        try {
            // 使用 tasklist 过滤，只拿进程名，不解析完整路径
            Process p = Runtime.getRuntime().exec(
                    new String[]{"tasklist", "/fi", "pid eq " + pid, "/fo", "csv", "/nh"}
            );
            try (BufferedReader br = new BufferedReader(
                    new InputStreamReader(p.getInputStream(), "GBK"))) {
                String line = br.readLine();
                if (line != null && line.startsWith("\"")) {
                    // 格式: "explorer.exe","1234",...
                    return line.split(",")[0].replace("\"", "");
                }
            }
            p.destroy();
        } catch (Exception ignored) {}
        return null;
    }

    // ── 慢速缓存刷新（每 5 分钟后台执行，主循环不感知）──────────────────────
    private static void refreshSlowCache() {
        try {
            cachedLanIp    = getLanIp();
            cachedWifiSsid = getWifiSsid();
            cachedBattery  = getBatteryInfo();
            cacheTimestamp = System.currentTimeMillis();
        } catch (Exception e) {
            System.err.println("缓存刷新失败: " + e.getMessage());
        }
    }

    /** 获取局域网 IP（跳过 loopback 和虚拟网卡，取第一个活跃的 IPv4） */
    private static String getLanIp() {
        try {
            Enumeration<NetworkInterface> interfaces = NetworkInterface.getNetworkInterfaces();
            while (interfaces.hasMoreElements()) {
                NetworkInterface ni = interfaces.nextElement();
                // 跳过: 未启动、loopback、虚拟网卡
                if (!ni.isUp() || ni.isLoopback() || ni.isVirtual()) continue;
                String name = ni.getName().toLowerCase();
                // 跳过常见虚拟网卡前缀
                if (name.contains("vmware") || name.contains("vbox") ||
                        name.contains("hamachi") || name.contains("docker")) continue;

                Enumeration<InetAddress> addresses = ni.getInetAddresses();
                while (addresses.hasMoreElements()) {
                    InetAddress addr = addresses.nextElement();
                    String ip = addr.getHostAddress();
                    // 只取 IPv4，排除 loopback
                    if (!addr.isLoopbackAddress() && ip.contains(".") && !ip.startsWith("169.254")) {
                        return ip;
                    }
                }
            }
        } catch (Exception ignored) {}
        return "unknown";
    }

    /** 获取 WiFi SSID（通过 netsh，轻量、无需额外依赖） */
    private static String getWifiSsid() {
        try {
            Process p = Runtime.getRuntime().exec("netsh wlan show interfaces");
            try (BufferedReader br = new BufferedReader(
                    new InputStreamReader(p.getInputStream(), "GBK"))) {
                String line;
                while ((line = br.readLine()) != null) {
                    line = line.trim();
                    // 英文系统: "SSID" 行，中文系统: "SSID" 相同
                    if (line.startsWith("SSID") && !line.startsWith("BSSID")) {
                        String[] parts = line.split(":", 2);
                        if (parts.length == 2) {
                            String ssid = parts[1].trim();
                            if (!ssid.isEmpty()) return ssid;
                        }
                    }
                }
            }
            p.destroy();
        } catch (Exception ignored) {}
        return "未连接";
    }

    /** 获取电池信息（通过 WMIC，一次调用开销很小） */
    private static String getBatteryInfo() {
        try {
            Process p = Runtime.getRuntime().exec(
                    "wmic path Win32_Battery get EstimatedChargeRemaining,BatteryStatus /format:csv"
            );
            try (BufferedReader br = new BufferedReader(
                    new InputStreamReader(p.getInputStream(), "GBK"))) {
                String line;
                while ((line = br.readLine()) != null) {
                    line = line.trim();
                    if (line.isEmpty() || line.startsWith("Node")) continue;
                    // 格式: Node,BatteryStatus,EstimatedChargeRemaining
                    String[] parts = line.split(",");
                    if (parts.length >= 3) {
                        String statusCode = parts[1].trim();
                        String pct        = parts[2].trim();
                        if (pct.isEmpty()) return "未检测到电池";

                        // BatteryStatus: 1=放电中, 2=交流供电, 3=满电, 其他=充电中
                        String statusLabel;
                        switch (statusCode) {
                            case "1": statusLabel = "放电中"; break;
                            case "2": statusLabel = "充电中"; break;
                            case "3": statusLabel = "已充满"; break;
                            default:  statusLabel = "充电中"; break;
                        }
                        return pct + "% · " + statusLabel;
                    }
                }
            }
            p.destroy();
        } catch (Exception ignored) {}
        return "未检测到电池";
    }

    // ── 数据发送 ──────────────────────────────────────────────────────────────
    private static void sendData(String payload) {
        try {
            URL url = new URL(SERVER_URL + DEVICE_ID);
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setDoOutput(true);
            conn.setConnectTimeout(5000);
            conn.setReadTimeout(5000);
            conn.setRequestProperty("Content-Type", "application/json; charset=UTF-8");

            try (OutputStream os = conn.getOutputStream()) {
                os.write(payload.getBytes(StandardCharsets.UTF_8));
            }

            int code = conn.getResponseCode();
            conn.disconnect();
        } catch (Exception e) {
            System.err.println("数据发送失败，请检查 Monitoring 是否在线");
            e.printStackTrace();
        }
    }
}