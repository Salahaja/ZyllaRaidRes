# Zylla RaidRes

Pull a [raidres](https://raidres.top) soft-reserve list into
[RollFor](https://github.com/sica42/roll-for-vanilla) from inside WoW 1.12
(Turtle WoW / OctoWoW).

```
/rrb https://raidres.top/res/XXXXXX
```

```
RaidRes: fetching XXXXXX...
RaidRes: imported 12 player(s), 24 reservation(s), 1 hard-reserved (XXXXXX).
```

No website, no export button, no copying a base64 blob into RollFor's import
window. There's also a window (`/rrb gui`) for adding reserves by hand for
anyone who couldn't sign up.

## Install

1. **The addon.** Clone or download this repository into `Interface/AddOns`,
   so the folder is `Interface/AddOns/ZyllaRaidRes` (with `ZyllaRaidRes.toc`
   inside). The source zip from GitHub unpacks as `ZyllaRaidRes-main`, so
   rename it. The [release](../../releases/latest) zip is already named right.
2. **The DLL**, so the game can fetch by itself. Download `RaidResHttp.dll`
   from the [latest release](../../releases/latest), put it next to `WoW.exe`,
   and add a line `RaidResHttp.dll` to `dlls.txt`. VanillaFixes asks once
   whether to load it.

Type `/rrb` with nothing after it to see which way it's fetching.

Without the DLL it still works, but needs a small script running outside the
game (see [the watcher](#without-the-dll-the-watcher)).

## Why a DLL

WoW 1.12's Lua has **no network access**, and none of the usual client mods
(Nampower, SuperWoW, UnitXP) adds any. So the game can't fetch the list by
itself with an addon alone.

`RaidResHttp.dll` adds two Lua functions and nothing else:

| | |
|---|---|
| `RaidResHttpGet(path)` | starts a GET of `https://raidres.top<path>`, returns an id |
| `RaidResHttpResult(id)` | `"pending"`, or `"done", status, body`, or `"failed", reason` |

**It can only read pages from raidres.top.** The host is fixed in the DLL,
only GET is possible, and redirects aren't followed. Paths may hold only
letters, digits and `/ _ . -`. A general "fetch any URL" function would let
every installed addon send your data anywhere, and this can't.

The request runs on a thread of its own, so the game never waits on the
network. The addon checks five times a second while a request is in flight
and stops checking when it's done.

The addon does what the watcher did with a page, in `Http.lua`: parse the
JSON, map raidres's item numbers to real WoW item ids, and write the same
`CustomData` files (when Nampower is there). So a list is still there after a
`/reload`. The tests hold the Lua conversion to the Python one, field for
field. Fetching a list also caches that raid's loot table for the window, and
**Get loot** fetches every raid table with no `/reload` needed.

The DLL's source, build script and notes are in [`dll/`](dll). It's built
with Visual Studio 2022 Build Tools, 32-bit, with a static runtime.

## Without the DLL: the watcher

WoW 1.12 can't reach the network, but with Nampower it can read and write files
in `CustomData`. So the addon writes down which list it wants, a small script
outside the game notices and leaves the answer beside it, and the addon reads it
back.

The easy way is to launch the game with `tools/play_with_raidres.bat` (or a
shortcut to it, set to run minimised). It starts the watcher hidden, then the
game through VanillaFixes, so Nampower is loaded. The watcher quits by itself
about ten seconds after the last copy of the game closes. If no game shows up
within two minutes, it quits then too.

```
play_with_raidres.bat            WoW.exe
play_with_raidres.bat WoW2.exe   the second client
```

Only one watcher runs at a time. Launching the second client starts no second
watcher, and the first one stays up until both games are closed. With no
console, its output goes to `CustomData/RaidResBridge_watcher.log`. Look there
when a `/rrb` gets no answer.

The game itself cannot start the watcher. 1.12 Lua has no `os.execute`, and
Nampower can only read and write files.

To run it by hand instead, leave this running:

```bash
cd "Interface/AddOns/ZyllaRaidRes/tools"
python raidres_bridge.py watch
```

Then in game, `/rrb <link>`. That is the whole thing.

To fetch without the game at all:

```bash
python raidres_bridge.py once https://raidres.top/res/XXXXXX
```

then `/rrb load` in game.

## No account needed

raidres serves both halves of what this needs to anyone:

| | |
|---|---|
| `GET /api/events/<ref>` | the reservations, with character names and classes |
| `GET /raids/raid_<raidId>.json` | `raidItemId` → the real WoW item id |

There **is** an endpoint that hands over RollFor's own format directly —
`/api/events/<ref>/rollfor` — but it is behind a login. Asking you for a
session cookie to fetch something already public would be a poor trade, so this
uses the two open endpoints and does the conversion itself. Nothing here
touches your account.

The translation matters: raidres numbers its items its own way, and RollFor
wants real WoW item ids. Getting that wrong is the failure that looks fine —
RollFor would import happily and then match nothing that ever drops — so the
tests check every id is plausible.

## How it reaches RollFor

Through `RollFor.key_bindings.import`, the same entry point RollFor's own
keybinding uses. It takes the list as a plain table and does the encoding,
importing, persisting and window refresh itself. Going through that rather
than reproducing any of it is what keeps this working when RollFor changes how
it stores things.

If RollFor is not loaded, the list is still fetched and waiting, and the addon
says so rather than failing quietly. A soft-reserve list that silently does not
load is worse than one that never loaded, because the raid finds out when the
loot drops.

## The window — `/rrb gui`

Pick a player, pick an instance, click the loot. RollFor can import a list but
has no way to see one, and its only soft-res window is a box you paste base64
into.

```
Soft Reserves              24 reservation(s), limit 2 each,  2 by hand
 Ayla      0/2  <        Zul'Gurub  (click the name on the left to change)
 Morn      0/2            Jeklik
 Zed       1/2              Primal Hakkari Shawl
 Grimtusk  2/2              Jin'do's Evil Eye      Aldwyn
 ...                      Venoxis
 [Send to RollFor] [Re-fetch] [Get loot] [Clear typed]
```

**The players come from the raid**, each showing their count against the
event's limit, with **whoever has reserved nothing at the top** — they are
the reason the window is open. People already on the list who have not zoned in
yet are listed after them. Anyone at the limit is dimmed and sinks to the
bottom.

**The loot comes from raidres's own table for the instance**, grouped by boss,
coloured by quality, with the name of anyone who already has it beside it.
Hover for the tooltip. Clicking gives it to the selected player; clicking again
takes it back.

The instance is chosen from the same left-hand pane — click the header and
it becomes a list of raids, click one and it goes back to players. One set of
rows doing two jobs, rather than a dropdown.

**Press "Get loot" once** to cache the loot tables (23 raids, ~150KB). They
change when the server patches, not when somebody reserves something, so they
are fetched on their own rather than with every list.

### What it will not let you do

Remove a reservation somebody made on the website. It is shown as theirs, and
deleting it here would look like it worked and come straight back on the next
fetch. Only typed lines carry a way to remove them.

Go over the event's limit. That limit comes from the event itself, not an
assumption — a list that allows one would otherwise quietly take a second.

Typed entries live in SavedVariables, separate from the fetched list, merged on
the way to RollFor. Separate because **a refetch must not discard what you
typed**. A player on both sides keeps one entry holding both sets of items; an
item on both sides is not doubled.

A list with nothing fetched at all is fine — a raid organised entirely in
chat is an ordinary case.

## Commands

| | |
|---|---|
| `/rrb <link>` | fetch that list and import it |
| `/rrb gui` | pick a player, pick an instance, click the loot |
| `/rrb load` | import what was fetched, plus anything typed |
| `/rrb` | what it does, and the last list imported |

Also `/raidres`.

## Tests

```bash
lua tools/test_bridge.lua
lua tools/test_http.lua
```

`test_http.lua` drives the in-game fetch against replies saved from the site
(`tools/fixtures`, with the players' names and ids replaced) and a stand-in for the DLL. It checks the result against
what the watcher makes of the same replies, which `tools/make_fixtures.py`
writes to `fixtures/expected.lua`.

Driven against the file the real fetcher produced rather than a fixture,
because the thing most likely to break is the shape of that file rather than
the logic around it. 86 checks, mutation-checked twelve ways.

## Requires

- **RaidResHttp.dll** to fetch from inside the game, *or*
- **Nampower** for `CustomData`, plus the watcher. Without either there is no
  way to reach the site, and the addon says so. With the DLL, Nampower only
  keeps the list across a `/reload`.
- **RollFor** to import into — optional for fetching, required for loading.
- **Python 3** and `curl` for the watcher, if you use it.
