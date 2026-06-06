/*
 * UltraLightProbe — native Win32, event-driven (v2).
 * Replaces the Java/JNA/GraalVM build: no reflection, no subprocesses, no GC.
 * Flat ~1-2 MB RAM. Reports one row per *activity session* (window + start/end),
 * driven by SetWinEventHook foreground events + a 120s housekeeping timer; the
 * thread blocks in GetMessage so idle/locked time costs almost no wakeups.
 * Sessions that fail to send go to a bounded offline ring buffer and are
 * replayed when connectivity returns, so the server never misses activity.
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
#include <shellapi.h>

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
#pragma comment(lib, "shell32.lib")

/* ── Configuration (single source of truth) ─────────────────────────────── */
/* DEVICE_ID is the default; overridden at runtime by exe name or --device arg.
   Exe name "desktop" -> desktop, else notebook. Phone/customers use --device. */
#define DEVICE_ID          L"notebook"
#define SERVER_HOST        L"9.3.0.1.9.1.0.0.0.7.4.0.1.0.0.2.ip6.arpa"
#define SERVER_PORT        ((INTERNET_PORT)80)
#define CHECKPOINT_MS      (30u * 60u * 1000u)   /* same window 30 min -> force checkpoint */
#define SLOW_REFRESH_MS    (5u  * 60u * 1000u)   /* lan/wifi/battery refresh cadence       */
#define TIMER_TICK_MS      120000u               /* housekeeping: title change / cp / flush */
#define KEEPALIVE_MS       240000u               /* active user, same window: refresh online */

/* ── Buffers (single-threaded: globals/statics, zero per-tick heap churn) ── */
#define TITLE_CAP   1024
#define PAYLOAD_CAP 4096
#define BODY_CAP    16384
#define PENDING_CAP   128     /* offline ring buffer: max queued sessions          */
#define PENDING_ENTRY 2048    /* per-entry byte cap (over-long titles not queued)  */

static wchar_t g_lan[64]      = L"unknown";
static wchar_t g_wifi[128]    = L"unknown";
static wchar_t g_battery[64]  = L"unknown";
static HINTERNET g_hSession   = NULL;

/* session state + offline ring buffer (single-threaded; flat, no heap churn) */
static wchar_t   g_cur_title[TITLE_CAP] = L"";
static ULONGLONG g_cur_start = 0;   /* epoch-ms when current window session began */
static ULONGLONG g_last_slow = 0;   /* epoch-ms of last slow-cache refresh        */
static ULONGLONG g_last_send = 0;   /* epoch-ms of last successful POST (any kind) */

typedef struct { char data[PENDING_ENTRY]; DWORD len; } pending_t;
static pending_t g_pending[PENDING_CAP];
static int g_pend_head  = 0;        /* index of oldest queued entry */
static int g_pend_count = 0;

/* Runtime device_id: detected from exe name, or overridden via --device <id>.
   g_server_path is set once at startup and used in send_data(). */
static wchar_t g_device_id[24]  = L"notebook";   /* default */
static wchar_t g_server_path[96] = L"";           /* /api/report/<device_id> */

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

