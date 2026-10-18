/* pingspy.c — 《说说你的ping》原生探针 DLL：借 LuaJIT 宿主 FFI 被 Lua 加载，直读引擎每连接 RTT；纯查询，无 hook、无线程、不写任何代码页。 */

#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

/* ============ 引擎逆向常量（client/server 双 exe 反汇编实证，见 .source/REVERSE_NOTES.md） ============ */
#define CN_OFF_RAKPEER  0x2B0                 /* cNetwork 内 RakPeer* 偏移（GetNetworkStatistics 实现，两 exe 一致） */
#define CN_OFF_MGR      0x328                 /* cNetwork 内 ClientObject 管理器（sub_1401E4320: mov rax,[rcx+328h]） */
#define VT_OFF_AVG      0x150                 /* RakPeer vtable 槽 42 = GetAveragePing(AddressOrGUID*)，avg_ping 生成码证实 */
#define VT_OFF_LAST     0x158                 /* vtable 槽 43 = GetLastPing(AddressOrGUID*)，ping 生成码证实 */
#define AOG_SIZE        10                    /* fork 的 AddressOrGUID：guid.g(8)@0 + systemIndex(2)@8 */
#define CN_CHECK_OFF    0x330                 /* cNetwork 校验可读范围 */
#define RVA_CN_CLIENT   0x672E50              /* client exe：cNetwork 单例全局 qword_140672E50 */
#define RVA_CN_SERVER   0x5EC780              /* dedicated exe：cNetwork 单例全局 qword_1405EC780 */
#define MGR_OFF_TREE    0x3D0                 /* 管理器内 ClientObject 红黑树 head 指针（mgr = cN+0x328；head = *(mgr+0x3D0)） */
#define CO_OFF_GUID     0x1A0                 /* ClientObject：RakNetGUID（g@0，hex dump 实证：随机 64 位） */
#define CO_OFF_USERID   0x30                  /* ClientObject：userid（MSVC string：buf@0x30 size@0x40，hex dump 实证 "KU_xxx" SSO 内联） */
#define TN_OFF_LEFT     0x00                  /* std::tree 节点 _Left */
#define TN_OFF_RIGHT    0x10                  /* std::tree 节点 _Right */
#define TN_OFF_VALUE    0x28                  /* std::tree 节点值 = ClientObject* */
#define TN_OFF_ISNIL    0x31                  /* std::tree 节点 _Isnil 标志 */

typedef int (__fastcall *PFN_GetPing)(void* rakpeer, void* aog); /* x64：rcx=this, rdx=&AddressOrGUID */

static volatile LONG g_attached = 0;            /* 0 未挂接 / 1 已挂接 */
static uint64_t g_cnetwork = 0;                 /* 缓存 cNetwork*（查询时实时解引用 RakPeer，容忍连接重建） */

#ifdef PINGSPY_LOG
static void spy_log(const char* fmt, ...)          /* 开发期诊断日志，写入 DLL 同目录 pingspy.log；发布编译去掉开关 */
{
    HMODULE self = NULL;
    wchar_t wpath[MAX_PATH];
    char path[MAX_PATH];
    int n, i;
    HANDLE file;
    char buf[512];
    int len;
    va_list ap;
    DWORD written;

    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            (LPCWSTR)&spy_log, &self))
        return;
    n = GetModuleFileNameW(self, wpath, MAX_PATH);
    while (n > 0 && wpath[n - 1] != L'\\' && wpath[n - 1] != L'/') n--; /* 截去文件名，留目录 */
    for (i = 0; i < n && i < MAX_PATH - 16; i++) path[i] = (char)wpath[i];
    strcpy(path + i, "pingspy_");
    i += 8;
    _ultoa(GetCurrentProcessId(), path + i, 10);                   /* 按进程 PID 分文件，避免 Master/Caves 双进程互清日志 */
    i += (int)strlen(path + i);
    strcpy(path + i, ".log");
    {
        static int first = 1;                      /* 进程内首笔写入时截断旧日志，避免跨次运行堆积 */
        file = CreateFileA(path, FILE_APPEND_DATA, FILE_SHARE_READ, NULL,
                            first ? CREATE_ALWAYS : OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (file != INVALID_HANDLE_VALUE) first = 0;
    }
    if (file == INVALID_HANDLE_VALUE) return;

    va_start(ap, fmt);
    len = _vsnprintf(buf, sizeof(buf) - 2, fmt, ap);
    va_end(ap);
    if (len > 0) {
        buf[len++] = '\r'; buf[len++] = '\n';
        WriteFile(file, buf, (DWORD)len, &written, NULL);
    }
    CloseHandle(file);
}
#else
#define spy_log(...) ((void)0)
#endif

