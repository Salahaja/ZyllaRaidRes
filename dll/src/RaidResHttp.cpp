// RaidResHttp.dll -- lets the 1.12 client fetch from raidres.top, and nothing else.
//
// WoW 1.12's Lua has no network access. This adds two functions to it:
//
//   id, err            = RaidResHttpGet("/api/events/XXXXXX")
//   state, a, b        = RaidResHttpResult(id)
//       "pending"                  still running; ask again later
//       "done", status, body       finished (status is the HTTP code)
//       "failed", message          never got an answer
//       nil, "unknown request"     no such id, or already collected
//
//   talking, queued, uncollected, oldest = RaidResHttpStatus()
//       what the DLL is doing right now, for /rrb debug
//
// The host is fixed and only GET is possible. A general "fetch any URL" would
// hand every installed addon a way to send your data anywhere; this can only
// read pages off one site that publishes soft-reserve lists.
//
// The request runs on a thread of its own. The game's main thread never waits
// on the network, and Lua is never touched from that thread -- the result sits
// in a table until Lua comes and asks for it.
//
// Those threads must never cost the game anything, so (since 1.3.0):
//   - every request has a hard deadline, however slowly the server answers;
//   - at most MAX_TALKING talk to the network at once, the rest wait their turn;
//   - they run below normal priority, so the game's own threads always win;
//   - a read that returns nothing ends the reply instead of asking again.
// 1.1.0 had none of these: a stalled or trickling connection kept its thread
// alive with no end, and a zero-byte read could spin a core.
//
// Lua functions are registered from a hook on the engine's LoadScriptFunctions,
// which runs every time the UI's Lua state is rebuilt (login, /reload), so the
// functions are there after a reload too. Addresses are for the 1.12.1 (5875)
// client OctoWoW ships; they were checked against its WoW.exe.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>

#include <cstdint>
#include <cstdio>
#include <map>
#include <string>

#include "MinHook.h"

#pragma comment(lib, "winhttp.lib")

// ---------------------------------------------------------------------------
// The client
// ---------------------------------------------------------------------------

namespace Client {

using CFunction = int(__fastcall *)(void *L);

// Engine functions, all MSVC fastcall: L in ecx, the next argument in edx.
using LoadScriptFunctions_t = void(__fastcall *)();
using InvalidFunctionPtrCheck_t = void(__fastcall *)();
using RegisterFunction_t = void(__fastcall *)(const char *name, CFunction fn);
using isstring_t = int(__fastcall *)(void *L, int idx);
using isnumber_t = int(__fastcall *)(void *L, int idx);
using tostring_t = const char *(__fastcall *)(void *L, int idx);
using tonumber_t = double(__fastcall *)(void *L, int idx);
using pushnil_t = void(__fastcall *)(void *L);
using pushnumber_t = void(__fastcall *)(void *L, double n);
using pushstring_t = void(__fastcall *)(void *L, const char *s);
using pushlstring_t = void(__fastcall *)(void *L, const char *s, unsigned int len);

const uintptr_t LOAD_SCRIPT_FUNCTIONS = 0x00490250;
// Rejects any Lua C function whose address is outside WoW.exe -- which is
// every function a DLL adds. ClassicAPI and the others disable it the same
// way; doing it here too means this does not depend on one of them loading.
const uintptr_t INVALID_FUNCTION_PTR_CHECK = 0x0042A320;

const auto RegisterFunction = reinterpret_cast<RegisterFunction_t>(0x00704120);
const auto IsString = reinterpret_cast<isstring_t>(0x006F3510);
const auto IsNumber = reinterpret_cast<isnumber_t>(0x006F34D0);
const auto ToString = reinterpret_cast<tostring_t>(0x006F3690);
const auto ToNumber = reinterpret_cast<tonumber_t>(0x006F3620);
const auto PushNil = reinterpret_cast<pushnil_t>(0x006F37F0);
const auto PushNumber = reinterpret_cast<pushnumber_t>(0x006F3810);
const auto PushString = reinterpret_cast<pushstring_t>(0x006F3890);
const auto PushLString = reinterpret_cast<pushlstring_t>(0x006F3840);

} // namespace Client

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

