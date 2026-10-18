# RaidResHttp.dll

Lets the WoW 1.12 client fetch pages from raidres.top, so RaidResBridge's
`/rrb <link>` works with no watcher running outside the game.

It adds `RaidResHttpGet(path)`, `RaidResHttpResult(id)` and
`RaidResHttpStatus()` to the game's Lua. The host is fixed, only GET is
possible, redirects are refused, and paths may hold only letters, digits and
`/ _ . -`. Requests run on their own threads, so the game never waits on the
network.

## It never costs the game anything

A request thread lives inside WoW's process, and with two clients running
there are two of them competing for the same cores. So, since 1.3.0:

| | |
|---|---|
| **A hard deadline** | 30 seconds per request, however slowly the server answers. Each single wait is also capped at 10 seconds. |
| **Three at a time** | At most 3 requests talk to the network at once, per client. The rest wait their turn, which costs nothing. Each client has its own 3, so one client's stuck request never holds up another's. |
| **Below normal priority** | The game's own threads always come first. |
| **No spin** | A read that returns nothing ends the reply rather than asking again. |

1.1.0 and 1.2.0 had none of these. A server that never answered, or one that
trickled a byte at a time, kept the request's thread alive indefinitely. Each
fetch that hit one added another, until the game was closed.

`/rrb debug` shows what the DLL is doing: how many requests are talking,
waiting their turn and not yet collected, and the oldest one's age. Nothing
should ever be older than the deadline.

## Build

Needs Visual Studio 2022 Build Tools (C++). The output is 32-bit with a static
runtime, so it needs no redistributable.

```
build.bat
build\test_fetch.exe [ref]   fetches real pages through the same code, outside the game;
                             give an event ref to fetch that event too

python tools\fake_server.py  a local stand-in that answers, stalls, hangs or trickles
build\test_local.exe         the request threads against it: deadlines, the cap,
                             priority, and that no thread is left behind
build\test_local.exe cap     just the cap; run two at once, as two clients would
```

Install: copy `build\RaidResHttp.dll` next to `WoW.exe` and add the line
`RaidResHttp.dll` to `dlls.txt`.

## How it hooks in

The approach and addresses come from [ClassicAPI](https://github.com/brues-code/ClassicAPI). Its
notes are verified against OctoWoW's WoW.exe, and the bytes were checked again
against this client before use:

- `LoadScriptFunctions` (0x490250) is hooked, and the two functions are
  registered after it with `FrameScript_RegisterFunction` (0x704120). This
  runs on every Lua rebuild, so they survive `/reload`.
- The engine's check that rejects Lua C functions outside WoW.exe
  (0x42A320) is turned into a no-op, as ClassicAPI and the others do.
- Hooks are installed from the `Load` export, which VanillaFixes calls on the
  main thread once every DLL is in, never from DllMain.

`external/minhook-1.3.3` is [MinHook](https://github.com/TsudaKageyu/minhook) 1.3.3 (BSD-2, see its LICENSE.txt), unmodified apart from leaving out its build projects.
