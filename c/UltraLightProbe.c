/*
 * UltraLightProbe — native Win32 rewrite.
 * Replaces the Java/JNA/GraalVM build: no reflection (kills the IntByReference
 * crash), no subprocesses (tasklist/netsh/wmic gone), no GC. Flat ~1-2 MB RAM.
 */
#define _WIN32_WINNT 0x0601
#define WIN32_LEAN_AND_MEAN
#define _CRT_SECURE_NO_WARNINGS

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <wlanapi.h>
#include <winhttp.h>
#include <wchar.h>
#include <wctype.h>
#include <string.h>
#include <stdlib.h>

#ifdef CONSOLE_BUILD
#include <stdio.h>
#include <io.h>
#include <fcntl.h>
#define LOGW(...) do { wprintf(__VA_ARGS__); fflush(stdout); } while (0)
#else
#define LOGW(...) ((void)0)
#endif

#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "wlanapi.lib")
#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "user32.lib")

/* ── Configuration (single source of truth) ─────────────────────────────── */
#define DEVICE_ID          L"notebook"
#define SERVER_HOST        L"9.3.0.1.9.1.0.0.0.7.4.0.1.0.0.2.ip6.arpa"
#define SERVER_PORT        ((INTERNET_PORT)80)
#define SERVER_PATH        L"/api/report/" DEVICE_ID
#define POLL_MS            3000
#define FORCE_TICKS        600   /* 600 * 3s = 30 min forced re-send */
#define SLOW_REFRESH_TICKS 100   /* 100 * 3s = 5 min slow-cache refresh */

/* ── Buffers (single-threaded: globals/statics, zero per-tick heap churn) ── */
#define TITLE_CAP   1024
#define PAYLOAD_CAP 4096
#define BODY_CAP    16384

static wchar_t g_lan[64]      = L"unknown";
static wchar_t g_wifi[128]    = L"unknown";
static wchar_t g_battery[64]  = L"unknown";
static HINTERNET g_hSession   = NULL;

/* ── small helpers ──────────────────────────────────────────────────────── */
static void copy_w(wchar_t *dst, size_t cap, const wchar_t *src) {
    if (cap == 0) return;
    wcsncpy(dst, src, cap - 1);
    dst[cap - 1] = L'\0';
}

static void to_lower_w(const wchar_t *src, wchar_t *dst, size_t cap) {
    size_t i = 0;
    for (; src[i] && i < cap - 1; i++) dst[i] = (wchar_t)towlower(src[i]);
    dst[i] = L'\0';
}

/* Escape backslash and double-quote for JSON string context. */
static void json_escape_w(const wchar_t *in, wchar_t *out, size_t cap) {
    size_t o = 0;
    for (size_t i = 0; in[i] && o + 2 < cap; i++) {
        if (in[i] == L'\\' || in[i] == L'"') out[o++] = L'\\';
        out[o++] = in[i];
    }
    out[o] = L'\0';
}

/* ── process name by PID (no tasklist subprocess) ───────────────────────── */
static BOOL get_process_name(DWORD pid, wchar_t *out, size_t cap) {
    if (pid == 0) return FALSE;
    HANDLE hp = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!hp) return FALSE;
    wchar_t path[MAX_PATH];
    DWORD sz = MAX_PATH;
    BOOL ok = QueryFullProcessImageNameW(hp, 0, path, &sz);
    CloseHandle(hp);
    if (!ok) return FALSE;
    const wchar_t *base = wcsrchr(path, L'\\');
    base = base ? base + 1 : path;
    copy_w(out, cap, base);
    return out[0] != L'\0';
}

/* ── foreground window title (no JNA, no IntByReference) ─────────────────── */
static void get_window_title(wchar_t *out, size_t cap) {
    HWND h = GetForegroundWindow();
    if (!h) { copy_w(out, cap, L"桌面"); return; }

    wchar_t buf[512];
    int len = GetWindowTextW(h, buf, 512);
    if (len > 0) {
        int s = 0, e = len - 1;
        while (s <= e && iswspace(buf[s])) s++;
        while (e >= s && iswspace(buf[e])) e--;
        if (e >= s) {
            buf[e + 1] = L'\0';
            copy_w(out, cap, buf + s);
            return;
        }
    }

    /* Empty title: identify shell surfaces by process name. */
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    wchar_t name[MAX_PATH];
    if (get_process_name(pid, name, MAX_PATH)) {
        wchar_t lp[MAX_PATH];
        to_lower_w(name, lp, MAX_PATH);
        if (wcsstr(lp, L"explorer"))             { copy_w(out, cap, L"任务栏 / 文件资源管理器"); return; }
        if (wcsstr(lp, L"searchhost") ||
            wcsstr(lp, L"searchui"))             { copy_w(out, cap, L"Windows 搜索"); return; }
        if (wcsstr(lp, L"taskview") ||
            wcsstr(lp, L"multitasking"))         { copy_w(out, cap, L"任务视图 (Win+Tab)"); return; }
        if (wcsstr(lp, L"shellexperiencehost"))  { copy_w(out, cap, L"开始菜单 / 操作中心"); return; }
        if (wcsstr(lp, L"applicationframehost")) { copy_w(out, cap, L"UWP 应用框架"); return; }
        if (wcsstr(lp, L"winstore"))             { copy_w(out, cap, L"Microsoft Store"); return; }
        if (wcsstr(lp, L"lockapp"))              { copy_w(out, cap, L"锁屏界面"); return; }
        swprintf(out, cap, L"系统: %ls", name);
        return;
    }
    copy_w(out, cap, L"正在选择同类型窗口");
}

