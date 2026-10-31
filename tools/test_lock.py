"""test_lock.py -- reserving and unreserving, without touching raidres.

    python tools/test_lock.py

The watcher's in-page script (_RESERVE_JS) runs in a real Chrome: a
throwaway headless one on about:blank, its own profile and port, gone when
this ends. fetch() there is replaced by a stand-in that answers from the
real raidres replies in tools/fixtures and records what was sent. So these
check the actual JavaScript the watcher runs against the site's own shapes,
and nothing ever leaves the machine.
"""

import copy, json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import raidres_lock as w

checks = failures = 0

def check(label, got, want):
    global checks, failures
    checks += 1
    if got != want:
        failures += 1
        print("  FAIL %s: got %r, wanted %r" % (label, got, want))

def fixture(name):
    with open(os.path.join(HERE, "fixtures", name), encoding="utf-8") as f:
        return json.load(f)

EVENT = fixture("event_DEMO42.json")
RAID = fixture("raid_100.json")
GAME_ID = {i["id"]: i["gameDbItemId"] for i in RAID["raidItems"]}
RAIDRES_ID = {v: k for k, v in GAME_ID.items()}

# ------------------------------------------------------------------ python side
print("checking what the game sends")
check("a good reserve passes", w.check_reserve("DEMO42", "19721", "Aldwyn", "Paladin"), 19721)
check("with a spec of its class", w.check_reserve("DEMO42", 19721, "Aldwyn", "Paladin",
                                                  "PaladinHoly"), 19721)
check("an accented name passes", w.check_reserve("DEMO42", 1, "Aldwýn", "Paladin"), 1)
for label, call in [
        ("a bad ref", lambda: w.check_reserve("../x", 1, "Aldwyn", "Paladin")),
        ("a bad item", lambda: w.check_reserve("DEMO42", "abc", "Aldwyn", "Paladin")),
        ("a name with a quote", lambda: w.check_reserve("DEMO42", 1, "Al'dwyn", "Paladin")),
        ("an unknown class", lambda: w.check_reserve("DEMO42", 1, "Aldwyn", "Monk")),
        ("another class's spec", lambda: w.check_reserve("DEMO42", 1, "Aldwyn", "Paladin",
                                                         "WarriorFury"))]:
    try:
        call()
        check(label + " is refused", "passed", "refused")
    except ValueError:
        check(label + " is refused", "refused", "refused")
check("taking one back needs no class", w.check_reserve("DEMO42", 1, "Aldwyn", None, None, True), 1)
check("ok comes back as one line", w.reserve_line({"result": "ok", "done": "reserved",
                                                   "spec": "PaladinHoly"}), "ok reserved PaladinHoly")
check("an error carries raidres's words", w.reserve_line({"result": "error", "message": "nope"}),
      "error: nope")
check("an error with no words still says so", w.reserve_line({"result": "error"}),
      "error: raidres didn't say why")
check("asking for a spec", w.reserve_line({"result": "needspec"}), "needspec")

print("a new event, as the game sends it")
from datetime import datetime, timedelta, timezone
NOW = datetime(2026, 10, 29, 18, 0).astimezone()
body = w.event_body("95", "2026-11-02", "20:00", "2", "1", "1", "0", "0", "MC Sunday", now=NOW)
check("the raid and the reserves each", (body["raidId"], body["reservationLimit"]), (95, 2))
check("the switches", (body["lockAtStartTime"], body["allowComments"], body["allowSrPlus"],
                       body["allowDuplicateReservation"]), (True, True, False, False))
check("the description", body["description"], "MC Sunday")
start = datetime.strptime(body["startTime"], "%Y-%m-%dT%H:%M:%S.000Z").replace(tzinfo=timezone.utc)
check("the start goes as UTC, the way the form's toISOString() sends it",
      start.astimezone().strftime("%Y-%m-%d %H:%M"), "2026-11-02 20:00")
check("ending in Z", body["startTime"].endswith(".000Z"), True)
check("what the form keeps for later goes empty",
      (body["advancedHrItems"], body["extraAdministratorUserIdentifiers"], body["forbiddenUserIds"],
       body["previousRaidEventReference"], body["locked"]), ([], [], [], None, None))
for label, call in [
        ("a time already gone", lambda: w.event_body("95", "2026-10-29", "17:00", "1", "0", "1", "0",
                                                     "0", "", now=NOW)),
        ("no such day", lambda: w.event_body("95", "2026-02-30", "20:00", "1", "0", "1", "0", "0", "",
                                             now=NOW)),
        ("too many reserves each", lambda: w.event_body("95", "2026-11-02", "20:00", "11", "0", "1",
                                                        "0", "0", "", now=NOW)),
        ("a switch that isn't 0 or 1", lambda: w.event_body("95", "2026-11-02", "20:00", "1", "yes",
                                                            "1", "0", "0", "", now=NOW)),
        ("a bad raid", lambda: w.event_body("x", "2026-11-02", "20:00", "1", "0", "1", "0", "0", "",
                                            now=NOW))]:
    try:
        call()
        check(label + " is refused", "passed", "refused")
    except ValueError:
        check(label + " is refused", "refused", "refused")
check("a short command is refused before Chrome", w.create_event(["95", "2026-11-02"]),
      "error: bad command")
check("a bad setting is refused before Chrome", w.event_settings(["DEMO42", "srplus=maybe"]),
      "error: srplus must be 0 or 1")
check("so is an unknown one", w.event_settings(["DEMO42", "admins=all"]), "error: bad setting: 'admins=all'")
check("reserves each must be 1 or more", w.event_settings(["DEMO42", "limit=0"]), "error: reserves each out of range")
check("the same item twice is 0 or 1", w.event_settings(["DEMO42", "dupes=yes"]), "error: dupes must be 0 or 1")
check("an admin change must say which way", w.set_admin(["DEMO42", "Brisa", "maybe"]), "error: bad command")
check("and a name, not a path", w.set_admin(["DEMO42", "../x", "add"]), "error: bad character name: '../x'")
check("a saved account must be digits", w.set_admin(["DEMO42", "Brisa", "add", "id=12ab"]),
      "error: bad raidres user-ID: 'id=12ab'")
