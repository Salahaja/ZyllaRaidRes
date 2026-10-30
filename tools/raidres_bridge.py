#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Carry a raidres list into the game, because the game cannot fetch it itself.

WoW 1.12's Lua has no network access and Nampower adds none -- sixty-odd custom
functions, not one of them HTTP. What it does add is CustomData, a folder the
client can read and write. So the addon writes down which list it wants, this
watches for that and leaves the answer beside it, and the addon reads it back.

Nothing here needs an account. raidres serves the event and the raid's item
table to anyone:

    GET /api/events/<ref>          the reservations, with character names
    GET /raids/raid_<raidId>.json  raidItemId -> the real WoW item id

The /api/events/<ref>/rollfor endpoint would hand over RollFor's own format
directly, but it is behind a login, and asking you for a session cookie to get
something already public would be a poor trade. The two public endpoints carry
everything that one does.

Usage:
    python raidres_bridge.py watch                 sit and wait for the game
    pythonw raidres_bridge.py watch --with-game    the same, hidden, quitting
                                                   when the game closes
    python raidres_bridge.py once <link-or-ref>    fetch one list and exit
    python raidres_bridge.py raids                 cache every raid's loot table
"""

import io
import json
import os
import re
import subprocess
import sys
import time

# The addon and this script meet in CustomData; the client writes there too.
HERE = os.path.dirname(os.path.abspath(__file__))
CUSTOM = os.path.normpath(os.path.join(HERE, "..", "..", "..", "..", "CustomData"))
REQUEST = "RaidResBridge_request.txt"
REPLY = "RaidResBridge_data.lua"

LOG = "RaidResBridge_watcher.log"
LOCK = "RaidResBridge_watcher.pid"

# What --with-game waits on. Several, because this client folder has more than
# one copy of the exe for running two characters at once.
GAME_EXES = ("wow.exe", "wow2.exe", "wow_modernized.exe")
GAME_GRACE = 120    # seconds for the game to appear after the launcher starts

# Run hidden under pythonw, every curl and tasklist would otherwise flash a
# console window over the game.
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)

BASE = "https://raidres.top"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")


def get(path):
    """GET as JSON, through curl.

    curl rather than urllib because the site sits behind a filter that judges
    clients by more than the user agent, and curl's TLS handshake gets through
    where Python's does not. The same reason the scraper next door uses it.
    """
    out = subprocess.check_output(
        ["curl", "-s", "--compressed", "--max-time", "30",
         "-H", "User-Agent: " + UA, "-H", "Accept: application/json",
         BASE + path],
        stderr=subprocess.DEVNULL, creationflags=NO_WINDOW)
    return json.loads(out.decode("utf-8", "replace"))


def reference(text):
    """The event id out of whatever was typed: a full link, or just the id."""
    text = (text or "").strip().rstrip("/")
    if "/" in text:
        text = text.split("/")[-1]
    return "".join(c for c in text if c.isalnum())


def sr_plus(r):
    """A reservation's SR+ is {id, value, isValid}, or null, and RollFor rolls
    with the number. isValid is not a gate: raidres's own option says it
    decides next event's SR+ increase, not whether this one counts."""
    sp = r.get("srPlus")
    if isinstance(sp, dict):
        sp = sp.get("value")
    try:
        return int(sp or 0)
    except (TypeError, ValueError):
        return 0


