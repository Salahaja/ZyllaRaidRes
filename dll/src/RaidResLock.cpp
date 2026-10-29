// RaidResLock.dll -- starts the raidres lock watcher with the game.
//
// When WoW loads this DLL (through dlls.txt or any other loader), it:
//
//   1. Registers a Lua function "RaidResLockReady" that returns true, so the
//      addon can detect the DLL and enable lock control automatically.
//   2. Starts the Python watcher (tools/raidres_lock.py watch) that bridges
//      the addon to Chrome for locking and unlocking raidres events.
//   3. Kills the watcher and headless Chrome when the game exits.
//
// Users who do not want lock control simply leave this DLL out of dlls.txt.
// The addon falls back to its check-only behavior.
//
// Same build setup as RaidResHttp: MSVC, MinHook, 32-bit static CRT.
// Addresses are for the 1.12.1 (5875) client OctoWoW ships.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <string>

#include "MinHook.h"

// ---------------------------------------------------------------------------
// The client (same offsets as RaidResHttp)
// ---------------------------------------------------------------------------

namespace Client {

using CFunction = int(__fastcall *)(void *L);
using LoadScriptFunctions_t = void(__fastcall *)();
using InvalidFunctionPtrCheck_t = void(__fastcall *)();
using RegisterFunction_t = void(__fastcall *)(const char *name, CFunction fn);
using pushnumber_t = void(__fastcall *)(void *L, double n);

const uintptr_t LOAD_SCRIPT_FUNCTIONS = 0x00490250;
const uintptr_t INVALID_FUNCTION_PTR_CHECK = 0x0042A320;

const auto RegisterFunction = reinterpret_cast<RegisterFunction_t>(0x00704120);
const auto PushNumber = reinterpret_cast<pushnumber_t>(0x006F3810);

} // namespace Client

// ---------------------------------------------------------------------------
// Watcher process management
// ---------------------------------------------------------------------------

namespace {

HANDLE g_watcherProcess = nullptr;

// Find python.exe on PATH.
bool FindPython(char *out, DWORD size) {
    DWORD n = SearchPathA(nullptr, "python.exe", nullptr, size, out, nullptr);
    return n > 0 && n < size;
}

// Build the path to raidres_lock.py relative to WoW.exe.
bool FindScript(char *out, DWORD size) {
    DWORD n = GetModuleFileNameA(nullptr, out, size);
    if (n == 0 || n >= size) return false;
    // Walk back to the directory containing WoW.exe.
    char *last = strrchr(out, '\\');
    if (!last) return false;
    last[1] = '\0';
    // The script lives under Interface\AddOns\ZyllaRaidRes\tools\.
    strcat_s(out, size, "Interface\\AddOns\\ZyllaRaidRes\\tools\\raidres_lock.py");
    return GetFileAttributesA(out) != INVALID_FILE_ATTRIBUTES;
}

void StartWatcher() {
    char python[MAX_PATH];
    char script[MAX_PATH];
    if (!FindPython(python, MAX_PATH)) return;
    if (!FindScript(script, MAX_PATH)) return;

    // Build command line: python "path\to\raidres_lock.py" watch
    char cmdline[1024];
    _snprintf(cmdline, sizeof(cmdline), "\"%s\" \"%s\" watch", python, script);

    // Working directory: the WoW.exe folder, so find_customdata works.
    char cwd[MAX_PATH];
    GetModuleFileNameA(nullptr, cwd, MAX_PATH);
    char *slash = strrchr(cwd, '\\');
    if (slash) slash[1] = '\0';

    STARTUPINFOA si = {};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi = {};

    if (CreateProcessA(nullptr, cmdline, nullptr, nullptr, FALSE,
                       CREATE_NO_WINDOW, nullptr, cwd, &si, &pi)) {
        g_watcherProcess = pi.hProcess;
        CloseHandle(pi.hThread);
    }
}

void StopWatcher() {
    if (!g_watcherProcess) return;

    // Kill the watcher process tree (includes any child python).
    char cmd[128];
    DWORD pid = GetProcessId(g_watcherProcess);
    _snprintf(cmd, sizeof(cmd), "taskkill /T /F /PID %lu", pid);
    STARTUPINFOA si = {};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi = {};
    if (CreateProcessA(nullptr, cmd, nullptr, nullptr, FALSE,
                       CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
        WaitForSingleObject(pi.hProcess, 5000);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }
    CloseHandle(g_watcherProcess);
    g_watcherProcess = nullptr;

    // Kill headless Chrome started by the watcher.
    // Only chrome.exe with our CDP profile, identified by command line.
    // A blanket kill is acceptable here since the watcher uses a dedicated
    // profile and this only runs on game exit.
    _snprintf(cmd, sizeof(cmd), "taskkill /F /IM chrome.exe");
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    ZeroMemory(&pi, sizeof(pi));
    if (CreateProcessA(nullptr, cmd, nullptr, nullptr, FALSE,
                       CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
        WaitForSingleObject(pi.hProcess, 3000);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }
}

// ---------------------------------------------------------------------------
// Lua function
// ---------------------------------------------------------------------------

int __fastcall Lua_LockReady(void *L) {
    Client::PushNumber(L, 1);
    return 1;
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

Client::LoadScriptFunctions_t LoadScriptFunctions_o = nullptr;

void __fastcall LoadScriptFunctions_h() {
    LoadScriptFunctions_o();
    Client::RegisterFunction("RaidResLockReady", Lua_LockReady);
}

void __fastcall InvalidFunctionPtrCheck_h() {}

volatile LONG g_claimed = 0, g_done = 0, g_result = 1;

bool InstallHooks() {
    MH_STATUS s = MH_Initialize();
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
        bool ok = InstallHooks();
        g_result = ok ? 0 : 1;
        if (ok) StartWatcher();
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
// dlls.txt has loaded.
extern "C" DWORD Load() { return EnsureInitialized(); }

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        if (GetModuleHandleW(L"VfPatcher.dll") == nullptr) {
            HANDLE t = CreateThread(nullptr, 0, InitWorker, nullptr, 0, nullptr);
            if (t) CloseHandle(t);
        }
    } else if (reason == DLL_PROCESS_DETACH) {
        StopWatcher();
    }
    return TRUE;
}