/* addr 起始 len 字节是否可按需访问（need_exec 时要求可执行），跨区域逐段校验 */
static int region_readable(uint64_t addr, size_t len, int need_exec)
{
    MEMORY_BASIC_INFORMATION mbi;
    uint64_t p = addr, end = addr + len;
    const DWORD rd = PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY |
                     PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
    const DWORD ex = PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;

    while (p < end) {
        if (!VirtualQuery((LPCVOID)p, &mbi, sizeof(mbi))) return 0;
        if (mbi.State != MEM_COMMIT) return 0;
        if (mbi.Protect & (PAGE_GUARD | PAGE_NOACCESS)) return 0;
        if (!(mbi.Protect & rd)) return 0;
        if (need_exec && !(mbi.Protect & ex)) return 0;
        if (end <= (uint64_t)mbi.BaseAddress + mbi.RegionSize) return 1;
        p = (uint64_t)mbi.BaseAddress + mbi.RegionSize; /* 越过本区域继续 */
    }
    return 1;
}

/* 纯结构校验：不包含任何被调代码。vtable 表本体在 .rdata（只读不执行），可执行仅用于槽内函数指针。 */
static int validate_cnetwork(uint64_t cand)
{
    uint64_t vt1, vt2, rakpeer, vtable, f_avg, f_last;

    if (!cand || (cand >> 62) != 0 || cand < 0x10000) return 0;
    if (!region_readable(cand, CN_CHECK_OFF, 0)) return 0;

    vt1 = *(uint64_t*)cand;                            /* cNetwork 多继承双 vtable（ctor 写 [0]/[8]） */
    vt2 = *(uint64_t*)(cand + 8);
    if (!vt1 || !vt2) return 0;
    if (!region_readable(vt1, 8, 0) || !region_readable(vt2, 8, 0)) return 0;
    if (*(uint8_t*)(cand + 0x30A) > 1) return 0;       /* GetPing 使用的布尔标志 */

    rakpeer = *(uint64_t*)(cand + CN_OFF_RAKPEER);     /* 网络未启动时为 NULL：由 Lua 侧重试覆盖 */
    if (!rakpeer || !region_readable(rakpeer, 8, 0)) return 0;
    vtable = *(uint64_t*)rakpeer;
    /* RakPeerInterface 约 150 个虚函数：0x400 字节连续只读 vtable 是极强的类特征 */
    if (!vtable || !region_readable(vtable, 0x400, 0)) return 0;

    f_avg  = *(uint64_t*)(vtable + VT_OFF_AVG);
    f_last = *(uint64_t*)(vtable + VT_OFF_LAST);
    if (!f_avg || !f_last) return 0;
    if (!region_readable(f_avg, 1, 1) || !region_readable(f_last, 1, 1)) return 0;

    return 1;
}

/* 按 exe 名选单例全局 RVA 直读 cNetwork*；全局由引擎自身写入，无扫描、无试探调用 */
__declspec(dllexport) int __cdecl PN_Attach(void)
{
    wchar_t exe[MAX_PATH];
    uint8_t* base = (uint8_t*)GetModuleHandleW(NULL);
    uint64_t rva, cn;

    if (g_attached) return 1;
    if (!base || !GetModuleFileNameW(base, exe, MAX_PATH)) return -1;

    /* dedicated server 进程选 server RVA；listen host 与客户端同为 dontstarve_steam_x64 */
    rva = (wcsstr(exe, L"dedicated_server") != NULL) ? RVA_CN_SERVER : RVA_CN_CLIENT;
    cn = *(uint64_t*)(base + rva);

    if (!validate_cnetwork(cn)) {
        spy_log("[pingspy] attach: validate failed (rva=%llx cn=%llx)", (unsigned long long)rva, (unsigned long long)cn);
        return -2;
    }
    g_cnetwork = cn;
    InterlockedExchange(&g_attached, 1);
    spy_log("[pingspy] attach: OK (rva=%llx cn=%llx)", (unsigned long long)rva, (unsigned long long)cn);
    return 1;
}