def build(ref):
    """-> RollFor's RaidResData, as a plain structure.

    RollFor wants real WoW item ids; raidres numbers its items its own way and
    keeps the translation in the raid file, which is why both requests are
    needed.
    """
    event = get("/api/events/%s" % ref)
    raid = get("/raids/raid_%d.json" % event["raidId"])
    by_raid_item = dict((i["id"], i) for i in raid["raidItems"])

    characters = {}
    order = []
    skipped = 0
    for r in event.get("reservations", []):
        item = by_raid_item.get(r["raidItemId"])
        if not item:
            #[[ An item the raid file does not list. Dropping it loses one
            #   reservation; inventing an id would put somebody else's name on
            #   the wrong loot, which is worse. ]]
            skipped += 1
            continue
        name = (r.get("character") or {}).get("name")
        if not name:
            skipped += 1
            continue
        if name not in characters:
            characters[name] = {"name": name, "role": "", "items": []}
            order.append(name)
        characters[name]["items"].append({
            "id": item["gameDbItemId"],
            "quality": item.get("quality", 4),
            "sr_plus": sr_plus(r),
        })

    hard = []
    for h in event.get("advancedHrItems", []):
        item = by_raid_item.get(h["raidItemId"])
        if item and h.get("isHardReserved"):
            hard.append({"id": item["gameDbItemId"],
                         "quality": item.get("quality", 4)})

    return {
        "metadata": {
            "id": ref,
            "instance": event["raidId"],
            "instances": [raid.get("name", "")],
            "origin": "raidres",
        },
        "hardreserves": hard,
        "softreserves": [characters[n] for n in order],
    }, {
        "players": len(order),
        "reservations": sum(len(characters[n]["items"]) for n in order),
        "hard": len(hard),
        "skipped": skipped,
        "raid": raid.get("name", "?"),
        "limit": event.get("reservationLimit"),
        "locked": event.get("locked"),
    }


def lua_literal(value):
    """A Lua table, written out so the addon can loadstring it.

    Lua rather than JSON because the addon would otherwise need a JSON parser
    to read what RollFor is only going to re-encode to JSON anyway.
    """
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        out = value.replace("\\", "\\\\").replace('"', '\\"')
        out = out.replace("\n", "\\n").replace("\r", "")
        return '"' + out + '"'
    if isinstance(value, list):
        return "{" + ",".join(lua_literal(v) for v in value) + "}"
    if isinstance(value, dict):
        return "{" + ",".join(
            "[%s]=%s" % (lua_literal(k), lua_literal(v))
            for k, v in value.items()) + "}"
    return "nil"


def write_reply(ref, data, stats):
    os.makedirs(CUSTOM, exist_ok=True)
    body = (
        "-- GENERATED by raidres_bridge.py -- do not edit.\n"
        "-- %s, %d player(s), %d reservation(s).\n"
        "RaidResBridge_Data = %s\n"
        "RaidResBridge_Ref = %s\n"
        #[[ The event's own limit, so the window can say 1/2 rather than
        #   assuming. Events differ, and guessing two would quietly let a
        #   third reserve be added on a list that allows one. ]]
        "RaidResBridge_Limit = %s\n"
        % (stats["raid"], stats["players"], stats["reservations"],
           lua_literal(data), lua_literal(ref),
           lua_literal(stats.get("limit") or 2)))
    # Whether raidres has the list locked, for the window's badge. Left out
    # when the event doesn't say: that reads back as unknown, not unlocked.
    if isinstance(stats.get("locked"), bool):
        body += "RaidResBridge_Locked = %s\n" % lua_literal(stats["locked"])
    path = os.path.join(CUSTOM, REPLY)
    io.open(path, "w", encoding="utf-8", newline="\n").write(body)
    return path


#[[ Every raid raidres knows, cached for the picker.
#
#   The ids are not contiguous -- 103 to 105 are missing and 110 sits beside
#   113 -- so the range is swept rather than counted, and whatever answers is
#   what exists. Only this server's game is kept; the file also serves other
#   versions of WoW, whose loot tables would be wrong here in a way that looks
#   entirely plausible. ]]
RAID_SWEEP = list(range(90, 125))
GAME = "TURTLE"


# raidres's item-select filters, in its order: each matches an item whose
# tooltip has one of these words as a whole tag's text (">Plate</"). Copied
# from the site's own list, so "Plate" shows here exactly what it shows there.
# Http.lua holds the same list for the in-game fetch; Gui.lua names them.
ITEM_TYPES = [
    ("cloth", ["Cloth"]),
    ("leather", ["Leather"]),
    ("mail", ["Mail"]),
    ("plate", ["Plate"]),
    ("weapon", ["Arrow", "Bullet", "Held In Off-Hand", "Main Hand", "Off Hand",
                "One-hand", "Ranged", "Thrown", "Two-hand"]),
    ("neck", ["Neck"]),
    ("back", ["Back"]),
    ("ring", ["Finger"]),
    ("trinket", ["Trinket"]),
    ("profession", ["Enchanting Bag", "Explosive", "Fishing Pole", "Herb Bag"] +
     ["Requires " + p for p in ("Alchemy", "Blacksmithing", "Cooking", "Enchanting",
                                "Engineering", "First Aid", "Fishing", "Herbalism",
                                "Jewelcrafting", "Leatherworking", "Mining",
                                "Skinning", "Tailoring")]),
    ("class", ["Ammo Pouch", "Bag", "Book", "Idol", "Libram", "Part", "Quiver",
               "Reagent", "Relic", "Soul Bag", "Totem", "Classes: "]),
]
# A "Requires" line that isn't a level: a profession recipe. Those match only
# their "Requires <profession>" words; everything else only the others.
REQUIRES_OTHER = re.compile(r">requires (?!level (?:[1-9]|[1-9]\d|1[01]\d|120)\b)")
SHARED = 999    # raidres's position for loot more than one boss drops