body = w.event_body("95", "2026-11-02", "20:00", "2", "0", "1", "0", "0", "", now=NOW,
                    options={"admins": "221800000000000001,221800000000000002,221800000000000001"})
check("a new event's admins go as raidres user-IDs, as text, once each",
      body["extraAdministratorUserIdentifiers"], ["221800000000000001", "221800000000000002"])
for label, admins in [("an admin id that isn't digits", "12,ab"),
                      ("an eleventh admin", ",".join(str(100 + i) for i in range(11)))]:
    try:
        w.event_body("95", "2026-11-02", "20:00", "2", "0", "1", "0", "0", "", now=NOW,
                     options={"admins": admins})
        check(label + " is refused", "passed", "refused")
    except ValueError:
        check(label + " is refused", "refused", "refused")
check("admins come before the description", w.split_options(["admins=1,2", "MC"]),
      ({"admins": "1,2"}, "MC"))
check("an SR+ change must say what", w.set_srplus(["DEMO42", "1", "Aldwyn", "value=x"]),
      "error: bad SR+ change: 'value=x'")
opts, desc = w.split_options(["hr=19137,17076", "inc=10", "prev=WW8CK7", "MC", "inc=5", "night"])
check("options come before the description", (opts, desc),
      ({"hr": "19137,17076", "inc": "10", "prev": "WW8CK7"}, "MC inc=5 night"))
body = w.event_body("95", "2026-11-02", "20:00", "2", "0", "1", "1", "0", "",
                    now=NOW, options={"inc": "10", "skip": "1", "input": "0", "valid": "1",
                                      "prev": "WW8CK7"})
check("SR+ settings go as raidres's form names them",
      (body["defaultSrPlusIncrease"], body["srPlusAllowEventSkipCount"], body["allowSrPlusInput"],
       body["requireSrPlusValidation"], body["previousRaidEventReference"]), (10, 1, False, True, "WW8CK7"))
body = w.event_body("95", "2026-11-02", "20:00", "2", "0", "1", "0", "0", "",
                    now=NOW, options={"inc": "10", "prev": "WW8CK7"})
check("and are dropped with SR+ off", (body["defaultSrPlusIncrease"], body["previousRaidEventReference"]),
      (0, None))
try:
    w.event_body("95", "2026-11-02", "20:00", "2", "0", "1", "1", "0", "", now=NOW,
                 options={"prev": "../x"})
    check("a bad carry-over list is refused", "passed", "refused")
except ValueError:
    check("a bad carry-over list is refused", "refused", "refused")

print("is the list locked, by the site's rule")
import datetime
import raidres_bridge as bridge
START = datetime.datetime(2026, 11, 1, 20, tzinfo=datetime.timezone.utc).timestamp()

def ev(**fields):
    e = {"locked": None, "lockAtStartTime": False, "lockMinutesBeforeStartTime": 0,
         "startTime": "2026-11-01T20:00:00.000Z"}
    e.update(fields)
    return e

check("locked", bridge.event_locked(ev(locked=True)), True)
check("unlocked", bridge.event_locked(ev(locked=False)), False)
check("never set is open", bridge.event_locked(ev()), False)
check("never set, locking at the start: open before it",
      bridge.event_locked(ev(lockAtStartTime=True), now=START - 1), False)
check("and locked from it", bridge.event_locked(ev(lockAtStartTime=True), now=START), True)
check("its minutes before count", bridge.event_locked(
    ev(lockAtStartTime=True, lockMinutesBeforeStartTime=30), now=START - 1800), True)
check("but not a second sooner", bridge.event_locked(
    ev(lockAtStartTime=True, lockMinutesBeforeStartTime=30), now=START - 1801), False)
check("a lock someone set wins over the start time",
      bridge.event_locked(ev(locked=False, lockAtStartTime=True), now=START + 99), False)
check("an event with no lock at all is unknown", bridge.event_locked({"startTime": "x"}), None)
check("so is one that isn't true or false", bridge.event_locked(ev(locked="yes")), None)
check("or a start time that can't be read",
      bridge.event_locked(ev(lockAtStartTime=True, startTime="soon")), None)

# ------------------------------------------------------------------ in a real Chrome
tmp = tempfile.mkdtemp(prefix="raidres-lock-test-")
os.environ["LOCALAPPDATA"] = tmp       # its own profile, never the signed-in one
w.CDP_PORT = 9341                      # and never the real watcher's port
w.log = lambda msg: None
if not w.find_chrome_exe():
    print("Chrome isn't installed: skipping the in-page checks")
    print("\n%d check(s), %d failure(s)" % (checks, failures))
    sys.exit(1 if failures else 0)
if not w.start_chrome("about:blank", headless=True):
    print("FAIL: could not start a test Chrome")
    sys.exit(1)
tab = next(t for t in w.cdp_tabs() if t.get("type") == "page" and t.get("webSocketDebuggerUrl"))
ws = w.WebSocket(tab["webSocketDebuggerUrl"])