namespace {

#ifdef RAIDRES_TEST_SERVER
// test_local.exe: a plain-HTTP fake server on this machine that misbehaves
// on purpose, and short limits so the tests don't take minutes.
const wchar_t *const HOST = L"127.0.0.1";
const INTERNET_PORT PORT = RAIDRES_TEST_SERVER;
const DWORD SECURE = 0;
const DWORD TIMEOUT_MS = 2000;            // any one wait on the network
const DWORD DEADLINE_MS = 5000;           // the whole request
#else
const wchar_t *const HOST = L"raidres.top";
const INTERNET_PORT PORT = INTERNET_DEFAULT_HTTPS_PORT;
const DWORD SECURE = WINHTTP_FLAG_SECURE;
const DWORD TIMEOUT_MS = 10000;
const DWORD DEADLINE_MS = 30000;
#endif
const size_t MAX_PATH_LEN = 256;
const size_t MAX_BODY = 4 * 1024 * 1024;  // the biggest raid file is ~80 KB
const size_t MAX_KEPT = 16;               // results nobody collected, e.g. across a /reload
const LONG MAX_TALKING = 3;               // requests on the network at once

enum class State { Pending, Done, Failed };

struct Request {
    State state = State::Pending;
    DWORD status = 0;
    std::string body;   // the page, or the reason it failed
    DWORD started = 0;  // GetTickCount when it was asked for
};

CRITICAL_SECTION g_lock;
std::map<int, Request> g_requests;
int g_nextId = 1;

HANDLE g_slots = nullptr;        // a semaphore, MAX_TALKING wide
volatile LONG g_talking = 0;     // threads on the network now
volatile LONG g_queued = 0;      // threads waiting for a slot

struct Job {
    int id;
    std::wstring path;
};

// A path on raidres.top: "/api/events/XXXXXX", "/raids/raid_100.json".
// Letters, digits and / _ . - only, so there is no query string, no escape,
// no "..", and nothing that could change which host is asked.
bool ValidPath(const char *p, std::string &why) {
    size_t n = strlen(p);
    if (n == 0 || p[0] != '/') { why = "the path must start with /"; return false; }
    if (n > MAX_PATH_LEN) { why = "the path is too long"; return false; }
    for (size_t i = 0; i < n; i++) {
        char c = p[i];
        bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                  (c >= '0' && c <= '9') || c == '/' || c == '_' || c == '.' || c == '-';
        if (!ok) { why = "the path may only hold letters, digits and / _ . -"; return false; }
    }
    if (strstr(p, "..")) { why = "the path may not contain .."; return false; }
    return true;
}

std::string WinError(const char *what, DWORD code) {
    char buf[96];
    snprintf(buf, sizeof(buf), "%s failed (error %lu)", what, code);
    return buf;
}

void Finish(int id, State state, DWORD status, std::string body) {
    EnterCriticalSection(&g_lock);
    auto it = g_requests.find(id);
    if (it != g_requests.end()) {
        it->second.state = state;
        it->second.status = status;
        it->second.body.swap(body);
    }
    LeaveCriticalSection(&g_lock);
}

// Everything that talks to the network. Runs on the request's own thread.
bool Fetch(const std::wstring &path, DWORD &status, std::string &body) {
    bool ok = false;
    HINTERNET session = nullptr, connect = nullptr, request = nullptr;
    const DWORD began = GetTickCount();

    session = WinHttpOpen(L"RaidResHttp/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                          WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) { body = WinError("WinHttpOpen", GetLastError()); goto done; }
    WinHttpSetTimeouts(session, TIMEOUT_MS, TIMEOUT_MS, TIMEOUT_MS, TIMEOUT_MS);
    {
        // Windows 7's WinHTTP offers TLS 1.0 unless told otherwise, and the
        // site will not talk that. Harmless where 1.2 is already the default.
        DWORD protocols = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2;
        WinHttpSetOption(session, WINHTTP_OPTION_SECURE_PROTOCOLS, &protocols, sizeof(protocols));
    }

    connect = WinHttpConnect(session, HOST, PORT, 0);
    if (!connect) { body = WinError("WinHttpConnect", GetLastError()); goto done; }

    request = WinHttpOpenRequest(connect, L"GET", path.c_str(), nullptr, WINHTTP_NO_REFERER,
                                 WINHTTP_DEFAULT_ACCEPT_TYPES, SECURE);
    if (!request) { body = WinError("WinHttpOpenRequest", GetLastError()); goto done; }
    {
        // A redirect could take the request to another host, which is the one
        // thing this must never do. A 3xx comes back to Lua as a status instead.
        DWORD off = WINHTTP_DISABLE_REDIRECTS;
        WinHttpSetOption(request, WINHTTP_OPTION_DISABLE_FEATURE, &off, sizeof(off));
    }

    if (!WinHttpSendRequest(request, L"Accept: application/json\r\n", (DWORD)-1L,
                            WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(request, nullptr)) {
        body = WinError("the request", GetLastError());
        goto done;
    }

    {
        DWORD size = sizeof(status);
        WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                            WINHTTP_HEADER_NAME_BY_INDEX, &status, &size, WINHTTP_NO_HEADER_INDEX);
    }

    for (;;) {
        // However slowly it trickles in: each wait is bounded by TIMEOUT_MS,
        // and this bounds them all together.
        if (GetTickCount() - began > DEADLINE_MS) {
            body = "raidres took too long to answer";
            goto done;
        }
        DWORD avail = 0;
        if (!WinHttpQueryDataAvailable(request, &avail)) {
            body = WinError("reading the reply", GetLastError());
            goto done;
        }
        if (avail == 0) break;
        if (body.size() + avail > MAX_BODY) { body = "the reply is too large"; goto done; }
        size_t at = body.size();
        body.resize(at + avail);
        DWORD got = 0;
        if (!WinHttpReadData(request, &body[at], avail, &got)) {
            body = WinError("reading the reply", GetLastError());
            goto done;
        }
        body.resize(at + got);
        if (got == 0) break;   // nothing more is coming; asking again would spin
    }
    ok = true;

done:
    if (request) WinHttpCloseHandle(request);
    if (connect) WinHttpCloseHandle(connect);
    if (session) WinHttpCloseHandle(session);
    return ok;
}

DWORD WINAPI Worker(LPVOID arg) {
    Job *job = static_cast<Job *>(arg);
    // Below the game's own threads, always: a fetch can wait a moment longer,
    // a frame can't.
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);

    // Wait for one of MAX_TALKING slots. Waiting costs nothing; every slot
    // comes back within DEADLINE_MS plus one TIMEOUT_MS.
    InterlockedIncrement(&g_queued);
    WaitForSingleObject(g_slots, INFINITE);
    InterlockedDecrement(&g_queued);
    InterlockedIncrement(&g_talking);

    DWORD status = 0;
    std::string body;
    bool ok = Fetch(job->path, status, body);

    InterlockedDecrement(&g_talking);
    ReleaseSemaphore(g_slots, 1, nullptr);

    Finish(job->id, ok ? State::Done : State::Failed, status, std::move(body));
    delete job;
    return 0;
}

// Drop the oldest finished results nobody collected. A /reload forgets every
// id Lua held, so without this they would pile up for the whole session.
void Prune() {
    while (g_requests.size() >= MAX_KEPT) {
        auto victim = g_requests.end();
        for (auto it = g_requests.begin(); it != g_requests.end(); ++it)
            if (it->second.state != State::Pending) { victim = it; break; }
        if (victim == g_requests.end()) return;
        g_requests.erase(victim);
    }
}

// Returns the id, or 0 with a reason.
int Start(const char *path, std::string &why) {
    if (!ValidPath(path, why)) return 0;

    EnterCriticalSection(&g_lock);
    Prune();
    if (g_requests.size() >= MAX_KEPT) {
        LeaveCriticalSection(&g_lock);
        why = "too many requests already running";
        return 0;
    }
    int id = g_nextId++;
    g_requests[id].started = GetTickCount();
    LeaveCriticalSection(&g_lock);

    Job *job = new Job;
    job->id = id;
    job->path.assign(path, path + strlen(path));   // ASCII only, checked above
    HANDLE t = CreateThread(nullptr, 0, Worker, job, 0, nullptr);
    if (!t) {
        delete job;
        EnterCriticalSection(&g_lock);
        g_requests.erase(id);
        LeaveCriticalSection(&g_lock);
        why = "could not start a thread";
        return 0;
    }
    CloseHandle(t);
    return id;
}

// Once, before any request: from DllMain in the game, from main() in tests.
void InitRequests() {
    InitializeCriticalSection(&g_lock);
    g_slots = CreateSemaphoreW(nullptr, MAX_TALKING, MAX_TALKING, nullptr);
}

struct Status {
    LONG talking, queued;
    int uncollected;      // finished or pending, not yet handed to Lua
    DWORD oldestMs;       // the longest any pending request has been waiting
};

Status GetStatus() {
    Status st = { g_talking, g_queued, 0, 0 };
    DWORD now = GetTickCount();
    EnterCriticalSection(&g_lock);
    for (auto it = g_requests.begin(); it != g_requests.end(); ++it) {
        st.uncollected++;
        if (it->second.state == State::Pending && now - it->second.started > st.oldestMs)
            st.oldestMs = now - it->second.started;
    }
    LeaveCriticalSection(&g_lock);
    return st;
}

// ---------------------------------------------------------------------------
// The Lua side
// ---------------------------------------------------------------------------

int __fastcall Lua_Get(void *L) {
    using namespace Client;
    if (!IsString(L, 1)) {
        PushNil(L);
        PushString(L, "usage: RaidResHttpGet(\"/api/events/<ref>\")");
        return 2;
    }
    std::string why;
    int id = Start(ToString(L, 1), why);
    if (!id) {
        PushNil(L);
        PushString(L, why.c_str());
        return 2;
    }
    PushNumber(L, id);
    return 1;
}

int __fastcall Lua_Result(void *L) {
    using namespace Client;
    if (!IsNumber(L, 1)) {
        PushNil(L);
        PushString(L, "usage: RaidResHttpResult(id)");
        return 2;
    }
    int id = (int)ToNumber(L, 1);

    // Copied out under the lock and pushed after it: the Lua calls allocate,
    // may collect garbage, and have no business holding up a worker.
    Request r;
    bool found = false;
    EnterCriticalSection(&g_lock);
    auto it = g_requests.find(id);
    if (it != g_requests.end()) {
        found = true;
        if (it->second.state == State::Pending) {
            r.state = State::Pending;
        } else {
            r = std::move(it->second);
            g_requests.erase(it);   // a result is handed over once
        }
    }
    LeaveCriticalSection(&g_lock);

    if (!found) {
        PushNil(L);
        PushString(L, "unknown request");
        return 2;
    }
    switch (r.state) {
    case State::Pending:
        PushString(L, "pending");
        return 1;
    case State::Done:
        PushString(L, "done");
        PushNumber(L, r.status);
        PushLString(L, r.body.data(), (unsigned int)r.body.size());
        return 3;
    default:
        PushString(L, "failed");
        PushString(L, r.body.c_str());
        return 2;
    }
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

int __fastcall Lua_Status(void *L) {
    using namespace Client;
    Status st = GetStatus();
    PushNumber(L, st.talking);
    PushNumber(L, st.queued);
    PushNumber(L, st.uncollected);
    PushNumber(L, st.oldestMs / 1000.0);
    return 4;
}

Client::LoadScriptFunctions_t LoadScriptFunctions_o = nullptr;

void __fastcall LoadScriptFunctions_h() {
    LoadScriptFunctions_o();
    Client::RegisterFunction("RaidResHttpGet", Lua_Get);
    Client::RegisterFunction("RaidResHttpResult", Lua_Result);
    Client::RegisterFunction("RaidResHttpStatus", Lua_Status);
}

void __fastcall InvalidFunctionPtrCheck_h() {}

volatile LONG g_claimed = 0, g_done = 0, g_result = 1;

bool InstallHooks() {
    MH_STATUS s = MH_Initialize();
    // Another DLL in the process may have initialised its own copy; each copy
    // is separate, so ALREADY_INITIALIZED only means ours ran before.
    if (s != MH_OK && s != MH_ERROR_ALREADY_INITIALIZED) return false;

    if (MH_CreateHook(reinterpret_cast<LPVOID>(Client::INVALID_FUNCTION_PTR_CHECK),
                      reinterpret_cast<LPVOID>(InvalidFunctionPtrCheck_h), nullptr) != MH_OK)
        return false;
    if (MH_CreateHook(reinterpret_cast<LPVOID>(Client::LOAD_SCRIPT_FUNCTIONS),
                      reinterpret_cast<LPVOID>(LoadScriptFunctions_h),
                      reinterpret_cast<LPVOID *>(&LoadScriptFunctions_o)) != MH_OK)
        return false;
    return MH_EnableHook(MH_ALL_HOOKS) == MH_OK;
}

DWORD EnsureInitialized() {
    if (InterlockedCompareExchange(&g_claimed, 1, 0) == 0) {
        g_result = InstallHooks() ? 0 : 1;
        InterlockedExchange(&g_done, 1);
    } else {
        while (InterlockedCompareExchange(&g_done, 0, 0) == 0) Sleep(1);
    }
    return (DWORD)g_result;
}

DWORD WINAPI InitWorker(LPVOID) {
    EnsureInitialized();
    return 0;
}

} // namespace

// VanillaFixes calls this on the game's main thread once every DLL in
// dlls.txt has loaded. Hooking from DllMain instead would run under the loader
// lock, racing the DLLs loaded after this one. Exported as "Load" (see .def).
extern "C" DWORD Load() { return EnsureInitialized(); }

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        InitRequests();
        // Not loaded by VanillaFixes: nothing will call Load, so install from a
        // thread of our own, which cannot start until the loader lock is free.
        if (GetModuleHandleW(L"VfPatcher.dll") == nullptr) {
            HANDLE t = CreateThread(nullptr, 0, InitWorker, nullptr, 0, nullptr);
            if (t) CloseHandle(t);
        }
    }
    // No teardown on detach: that is process exit, and request threads may
    // still be running. Unhooking or freeing under them would only add risk.
    return TRUE;
}
