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
2. **RaidResHttp.dll** — so the game can fetch lists by itself. Download it
   from the [latest release](../../releases/latest), put it next to `WoW.exe`,
   and add a line `RaidResHttp.dll` to `dlls.txt`. VanillaFixes asks once
   whether to load it.
3. **RaidResLock.dll** *(optional)* — lock and unlock raidres events from in
   game. Download it from the same release, put it next to `WoW.exe`, and add
   `RaidResLock.dll` to `dlls.txt`. Requires
   **[Python 3](https://www.python.org/downloads/)** (with "Add to PATH"
   ticked) and **[Google Chrome](https://www.google.com/chrome/)** installed.
   See [Locking and unlocking from in game](#locking-and-unlocking-from-in-game).

Type `/rrb help` to see which way it's fetching.

Without the DLLs it still works, but needs a small script running outside the
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

## Matching names

raidres names are whatever people typed at signup: a typo, an accent the
keyboard didn't have, last week's alt. Unmatched, the same person shows twice,
once in the raid with nothing reserved and once on the list marked *not here*.
RollFor would give their reserves to nobody.

- **It matches them the way RollFor does.** Raid members who aren't on the
  list are paired with signups who aren't in the raid, by how alike the names
  are. Accents and case don't count, so *Jörunn* is *Jorunn*.
- **Only clear-cut pairs are matched:** at least 75% alike, and clearly the
  best pairing for both people. A matched member shows as **Corvanne · as
  Corvane**, with that signup's reserves.
- **Anything less is offered.** An unmatched signup shows **maybe Ivar?** when
  someone comes close (60% or more), and the Players label counts them (*1 to
  check*).
- **Match settles the rest.** Select the person and press **Match** (in a raid):
  - *Who is Ivor in your raid?* for a signup, closest first, or **Nobody
    here**, which also stops it being guessed at again.
  - *Which signup is Ivo?* for a raid member who isn't on the list.
  - **Unmatch**, or **Keep this match** to pin an automatic one.
- **Your choices are remembered** across sessions, in
  `RaidResBridge_Names`. People tend to sign up the same way every week.
- **RollFor gets the in-game names.** The list is renamed before it's sent, so
  RollFor sees exact matches and has nothing left to guess for those players.
  The fetched list itself is never changed, so unmatching restores it.

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

**The window's RollFor box says whether RollFor really holds the list.** It
doesn't assume a send worked. It reads RollFor's own record back
(`RollForCharDb.softres`, where RollFor 4.x keeps what it imported and when)
and compares it with what was last sent from here:

| The box says | Meaning |
|---|---|
| **In RollFor** · sent 2 minutes ago | RollFor holds exactly this list |
| **Changed since it was sent** | the list moved on after the last send |
| **RollFor holds a different list** | something else imported since, e.g. RollFor's own import window |
| **RollFor's list was cleared** | cleared in RollFor after this was sent |
| **Not sent to RollFor yet** | nothing sent from here yet |
| **RollFor refused the list** | the import failed; RollFor's reason is underneath |
| **RollFor isn't loaded** | reserves wait here until it is |

What was last sent is saved per character, as RollFor's own copy is, so the
answer holds across a `/reload`. A RollFor that keeps its list elsewhere just
means the box goes by what was sent.

RollFor answers every import in chat ("Soft-res data loaded successfully!",
then its soft-res check). After a fetch, or when you press *Send to RollFor*,
that's the confirmation you asked for, so it shows. The automatic send after
every click in the window keeps it quiet, because the box already says the
same thing and the chat would fill up otherwise.

## The window: `/rrb`

Made for the raid leader ten minutes before the pull, with a roster in front of
them and people whispering what they want. It's built from the client's own
parts so it looks like it shipped with the game:
- the Options window's dialog border, header banner and labelled boxes
- the Who list's column headers
- the quest log's highlight and +/- boss headers
- a standard dropdown
- the client's own class and item colours

With pfUI loaded, it's skinned the way pfUI skins every Blizzard window: pfUI's
backdrops, buttons, checkboxes, scroll bars and close buttons, with rows lit
flat the way pfUI's own lists are. To keep the Blizzard look under pfUI, pick
it from the minimap button's menu or type `/rrb skin blizzard`. A change to a
look that's already on screen asks to reload the UI, which is the only clean
way to swap it.

```
                      .-----------------------.
+---------------------|     Zylla RaidRes     |---------------------- [x] +
|                     '-----------------------'                           |
|  Raidres link [ https://raidres.top/res/XXXXXX ][v] [Fetch]  XXXXXX      Locked [Unlock] |
|                                                    Zul'Gurub                           |
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
|  Click loot to reserve it for Newbie (1 left).                                      |
|                                                                                     |
|  RollFor                                                                            |
|  +--------------------------------------------------------------------------------+ |
|  | ## In RollFor  sent just now [Clear typed] [View in RollFor] [Send to RollFor] | |
|  |    15 players, 28 reserves, 1 typed here                                       | |
|  +--------------------------------------------------------------------------------+ |
+-------------------------------------------------------------------------------------+
```

1. **Paste the link** at the top and press Fetch or Enter. The box keeps the
   last list's link, so fetching again to refresh it is one click. The
   **arrow** beside it lists the last five lists fetched, each with its raid
   and when, and picking one fetches it again. Beside Fetch is the list's
   code, with its raid's name underneath.
   The button at the right shows whether raidres has the list **locked**
   (green) or **unlocked** (gold), or *Lock ?* when it isn't known. With
   RaidResHttp.dll it looks again every 30 seconds while the window is open,
   so you see a late joiner's unlock and your own re-lock without leaving
   the game, and the window says when it changes. Click the button to check
   right now. Without the DLL it shows the state as of the last fetch.
   It only *shows* the lock: locking and unlocking are done on the raidres
   site.
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
5. **Every change goes to RollFor as you make it,** and the **RollFor** box at
   the bottom shows that RollFor has it (see
   [How it reaches RollFor](#how-it-reaches-rollfor)). *Send to RollFor* sends
   everything again and lets RollFor report in chat. *View in RollFor* opens
   RollFor's own soft-res window, so you can see the list the way RollFor has
   it.

The line under the lists always says what your next click will do, and answers
when a click is refused.

## The minimap button

The window is one click away, and you can check the night's state without
opening anything. Hover it for:
- **List**: the raidres list and its raid
- **Players**: how many of the raid have all their reserves (*12 of 15 done*)
- **Raidres**: whether the list is locked
- **RollFor**: whether RollFor has it (*Up to date*, *Changed, not sent*, ...)

**Left-click** opens or closes the window. **Right-click** opens the menu:
- *Send to RollFor* and *View in RollFor*
- **Look**: *Automatic* (pfUI's when pfUI is loaded), *Blizzard* or *pfUI*
- *Hide this button*. `/rrb minimap` brings it back.

**Drag** moves it around the minimap's edge. That works on the round minimap
and on pfUI's square one. Where it sits is saved. It uses the client's
tracking-button border, or pfUI's flat square in pfUI's look. pfUI's
minimap-button bar can gather it like any other button.

**The loot** is raidres's own table for the instance, in raidres's own order:
boss by boss in kill order, A to Z within each boss. Loot that more than one
boss drops comes last, under *Shared*. Items are coloured by quality, with
icons once the game has seen an item, and who holds each item is shown beside
it.
- **Sort** (above the loot, on the right): *By boss*, *A to Z* or *Z to A*.
  The last two give one list with no boss headings.
- **Show** (beside Sort): only some kinds of loot, using the same filters as
  raidres's item picker: *Cloth*, *Leather*, *Mail*, *Plate*,
  *Weapon/Shield*, *Neck*, *Cape*, *Ring*, *Trinket*, *Profession*,
  *Class* and *Hard reserved*. Tick several to see any of them; the menu stays
  open while you tick. The button says what's showing, e.g. *Plate +1*. Each
  kind matches the same words in the item's raidres tooltip that the site
  matches, so a kind shows the same items here as there. Both choices are
  remembered.

  Loot tables cached by an older version don't have kinds yet. *Show* says so and
  offers *Update loot tables*.
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

- **Remove a reservation someone else made on raidres.** It's shown as theirs,
  and deleting it here would look like it worked and come straight back on
  the next fetch. Your own you can change from here: see
  [Your own reserves](#your-own-reserves-on-raidres-from-in-game).
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

## Locking and unlocking from in game

With `RaidResHttp.dll` the lock button shows the state. Without it, the
state is whatever the last fetch saw. Either way, **locking and unlocking
on raidres normally means opening the site.**

If you'd rather do it from in game, `RaidResLock.dll` does it through
Chrome automatically:

### With the DLL (recommended)

1. **[Python 3](https://www.python.org/downloads/)** installed and on
   your PATH. The installer's "Add python.exe to PATH" checkbox does this.
2. **[Google Chrome](https://www.google.com/chrome/)** installed in the
   default location.
3. **Sign into raidres once.** Run `tools\start_chrome_cdp.bat` — it
   opens a Chrome window with its own profile. Sign into
   [raidres.top](https://raidres.top) there, then close it.
4. **Place `RaidResLock.dll`** next to `WoW.exe` and add a line
   `RaidResLock.dll` to `dlls.txt`.

That's it. When the game starts, the DLL launches the watcher in the
background and the addon detects it — no `/rrb lockcontrol on` needed.
Chrome runs headless (no visible window) for lock/unlock.

**The watcher and its Chrome close with the game, however the game ends**:
a normal exit, a crash, or Task Manager. Your own Chrome is never touched;
the watcher only ever closes the Chrome it started, which uses its own
profile (`chrome-cdp-raidres`). Two guards make sure of it:
- **The DLL starts the watcher in a Windows job object.** Only the game
  holds that job, so Windows ends the watcher whenever the game process
  ends.
- **The watcher puts its Chrome in a job of its own**, so Chrome and all its
  helper processes go when the watcher goes. The watcher is also told the
  game's process id (`watch --parent`), so it stops by itself if the game
  has gone.

`dll/build/test_lockjob.exe` checks this. It starts the watcher's own
`start_chrome` the way the DLL would, then crashes on purpose; nothing may be
left running.

**To check on your own machine**, run this while the game is open, and again
after closing it:

```bash
powershell -ExecutionPolicy Bypass -File Interface/AddOns/ZyllaRaidRes/tools/check_lock_cleanup.ps1
```

It lists each watcher and its Chrome and says which outlived its game.
`-WaitForExit` waits for the game to close and then reports.
`-StopLeftovers` ends anything left behind (only the watcher and its
profile, never your own Chrome). Builds before 1.5.0 could leave a watcher
running after the game closed. That watcher kept answering the next game's
lock commands with a Chrome nothing would close.

**Session expiry.** The lock button tooltip shows when your raidres
session expires. If the session has expired, the button turns into
**Sign in** and opens Chrome to the login page so you can re-authenticate.
After signing in, close Chrome and the next lock/unlock goes headless
again.

**`/rrb restart`** kills and restarts the helper's Chrome if it gets
stuck.

Users who don't want lock control simply leave `RaidResLock.dll` out of
`dlls.txt`. The lock button stays read-only with no errors.

### Without the DLL (manual)

1. **Python 3** and **Chrome** on the same machine.
2. Start Chrome once with `tools\start_chrome_cdp.bat` and sign into
   raidres.
3. Run the lock watcher: `python tools/raidres_lock.py watch`.
4. In game: `/rrb lockcontrol on`.

The lock button now **toggles** lock/unlock instead of only checking. The
script talks to Chrome through the DevTools Protocol, telling it to call
the same API the raidres site itself uses. **Chrome manages its own
cookies; the script never sees, stores or touches your session.** Nothing
leaves your machine except the same HTTPS request Chrome would send if you
clicked the button on the site.

The setting is saved (`/rrb lockcontrol` to check, `off` to turn it back).
Anyone without the script running gets the same read-only lock button as
before, with no errors.

## Your own reserves on raidres, from in game

Everyone else's reserves are typed into the window, because only they can sign
in to raidres as themselves. **Yours can go on raidres itself.** This uses the
same RaidResLock.dll and signed-in Chrome as locking, so set that up first.

1. Open the window and pick **yourself** in the players list. The hint says
   *Click loot to reserve it on raidres as Salahaja (1 left)*.
2. **Click loot** to reserve it on raidres.
3. **Click it again**, or the X beside it in your reserves, to take it back
   there. Your raidres rows are marked `raidres` beside that X.
4. The list is fetched again afterwards, so the window, and RollFor, show
   what raidres now has.

It makes the same requests raidres's own reservation form makes, from inside
the signed-in page. As with locking, the session never leaves Chrome.

**Your specialization.** raidres needs a spec for your first reserve on a
list. It uses the one you signed up with, or the one saved on your raidres
character. Failing both, the window asks once, from your class's own list,
and remembers it.

**What it says no to, before sending anything:** a locked list, a full limit,
a hard-reserved item, or an item that isn't in that raid's loot on raidres.
Anything raidres itself refuses comes back in raidres's own words. You're
matched as the signed-in raidres user, not by name alone, so the X never
reaches somebody else's reserve.

From a terminal, `tools/raidres_lock.py reserve` and `unreserve` do the same.
`--dry-run` looks everything up and shows what it would send, without sending
it:

```bash
python tools/raidres_lock.py reserve WW8CK7 19137 Salahaja Paladin --dry-run
```

## A new event, from in game

The raid leader's side: **make the raidres event without leaving the game.**
Like reserving, it goes through RaidResLock.dll and the signed-in Chrome.

Open it with `/rrb new`, from **New event...** at the bottom of the arrow beside
the link box, or from the minimap button's menu. It asks for what raidres's own
*Create event* form asks for:

- **Raid**: grouped by size the way raidres groups it (40-man, 20-man, 10-man,
  world boss), from raidres's own raid list. Without RaidResHttp.dll it offers
  the raids whose loot tables are cached.
- **Starts**: a day in the next two weeks, and an hour and quarter. This is on
  your own clock, the same as raidres's site in a browser; it's sent as the UTC
  raidres stores.
- **Reserves each.**
- **Lock at the start time**, **Allow comments**, **Use SR+**, and **Same item
  twice**.
- **Description.**
- **Hard reserves**: one of your saved HR lists on raidres for that raid, or
  items ticked boss by boss from the raid's loot.
- **SR+ each event** and **from**: with SR+ on, how much each event adds, and
  which of your recent lists for the same raid SR+ carries over from.

**Create event** makes it. The new link goes into the window's box and is
fetched, and you're asked whether to post it in raid (or party) chat as one
line. Anyone else running the addon gets it as a clickable link. The choices
are remembered for next time.

Extra admins and banned users are left to raidres's site: each is a list to
manage there, not a field here. A time already gone is refused
before anything is sent. Anything raidres refuses comes back in its own words,
and the dialog stays open to fix it.

**Changing an event you made**: *Event settings for REF...* under the arrow
(or `/rrb settings`, or the minimap menu) opens the same dialog for the open
list, showing only its hard reserves and SR+. They start as raidres has them
now. **Save** changes only those. The start time, admins and reserves stay as
they are. Hard reserves are sent only if you changed them, so ones set on the
site with class limits or notes aren't flattened. raidres refuses anything it
won't take, such as carrying SR+ from a list without SR+, in its own words.

From a terminal, `tools/raidres_lock.py create` does the same, and `--dry-run`
shows what it would send:

```bash
python tools/raidres_lock.py create 95 2026-11-01 20:00 1 1 1 0 0 MC Sunday --dry-run
```

## Commands

| | |
|---|---|
| `/rrb` | open or close the window |
| `/rrb <link>` | fetch that list and import it |
| `/rrb load` | import what was fetched, plus anything typed |
| `/rrb lockcontrol` | toggle in-game lock/unlock (manual mode, without RaidResLock.dll) |
| `/rrb restart` | restart the helper script's Chrome (if it gets stuck) |
| `/rrb new` | make a new raidres event (needs RaidResLock.dll) |
| `/rrb settings` | change the open list's hard reserves and SR+ |
| `/rrb minimap` | show or hide the minimap button |
| `/rrb skin auto`, `blizzard` or `pfui` | pick the look; `auto` is pfUI's when pfUI is loaded |
| `/rrb help` | the commands, and how it's fetching |
| `/rrb debug` | what RaidResHttp.dll is doing right now: requests talking, queued, and the oldest one's age |

Also `/raidres`. `/rrb gui` still works.

## Tests

Run with Lua 5.x from anywhere. Each prints its checks and exits non-zero on a
failure.

```bash
lua tools/test_bridge.lua   # lists, the merge, typed reserves, names   (139)
lua tools/test_http.lua     # the in-game fetch, against a stand-in DLL (134)
lua tools/test_gui.lua      # the window, minimap, RollFor box, events  (509)
python tools/test_lock.py   # reserving and events, in a throwaway Chrome (79)
lua tools/vanilla_lint.lua RaidResBridge.lua Http.lua Names.lua Manual.lua Gui.lua Event.lua Minimap.lua Chat.lua
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
- **`test_lock.py`** runs the watcher's real in-page reserve script in a
  throwaway headless Chrome on `about:blank`, with `fetch` answering from the
  fixtures. It checks the actual JavaScript against raidres's own reply
  shapes, and nothing leaves the machine.
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
- **RaidResLock.dll** *(optional)* for in-game lock/unlock. Needs **Python 3**
  on PATH and **Google Chrome** installed.
