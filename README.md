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
window. Type `/rrb` for a window that shows who still needs reserves and
adds them by hand for anyone who couldn't sign up.

## Install

1. **The addon.** Clone or download this repository into `Interface/AddOns`,
   so the folder is `Interface/AddOns/ZyllaRaidRes` (with `ZyllaRaidRes.toc`
   inside). The source zip from GitHub unpacks as `ZyllaRaidRes-main`, so
   rename it. The [release](../../releases/latest) zip is already named right.
2. **The DLL**, so the game can fetch by itself. Download `RaidResHttp.dll`
   from the [latest release](../../releases/latest), put it next to `WoW.exe`,
   and add a line `RaidResHttp.dll` to `dlls.txt`. VanillaFixes asks once
   whether to load it.

Type `/rrb help` to see which way it's fetching.

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

## Links in raid chat

When someone posts a raidres link in **raid chat**, it shows as a clickable
**[Raidres XXXXXX]**. Click it and the window opens with that list, already
fetching.

- **Raid chat only.** Raid, raid leader and raid warning messages. Guild,
  world, whispers and every other channel are left as they are. The click
  holds to the same rule: only a link the addon saw in raid chat this session
  does anything.
- **Switching asks first.** If it would replace a different active list, it
  asks, naming who posted it. Clicking the active list again just refreshes
  it. Reserves you typed in the window stay either way.
- **Shift-click** puts the URL in your chat box.
- **It works alongside ShaguTweaks and pfUI.** They turn URLs into
  copy-the-link links as the text is drawn. This runs one step earlier, so a
  raidres link in raid chat is already a raidres link by the time they see
  it, and every other URL is still theirs.

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

## The window: `/rrb`

Made for the raid leader ten minutes before the pull, with a roster in front of
them and people whispering what they want. It's built from the client's own
parts so it looks like it shipped with the game:
- the Options window's dialog border, header banner and labelled boxes
- the Who list's column headers
- the quest log's highlight and +/- boss headers
- a standard dropdown
- the client's own class and item colours

With pfUI loaded, it's skinned the way pfUI skins every Blizzard window.

```
                      .-----------------------.
+---------------------|     Zylla RaidRes     |---------------------- [x] +
|                     '-----------------------'                           |
|  Raidres link [ https://raidres.top/res/XXXXXX ] [Fetch]  XXXXXX  ZG, 12  |
|                                                                           |
|  Players  12 of 15 done   [ ] Missing only   Loot                         |
|  +--------------------------------------+   +----------------------------------+ |
|  | Name                  | Reserves     |   | [Zul'Gurub     v] [Search  ] [x] Usable | |
|  | Newbie                     0/2       |   | - Hakkar                         | |
|  | Zed                        0/2       |   |   [] Heart of Hakkar  v Newbie   | |
|  | Aldwyn  not here           2/2       |   |   [] Zin'rokh       Hard reserve | |
|  | ...                                  |   | + Jin'do the Hexxer              | |
|  +--------------------------------------+   | ...                              | |
|  Newbie's reserves  1 of 2                  |                                  | |
|  +--------------------------------------+   |                                  | |
|  |  [] Bloodsoaked Legplates        [X] |   |                                  | |
|  +--------------------------------------+   +----------------------------------+ |
|  Click loot to reserve it for Newbie (1 left).  [Clear typed] [Send to RollFor] |
+---------------------------------------------------------------------------+
```

1. **Paste the link** at the top and press Fetch or Enter. The box keeps the
   last list's link, so fetching again to refresh it is one click.
2. **The players are your raid**, each counted against the event's own limit:
   red with nothing, yellow part way, green when done. Whoever still has
   reserves to make is at the top. People on the list who aren't in your group
   yet follow, marked *not here*. Tick **Missing only** to see only those
   still to reserve. Click **Name** or **Reserves** to sort by that column.
3. **Pick one.** Its row stays lit, and their reserves show under the list. Ones typed here have an
   X to take them back, and ones from raidres are marked `raidres` and locked.
   Click the player again to let go.
4. **Click loot** to reserve it for them, and click again to take it back.
   Rows they hold get a check mark. When they're full, the rest of the loot
   dims.
5. **Every change goes to RollFor as you make it.** *Send to RollFor* only
   sends everything again, e.g. after RollFor was reloaded.

The line at the bottom always says what your next click will do, and answers
when a click is refused.

