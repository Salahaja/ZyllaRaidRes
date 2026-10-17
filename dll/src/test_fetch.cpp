// test_fetch.exe -- the request side of RaidResHttp.dll, outside the game.
// Built from the same source; only the Lua glue is left unused, because it
// calls into WoW.exe.
#include "RaidResHttp.cpp"
#include <cstdio>

static int failures = 0;
static void check(const char *what, bool ok) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

// Polls the way the addon will: ask, come back later.
static Request wait(int id) {
    for (int i = 0; i < 300; i++) {
        EnterCriticalSection(&g_lock);
        Request r = g_requests[id];
        LeaveCriticalSection(&g_lock);
        if (r.state != State::Pending) return r;
        Sleep(100);
    }
    return Request();
}

// test_fetch.exe [event-ref]   -- with a ref, also fetches that real event.
int main(int argc, char **argv) {
    InitializeCriticalSection(&g_lock);
    const std::string ref = argc > 1 ? argv[1] : "";
    std::string why;

    printf("paths\n");
    check("a plain path passes", ValidPath("/api/events/XXXXXX", why));
    check("no leading slash is refused", !ValidPath("api/events/x", why));
    check("a query string is refused", !ValidPath("/api/events/x?a=1", why));
    // "//host/x" is a legal path character-wise, and harmless: the connection
    // is to raidres.top before the path is ever looked at, so it is only sent
    // to raidres.top as a strange path. The fetch below proves where it went.
    check("an @ is refused", !ValidPath("/x@evil.example", why));
    check("a colon is refused", !ValidPath("/x:80", why));
    check(".. is refused", !ValidPath("/raids/../x", why));
    check("a space is refused", !ValidPath("/a b", why));
    check("an empty path is refused", !ValidPath("", why));
    std::string longp(300, 'a'); longp[0] = '/';
    check("an overlong path is refused", !ValidPath(longp.c_str(), why));

    printf("fetching\n");
    DWORD t0 = GetTickCount();
    int ev = ref.empty() ? 0 : Start(("/api/events/" + ref).c_str(), why);
    int raid = Start("/raids/raid_100.json", why);
    int missing = Start("/raids/raid_1.json", why);
    int other = Start("//example.com/", why);
    check("Start returns at once", GetTickCount() - t0 < 200);
    Request a = ev ? wait(ev) : Request(), b = wait(raid), c = wait(missing), d = wait(other);
    if (ev) printf("    event: state %d status %lu, %u bytes\n", (int)a.state, a.status, (unsigned)a.body.size());
    printf("    raid:  state %d status %lu, %u bytes\n", (int)b.state, b.status, (unsigned)b.body.size());
    printf("    404:   state %d status %lu\n", (int)c.state, c.status);
    if (ev) {
        check("the event arrives", a.state == State::Done && a.status / 100 == 2);
        check("the event is JSON",
              a.body.find("\"reference\":\"" + ref + "\"") != std::string::npos);
    } else {
        printf("    (no event ref given; pass one to fetch a real event too)\n");
    }
    check("the raid arrives", b.state == State::Done && b.status == 200 && b.body.find("raidItems") != std::string::npos);
    check("a missing page is a status, not a failure", c.state == State::Done && c.status == 404);
    printf("    //example.com/: status %lu, %u bytes\n", d.status, (unsigned)d.body.size());
    check("a //host path still asks raidres.top", d.state == State::Done &&
          d.body.find("Example Domain") == std::string::npos);

    printf("pruning\n");
    g_requests.clear();
    for (int i = 0; i < 20; i++) { g_requests[1000 + i].state = State::Done; }
    EnterCriticalSection(&g_lock); Prune(); LeaveCriticalSection(&g_lock);
    check("uncollected results are capped", g_requests.size() < MAX_KEPT);

    printf(failures ? "\n%d FAILED\n" : "\nall passed\n", failures);
    return failures ? 1 : 0;
}