__declspec(dllexport) int __cdecl PN_Status(void)
{
    return g_attached;
}

/* 取当前 RakPeer 与 vtable（公共校验路径）；失效返回 0 并解除挂接 */
static int get_rakpeer(uint64_t* rp_out, uint64_t* vt_out)
{
    uint64_t rakpeer, vtable;

    if (!g_attached || !g_cnetwork) return 0;
    if (!region_readable(g_cnetwork, CN_CHECK_OFF, 0)) {
        InterlockedExchange(&g_attached, 0);
        spy_log("[pingspy] query: cnetwork gone, detached");
        return 0;
    }
    rakpeer = *(uint64_t*)(g_cnetwork + CN_OFF_RAKPEER);
    if (!rakpeer || !region_readable(rakpeer, 8, 0)) return 0;
    vtable = *(uint64_t*)rakpeer;                                  /* 连接重建时 RakPeer 可能更换，实时取 vtable */
    if (!region_readable(vtable, 0x160, 0)) return 0;
    *rp_out = rakpeer;
    *vt_out = vtable;
    return 1;
}

/* slot_off 取 VT_OFF_AVG / VT_OFF_LAST；返回 -1 表示无连接或探针失效 */
static int query(uint64_t guid, uint64_t slot_off)
{
    uint64_t rakpeer, vtable;
    unsigned char aog[AOG_SIZE];
    PFN_GetPing fn;

    if (!get_rakpeer(&rakpeer, &vtable)) return -1;

    *(uint64_t*)aog = guid;
    *(uint16_t*)(aog + 8) = 0xFFFF;                                /* 强制按 guid 查找 */
    fn = (PFN_GetPing)*(uint64_t*)(vtable + slot_off);
    return fn((void*)rakpeer, aog);
}

/* 读 MSVC std::string（SSO：cap<16 时缓冲内联） */
static int read_msvc_string(uint64_t obj, char* out, size_t outlen)
{
    uint64_t cap, size, ptr;
    const char* p;

    if (!region_readable(obj, 0x20, 0)) return 0;
    cap = *(uint64_t*)(obj + 0x18);
    size = *(uint64_t*)(obj + 0x10);
    if (size == 0 || size >= outlen) return 0;
    if (cap >= 16) {
        ptr = *(uint64_t*)obj;
        if (!ptr || !region_readable(ptr, size + 1, 0)) return 0;
        p = (const char*)ptr;
    } else {
        p = (const char*)obj;
    }
    memcpy(out, p, size);
    out[size] = 0;
    return 1;
}

/* 中序遍历 ClientObject 树，按 userid 匹配；命中则回填其 RakNetGUID */
static struct {
    unsigned found;
    uint64_t guid;
    const char* userid;
} g_match;

#ifdef PINGSPY_LOG
static unsigned g_dbg_nodes = 0;                   /* 诊断打印限幅，避免每秒轮询刷屏 */
#endif

/* 认证连接判定：ClientObject 的 netid C 字符串（@+0x1EC）非空；服务器自身 self 对象的 netid 为空 */
static int has_netid(uint64_t co)
{
    return region_readable(co + 0x1EC, 2, 0) && *(const char*)(co + 0x1EC) != 0;
}

