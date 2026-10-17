# RaidResHttp.dll

Lets the WoW 1.12 client fetch pages from raidres.top, so RaidResBridge's
`/rrb <link>` works with no watcher running outside the game.

It adds `RaidResHttpGet(path)` and `RaidResHttpResult(id)` to the game's Lua.
The host is fixed, only GET is possible, redirects are refused, and paths may
hold only letters, digits and `/ _ . -`. Requests run on their own threads, so
the game never waits on the network.

## Build

Needs Visual Studio 2022 Build Tools (C++). The output is 32-bit with a static
runtime, so it needs no redistributable.

```
build.bat
build\test_fetch.exe [ref]   fetches real pages through the same code, outside the game;
                             give an event ref to fetch that event too
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
