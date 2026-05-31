package com.flandre;

import com.sun.jna.Native;
import com.sun.jna.platform.win32.User32;
import com.sun.jna.platform.win32.WinDef.HWND;

import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

public class UltraLightProbe {
    //http://9.3.0.1.9.1.0.0.0.7.4.0.1.0.0.2.ip6.arpa/
    //https://9.3.0.1.9.1.0.0.0.7.4.0.1.0.0.2.ip6.arpa/api/report/
    //http://127.0.0.1:8085/api/report/
    // 配置：Monitoring 服务器的地址和本设备 ID
    private static final String SERVER_URL = "http://9.3.0.1.9.1.0.0.0.7.4.0.1.0.0.2.ip6.arpa/api/report/"; // 记得换成你笔记本的虚拟 IP
    private static final String DEVICE_ID = "notebook"; // 每个设备手动改这个名字

    public static void main(String[] args) {
        System.out.println("Probe 启动成功，正在监控中...");

        String lastTitle = "";
        int time=0;
        while (true) {
            try {
                time++;
                // 1. 获取窗口标题
                String currentTitle = getActiveWindowTitle();
                if (currentTitle.equals("")){
                    currentTitle = "正在选择同类型窗口";
                }
                // 2. 只有状态变了才发送（减少无效网络请求）
                //强制30分钟发一次
                if (!currentTitle.equals(lastTitle)||time>20*30) {
                    time=0;
                    sendData(currentTitle);
                    lastTitle = currentTitle;
                    System.out.println("已发送: " + currentTitle);
                }

                // 3. 休眠 3 秒（采集频率）
                Thread.sleep(3000);
            } catch (Exception e) {
                System.err.println("发生错误: " + e.getMessage());
            }
        }
    }

    private static String getActiveWindowTitle() {
        HWND hwnd = User32.INSTANCE.GetForegroundWindow();
        if (hwnd == null) return "Desktop";
        char[] windowText = new char[512];
        User32.INSTANCE.GetWindowText(hwnd, windowText, 512);
        return Native.toString(windowText);
    }

    private static void sendData(String status) {
        try {
            // 注意：这里拼凑的是 /{deviceId} 路径
            URL url = new URL(SERVER_URL + DEVICE_ID);
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setDoOutput(true);
            conn.setRequestProperty("Content-Type", "text/plain; charset=UTF-8");

            try (OutputStream os = conn.getOutputStream()) {
                byte[] input = status.getBytes(StandardCharsets.UTF_8);
                os.write(input, 0, input.length);
            }

            // 获取响应码（触发请求发送）
            int code = conn.getResponseCode();
            conn.disconnect();
        } catch (Exception e) {
            System.err.println("数据发送失败，请检查 Monitoring 是否在线");
            // 关键：把堆栈打印出来，这样我们才知道 exe 里到底缺什么
            e.printStackTrace();
            System.err.println("错误详情: " + e.toString());
        }
    }
}
