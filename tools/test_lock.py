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

def run(args, me="1000", event=None, chars=None, reply=None):
    """Run _RESERVE_JS once against a stand-in site. Returns (answer, sent)."""
    site = {
        "me": {"status": 200, "body": {"id": me}} if me else {"status": 401, "body": None},
        "event": {"status": 200, "body": event if event is not None else EVENT},
        "raid": {"status": 200, "body": RAID},
        "chars": {"status": 200, "body": chars if chars is not None else []},
        "reply": reply or {"status": 201, "body": {"ok": True}},
    }
    stand_in = r"""
    (site) => {
      window.__sent = [];
      window.fetch = async (url, opts) => {
        opts = opts || {};
        let r;
        if (url === '/api/auth/me') r = site.me;
        else if (url.startsWith('/api/events/')) r = site.event;
        else if (url.startsWith('/raids/raid_')) r = site.raid;
        else if (url === '/api/user-characters') r = site.chars;
        else if (url.startsWith('/api/raid-event-reservations')) {
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
        "expression": "(%s)(%s)" % (w._RESERVE_JS, json.dumps(args)),
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
    answer, sent = run(args(HELD, "Aldwyn", remove=True), me="9999", event=OPEN)
    check("nor someone else's", answer["message"], "Aldwyn hasn't reserved that on raidres")
    check("and nothing is sent for them", sent, [])
finally:
    ws.close()
    w.kill_chrome()

print("\n%d check(s), %d failure(s)" % (checks, failures))
sys.exit(1 if failures else 0)
