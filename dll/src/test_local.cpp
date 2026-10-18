// test_local.exe -- RaidResHttp's request threads against a server that
// misbehaves on purpose (dll/tools/fake_server.py), on this machine.
//
//   python dll\tools\fake_server.py
//   build\test_local.exe            the full run
//   build\test_local.exe cap        just the cap, for running two side by side
//                                   the way two game clients would
//
// The claim: no request can keep a thread alive or busy for long, however the
// server behaves; no more than MAX_TALKING talk at once; they run below the
// game's priority; and when they're done, no thread is left behind.

#define RAIDRES_TEST_SERVER 8765
#include "RaidResHttp.cpp"
#include <cstdio>
#include <tlhelp32.h>

static int failures = 0;
static void check(const char *what, bool ok) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

static int ourThreads() {
    int n = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    THREADENTRY32 te;
    te.dwSize = sizeof(te);
    if (Thread32First(snap, &te)) {
        do { if (te.th32OwnerProcessID == GetCurrentProcessId()) n++; } while (Thread32Next(snap, &te));
    }
    CloseHandle(snap);
    return n;
}

// How many threads in this process started in our Worker -- request threads
// still alive. Windows records where each thread began.
static int workersAlive() {
    typedef LONG(WINAPI * NtQIT)(HANDLE, int, PVOID, ULONG, PULONG);
    NtQIT query = (NtQIT)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryInformationThread");
    int n = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    THREADENTRY32 te;
    te.dwSize = sizeof(te);
    if (query && Thread32First(snap, &te)) {
        do {
            if (te.th32OwnerProcessID != GetCurrentProcessId()) continue;
            HANDLE th = OpenThread(THREAD_QUERY_INFORMATION, FALSE, te.th32ThreadID);
            if (!th) continue;
            void *start = nullptr;
            if (query(th, 9 /* ThreadQuerySetWin32StartAddress */, &start, sizeof(start), nullptr) == 0 &&
                start == (void *)&Worker)
                n++;
            CloseHandle(th);
        } while (Thread32Next(snap, &te));
    }
    CloseHandle(snap);
    return n;
}

static Request take(int id) {
    EnterCriticalSection(&g_lock);
    Request r = g_requests[id];
    LeaveCriticalSection(&g_lock);
    return r;
}

// Wait for a request, up to `limitMs`; returns how long it took.
static DWORD waitFor(int id, DWORD limitMs, Request &out) {
    DWORD t0 = GetTickCount();
    while (GetTickCount() - t0 < limitMs) {
        out = take(id);
        if (out.state != State::Pending) return GetTickCount() - t0;
        Sleep(50);
    }
    out = take(id);
    return GetTickCount() - t0;
}

// The cap: n slow requests at once, watching how many talk at a time.
static void capTest(int n) {
    std::string why;
    int ids[16];
    DWORD t0 = GetTickCount();
    for (int i = 0; i < n; i++) ids[i] = Start("/slow", why);
    LONG most = 0, queuedSeen = 0;
    bool allDone = false;
    while (!allDone && GetTickCount() - t0 < 20000) {
        Status st = GetStatus();
        if (st.talking > most) most = st.talking;
        if (st.queued > queuedSeen) queuedSeen = st.queued;
        allDone = true;
        for (int i = 0; i < n; i++) if (take(ids[i]).state == State::Pending) allDone = false;
        Sleep(20);
    }
    DWORD took = GetTickCount() - t0;
    printf("    %d slow requests: at most %ld talking, up to %ld queued, %lu ms\n",
           n, most, queuedSeen, took);
    check("all of them finish", allDone);
    check("no more than 3 talk at once", most <= MAX_TALKING);
    check("the rest wait their turn", queuedSeen > 0);
    int done = 0;
    for (int i = 0; i < n; i++) if (take(ids[i]).state == State::Done) done++;
    check("and every one is answered", done == n);
}

int main(int argc, char **argv) {
    InitRequests();
    std::string why;

    if (argc > 1 && strcmp(argv[1], "cap") == 0) {
        printf("cap only (pid %lu)\n", GetCurrentProcessId());
        capTest(7);
        printf(failures ? "\n%d FAILED\n" : "\nall passed\n", failures);
        return failures ? 1 : 0;
    }

    int before = ourThreads();
    Request r;

    printf("a normal answer\n");
    int ok = Start("/ok", why);
    waitFor(ok, 5000, r);
    check("comes back", r.state == State::Done && r.status == 200 && r.body == "hello");

    printf("a server that never answers\n");
    int hang = Start("/hang", why);
    DWORD tookHang = waitFor(hang, 30000, r);
    printf("    gave up after %lu ms: %s\n", tookHang, r.body.c_str());
    check("is given up on", r.state == State::Failed);
    check("within a few seconds, not never", tookHang < 4 * TIMEOUT_MS + 1000);

    printf("a server that trickles forever\n");
    int drip = Start("/drip", why);
    DWORD tookDrip = waitFor(drip, 60000, r);
    printf("    gave up after %lu ms: %s\n", tookDrip, r.body.c_str());
    check("is given up on", r.state == State::Failed);
    check("at the deadline, although no single wait timed out",
          tookDrip >= DEADLINE_MS && tookDrip < DEADLINE_MS + TIMEOUT_MS + 1000);
    check("and says why", r.body.find("too long") != std::string::npos);

    printf("seven at once\n");
    capTest(7);

    printf("priority\n");
    int pr = Start("/slow", why);
    Sleep(300);
    // The worker's priority, read from outside it.
    int seen = THREAD_PRIORITY_NORMAL;
    {
        HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
        THREADENTRY32 te;
        te.dwSize = sizeof(te);
        if (Thread32First(snap, &te)) {
            do {
                if (te.th32OwnerProcessID == GetCurrentProcessId() && te.th32ThreadID != GetCurrentThreadId()) {
                    HANDLE th = OpenThread(THREAD_QUERY_INFORMATION, FALSE, te.th32ThreadID);
                    if (th) {
                        int p = GetThreadPriority(th);
                        if (p == THREAD_PRIORITY_BELOW_NORMAL) seen = p;
                        CloseHandle(th);
                    }
                }
            } while (Thread32Next(snap, &te));
        }
        CloseHandle(snap);
    }
    check("request threads run below normal priority", seen == THREAD_PRIORITY_BELOW_NORMAL);
    waitFor(pr, 5000, r);

    printf("afterwards\n");
    Sleep(500);
    Status st = GetStatus();
    check("nothing is still talking", st.talking == 0);
    check("nothing is still queued", st.queued == 0);
    int after = ourThreads();
    printf("    threads: %d before, %d after, %d of them request threads\n",
           before, after, workersAlive());
    check("no request thread is left behind", workersAlive() == 0);

    // What's left is WinHTTP's own pool, kept for reuse. It must not grow
    // with use: another round of the same leaves the count where it is.
    capTest(7);
    int hang2 = Start("/hang", why);
    waitFor(hang2, 30000, r);
    Sleep(500);
    int again = ourThreads();
    printf("    after a second round: %d threads, %d request threads\n", again, workersAlive());
    check("and another round adds none", again <= after + 1 && workersAlive() == 0);

    printf(failures ? "\n%d FAILED\n" : "\nall passed\n", failures);
    return failures ? 1 : 0;
}