def item_types(tooltip):
    """The ITEM_TYPES keys an item's tooltip matches, space-separated."""
    if not isinstance(tooltip, str):
        return ""
    tt = tooltip.lower()
    other = bool(REQUIRES_OTHER.search(tt))
    out = []
    for key, words in ITEM_TYPES:
        for word in words:
            w = word.lower()
            if "requires " in w:
                hit = other and (">%s</" % w in tt or ">%s (" % w in tt)
            else:
                hit = not other and ">%s</" % w in tt
            if hit:
                out.append(key)
                break
    return " ".join(out)


def fetch_raids():
    raids = {}
    for rid in RAID_SWEEP:
        try:
            raid = get("/raids/raid_%d.json" % rid)
        except Exception:
            continue
        if raid.get("game") != GAME:
            continue
        bosses = dict((b["id"], b.get("name", "?")) for b in raid.get("raidBosses", []))
        places = dict((b["id"], b.get("position", 0)) for b in raid.get("raidBosses", []))
        items = []
        for it in raid.get("raidItems", []):
            dropped_by = it.get("raidBosses") or []
            first = (dropped_by or [None])[0]
            items.append({
                "g": it.get("gameDbItemId"),
                "n": it.get("name", "?"),
                "q": it.get("quality", 4),
                "b": bosses.get(first, ""),
                "c": it.get("characterClasses") or [],
                # where it sorts: its boss's place in the kill order, or
                # SHARED when more than one boss drops it, as on raidres
                "o": SHARED if len(dropped_by) > 1 else places.get(first, SHARED),
                "t": item_types(it.get("tooltip")),
            })
        raids[rid] = {"name": raid.get("name", "?"), "items": items}
        print("  raid %-4d %-30s %3d items" % (rid, raids[rid]["name"], len(items)))

    if not raids:
        print("  no raids came back.")
        return False
    body = ("-- GENERATED by raidres_bridge.py -- do not edit.\n"
            "RaidResBridge_Raids = %s\n" % lua_literal(raids))
    os.makedirs(CUSTOM, exist_ok=True)
    path = os.path.join(CUSTOM, "RaidResBridge_raids.lua")
    io.open(path, "w", encoding="utf-8", newline="\n").write(body)
    print("  wrote %s (%d raids, %d KB)"
          % (path, len(raids), len(body) // 1024))
    return True


def fetch_once(text):
    ref = reference(text)
    if not ref:
        print("  that does not look like a raidres link or id: %r" % text)
        return False
    print("  fetching %s ..." % ref)
    try:
        data, stats = build(ref)
    except Exception as e:
        print("  failed: %s: %s" % (type(e).__name__, e))
        return False
    if stats["players"] == 0:
        print("  nothing reserved on that list yet.")
    path = write_reply(ref, data, stats)
    print("  %s: %d player(s), %d reservation(s), %d hard-reserved%s"
          % (stats["raid"], stats["players"], stats["reservations"],
             stats["hard"],
             (", %d skipped" % stats["skipped"]) if stats["skipped"] else ""))
    if stats.get("locked"):
        print("  note: the list is LOCKED, so it will not change again.")
    print("  wrote %s" % path)
    print("  in game: /rrb load")
    return True


def game_running():
    """Is any copy of the game up? tasklist, because psutil is not a given."""
    try:
        out = subprocess.check_output(["tasklist", "/FO", "CSV", "/NH"],
                                      stderr=subprocess.DEVNULL,
                                      creationflags=NO_WINDOW)
    except Exception:
        return True     # cannot tell -- keep serving rather than vanish
    for line in out.decode("mbcs", "replace").splitlines():
        name = line.split(",", 1)[0].strip('"').lower()
        if name in GAME_EXES:
            return True
    return False


def pid_alive(pid):
    """Windows has no os.kill(pid, 0); ask the kernel for the exit code."""
    import ctypes
    k = ctypes.windll.kernel32
    h = k.OpenProcess(0x1000, False, pid)   # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return False
    code = ctypes.c_ulong()
    k.GetExitCodeProcess(h, ctypes.byref(code))
    k.CloseHandle(h)
    return code.value == 259                # STILL_ACTIVE


def take_lock():
    """One watcher at a time.

    Launching the game twice -- the second client -- runs the launcher twice,
    and two watchers would both answer every request and race on the reply.
    """
    path = os.path.join(CUSTOM, LOCK)
    try:
        other = int(io.open(path).read().strip())
        if other != os.getpid() and pid_alive(other):
            return False
    except (IOError, OSError, ValueError):
        pass
    os.makedirs(CUSTOM, exist_ok=True)
    io.open(path, "w").write(str(os.getpid()))
    return True


def drop_lock():
    path = os.path.join(CUSTOM, LOCK)
    try:
        if int(io.open(path).read().strip()) == os.getpid():
            os.remove(path)
    except (IOError, OSError, ValueError):
        pass


def watch(with_game=False):
    if not take_lock():
        print("another watcher is already running.")
        return
    try:
        _watch(with_game)
    finally:
        drop_lock()


def _watch(with_game):
    """Wait for the game to ask for something.

    Polling a file rather than anything cleverer because the game can only
    write files, and a request that arrives while this is not running should
    still be picked up when it starts -- which falls out of checking the file
    rather than watching for a change to it.
    """
    req = os.path.join(CUSTOM, REQUEST)
    print("watching %s" % req)
    print("in game: /rrb <raidres link>   (Ctrl+C to stop)\n")
    last = None
    started = time.time()
    seen_game = False
    tick = 0
    while True:
        try:
            #[[ Checked every ten seconds, not every pass: tasklist is a
            #   process of its own, and two seconds is for the request file. ]]
            if with_game and tick % 5 == 0:
                if game_running():
                    seen_game = True
                elif seen_game or time.time() - started > GAME_GRACE:
                    print("[%s] the game has closed, stopping."
                          % time.strftime("%H:%M:%S"))
                    return
            tick += 1
            if os.path.exists(req):
                text = io.open(req, encoding="utf-8", errors="replace").read().strip()
                #[[ Compared by content, not by timestamp: asking for the same
                #   list twice in a row is a deliberate refresh, and the file's
                #   mtime would say nothing had happened. ]]
                stamped = text + "|" + str(os.path.getmtime(req))
                if text and stamped != last:
                    last = stamped
                    print("[%s] request: %s" % (time.strftime("%H:%M:%S"), text))
                    if text == "RAIDS":
                        fetch_raids()
                    else:
                        fetch_once(text)
                    print("")
            time.sleep(2)
        except KeyboardInterrupt:
            print("\nstopped.")
            return
        except Exception as e:
            print("  watcher error: %s: %s" % (type(e).__name__, e))
            time.sleep(5)


if __name__ == "__main__":
    #[[ pythonw has no console: sys.stdout is None and every print would go
    #   nowhere. Into a log instead, so a fetch that failed says why. ]]
    if sys.stdout is None:
        os.makedirs(CUSTOM, exist_ok=True)
        sys.stdout = sys.stderr = io.open(os.path.join(CUSTOM, LOG), "w",
                                          encoding="utf-8", buffering=1)
    cmd = sys.argv[1] if len(sys.argv) > 1 else "watch"
    if cmd == "raids":
        sys.exit(0 if fetch_raids() else 1)
    elif cmd == "once" and len(sys.argv) > 2:
        sys.exit(0 if fetch_once(sys.argv[2]) else 1)
    elif cmd == "watch":
        watch(with_game="--with-game" in sys.argv[2:])
    else:
        sys.exit(__doc__)