/* ── LAN IPv4 (no NetworkInterface; GetAdaptersAddresses) ───────────────── */
static BOOL adapter_is_virtual(PIP_ADAPTER_ADDRESSES aa) {
    wchar_t lp[512];
    const wchar_t *toks[] = { L"vmware", L"virtualbox", L"vbox", L"hyper-v",
                              L"hamachi", L"docker", L"virtual", L"loopback" };
    const wchar_t *fields[2] = { aa->FriendlyName, aa->Description };
    for (int f = 0; f < 2; f++) {
        if (!fields[f]) continue;
        to_lower_w(fields[f], lp, 512);
        for (int t = 0; t < (int)(sizeof(toks) / sizeof(toks[0])); t++)
            if (wcsstr(lp, toks[t])) return TRUE;
    }
    return FALSE;
}

static void get_lan_ip(wchar_t *out, size_t cap) {
    static unsigned char sbuf[16384];
    ULONG flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
    ULONG size = sizeof(sbuf);
    PIP_ADAPTER_ADDRESSES base = (PIP_ADAPTER_ADDRESSES)sbuf;
    void *heap = NULL;

    DWORD r = GetAdaptersAddresses(AF_INET, flags, NULL, base, &size);
    if (r == ERROR_BUFFER_OVERFLOW) {
        heap = malloc(size);
        if (!heap) { copy_w(out, cap, L"unknown"); return; }
        base = (PIP_ADAPTER_ADDRESSES)heap;
        r = GetAdaptersAddresses(AF_INET, flags, NULL, base, &size);
    }
    if (r != NO_ERROR) { if (heap) free(heap); copy_w(out, cap, L"unknown"); return; }

    for (PIP_ADAPTER_ADDRESSES aa = base; aa; aa = aa->Next) {
        if (aa->OperStatus != IfOperStatusUp) continue;
        if (aa->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
        if (adapter_is_virtual(aa)) continue;
        for (PIP_ADAPTER_UNICAST_ADDRESS ua = aa->FirstUnicastAddress; ua; ua = ua->Next) {
            SOCKADDR *sa = ua->Address.lpSockaddr;
            if (!sa || sa->sa_family != AF_INET) continue;
            unsigned char *b = (unsigned char *)&((struct sockaddr_in *)sa)->sin_addr;
            if (b[0] == 127) continue;                    /* loopback */
            if (b[0] == 169 && b[1] == 254) continue;     /* APIPA */
            swprintf(out, cap, L"%u.%u.%u.%u", b[0], b[1], b[2], b[3]);
            if (heap) free(heap);
            return;
        }
    }
    if (heap) free(heap);
    copy_w(out, cap, L"unknown");
}

/* ── WiFi SSID (no netsh; WLAN API) ─────────────────────────────────────── */
static void get_wifi_ssid(wchar_t *out, size_t cap) {
    HANDLE hClient = NULL;
    DWORD ver = 0;
    if (WlanOpenHandle(2, NULL, &ver, &hClient) != ERROR_SUCCESS) {
        copy_w(out, cap, L"未连接");
        return;
    }
    PWLAN_INTERFACE_INFO_LIST list = NULL;
    BOOL found = FALSE;
    if (WlanEnumInterfaces(hClient, NULL, &list) == ERROR_SUCCESS && list) {
        for (DWORD i = 0; i < list->dwNumberOfItems && !found; i++) {
            WLAN_INTERFACE_INFO *info = &list->InterfaceInfo[i];
            if (info->isState != wlan_interface_state_connected) continue;
            PWLAN_CONNECTION_ATTRIBUTES conn = NULL;
            DWORD dataSize = 0;
            if (WlanQueryInterface(hClient, &info->InterfaceGuid,
                    wlan_intf_opcode_current_connection, NULL,
                    &dataSize, (PVOID *)&conn, NULL) == ERROR_SUCCESS && conn) {
                DOT11_SSID *ssid = &conn->wlanAssociationAttributes.dot11Ssid;
                if (ssid->uSSIDLength > 0) {
                    int n = MultiByteToWideChar(CP_UTF8, 0, (LPCCH)ssid->ucSSID,
                                                (int)ssid->uSSIDLength, out, (int)cap - 1);
                    if (n <= 0)
                        n = MultiByteToWideChar(CP_ACP, 0, (LPCCH)ssid->ucSSID,
                                                (int)ssid->uSSIDLength, out, (int)cap - 1);
                    if (n > 0) { out[n] = L'\0'; found = TRUE; }
                }
                WlanFreeMemory(conn);
            }
        }
        WlanFreeMemory(list);
    }
    WlanCloseHandle(hClient, NULL);
    if (!found) copy_w(out, cap, L"未连接");
}

/* ── battery (no wmic; GetSystemPowerStatus) ────────────────────────────── */
static void get_battery(wchar_t *out, size_t cap) {
    SYSTEM_POWER_STATUS sps;
    if (!GetSystemPowerStatus(&sps) ||
        (sps.BatteryFlag & 128) ||         /* 128 = no system battery */
        sps.BatteryLifePercent == 255) {   /* 255 = unknown */
        copy_w(out, cap, L"未检测到电池");
        return;
    }
    int pct = sps.BatteryLifePercent;
    const wchar_t *label;
    if (sps.BatteryFlag & 8)            label = L"充电中";          /* 8 = charging */
    else if (sps.ACLineStatus == 1)    label = (pct >= 100) ? L"已充满" : L"充电中";
    else                               label = L"放电中";
    swprintf(out, cap, L"%d%% · %ls", pct, label);
}

/* ── slow cache + payload ───────────────────────────────────────────────── */
static void refresh_slow_cache(void) {
    get_lan_ip(g_lan, sizeof(g_lan) / sizeof(wchar_t));
    get_wifi_ssid(g_wifi, sizeof(g_wifi) / sizeof(wchar_t));
    get_battery(g_battery, sizeof(g_battery) / sizeof(wchar_t));
}

static void build_payload(const wchar_t *title, wchar_t *out, size_t cap) {
    wchar_t et[TITLE_CAP], ew[256];
    json_escape_w(title, et, TITLE_CAP);
    json_escape_w(g_wifi, ew, 256);
    swprintf(out, cap,
             L"{\"window\":\"%ls\",\"lan\":\"%ls\",\"wifi\":\"%ls\",\"battery\":\"%ls\"}",
             et, g_lan, ew, g_battery);
}

/* ── HTTP POST (no HttpURLConnection; WinHTTP). Offline = silent return. ─── */
static void send_data(const char *body, DWORD bodyLen) {
    if (!g_hSession) return;
    HINTERNET hConnect = WinHttpConnect(g_hSession, SERVER_HOST, SERVER_PORT, 0);
    if (!hConnect) return;
    HINTERNET hReq = WinHttpOpenRequest(hConnect, L"POST", SERVER_PATH, NULL,
                                        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
    if (hReq) {
        WinHttpSetTimeouts(hReq, 5000, 5000, 5000, 5000);
        LPCWSTR headers = L"Content-Type: application/json; charset=UTF-8\r\n";
        if (WinHttpSendRequest(hReq, headers, (DWORD)-1L, (LPVOID)body, bodyLen, bodyLen, 0))
            WinHttpReceiveResponse(hReq, NULL);
        WinHttpCloseHandle(hReq);
    }
    WinHttpCloseHandle(hConnect);
}

/* ── main loop ──────────────────────────────────────────────────────────── */
static void run(void) {
    HANDLE mutex = CreateMutexW(NULL, FALSE, L"Local\\UltraLightProbe_" DEVICE_ID);
    if (mutex && GetLastError() == ERROR_ALREADY_EXISTS) return;  /* one instance */

    g_hSession = WinHttpOpen(L"UltraLightProbe/1.0",
                             WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                             WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);

    LOGW(L"Probe 启动成功，正在监控中...\n");

    wchar_t title[TITLE_CAP], payload[PAYLOAD_CAP], lastPayload[PAYLOAD_CAP];
    char body[BODY_CAP];
    lastPayload[0] = L'\0';
    int forceCount = 0;
    unsigned long tick = 0;

    for (;;) {
        if (tick % SLOW_REFRESH_TICKS == 0) refresh_slow_cache();
        get_window_title(title, TITLE_CAP);
        build_payload(title, payload, PAYLOAD_CAP);
        forceCount++;

        if (wcscmp(payload, lastPayload) != 0 || forceCount > FORCE_TICKS) {
            forceCount = 0;
            int n = WideCharToMultiByte(CP_UTF8, 0, payload, -1, body, BODY_CAP, NULL, NULL);
            if (n > 0) {
                send_data(body, (DWORD)(n - 1));  /* drop trailing NUL */
                copy_w(lastPayload, PAYLOAD_CAP, payload);
                LOGW(L"已发送: %ls\n", payload);
            }
        }
        Sleep(POLL_MS);
        tick++;
    }
}

#ifdef CONSOLE_BUILD
int wmain(void) {
    SetConsoleOutputCP(CP_UTF8);
    _setmode(_fileno(stdout), _O_U8TEXT);
    run();
    return 0;
}
#else
int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE hPrev, PWSTR cmd, int show) {
    (void)hInst; (void)hPrev; (void)cmd; (void)show;
    run();
    return 0;
}
#endif