def run(args, me="1000", event=None, chars=None, reply=None, script=None, tpls=None, sugg=None):
    """Run an in-page script once against a stand-in site. Returns (answer, sent)."""
    site = {
        "me": {"status": 200, "body": {"id": me}} if me else {"status": 401, "body": None},
        "event": {"status": 200, "body": event if event is not None else EVENT},
        "raid": {"status": 200, "body": RAID},
        "chars": {"status": 200, "body": chars if chars is not None else []},
        "reply": reply or {"status": 201, "body": {"ok": True}},
        "tpls": {"status": 200, "body": tpls if tpls is not None else []},
        "sugg": sugg or {"status": 201, "body": []},
    }
    stand_in = r"""
    (site) => {
      window.__sent = [];
      window.fetch = async (url, opts) => {
        opts = opts || {};
        let r;
        if (url === '/api/auth/me') r = site.me;
        else if (url.startsWith('/api/events/') && (opts.method === 'PATCH' || opts.method === 'PUT')) {
          window.__sent.push({ url, method: opts.method, body: JSON.parse(opts.body) });
          r = site.reply;
        }
        else if (url.startsWith('/api/events/')) r = site.event;
        else if (url.startsWith('/raids/raid_')) r = site.raid;
        else if (url === '/api/user-characters') r = site.chars;
        else if (url === '/api/raid-event-templates') r = site.tpls;
        else if (url.startsWith('/api/sr-plus/previous-event-suggestions?raidId=')) {
          window.__sent.push({ url, method: 'GET' });
          r = site.sugg;
        }
        else if (url === '/api/events' || url.startsWith('/api/raid-event-reservations')) {
          window.__sent.push({ url, method: opts.method, body: JSON.parse(opts.body) });
          r = site.reply;
        } else r = { status: 404, body: null };
        return { status: r.status, ok: r.status >= 200 && r.status < 300,
                 json: async () => { if (r.body === null) throw new Error('no body'); return r.body; } };
      };
      return true;
    }
    """
    ws.call("Runtime.evaluate", {"expression": "(%s)(%s)" % (stand_in, json.dumps(site)),
                                 "returnByValue": True})
    out = ws.call("Runtime.evaluate", {
        "expression": "(%s)(%s)" % (script or w._RESERVE_JS, json.dumps(args)),
        "awaitPromise": True, "returnByValue": True})
    value = out.get("result", {}).get("result", {}).get("value")
    if not isinstance(value, str):
        raise RuntimeError("the script failed: %s" % json.dumps(out)[:400])
    sent = ws.call("Runtime.evaluate", {"expression": "JSON.stringify(window.__sent)",
                                        "returnByValue": True})["result"]["result"]["value"]
    return json.loads(value), json.loads(sent)

def args(item, name, cls="Paladin", spec=None, remove=False, dry=False):
    return {"ref": "DEMO42", "item": item, "name": name, "cls": cls, "spec": spec,
            "remove": remove, "dry": dry}

OPEN = copy.deepcopy(EVENT)
OPEN["locked"] = False
ALDWYN_ITEMS = [r["raidItemId"] for r in EVENT["reservations"]
                if r["user"]["id"] == "1000" and r["character"]["name"] == "Aldwyn"]
FREE = next(g for i, g in GAME_ID.items() if i not in ALDWYN_ITEMS)
HELD = GAME_ID[ALDWYN_ITEMS[0]]