static void walk_tree(uint64_t node, uint64_t head)
{
    uint64_t left, right, co;
    char uid[64], nid[64];

    if (g_match.found || !node || node == head) return;
    if (!region_readable(node, 0x38, 0)) return;
    if (*(uint8_t*)(node + TN_OFF_ISNIL)) return;                  /* 哨兵 */

    left = *(uint64_t*)(node + TN_OFF_LEFT);
    right = *(uint64_t*)(node + TN_OFF_RIGHT);
    walk_tree(left, head);
    if (g_match.found) return;

    co = *(uint64_t*)(node + TN_OFF_VALUE);
    if (co && region_readable(co, 0x220, 0)) {
        /* 对象状态不同，userid 位置不同：认证后在 +0x1C8（标准 string），部分对象在 +0x30；
         * 任一命中即取 guid@+0x1A0（两种形态下均为 RakNetGUID） */
        int oa = read_msvc_string(co + 0x1C8, uid, sizeof(uid));
        int ob = read_msvc_string(co + 0x30, nid, sizeof(nid));
        int hit = ((oa && strcmp(uid, g_match.userid) == 0) || (ob && strcmp(nid, g_match.userid) == 0)) &&
                  has_netid(co);                                   /* 排除服务器自身 self 对象（netid 空） */
#ifdef PINGSPY_LOG
        if (g_dbg_nodes < 4) {
            g_dbg_nodes++;
            spy_log("[pingspy] CO@%llx userid(1C8)='%s' userid(30)='%s' netid=%s hit=%d",
                    (unsigned long long)co, oa ? uid : "-", ob ? nid : "-",
                    has_netid(co) ? "set" : "empty", hit);
        }
#endif
        if (hit) {
            g_match.guid = *(uint64_t*)(co + CO_OFF_GUID);
            g_match.found = 1;
            spy_log("[pingspy] matched guid=%llx", (unsigned long long)g_match.guid);
            return;
        }
    }
    walk_tree(right, head);
}

/* 按 userid 找 ClientObject → RakNetGUID → 引擎最近 RTT（毫秒；-1 无连接/无值） */
__declspec(dllexport) int __cdecl PN_QueryByUserid(const char* userid)
{
    uint64_t mgr, head, root, guid;

    if (!userid || !userid[0]) return -1;
    if (!g_attached && PN_Attach() != 1) return -1; /* 网络层未就绪时随查询自动重试（幂等、纯只读校验） */
    if (!region_readable(g_cnetwork, CN_CHECK_OFF, 0)) return -1;
    mgr = *(uint64_t*)(g_cnetwork + CN_OFF_MGR);
    if (!mgr || !region_readable(mgr + MGR_OFF_TREE, 8, 0)) return -1;
    head = *(uint64_t*)(mgr + MGR_OFF_TREE);
    if (!head || !region_readable(head, 0x38, 0)) return -1;

    g_match.found = 0;
    g_match.userid = userid;
    g_match.guid = 0;
    root = *(uint64_t*)head;                                       /* head._Left = 根 */
    walk_tree(root, head);
    if (!g_match.found) {
        spy_log("[pingspy] userid not found in ClientObject tree: %s", userid);
        return -1;
    }

    guid = g_match.guid;
    if (guid == 0 || guid == 0xFFFFFFFFFFFFFFFFULL) return -1;
    {
        int last = query(guid, VT_OFF_LAST);
        int avg = query(guid, VT_OFF_AVG);
        spy_log("[pingspy] query guid=%llx last=%d avg=%d", (unsigned long long)guid, last, avg);
        return last >= 0 ? last : avg;                             /* 两者取有效值 */
    }
}

/* 同上但取引擎平均 RTT */
__declspec(dllexport) int __cdecl PN_QueryByUseridAvg(const char* userid)
{
    uint64_t mgr, head, root, guid;

    if (!userid || !userid[0]) return -1;
    if (!g_attached && PN_Attach() != 1) return -1;
    if (!region_readable(g_cnetwork, CN_CHECK_OFF, 0)) return -1;
    mgr = *(uint64_t*)(g_cnetwork + CN_OFF_MGR);
    if (!mgr || !region_readable(mgr + MGR_OFF_TREE, 8, 0)) return -1;
    head = *(uint64_t*)(mgr + MGR_OFF_TREE);
    if (!head || !region_readable(head, 0x38, 0)) return -1;

    g_match.found = 0;
    g_match.userid = userid;
    g_match.guid = 0;
    root = *(uint64_t*)head;                                       /* head._Left = 根 */
    spy_log("[pingspy] tree: head=%llx root=%llx empty=%d", (unsigned long long)head, (unsigned long long)root, root == head);
    walk_tree(root, head);
    if (!g_match.found) return -1;

    guid = g_match.guid;
    if (guid == 0 || guid == 0xFFFFFFFFFFFFFFFFULL) return -1;
    return query(guid, VT_OFF_AVG);
}

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved)
{
    (void)hinst; (void)reason; (void)reserved;
    return TRUE;                                                   /* 懒初始化：一切工作推迟到首次导出调用 */
}