**The loot** is raidres's own table for the instance, grouped by boss and
coloured by quality, with item icons once the game has seen an item. Who holds
each item is shown beside it.
- **It picks the raid for you,** and the newest signal wins:
  1. **The raid your group is in.** Yours if you're inside one, otherwise
     wherever most of your raid already is. One member inside is enough, so
     the loot is ready while you're still in town. It reads the zone from the
     raid roster, the same one a member's tooltip shows, and checks again
     every few seconds while the window is open. Offline members don't count.
     On a tie, the list's own raid wins if it's one of them.
  2. **A newly fetched list** switches to the list's raid.
  3. **Choosing from the dropdown** stands until one of those changes. Everyone
     leaving a raid doesn't change it.

  The *Loot* label says which it went by: *you're here*, *3 of your raid are
  here*, or *the list's raid*.
  Raid zones are named after their raids, apart from AQ40 (zone *Ahn'Qiraj*)
  and UBRS (zone *Blackrock Spire*), which it knows. World bosses are left to
  the dropdown, because standing in Azshara says nothing about Azuregos.
- **Boss headers fold** like zones in the quest log. A search opens them all,
  so nothing it finds stays hidden.
- **Search** matches item or boss names, so `hakkar` shows Hakkar's loot.
- **Usable** (on by default) hides items the selected player's class can't
  use, such as other classes' tier pieces. Loot meant for everyone always
  shows.
- **Clicks work as elsewhere in the game:** shift-click links the item in chat
  (or a WIM whisper), and ctrl-click tries it on. Hover for the tooltip, which
  also says what a click will do.

**Loot tables** download once from the bottom of the dropdown, or from the button in
an empty loot pane (23 raids, ~150KB). They change when the server patches,
not when somebody reserves something. Fetching a list also brings that raid's
table along.

### What it won't let you do

- **Remove a reservation someone made on raidres.** It's shown as theirs, and
  deleting it here would look like it worked and come straight back on the
  next fetch. Change it on raidres.
- **Soft-reserve a hard-reserved item.**
- **Go over the event's limit.** The limit comes from the event itself, not an
  assumption, so a list that allows one won't quietly take a second.
- **Clear what you typed without asking first.** *Clear typed* says how many
  it will remove and needs a yes. Reserves from raidres stay.

Typed entries live in SavedVariables, separate from the fetched list, and are
merged on the way to RollFor. They're kept separate because **a refetch must
not discard what you typed**. A player on both sides keeps one entry holding
both sets of items, and an item on both sides isn't doubled.

A list with nothing fetched at all is fine. A raid organised entirely in chat
is an ordinary case.

## Commands

| | |
|---|---|
| `/rrb` | open or close the window |
| `/rrb <link>` | fetch that list and import it |
| `/rrb load` | import what was fetched, plus anything typed |
| `/rrb help` | the commands, and how it's fetching |

Also `/raidres`. `/rrb gui` still works.

## Tests

Run with Lua 5.x from anywhere. Each prints its checks and exits non-zero on a
failure.

```bash
lua tools/test_bridge.lua   # reading lists, the merge, typed reserves  (86)
lua tools/test_http.lua     # the in-game fetch, against a stand-in DLL (76)
lua tools/test_gui.lua      # the window and raid-chat links, clicked   (214)
lua tools/vanilla_lint.lua RaidResBridge.lua Http.lua Manual.lua Gui.lua Chat.lua
```

- **The fixtures** in `tools/fixtures` are real raidres replies with the
  players' names, Discord ids and the event token replaced.
  `tools/make_fixtures.py` rebuilds them and writes `expected.lua`, which is
  what the watcher makes of the same replies. `test_http.lua` holds the
  in-game conversion to that, field for field.
- **`test_gui.lua`** builds the real window on a small stand-in for the 1.12
  widget API, then clicks through it the way a raid leader would. It checks
  what's on screen after each step: row texts, the hint line, enabled
  buttons, tooltips. It has no layout engine, so it can't catch a misplaced
  frame.
- **The suites are mutation-checked.** Each behaviour they claim to cover was
  broken on purpose, one at a time, to confirm a test fails.
- **`vanilla_lint.lua`** catches what Lua 5.4 accepts and the 1.12 client
  doesn't, including closures over a `for` loop's variables. Those read `nil`
  in game, because Lua 5.0 shares those variables with every closure made in
  the loop.

## Requires

- **RaidResHttp.dll** to fetch from inside the game, *or*
- **Nampower** for `CustomData`, plus the watcher. Without either there is no
  way to reach the site, and the addon says so. With the DLL, Nampower only
  keeps the list across a `/reload`.
- **RollFor** to import into — optional for fetching, required for loading.
- **Python 3** and `curl` for the watcher, if you use it.