try:
    print("reserving, in a real page")
    answer, sent = run(args(FREE, "Aldwyn"), event=EVENT)
    check("a locked list is refused", answer, {"result": "error",
                                               "message": "the list is locked on raidres"})
    check("and nothing is sent", sent, [])

    answer, sent = run(args(FREE, "Aldwyn"), me=None, event=OPEN)
    check("signed out says so", answer["result"], "signin")

    answer, sent = run(args(FREE, "Aldwyn"), event=OPEN)
    check("a full character is refused", answer["message"], "Aldwyn already has 2 of 2 reserved")

    one = copy.deepcopy(OPEN)
    one["reservations"] = [r for r in one["reservations"] if r["raidItemId"] != ALDWYN_ITEMS[1]]
    answer, sent = run(args(HELD, "aldwyn"), event=one)
    check("the same item twice, where the list allows it", answer["result"], "ok")
    single = copy.deepcopy(one)
    single["allowDuplicateReservation"] = False
    answer, sent = run(args(HELD, "aldwyn"), event=single)
    check("the same item twice, where it doesn't", answer.get("message"),
          "aldwyn already has that reserved")
    check("is refused before sending", sent, [])

    answer, sent = run(args(FREE, "Aldwyn"), event=one)
    check("a free item is reserved", answer, {"result": "ok", "done": "reserved",
                                              "spec": "PaladinProtection"})
    check("with one POST", [(s["method"], s["url"]) for s in sent],
          [("POST", "/api/raid-event-reservations")])
    body = sent[0]["body"]
    check("by raidres's own item id, not the game's", body["raidItemIds"], [RAIDRES_ID[FREE]])
    check("as the name and spec already signed up",
          (body["characterName"], body["characterClass"], body["specialization"]),
          ("Aldwyn", "Paladin", "PaladinProtection"))
    check("the form's other fields", (body["reference"], body["isTemporary"], body["comment"]),
          ("DEMO42", False, ""))

    answer, sent = run(args(FREE, "Aldwyn", dry=True), event=one)
    check("a dry run plans it", (answer["result"], answer["method"]), ("plan", "POST"))
    check("and sends nothing", sent, [])

    answer, sent = run(args(FREE, "Aldwyn", cls="Warrior"), event=one)
    check("another class is refused", answer["message"], "Aldwyn is signed up as Paladin")

    answer, sent = run(args(999999, "Aldwyn"), event=one)
    check("an item not in the raid is refused", answer["message"],
          "that item isn't in this raid's loot on raidres")

    print("a first reserve, and the spec")
    answer, sent = run(args(FREE, "Newcomer", cls="Mage"), event=OPEN)
    check("no spec anywhere: ask the game", answer, {"result": "needspec"})
    check("and send nothing", sent, [])
    answer, sent = run(args(FREE, "Newcomer", cls="Mage"), event=OPEN,
                       chars=[{"name": "newcomer", "class": "Mage", "specialization": "MageFire"}])
    check("a saved raidres character gives it", sent[0]["body"]["specialization"], "MageFire")
    answer, sent = run(args(FREE, "Newcomer", cls="Mage", spec="MageFrost"), event=OPEN)
    check("else the game's pick", sent[0]["body"]["specialization"], "MageFrost")
    check("for the name the game gave", sent[0]["body"]["characterName"], "Newcomer")

    answer, sent = run(args(FREE, "Newcomer", cls="Mage", spec="MageFrost"), event=OPEN,
                       reply={"status": 400, "body": {"message": "You are banned from this event"}})
    check("raidres's refusal comes back in its words", answer,
          {"result": "error", "message": "You are banned from this event"})
    answer, sent = run(args(FREE, "Newcomer", cls="Mage", spec="MageFrost"), event=OPEN,
                       reply={"status": 429, "body": {"error": "be nice"}})
    check("its spam guard too", answer["message"], "be nice")

    print("for another player")
    owner = copy.deepcopy(OPEN) | {"isAuthor": True}
    answer, sent = run(args(FREE, "Wirelock", cls="Warrior", spec="WarriorFury") | {"forOther": True},
                       event=owner)
    check("an owner reserves for another player", answer["result"], "ok")
    check("as raidres's own 'for another player' switch",
          (sent[0]["body"]["characterName"], sent[0]["body"]["isTemporary"], sent[0]["body"]["specialization"]),
          ("Wirelock", True, "WarriorFury"))
    answer, sent = run(args(FREE, "Wirelock", cls="Warrior") | {"forOther": True}, event=owner)
    check("their spec is asked for, not looked up as yours", answer, {"result": "needspec"})
    answer, sent = run(args(FREE, "Wirelock", cls="Warrior", spec="WarriorFury") | {"forOther": True},
                       event=copy.deepcopy(OPEN) | {"isAuthor": False})
    check("not for someone who doesn't run the list", (answer.get("message"), sent),
          ("only the list's owner or its admins can reserve for others", []))
    answer, sent = run(args(FREE, "Wirelock", cls="Warrior", spec="WarriorFury") | {"forOther": True},
                       event=copy.deepcopy(OPEN) | {"isAuthor": False, "extraAdministratorUserIds": ["1000"]})
    check("an admin of it may", answer["result"], "ok")
    # someone who signed up themselves: an item more beside theirs, as the
    # site lets an admin add one, counted with theirs, in their class and spec
    brisa_rows = [r for r in OPEN["reservations"] if r["character"]["name"] == "Brisa"]
    brisa_cls = brisa_rows[0]["character"]["class"]
    brisa_spec = brisa_rows[0]["character"]["specialization"]
    brisa_free = next(g for i, g in GAME_ID.items() if i not in [r["raidItemId"] for r in brisa_rows])
    answer, sent = run(args(brisa_free, "Brisa", cls=brisa_cls, spec=brisa_spec) | {"forOther": True},
                       event=owner)
    check("their own count toward the limit", (answer.get("message"), sent),
          ("Brisa already has %d of %d reserved" % (len(brisa_rows), OPEN["reservationLimit"]), []))
    roomy = copy.deepcopy(owner) | {"reservationLimit": len(brisa_rows) + 1}
    answer, sent = run(args(brisa_free, "Brisa", cls=brisa_cls) | {"forOther": True}, event=roomy)
    check("with room, an owner adds one beside theirs", answer["result"], "ok")
    check("as one for another player, in the class and spec they signed up with",
          (sent[0]["body"]["characterName"], sent[0]["body"]["isTemporary"],
           sent[0]["body"]["characterClass"], sent[0]["body"]["specialization"]),
          ("Brisa", True, brisa_cls, brisa_spec))
    answer, sent = run(args(brisa_free, "Brisa", cls="Warrior", spec="WarriorFury") | {"forOther": True},
                       event=roomy)
    check("not in another class", (answer.get("message"), sent),
          ("Brisa is signed up as %s" % brisa_cls, []))
    answer, sent = run(args(GAME_ID[brisa_rows[0]["raidItemId"]], "Brisa", cls=brisa_cls) | {"forOther": True},
                       event=roomy | {"allowDuplicateReservation": False})
    check("nor one they hold already", (answer.get("message"), sent), ("Brisa already has that reserved", []))
    made = copy.deepcopy(owner)
    made["reservations"].append({"id": 777, "raidItemId": RAIDRES_ID[FREE], "comment": None, "srPlus": None,
        "character": {"name": "Wirelock", "class": "Warrior", "specialization": "WarriorFury", "isTemporary": True},
        "user": {"id": "1000"}})
    answer, sent = run(args(FREE, "Wirelock", remove=True) | {"forOther": True}, event=made)
    check("and one you made for them comes back off", [(x["method"], x["url"]) for x in sent],
          [("DELETE", "/api/raid-event-reservations/777")])

    print("anyone's reserve, as the list's owner or an admin")
    brisa = [r for r in OPEN["reservations"] if r["character"]["name"] == "Brisa"]
    brisa_item = GAME_ID[brisa[0]["raidItemId"]]
    not_brisas = next(g for i, g in GAME_ID.items() if i not in [r["raidItemId"] for r in brisa])
    theirs = {"forOther": True, "theirs": True}
    answer, sent = run(args(brisa_item, "Brisa", remove=True) | theirs, event=owner)
    check("an owner removes one they made themselves", [(x["method"], x["url"]) for x in sent],
          [("DELETE", "/api/raid-event-reservations/%d" % brisa[0]["id"])])
    check("and hears it went", answer, {"result": "ok", "done": "removed"})
    answer, sent = run(args(brisa_item, "Brisa", remove=True) | theirs,
                       event=copy.deepcopy(OPEN) | {"isAuthor": False, "extraAdministratorUserIds": ["1000"]})
    check("so does an admin of the list", len(sent), 1)
    answer, sent = run(args(brisa_item, "Brisa", remove=True) | theirs,
                       event=copy.deepcopy(OPEN) | {"isAuthor": False})
    check("nobody else", (answer.get("message"), sent),
          ("only the list's owner or its admins can remove someone's reserve", []))
    answer, sent = run(args(not_brisas, "Brisa", remove=True) | theirs, event=owner)
    check("one they don't hold is refused", (answer.get("message"), sent),
          ("Brisa hasn't reserved that on raidres", []))
    answer, sent = run(args(brisa_item, "Brisa", remove=True) | {"forOther": True}, event=owner)
    check("unreserve-for still takes back only what you made", (answer.get("message"), sent),
          ("Brisa hasn't reserved that on raidres", []))
    answer, sent = run(args(brisa_item, "Brisa", remove=True, dry=True) | theirs, event=owner)
    check("a dry run names the row and sends nothing", (answer.get("id"), sent), (brisa[0]["id"], []))
    check("the watcher wants three words after it", w.run_command("unreserve-theirs DEMO42 123"),
          "error: bad command")

    print("taking one back")
    answer, sent = run(args(HELD, "Aldwyn", remove=True), event=OPEN)
    held_row = next(r["id"] for r in EVENT["reservations"]
                    if r["user"]["id"] == "1000" and r["raidItemId"] == ALDWYN_ITEMS[0])
    check("it is removed", answer, {"result": "ok", "done": "removed"})
    check("with one DELETE of that row", sent,
          [{"url": "/api/raid-event-reservations/%d" % held_row, "method": "DELETE",
            "body": held_row}])
    answer, sent = run(args(FREE, "Aldwyn", remove=True), event=OPEN)
    check("one not held is refused", answer["message"], "Aldwyn hasn't reserved that on raidres")
    two_copies = copy.deepcopy(OPEN)
    first = next(r for r in two_copies["reservations"]
                 if r["user"]["id"] == "1000" and r["raidItemId"] == ALDWYN_ITEMS[0])
    first["srPlus"] = {"id": 1, "value": 30, "isValid": False}
    second = copy.deepcopy(first) | {"id": 888, "srPlus": {"id": 2, "value": 10, "isValid": False}}
    two_copies["reservations"].append(second)
    answer, sent = run(args(HELD, "Aldwyn", remove=True), event=two_copies)
    check("of two copies, the one with less SR+ goes", sent[0]["url"], "/api/raid-event-reservations/888")
    second["srPlus"] = {"id": 2, "value": 30, "isValid": False}
    answer, sent = run(args(HELD, "Aldwyn", remove=True), event=two_copies)
    check("alike, the later one", sent[0]["url"], "/api/raid-event-reservations/888")
    answer, sent = run(args(HELD, "Aldwyn", remove=True), me="9999", event=OPEN)
    check("nor someone else's", answer["message"], "Aldwyn hasn't reserved that on raidres")
    check("and nothing is sent for them", sent, [])
    print("a new event, in a real page")
    body = w.event_body("95", "2099-11-02", "20:00", "1", "0", "1", "0", "0", "test")
    answer, sent = run({"body": body, "dry": False}, script=w._CREATE_JS,
                       reply={"status": 201, "body": {"reference": "NEW123", "raidId": 95}})
    check("it is created", answer, {"result": "ok", "done": "created", "reference": "NEW123"})
    check("with one POST of the form's fields", [(x["method"], x["url"], x["body"]) for x in sent],
          [("POST", "/api/events", body)])
    answer, sent = run({"body": body, "dry": True}, script=w._CREATE_JS)
    check("a dry run plans it", (answer["result"], answer["body"]), ("plan", body))
    check("and sends nothing", sent, [])
    answer, sent = run({"body": body, "dry": False}, script=w._CREATE_JS, me=None)
    check("signed out says so, and sends nothing", (answer["result"], sent), ("signin", []))
    answer, sent = run({"body": body, "dry": False}, script=w._CREATE_JS,
                       reply={"status": 400, "body": {"message": "Start time must be in the future"}})
    check("raidres's refusal in its words", answer,
          {"result": "error", "message": "Start time must be in the future"})
    answer, sent = run({"body": body, "dry": False}, script=w._CREATE_JS,
                       reply={"status": 201, "body": {}})
    check("a reply with no link says so", answer["message"], "raidres made it but didn't say its link")

    print("hard reserves on a new event")
    two = [RAID["raidItems"][0], RAID["raidItems"][5]]
    answer, sent = run({"body": copy.deepcopy(body) | {"raidId": 100}, "hr": [two[0]["gameDbItemId"], two[1]["gameDbItemId"]],
                        "dry": False}, script=w._CREATE_JS, reply={"status": 201, "body": {"reference": "HR0001"}})
    hr = sent[0]["body"]["advancedHrItems"]
    check("picked items go by raidres's own ids", [h["raidItemId"] for h in hr], [two[0]["id"], two[1]["id"]])
    check("as hard reserves, the form's shape",
          (hr[0]["isHardReserved"], hr[0]["note"], hr[0]["characterNames"]), (True, None, []))
    answer, sent = run({"body": copy.deepcopy(body) | {"raidId": 100}, "hr": [999999], "dry": False},
                       script=w._CREATE_JS)
    check("an item not in the raid is refused", (answer.get("message"), sent),
          ("item 999999 isn't in this raid's loot on raidres", []))
    saved = [{"id": 7, "name": "ZG HRs", "raidId": 100, "raidEventTemplateItems": [
        {"id": 1, "raidItemId": two[0]["id"], "isHardReserved": True, "note": None},
        {"id": 2, "raidItemId": two[1]["id"], "isHardReserved": False, "note": "MS > OS"},
        {"id": 3, "raidItemId": 4242, "isHardReserved": False, "note": None}]}]
    answer, sent = run({"body": copy.deepcopy(body) | {"raidId": 100}, "tpl": 7, "dry": False},
                       script=w._CREATE_JS, tpls=saved, reply={"status": 201, "body": {"reference": "HR0002"}})
    hr = sent[0]["body"]["advancedHrItems"]
    check("a saved list brings its HRs and notes, as the form loads it",
          [(h["raidItemId"], h["isHardReserved"], h["note"]) for h in hr],
          [(two[0]["id"], True, None), (two[1]["id"], False, "MS > OS")])
    check("without the saved list's own row ids", "id" in hr[0], False)
    answer, sent = run({"body": copy.deepcopy(body) | {"raidId": 95}, "tpl": 7, "dry": False},
                       script=w._CREATE_JS, tpls=saved)
    check("a saved list for another raid is refused", answer.get("message"), "that saved HR list is for another raid")
    answer, sent = run({}, script=w._TEMPLATES_JS, tpls=saved)
    check("the saved lists, small", answer, {"result": "ok", "lists": [{"id": 7, "name": "ZG HRs", "raid": 100, "hr": 1}]})

    print("an existing event's settings")
    mine = copy.deepcopy(OPEN) | {"isAuthor": True, "advancedHrItems": [
        {"raidItemId": two[1]["id"], "isHardReserved": False, "note": "MS > OS"}]}
    answer, sent = run({"ref": "DEMO42", "hr": [two[0]["gameDbItemId"]], "sr": True, "inc": 15, "prev": "OLD111"},
                       script=w._SETTINGS_JS, event=mine, reply={"status": 200, "body": {}})
    check("saved", answer, {"result": "ok", "done": "saved"})
    check("one PATCH of only what changes", (sent[0]["method"], sent[0]["url"], sorted(sent[0]["body"])),
          ("PATCH", "/api/events/DEMO42", ["advancedHrItems", "allowSrPlus", "defaultSrPlusIncrease",
                                           "previousRaidEventReference", "reference"]))
    check("the picked HR, and the site's note kept",
          [(h["raidItemId"], h["isHardReserved"], h["note"]) for h in sent[0]["body"]["advancedHrItems"]],
          [(two[0]["id"], True, None), (two[1]["id"], False, "MS > OS")])
    third = RAID["raidItems"][9]
    sited = copy.deepcopy(OPEN) | {"isAuthor": True, "advancedHrItems": [
        {"id": 51, "raidItemId": two[0]["id"], "isHardReserved": True, "note": "tanks first",
         "characterClasses": ["Warrior"], "characterSpecializations": ["WarriorProtection"],
         "characterNames": ["Aldwyn"]},
        {"id": 52, "raidItemId": two[1]["id"], "isHardReserved": False, "note": None,
         "characterClasses": ["Priest"], "characterSpecializations": [], "characterNames": []},
        {"id": 53, "raidItemId": third["id"], "isHardReserved": False, "note": "OS only",
         "characterClasses": [], "characterSpecializations": [], "characterNames": []}]}
    answer, sent = run({"ref": "DEMO42", "hr": [two[0]["gameDbItemId"], third["gameDbItemId"]], "sr": False},
                       script=w._SETTINGS_JS, event=sited, reply={"status": 200, "body": {}})
    hr = {h["raidItemId"]: h for h in sent[0]["body"]["advancedHrItems"]}
    check("one that stays HR keeps the site's class, spec and name limits and note",
          (hr[two[0]["id"]]["isHardReserved"], hr[two[0]["id"]]["note"], hr[two[0]["id"]]["characterClasses"],
           hr[two[0]["id"]]["characterSpecializations"], hr[two[0]["id"]]["characterNames"]),
          (True, "tanks first", ["Warrior"], ["WarriorProtection"], ["Aldwyn"]))
    check("one with only limits, no note, is kept as it was", (hr[two[1]["id"]]["isHardReserved"],
          hr[two[1]["id"]]["characterClasses"]), (False, ["Priest"]))
    check("one with a note made HR keeps its note", (hr[third["id"]]["isHardReserved"], hr[third["id"]]["note"]),
          (True, "OS only"))
    check("without the site's own row ids", any("id" in h for h in hr.values()), False)
    answer, sent = run({"ref": "DEMO42", "sr": False}, script=w._SETTINGS_JS, event=mine,
                       reply={"status": 200, "body": {}})
    check("SR+ off alone touches nothing else", sent[0]["body"], {"reference": "DEMO42", "allowSrPlus": False})
    answer, sent = run({"ref": "DEMO42", "limit": 3, "dupes": True}, script=w._SETTINGS_JS, event=mine,
                       reply={"status": 200, "body": {}})
    check("reserves each and the same item twice go as raidres names them", sent[0]["body"],
          {"reference": "DEMO42", "reservationLimit": 3, "allowDuplicateReservation": True})
    answer, sent = run({"ref": "DEMO42", "dupes": False}, script=w._SETTINGS_JS, event=mine,
                       reply={"status": 200, "body": {}})
    check("one alone leaves the other", sent[0]["body"], {"reference": "DEMO42", "allowDuplicateReservation": False})
    answer, sent = run({"ref": "DEMO42", "hr": [], "sr": False}, script=w._SETTINGS_JS, event=mine,
                       reply={"status": 200, "body": {}})
    check("clearing HRs keeps the notes", [h["note"] for h in sent[0]["body"]["advancedHrItems"]], ["MS > OS"])
    answer, sent = run({"ref": "DEMO42", "sr": False}, script=w._SETTINGS_JS,
                       event=copy.deepcopy(OPEN) | {"isAuthor": False})
    check("someone else's list is refused before sending", (answer.get("message"), sent),
          ("that list isn't yours to change", []))

    print("the game's ids, echoed")
    check("an id comes off the command", w.split_tag("#1795222800123 lock DEMO42"),
          ("1795222800123", "lock DEMO42"))
    check("a command without one is as it was", w.split_tag("lock DEMO42"), (None, "lock DEMO42"))
    check("the answer carries it back", w.tag_result("42", "ok saved"), "#42 ok saved")
    check("or not, for a command without one", w.tag_result(None, "ok saved"), "ok saved")
    tag, line = w.split_tag("#7 frobnicate DEMO42")
    check("even a bad command's answer is tagged", w.tag_result(tag, w.run_command(line)),
          "#7 error: bad command")

    print("the events SR+ can carry on from")
    # as raidres answered for Molten Core on 2026-10-30
    sugg = [{"allowSrPlusInput": False, "defaultSrPlusIncrease": 0, "raidName": "Molten Core",
             "reference": "WASZWA", "srPlusAllowEventSkipCount": 2,
             "startTime": "2026-10-25T23:00:00.000Z", "requireSrPlusValidation": False},
            {"allowSrPlusInput": True, "defaultSrPlusIncrease": 10, "raidName": "Molten Core",
             "reference": "7D6NTD", "srPlusAllowEventSkipCount": 0,
             "startTime": "2026-11-21T01:00:00.000Z", "requireSrPlusValidation": True}]
    answer, sent = run({"raid": 95}, script=w._SUGGEST_JS, sugg={"status": 201, "body": sugg})
    check("asked for that raid", sent, [{"url": "/api/sr-plus/previous-event-suggestions?raidId=95",
                                         "method": "GET"}])
    check("newest first, small, with the settings the form copies", answer, {"result": "ok", "events": [
        {"ref": "7D6NTD", "start": 1795222800, "inc": 10, "skip": 0, "input": True, "valid": True},
        {"ref": "WASZWA", "start": 1792969200, "inc": 0, "skip": 2, "input": False, "valid": False}]})
    answer, sent = run({"raid": 95}, script=w._SUGGEST_JS, sugg={"status": 500, "body": None})
    check("raidres's trouble said", answer, {"result": "error", "message": "raidres said HTTP 500"})
    answer, sent = run({"raid": 95}, me=None, script=w._SUGGEST_JS)
    check("signed out, asks to sign in", answer, {"result": "signin"})
    check("a bad raid isn't sent", w.suggest(["x"]), "error: bad command")
    answer, sent = run({"ref": "DEMO42", "sr": True, "inc": 10, "prev": "OLD111", "skip": 2,
                        "input": False, "valid": True},
                       script=w._SETTINGS_JS, event=mine, reply={"status": 200, "body": {}})
    body = sent[0]["body"]
    check("settings carry what the earlier event had",
          (body["srPlusAllowEventSkipCount"], body["allowSrPlusInput"], body["requireSrPlusValidation"]),
          (2, False, True))

    print("one reserve's SR+")
    sr = copy.deepcopy(OPEN) | {"allowSrPlus": True}
    for r in sr["reservations"]:
        r["srPlus"] = None
    sr["reservations"][0]["srPlus"] = {"id": 1, "value": 20, "isValid": True}
    target = next(r for r in sr["reservations"] if r["character"]["name"] == "Aldwyn")
    tg = GAME_ID[target["raidItemId"]]
    answer, sent = run({"ref": "DEMO42", "item": tg, "name": "aldwyn", "value": 35},
                       script=w._SRPLUS_JS, event=sr, reply={"status": 200, "body": {}})
    check("set", answer, {"result": "ok", "done": "srplus"})
    body = sent[0]["body"]
    check("one PUT to the list's SR+, as raidres's editor sends it",
          (sent[0]["method"], sent[0]["url"], body["reference"]), ("PUT", "/api/events/DEMO42/sr-plus", "DEMO42"))
    check("every reservation goes, as the editor sends them all", len(body["reservations"]), len(sr["reservations"]))
    got = {x["reservationId"]: (x["value"], x["isValid"]) for x in body["reservations"]}
    check("that one changed", got[target["id"]][0], 35)
    check("the others kept as they were", got[sr["reservations"][0]["id"]],
          (35, True) if sr["reservations"][0]["id"] == target["id"] else (20, True))
    dup = copy.deepcopy(sr)
    copy2 = copy.deepcopy(target) | {"id": 999, "srPlus": None}
    dup["reservations"].append(copy2)
    answer, sent = run({"ref": "DEMO42", "item": tg, "name": "Aldwyn", "value": 40},
                       script=w._SRPLUS_JS, event=dup, reply={"status": 200, "body": {}})
    got = {x["reservationId"]: x["value"] for x in sent[0]["body"]["reservations"]}
    check("both copies of an item get it, as raidres keeps them alike", (got[target["id"]], got[999]), (40, 40))
    answer, sent = run({"ref": "DEMO42", "item": tg, "name": "Aldwyn", "valid": True},
                       script=w._SRPLUS_JS, event=sr, reply={"status": 200, "body": {}})
    got = {x["reservationId"]: (x["value"], x["isValid"]) for x in sent[0]["body"]["reservations"]}
    check("validating keeps its value", got[target["id"]][1], True)
    answer, sent = run({"ref": "DEMO42", "item": tg, "name": "Aldwyn", "value": 5},
                       script=w._SRPLUS_JS, event=copy.deepcopy(OPEN) | {"allowSrPlus": False})
    check("a list without SR+ is refused", (answer.get("message"), sent), ("SR+ isn't on for that list", []))
    answer, sent = run({"ref": "DEMO42", "item": tg, "name": "Nobody", "value": 5},
                       script=w._SRPLUS_JS, event=sr)
    check("someone who didn't reserve it is refused", answer.get("message"), "Nobody hasn't reserved that on raidres")
    answer, sent = run({"ref": "DEMO42", "item": tg, "name": "Aldwyn", "value": 5},
                       script=w._SRPLUS_JS, event=sr, reply={"status": 403, "body": {"message": "Forbidden"}})
    check("raidres's no to a non-officer, in its words", answer.get("message"), "Forbidden")

    print("admins of the list")
    owned = copy.deepcopy(OPEN) | {"isAuthor": True, "authorId": "1000", "extraAdministratorUserIds": ["1003"]}
    def admin(name, add=True, event=owned, dry=False):
        return run({"ref": "DEMO42", "name": name, "add": add, "dry": dry}, script=w._ADMIN_JS,
                   event=event, reply={"status": 200, "body": {}})
    answer, sent = admin("brisa")
    check("made an admin", answer, {"result": "ok", "done": "admin", "count": 2})
    check("with one PATCH of the whole list, the one there kept", (sent[0]["method"], sent[0]["url"],
          sent[0]["body"]), ("PATCH", "/api/events/DEMO42",
          {"reference": "DEMO42", "extraAdministratorUserIdentifiers": ["1003", "1001"]}))
    answer, sent = admin("Dagny", add=False)
    check("taken off, the rest kept", (answer.get("count"), sent[0]["body"]["extraAdministratorUserIdentifiers"]),
          (0, []))
    answer, sent = admin("Brisa", dry=True)
    check("a dry run plans it and sends nothing", (answer["result"], answer["body"]["extraAdministratorUserIdentifiers"],
          sent), ("plan", ["1003", "1001"], []))
    answer, sent = admin("Dagny")
    check("one already an admin is refused", (answer.get("message"), sent), ("Dagny is already an admin of it", []))
    answer, sent = admin("Brisa", add=False)
    check("one who isn't can't be taken off", answer.get("message"), "Brisa isn't an admin of it")
    answer, sent = admin("Aldwyn")
    check("nor the owner made one", (answer.get("message"), sent), ("Aldwyn owns the list", []))
    answer, sent = admin("Nobody")
    check("someone not on the list, with no account sent, is refused", answer.get("message"),
          "Nobody isn't signed up on this list, and their raidres account isn't known here")
    answer, sent = admin("Wirelock", event=made | {"authorId": "1000", "extraAdministratorUserIds": []})
    check("someone only reserved for by another isn't known by raidres's account", (answer.get("message"), sent),
          ("Wirelock was reserved for by someone else; they sign up on raidres themselves first", []))
    full = copy.deepcopy(owned) | {"extraAdministratorUserIds": [str(2000 + i) for i in range(10)]}
    answer, sent = admin("Brisa", event=full)
    check("not an eleventh", (answer.get("message"), sent),
          ("the list has 10 admins already, as many as raidres takes", []))
    answer, sent = admin("Brisa", event=copy.deepcopy(owned) | {"isAuthor": False})
    check("only the owner changes them", (answer.get("message"), sent),
          ("only the list's owner can change its admins", []))
    twice = copy.deepcopy(owned)
    twice["reservations"].append(copy.deepcopy(next(r for r in twice["reservations"]
                                                    if r["character"]["name"] == "Brisa")))
    twice["reservations"][-1]["user"] = {"id": "4444"}
    answer, sent = admin("Brisa", event=twice)
    check("two accounts under one name aren't guessed between", (answer.get("message"), sent),
          ("two raidres accounts signed up as Brisa", []))
    far = "221800000000000009"
    answer, sent = run({"ref": "DEMO42", "name": "Faraway", "add": True, "id": far, "dry": False},
                       script=w._ADMIN_JS, event=owned, reply={"status": 200, "body": {}})
    check("someone not on the list, by the account saved for them",
          sent[0]["body"]["extraAdministratorUserIdentifiers"], ["1003", far])
    answer, sent = run({"ref": "DEMO42", "name": "Brisa", "add": True, "id": far, "dry": False},
                       script=w._ADMIN_JS, event=owned, reply={"status": 200, "body": {}})
    check("the list's own account wins over a saved one",
          sent[0]["body"]["extraAdministratorUserIdentifiers"], ["1003", "1001"])
    answer, sent = run({"ref": "DEMO42", "name": "Wirelock", "add": True, "id": far, "dry": False},
                       script=w._ADMIN_JS, event=made | {"authorId": "1000", "extraAdministratorUserIds": []},
                       reply={"status": 200, "body": {}})
    check("and one only reserved for by another is found by theirs",
          sent[0]["body"]["extraAdministratorUserIdentifiers"], [far])
    answer, sent = run({"ref": "DEMO42", "name": "Faraway", "add": True, "id": "1000", "dry": False},
                       script=w._ADMIN_JS, event=owned)
    check("a saved account that's the owner's is refused", (answer.get("message"), sent),
          ("Faraway owns the list", []))

    print("locking, then reading it back")
    lock = "(a) => (%s)(a).then(v => JSON.stringify(v))" % w._LOCK_JS
    yes = {"status": 200, "body": {}}
    answer, sent = run({"ref": "DEMO42", "locked": True}, script=lock, event=EVENT, reply=yes)
    check("a lock raidres made answers 200", answer, "200")
    check("after one PATCH of the lock alone", sent,
          [{"url": "/api/events/DEMO42", "method": "PATCH",
            "body": {"reference": "DEMO42", "locked": True}}])
    answer, sent = run({"ref": "DEMO42", "locked": False}, script=lock, event=OPEN, reply=yes)
    check("an unlock that took answers 200", answer, "200")
    answer, sent = run({"ref": "DEMO42", "locked": False}, script=lock, event=EVENT, reply=yes)
    check("an unlock raidres said yes to but didn't make is caught", answer, "unchanged")
    never = copy.deepcopy(EVENT)
    never["locked"] = None
    answer, sent = run({"ref": "DEMO42", "locked": True}, script=lock, event=never, reply=yes)
    check("so is a lock that left it never set", answer, "unchanged")
    answer, sent = run({"ref": "DEMO42", "locked": True}, script=lock, event=EVENT,
                       reply={"status": 403, "body": None})
    check("a refusal answers its status", answer, "403")
finally:
    ws.close()
    w.kill_chrome()

print("\n%d check(s), %d failure(s)" % (checks, failures))
sys.exit(1 if failures else 0)