/* Wall-clock milliseconds since the Unix epoch (matches JS Date.now()). */
static ULONGLONG now_ms(void) {
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    ULONGLONG t = ((ULONGLONG)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
    return t / 10000ULL - 11644473600000ULL;   /* 100ns since 1601 -> ms since 1970 */
}

/* Detect device_id from executable name or --device command-line argument.
   Exe name convention: probe-<device_id>.exe  (last "-" suffix = device_id)
     probe.exe              -> notebook (default)
     probe-notebook.exe     -> notebook
     probe-desktop.exe      -> desktop
     probe-anything.exe     -> anything
   Override: probe.exe --device phone                                    */
static void init_device_id(void) {
    /* 1) try --device <id> command-line override */
    int argc;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argv) {
        for (int i = 1; i < argc - 1; i++) {
            if (wcscmp(argv[i], L"--device") == 0 && argv[i + 1][0]) {
                copy_w(g_device_id, 24, argv[i + 1]);
                LocalFree(argv);
                swprintf(g_server_path, 96, L"/api/report/%ls", g_device_id);
                LOGW(L"Device ID: %ls (from --device arg)\n", g_device_id);
                return;
            }
        }
        LocalFree(argv);
    }

    /* 2) detect from exe filename:   probe-<device_id>.exe  -> <device_id> */
    wchar_t path[MAX_PATH];
    DWORD sz = GetModuleFileNameW(NULL, path, MAX_PATH);
    if (sz > 0 && sz < MAX_PATH) {
        const wchar_t *base = wcsrchr(path, L'\\');
        base = base ? base + 1 : path;

        /* strip .exe suffix */
        wchar_t stem[MAX_PATH];
        wcsncpy(stem, base, MAX_PATH - 1);
        stem[MAX_PATH - 1] = L'\0';
        wchar_t *dot = wcsrchr(stem, L'.');
        if (dot) *dot = L'\0';

        /* find the last '-' */
        wchar_t *dash = wcsrchr(stem, L'-');
        if (dash && dash[1]) {
            copy_w(g_device_id, 24, dash + 1);
        }
        /* else: keep default "notebook" */
    }

    swprintf(g_server_path, 96, L"/api/report/%ls", g_device_id);
    LOGW(L"Device ID: %ls (from exe name)\n", g_device_id);
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

/* Session payload v2: window + slow-cache fields + start/end/duration (ms). */
static void build_payload(const wchar_t *title, ULONGLONG start, ULONGLONG end,
                          wchar_t *out, size_t cap) {
    wchar_t et[TITLE_CAP], ew[256];
    json_escape_w(title, et, TITLE_CAP);
    json_escape_w(g_wifi, ew, 256);
    ULONGLONG dur = (end >= start) ? (end - start) : 0;
    swprintf(out, cap,
             L"{\"window\":\"%ls\",\"lan\":\"%ls\",\"wifi\":\"%ls\",\"battery\":\"%ls\","
             L"\"start\":%llu,\"end\":%llu,\"dur\":%llu}",
             et, g_lan, ew, g_battery, start, end, dur);
}

/* ── HTTP POST (WinHTTP). Returns TRUE only on a 2xx/3xx response. ───────── */
static BOOL send_data(const char *body, DWORD bodyLen) {
    if (!g_hSession) return FALSE;
    BOOL ok = FALSE;
    HINTERNET hConnect = WinHttpConnect(g_hSession, SERVER_HOST, SERVER_PORT, 0);
    if (!hConnect) return FALSE;
    HINTERNET hReq = WinHttpOpenRequest(hConnect, L"POST", g_server_path, NULL,
                                        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
    if (hReq) {
        WinHttpSetTimeouts(hReq, 5000, 5000, 5000, 5000);
        LPCWSTR headers = L"Content-Type: application/json; charset=UTF-8\r\n";
        if (WinHttpSendRequest(hReq, headers, (DWORD)-1L, (LPVOID)body, bodyLen, bodyLen, 0) &&
            WinHttpReceiveResponse(hReq, NULL)) {
            DWORD status = 0, sz = sizeof(status);
            if (WinHttpQueryHeaders(hReq,
                    WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                    WINHTTP_HEADER_NAME_BY_INDEX, &status, &sz, WINHTTP_NO_HEADER_INDEX))
                ok = (status >= 200 && status < 400);
            else
                ok = TRUE;   /* got a response but couldn't read the code; assume sent */
        }
        WinHttpCloseHandle(hReq);
    }
    WinHttpCloseHandle(hConnect);
    return ok;
}

/* ── offline ring buffer ────────────────────────────────────────────────── */
static void enqueue_pending(const char *body, DWORD len) {
    if (len == 0 || len > PENDING_ENTRY) return;   /* too big to buffer (very rare) */
    if (g_pend_count == PENDING_CAP) {             /* full: drop the oldest         */
        g_pend_head = (g_pend_head + 1) % PENDING_CAP;
        g_pend_count--;
    }
    int idx = (g_pend_head + g_pend_count) % PENDING_CAP;
    memcpy(g_pending[idx].data, body, len);
    g_pending[idx].len = len;
    g_pend_count++;
}

/* Send queued sessions oldest-first; stop at the first failure (still offline). */
static void flush_pending(void) {
    while (g_pend_count > 0) {
        pending_t *p = &g_pending[g_pend_head];
        if (!send_data(p->data, p->len)) break;
        g_pend_head = (g_pend_head + 1) % PENDING_CAP;
        g_pend_count--;
    }
}

/* ── session reporting ──────────────────────────────────────────────────── */
static void report_session(const wchar_t *title, ULONGLONG start, ULONGLONG end) {
    wchar_t payload[PAYLOAD_CAP];
    char    body[BODY_CAP];
    build_payload(title, start, end, payload, PAYLOAD_CAP);
    int n = WideCharToMultiByte(CP_UTF8, 0, payload, -1, body, BODY_CAP, NULL, NULL);
    if (n <= 0) return;
    DWORD len = (DWORD)(n - 1);   /* drop trailing NUL */
    if (send_data(body, len)) {
        g_last_send = now_ms();
        LOGW(L"已发送: %ls\n", payload);
        flush_pending();          /* opportunistically drain any backlog */
    } else {
        enqueue_pending(body, len);
        LOGW(L"离线缓存(%d): %ls\n", g_pend_count, payload);
    }
}

/* Liveness ping: refresh the live device row only (no history row). Sent only
   while the user is active, so an idle/locked machine still reads offline. */
static void send_keepalive(void) {
    wchar_t payload[PAYLOAD_CAP], et[TITLE_CAP], ew[256];
    char    body[BODY_CAP];
    json_escape_w(g_cur_title, et, TITLE_CAP);
    json_escape_w(g_wifi, ew, 256);
    swprintf(payload, PAYLOAD_CAP,
             L"{\"keepalive\":1,\"window\":\"%ls\",\"lan\":\"%ls\",\"wifi\":\"%ls\",\"battery\":\"%ls\"}",
             et, g_lan, ew, g_battery);
    int n = WideCharToMultiByte(CP_UTF8, 0, payload, -1, body, BODY_CAP, NULL, NULL);
    if (n <= 0) return;
    if (send_data(body, (DWORD)(n - 1))) { g_last_send = now_ms(); flush_pending(); }
}

/* Close the current session, report it, and open a new one titled newTitle. */
static void roll_session(const wchar_t *newTitle) {
    ULONGLONG now = now_ms();
    if (g_cur_title[0] != L'\0' && g_cur_start != 0)
        report_session(g_cur_title, g_cur_start, now);
    copy_w(g_cur_title, TITLE_CAP, newTitle);
    g_cur_start = now;
}

/* Same window held >= 30 min: emit a segment and keep the title running. */
static void checkpoint_session(void) {
    ULONGLONG now = now_ms();
    if (g_cur_title[0] != L'\0' && g_cur_start != 0) {
        report_session(g_cur_title, g_cur_start, now);
        g_cur_start = now;
    }
}

/* Re-read the foreground title; roll the session if it changed. */
static void on_possible_change(void) {
    wchar_t title[TITLE_CAP];
    get_window_title(title, TITLE_CAP);
    if (wcscmp(title, g_cur_title) != 0)
        roll_session(title);
}

/* Foreground-window switch — delivered on this thread via the message loop. */
static void CALLBACK win_event_proc(HWINEVENTHOOK hHook, DWORD event, HWND hwnd,
                                    LONG idObject, LONG idChild,
                                    DWORD idThread, DWORD evTime) {
    (void)hHook; (void)event; (void)hwnd; (void)idObject;
    (void)idChild; (void)idThread; (void)evTime;
    on_possible_change();
}

/* Browser tab switch: catch window-title changes (Edge, Chrome, Firefox, etc.).
   Only fires when the foreground window's title changes, so it captures in-tab
   navigation with zero latency. Still fully event-driven — no extra wakeups. */
static void CALLBACK win_event_namechange_proc(HWINEVENTHOOK hHook, DWORD event, HWND hwnd,
                                                LONG idObject, LONG idChild,
                                                DWORD idThread, DWORD evTime) {
    (void)hHook; (void)event; (void)idThread; (void)evTime;
    if (idObject != OBJID_WINDOW || idChild != CHILDID_SELF) return;
    if (!hwnd || !IsWindowVisible(hwnd)) return;
    if (hwnd != GetForegroundWindow()) return;   /* only care about the active window */

    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    wchar_t name[MAX_PATH];
    if (!get_process_name(pid, name, MAX_PATH)) return;

    wchar_t lp[MAX_PATH];
    to_lower_w(name, lp, MAX_PATH);
    /* Known browsers — any process whose image name matches */
    static const wchar_t * const browsers[] = {
        L"chrome", L"msedge", L"firefox", L"opera",
        L"brave", L"vivaldi", L"browse", L"iexplore",
        L"thorium", L"waterfox", L"palemoon", L"seamonkey"
    };
    for (int i = 0; i < (int)(sizeof(browsers)/sizeof(browsers[0])); i++) {
        if (wcsstr(lp, browsers[i])) {
            on_possible_change();
            return;
        }
    }
}

/* 120s housekeeping: same-window title changes, slow cache, checkpoint, retry. */
static void CALLBACK timer_proc(HWND hwnd, UINT msg, UINT_PTR id, DWORD tick) {
    (void)hwnd; (void)msg; (void)id; (void)tick;
    ULONGLONG now = now_ms();
    if (now - g_last_slow >= SLOW_REFRESH_MS) { refresh_slow_cache(); g_last_slow = now; }
    on_possible_change();                                        /* tab/title changes */
    if (g_cur_start != 0 && now - g_cur_start >= CHECKPOINT_MS) checkpoint_session();
    /* Active user staying in one window: keep dashboard 'online' without a history
       row. Idle/locked => no input => no ping => correctly drops to offline. */
    LASTINPUTINFO lii; lii.cbSize = sizeof(lii);
    DWORD idle = GetLastInputInfo(&lii) ? (GetTickCount() - lii.dwTime) : 0;
    if (idle < KEEPALIVE_MS && now - g_last_send >= KEEPALIVE_MS) send_keepalive();
    flush_pending();
}

/* ── main: event-driven, blocks in GetMessage (near-zero idle wakeups) ───── */
static void run(void) {
    init_device_id();  /* detect device_id from exe name or --device arg */

    wchar_t mutex_name[64];
    swprintf(mutex_name, 64, L"Local\\UltraLightProbe_%ls", g_device_id);
    HANDLE mutex = CreateMutexW(NULL, FALSE, mutex_name);
    if (mutex && GetLastError() == ERROR_ALREADY_EXISTS) return;  /* one instance */

    g_hSession = WinHttpOpen(L"UltraLightProbe/2.0",
                             WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                             WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);

    refresh_slow_cache();
    g_last_slow = now_ms();
    g_last_send = now_ms();

    /* seed the first session from whatever is in the foreground at launch */
    {
        wchar_t title[TITLE_CAP];
        get_window_title(title, TITLE_CAP);
        copy_w(g_cur_title, TITLE_CAP, title);
        g_cur_start = now_ms();
    }

    LOGW(L"Probe v2 启动成功，事件驱动监控中...\n");

    HWINEVENTHOOK hook_fg = SetWinEventHook(
        EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
        NULL, win_event_proc, 0, 0,
        WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);

    HWINEVENTHOOK hook_name = SetWinEventHook(
        EVENT_OBJECT_NAMECHANGE, EVENT_OBJECT_NAMECHANGE,
        NULL, win_event_namechange_proc, 0, 0,
        WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);

    UINT_PTR timer = SetTimer(NULL, 0, TIMER_TICK_MS, timer_proc);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    if (timer) KillTimer(NULL, timer);
    if (hook_name) UnhookWinEvent(hook_name);
    if (hook_fg)  UnhookWinEvent(hook_fg);
}

#ifdef CONSOLE_BUILD
int main(void) {
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
