#!/usr/bin/env python3
"""Lock and unlock raidres events from inside WoW, through Chrome.

Chrome manages its own cookies -- this script never sees, stores or touches the
raidres session cookie.  It connects to Chrome's DevTools Protocol (CDP) and
runs a one-line fetch() in a tab that has raidres.top open.  Chrome sends the
cookie itself, the same way it would if you clicked the button on the page.

Requirements
  Python 3           (already needed for the watcher)
  Chrome             (launched automatically in headless mode)

No pip packages.  The WebSocket client is 80 lines of stdlib.

Usage
  python raidres_lock.py watch          watch CustomData for addon requests
  python raidres_lock.py watch --parent PID   ...and stop when process PID closes
  python raidres_lock.py lock   REF    lock event REF and exit
  python raidres_lock.py unlock REF    unlock event REF and exit
  python raidres_lock.py open   REF    open event REF in Chrome and exit
  python raidres_lock.py status         check Chrome and the raidres tab
  python raidres_lock.py reserve   REF ITEMID NAME CLASS [SPEC] [--dry-run]
  python raidres_lock.py unreserve REF ITEMID NAME [--dry-run]
                                        your own soft reserve on event REF,
                                        by WoW item id; --dry-run looks
                                        everything up and sends nothing
  python raidres_lock.py create RAIDID YYYY-MM-DD HH:MM LIMIT LOCK COMMENTS SRPLUS DUPES
                                [DESCRIPTION...] [--dry-run]
                                        a new event; switches are 0/1, the
                                        time this PC's; prints its reference
  python raidres_lock.py admin REF NAME add|remove [id=N] [--dry-run]
                                        make NAME an admin of your list REF,
                                        or no longer one
"""

import http.client, json, os, socket, struct, sys, time, re

CDP_PORT = 9222
CDP_HOST = "127.0.0.1"

_chrome_proc = None
_headless = False

# ---------------------------------------------------------------------------
# Minimal WebSocket client -- just enough for CDP (text frames, no TLS)
# ---------------------------------------------------------------------------

class WebSocket:
    def __init__(self, url):
        m = re.match(r"ws://([^:/]+):(\d+)(/.*)$", url)
        if not m:
            raise ValueError("bad ws url: " + url)
        host, port, path = m.group(1), int(m.group(2)), m.group(3)
        self.sock = socket.create_connection((host, port), timeout=15)
        key = __import__("base64").b64encode(os.urandom(16)).decode()
        handshake = (
            "GET %s HTTP/1.1\r\n"
            "Host: %s:%d\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n" % (path, host, port, key)
        )
        self.sock.sendall(handshake.encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            b = self.sock.recv(1)
            if not b:
                raise ConnectionError("handshake closed")
            resp += b
        if b"101" not in resp.split(b"\r\n")[0]:
            raise ConnectionError("handshake failed: " + resp.decode())
        self._id = 0

    def _recv_bytes(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("connection lost")
            buf += chunk
        return buf

    def _send_frame(self, data, opcode=1):
        raw = data.encode() if isinstance(data, str) else data
        mask = os.urandom(4)
        hdr = bytearray()
        hdr.append(0x80 | opcode)
        length = len(raw)
        if length < 126:
            hdr.append(0x80 | length)
        elif length < 65536:
            hdr.append(0x80 | 126)
            hdr += struct.pack(">H", length)
        else:
            hdr.append(0x80 | 127)
            hdr += struct.pack(">Q", length)
        hdr += mask
        hdr += bytes(b ^ mask[i % 4] for i, b in enumerate(raw))
        self.sock.sendall(hdr)

    def _recv_frame(self):
        h = self._recv_bytes(2)
        opcode = h[0] & 0x0F
        masked = bool(h[1] & 0x80)
        length = h[1] & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._recv_bytes(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._recv_bytes(8))[0]
        mk = self._recv_bytes(4) if masked else None
        payload = self._recv_bytes(length)
        if mk:
            payload = bytes(b ^ mk[i % 4] for i, b in enumerate(payload))
        if opcode == 9:
            self._send_frame(payload, opcode=10)
            return self._recv_frame()
        if opcode == 8:
            raise ConnectionError("server closed websocket")
        return payload.decode() if opcode == 1 else payload

    def call(self, method, params=None, timeout=30):
        self._id += 1
        msg = {"id": self._id, "method": method}
        if params:
            msg["params"] = params
        self._send_frame(json.dumps(msg))
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.sock.settimeout(max(0.5, deadline - time.time()))
            try:
                raw = self._recv_frame()
            except socket.timeout:
                continue
            reply = json.loads(raw)
            if reply.get("id") == self._id:
                return reply
        raise TimeoutError("CDP call %s timed out" % method)

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# CDP helpers
# ---------------------------------------------------------------------------

def cdp_tabs():
    conn = http.client.HTTPConnection(CDP_HOST, CDP_PORT, timeout=5)
    conn.request("GET", "/json")
    resp = conn.getresponse()
    tabs = json.loads(resp.read())
    conn.close()
    return tabs

def find_raidres_tab():
    for tab in cdp_tabs():
        url = tab.get("url", "")
        if "raidres.top" in url and tab.get("webSocketDebuggerUrl"):
            return tab
    return None

def open_raidres_tab():
    conn = http.client.HTTPConnection(CDP_HOST, CDP_PORT, timeout=10)
    conn.request("PUT", "/json/new?url=https://raidres.top")
    resp = conn.getresponse()
    tab = json.loads(resp.read())
    conn.close()
    for _ in range(20):
        time.sleep(1)
        found = find_raidres_tab()
        if found:
            return found
    return tab

def check_chrome():
    try:
        cdp_tabs()
        return True
    except Exception:
        return False

def find_chrome_exe():
    for pattern in [
        os.path.join(os.environ.get("ProgramFiles", ""), "Google", "Chrome", "Application", "chrome.exe"),
        os.path.join(os.environ.get("ProgramFiles(x86)", ""), "Google", "Chrome", "Application", "chrome.exe"),
        os.path.join(os.environ.get("LocalAppData", ""), "Google", "Chrome", "Application", "chrome.exe"),
    ]:
        if os.path.isfile(pattern):
            return pattern
    return None

_chrome_job = None

def _bound_to_us(proc):
    """Ties a process started suspended to this one, then lets it run.

    It goes into a job that ends everything in it when its last handle
    closes, and only this process holds that handle -- so the Chrome this
    starts, and every helper Chrome starts, goes when this process goes,
    however it goes. The game ending kills this watcher outright (the DLL's
    job, or the python.exe launcher's), and nothing in here would get the
    chance to close Chrome by hand. Any trouble just lets it run unbound."""
    global _chrome_job
    import ctypes
    from ctypes import wintypes
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateJobObjectW.restype = wintypes.HANDLE
    k32.CreateJobObjectW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p]
    k32.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int,
                                            ctypes.c_void_p, wintypes.DWORD]
    k32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    try:
        if _chrome_job is None:
            class Basic(ctypes.Structure):
                _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64),
                            ("PerJobUserTimeLimit", ctypes.c_int64),
                            ("LimitFlags", wintypes.DWORD),
                            ("MinimumWorkingSetSize", ctypes.c_size_t),
                            ("MaximumWorkingSetSize", ctypes.c_size_t),
                            ("ActiveProcessLimit", wintypes.DWORD),
                            ("Affinity", ctypes.c_size_t),
                            ("PriorityClass", wintypes.DWORD),
                            ("SchedulingClass", wintypes.DWORD)]
            class Extended(ctypes.Structure):
                _fields_ = [("BasicLimitInformation", Basic),
                            ("IoInfo", ctypes.c_uint64 * 6),
                            ("ProcessMemoryLimit", ctypes.c_size_t),
                            ("JobMemoryLimit", ctypes.c_size_t),
                            ("PeakProcessMemoryUsed", ctypes.c_size_t),
                            ("PeakJobMemoryUsed", ctypes.c_size_t)]
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
            JobObjectExtendedLimitInformation = 9
            job = k32.CreateJobObjectW(None, None)
            info = Extended()
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if job and k32.SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                                   ctypes.byref(info), ctypes.sizeof(info)):
                _chrome_job = job
        if _chrome_job and not k32.AssignProcessToJobObject(_chrome_job, int(proc._handle)):
            log("couldn't tie Chrome to the watcher (error %d)" % ctypes.get_last_error())
    finally:
        ctypes.WinDLL("ntdll").NtResumeProcess(wintypes.HANDLE(int(proc._handle)))

def start_chrome(url=None, headless=False):
    global _chrome_proc, _headless
    exe = find_chrome_exe()
    if not exe:
        log("Chrome not found in the usual places.")
        return False
    profile = os.path.join(os.environ.get("LocalAppData", ""), "chrome-cdp-raidres")
    args = [exe, "--remote-debugging-port=%d" % CDP_PORT,
            "--user-data-dir=%s" % profile]
    if headless:
        args.append("--headless=new")
    args.append(url or "https://raidres.top")
    log("starting Chrome%s with CDP..." % (" (headless)" if headless else ""))
    import subprocess
    CREATE_SUSPENDED = 0x4
    _chrome_proc = subprocess.Popen(args, close_fds=True, creationflags=CREATE_SUSPENDED)
    _bound_to_us(_chrome_proc)
    _headless = headless
    for _ in range(20):
        time.sleep(1)
        if check_chrome():
            log("Chrome CDP is ready.")
            return True
    log("Chrome started but CDP not reachable after 20s.")
    return False

def kill_chrome():
    global _chrome_proc, _headless
    if _chrome_proc and _chrome_proc.poll() is None:
        log("stopping Chrome (PID %d)..." % _chrome_proc.pid)
        import subprocess as sp
        sp.call(["taskkill", "/T", "/F", "/PID", str(_chrome_proc.pid)],
                stdout=sp.DEVNULL, stderr=sp.DEVNULL)
    _chrome_proc = None
    _headless = False
    for _ in range(10):
        if not check_chrome():
            return True
        time.sleep(1)
    return not check_chrome()

def ensure_chrome(url=None, need_visible=False):
    if check_chrome():
        if need_visible and _headless:
            kill_chrome()
            return start_chrome(url, headless=False)
        return True
    return start_chrome(url, headless=(not need_visible))


# ---------------------------------------------------------------------------
# Session expiry
# ---------------------------------------------------------------------------

def _get_expiry(ws):
    try:
        result = ws.call("Network.getCookies", {"urls": ["https://raidres.top"]})
        cookies = result.get("result", {}).get("cookies", [])
        nearest = None
        for c in cookies:
            exp = c.get("expires", -1)
            if exp > 0:
                if nearest is None or exp < nearest:
                    nearest = exp
        return int(nearest) if nearest else None
    except Exception:
        return None

def _format_expiry(ts):
    if ts is None:
        return None
    remaining = ts - time.time()
    if remaining <= 0:
        return "expired"
    when = time.strftime("%b %d %H:%M", time.localtime(ts))
    days = int(remaining // 86400)
    hours = int((remaining % 86400) // 3600)
    if days > 0:
        return "%dd %dh (%s)" % (days, hours, when)
    mins = int((remaining % 3600) // 60)
    if hours > 0:
        return "%dh %dm (%s)" % (hours, mins, when)
    return "%dm (%s)" % (max(1, mins), when)


# ---------------------------------------------------------------------------
# Lock / unlock
# ---------------------------------------------------------------------------

_REF_RE = re.compile(r"^[A-Za-z0-9]{3,20}$")

def validate_ref(ref):
    if not ref or not _REF_RE.match(ref):
        raise ValueError("bad ref: %r" % ref)
    return ref

def open_event(ref):
    validate_ref(ref)
    if not ensure_chrome("https://raidres.top/res/%s" % ref, need_visible=True):
        return "error: could not start Chrome"
    tab = find_raidres_tab()
    if not tab:
        log("no raidres.top tab in Chrome -- opening one")
        tab = open_raidres_tab()
        if not tab or not tab.get("webSocketDebuggerUrl"):
            return "error: could not open a raidres tab in Chrome"

    ws_url = tab["webSocketDebuggerUrl"]
    ws = WebSocket(ws_url)
    try:
        url = "https://raidres.top/res/%s" % ref
        ws.call("Page.navigate", {"url": url})
        ws.call("Page.bringToFront")
    finally:
        ws.close()
    return "ok"

def lock_unlock(ref, locked):
    validate_ref(ref)
    if not ensure_chrome("https://raidres.top/res/%s" % ref):
        return "error: could not start Chrome"
    tab = find_raidres_tab()
    if not tab:
        log("no raidres.top tab in Chrome -- opening one")
        tab = open_raidres_tab()
        if not tab or not tab.get("webSocketDebuggerUrl"):
            return "error: could not open a raidres tab in Chrome"

    ws_url = tab["webSocketDebuggerUrl"]
    ws = WebSocket(ws_url)
    try:
        js = (
            "fetch('https://raidres.top/api/events/%s', {"
            "  method: 'PATCH',"
            "  credentials: 'include',"
            "  headers: { 'Content-Type': 'application/json' },"
            "  body: JSON.stringify({ reference: '%s', locked: %s })"
            "}).then(r => { return r.status.toString() })"
            ".catch(e => 'error:' + e.message)"
        ) % (ref, ref, "true" if locked else "false")

        result = ws.call("Runtime.evaluate", {
            "expression": js,
            "awaitPromise": True,
            "returnByValue": True,
        })

        value = (result.get("result", {}).get("result", {}).get("value", "")
                 if "result" in result else "")

        if not value:
            err = result.get("result", {}).get("exceptionDetails", {})
            return "error: CDP eval failed: %s" % json.dumps(err)

        if value == "200":
            expiry = _format_expiry(_get_expiry(ws))
            if expiry:
                return "ok %s" % expiry
            return "ok"
        elif value.startswith("error:"):
            return "error: " + value[6:]
        else:
            status = value
            if status in ("401", "403"):
                expiry = _format_expiry(_get_expiry(ws))
                if expiry:
                    return "signin %s" % expiry
                return "signin"
            return "error: raidres returned HTTP %s" % status
    finally:
        ws.close()

# ---------------------------------------------------------------------------
# Reserve / unreserve your own items
#
# The same requests raidres's own reservation form makes, run inside the page
# like lock and unlock, so Chrome's own sign-in is used and never seen here:
#   POST   /api/raid-event-reservations       {reference, characterName,
#          characterClass, specialization, isTemporary, raidItemIds, comment}
#   DELETE /api/raid-event-reservations/<id>  one reserved item
# The game knows WoW item ids; raidres's own ids come from the raid's public
# loot file, /raids/raid_<raidId>.json (gameDbItemId -> id).
# ---------------------------------------------------------------------------

# raidres's classes and their specializations, as its reservation form has them.
SPECS = {
    "Druid":   ["DruidBalance", "DruidFeral", "DruidRestoration", "DruidBear"],
    "Hunter":  ["HunterBeastMastery", "HunterMarksmanship", "HunterSurvival"],
    "Mage":    ["MageArcane", "MageFire", "MageFrost"],
    "Paladin": ["PaladinHoly", "PaladinProtection", "PaladinRetribution"],
    "Priest":  ["PriestDiscipline", "PriestHoly", "PriestShadow"],
    "Rogue":   ["RogueSwords", "RogueDaggers", "RogueMaces"],
    "Shaman":  ["ShamanElemental", "ShamanEnhancement", "ShamanRestoration", "ShamanTank"],
    "Warlock": ["WarlockAffliction", "WarlockDemonology", "WarlockDestruction"],
    "Warrior": ["WarriorArms", "WarriorFury", "WarriorProtection"],
}

# A character name as the game writes it: letters, accented ones included.
_NAME_RE = re.compile(r"^[^\W\d_]{2,24}$")

# Shared by the in-page scripts below. send() answers {fail, reply}: fail is
# null when raidres took it, else the answer to hand back as it is.
_PAGE_HELPERS = r"""
  const answer = (o) => JSON.stringify(o);
  // raidres's own error text, read the way its errorMessageParser reads it
  const said = (d) => {
    if (typeof d === 'string') return d;
    if (Array.isArray(d)) return d.filter(x => typeof x === 'string').join(', ');
    if (d && typeof d === 'object') return d.message || d.error || '';
    return '';
  };
  const get = async (url) => {
    const r = await fetch(url, { credentials: 'include' });
    let body = null;
    try { body = await r.json(); } catch (e) {}
    return { status: r.status, ok: r.ok, body };
  };
  const send = async (url, method, body) => {
    const r = await fetch(url, { method, credentials: 'include',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    let reply = null;
    try { reply = await r.json(); } catch (e) {}
    if (r.ok) return { fail: null, reply };
    if (r.status === 401) return { fail: answer({ result: 'signin' }), reply };
    return { fail: answer({ result: 'error', message: said(reply) || ('raidres said HTTP ' + r.status) }),
             reply };
  };
  const signedIn = async () => {
    const me = await get('/api/auth/me');
    const who = me.body && (me.body.id != null ? me.body.id : (me.body.user && me.body.user.id));
    return me.ok && who != null ? who : null;
  };
"""

# Answers one JSON object: {result: ok|needspec|signin|plan|error, ...}.
_RESERVE_JS = r"""
async (a) => {
""" + _PAGE_HELPERS + r"""
  const who = await signedIn();
  if (who == null) return answer({ result: 'signin' });

  const ev = await get('/api/events/' + encodeURIComponent(a.ref));
  if (!ev.ok || !ev.body) return answer({ result: 'error', message: 'raidres has no list ' + a.ref });
  const e = ev.body;
  if (e.locked) return answer({ result: 'error', message: 'the list is locked on raidres' });
  if (e.archived) return answer({ result: 'error', message: 'the list is archived on raidres' });

  const raid = await get('/raids/raid_' + e.raidId + '.json');
  if (!raid.ok || !raid.body) return answer({ result: 'error', message: "couldn't load the list's loot table" });
  const ids = (raid.body.raidItems || []).filter(i => i.gameDbItemId === a.item).map(i => i.id);
  if (ids.length === 0) return answer({ result: 'error', message: "that item isn't in this raid's loot on raidres" });

  const name = a.name.toLocaleLowerCase();
  const mine = (e.reservations || []).filter(r => r.user && String(r.user.id) === String(who)
    && r.character && String(r.character.name).toLocaleLowerCase() === name);
  const held = mine.filter(r => r.raidItemId !== null);

  // For another player: raidres's own "This reservation is for another
  // player" (isTemporary), which only the list's owner and admins have.
  // Theirs are filed under you, so "mine" above is right for them too.
  if (a.forOther) {
    const admins = (e.extraAdministratorUserIds || []).map(String);
    if (e.isAuthor === false && !admins.includes(String(who)))
      return answer({ result: 'error', message: "only the list's owner or its admins can reserve for others" });
    const theirOwn = (e.reservations || []).some(r => r.character && r.user
      && String(r.character.name).toLocaleLowerCase() === name && String(r.user.id) !== String(who));
    if (theirOwn && !a.remove)
      return answer({ result: 'error', message: a.name + ' signed up on raidres themselves; they change it there' });
  }

  if (a.remove) {
    // of two copies, the one with the least SR+ goes (the later one, if alike)
    const sp = r => (r.srPlus && Number(r.srPlus.value)) || 0;
    const row = held.filter(r => ids.includes(r.raidItemId))
      .reduce((low, r) => (low && sp(low) < sp(r)) ? low : r, null);
    if (!row) return answer({ result: 'error', message: a.name + " hasn't reserved that on raidres" });
    if (a.dry) return answer({ result: 'plan', method: 'DELETE', id: row.id });
    return (await send('/api/raid-event-reservations/' + row.id, 'DELETE', row.id)).fail
      || answer({ result: 'ok', done: 'removed' });
  }

  if (!e.allowDuplicateReservation && held.some(r => ids.includes(r.raidItemId)))
    return answer({ result: 'error', message: a.name + ' already has that reserved' });
  if (e.reservationLimit && held.length >= e.reservationLimit)
    return answer({ result: 'error', message: a.name + ' already has ' + held.length + ' of '
      + e.reservationLimit + ' reserved' });
  const signedUp = mine.find(r => r.character.class);
  if (signedUp && signedUp.character.class !== a.cls)
    return answer({ result: 'error', message: a.name + ' is signed up as ' + signedUp.character.class });

  // The spec: the one already signed up with, else the saved character's,
  // else the game's pick -- and with none of those, ask the game for one.
  let spec = (mine.find(r => r.character.specialization) || { character: {} }).character.specialization;
  if (!spec && !a.forOther) {
    const chars = await get('/api/user-characters');
    const list = Array.isArray(chars.body) ? chars.body : ((chars.body && chars.body.data) || []);
    const saved = list.find(c => c && String(c.name).toLocaleLowerCase() === name && c.class === a.cls);
    spec = saved && saved.specialization;
  }
  spec = spec || a.spec;
  if (!spec) return answer({ result: 'needspec' });

  const body = { reference: e.reference, characterName: signedUp ? signedUp.character.name : a.name,
    characterClass: a.cls, specialization: spec, isTemporary: !!a.forOther, raidItemIds: [ids[0]], comment: '' };
  if (a.dry) return answer({ result: 'plan', method: 'POST', body, me: who, held: held.length,
    limit: e.reservationLimit });
  return (await send('/api/raid-event-reservations', 'POST', body)).fail
    || answer({ result: 'ok', done: 'reserved', spec });
}
"""

def check_reserve(ref, item, name, cls=None, spec=None, remove=False):
    """The arguments as the game sent them, checked; raises ValueError.
    Taking one back needs no class: the reservation already says."""
    validate_ref(ref)
    try:
        item = int(item)
    except (TypeError, ValueError):
        raise ValueError("bad item id: %r" % item)
    if item <= 0:
        raise ValueError("bad item id: %r" % item)
    if not _NAME_RE.match(name or ""):
        raise ValueError("bad character name: %r" % name)
    if remove:
        return item
    if cls not in SPECS:
        raise ValueError("unknown class: %r" % cls)
    if spec is not None and spec not in SPECS[cls]:
        raise ValueError("%r is not a %s specialization" % (spec, cls))
    return item

def reserve_line(answer):
    """The page's answer as the one line the addon reads back."""
    result = answer.get("result")
    if result == "ok":
        line = "ok " + answer.get("done", "")
        return line + (" " + answer["spec"] if answer.get("spec") else "")
    if result in ("needspec", "signin"):
        return result
    if result == "plan":
        return "plan " + json.dumps(answer)
    return "error: " + (answer.get("message") or "raidres didn't say why")

def reserve(ref, item, name, cls, spec=None, remove=False, dry=False, for_other=False):
    try:
        item = check_reserve(ref, item, name, cls, spec, remove)
    except ValueError as e:
        return "error: %s" % e
    if not ensure_chrome("https://raidres.top/res/%s" % ref):
        return "error: could not start Chrome"
    tab = find_raidres_tab()
    if not tab:
        log("no raidres.top tab in Chrome -- opening one")
        tab = open_raidres_tab()
        if not tab or not tab.get("webSocketDebuggerUrl"):
            return "error: could not open a raidres tab in Chrome"
    args = {"ref": ref, "item": item, "name": name, "cls": cls, "spec": spec,
            "remove": bool(remove), "dry": bool(dry), "forOther": bool(for_other)}
    ws = WebSocket(tab["webSocketDebuggerUrl"])
    try:
        # The arguments go in as JSON: nothing the game sent can become code.
        reply = ws.call("Runtime.evaluate", {
            "expression": "(%s)(%s)" % (_RESERVE_JS, json.dumps(args)),
            "awaitPromise": True,
            "returnByValue": True,
        }, timeout=45)
        value = reply.get("result", {}).get("result", {}).get("value")
        if not isinstance(value, str):
            err = reply.get("result", {}).get("exceptionDetails", {})
            return "error: CDP eval failed: %s" % json.dumps(err)[:200]
        line = reserve_line(json.loads(value))
        if line == "signin":
            expiry = _format_expiry(_get_expiry(ws))
            return "signin %s" % expiry if expiry else "signin"
        return line
    finally:
        ws.close()

# ---------------------------------------------------------------------------
# A new event
#
# POST /api/events with the fields raidres's own "Create event" form sends.
# Its reply carries the new event's reference. Hard reserves go as the form
# sends them: advancedHrItems, by raidres's own item ids -- picked from the
# loot (the game sends WoW ids; the raid's loot file maps them) or taken from
# one of the user's saved lists ("raid event templates"). Extra admins and
# banned users are left empty, for raidres's site.
# ---------------------------------------------------------------------------

_CREATE_JS = r"""
async (a) => {
""" + _PAGE_HELPERS + r"""
  if (await signedIn() == null) return answer({ result: 'signin' });
  const body = a.body;
  // A saved list's hard reserves, as the form loads them.
  if (a.tpl) {
    const t = await get('/api/raid-event-templates');
    const list = Array.isArray(t.body) ? t.body : ((t.body && t.body.data) || []);
    const tpl = list.find(x => x && x.id === a.tpl);
    if (!tpl) return answer({ result: 'error', message: "that saved HR list isn't on raidres any more" });
    if (tpl.raidId !== body.raidId) return answer({ result: 'error', message: 'that saved HR list is for another raid' });
    body.advancedHrItems = (tpl.raidEventTemplateItems || [])
      .filter(i => i.isHardReserved || (i.note && i.note.length > 0))
      .map(i => ({ raidItemId: i.raidItemId, isHardReserved: !!i.isHardReserved, note: i.note || null,
                   characterClasses: i.characterClasses || [],
                   characterSpecializations: i.characterSpecializations || [],
                   characterNames: i.characterNames || [] }));
  } else if (a.hr && a.hr.length > 0) {
    const raid = await get('/raids/raid_' + body.raidId + '.json');
    if (!raid.ok || !raid.body) return answer({ result: 'error', message: "couldn't load the raid's loot table" });
    const ids = [];
    for (const g of a.hr) {
      const it = (raid.body.raidItems || []).find(i => i.gameDbItemId === g);
      if (!it) return answer({ result: 'error', message: 'item ' + g + " isn't in this raid's loot on raidres" });
      ids.push(it.id);
    }
    body.advancedHrItems = ids.map(id => ({ raidItemId: id, isHardReserved: true, note: null,
      characterClasses: [], characterSpecializations: [], characterNames: [] }));
  }
  if (a.dry) return answer({ result: 'plan', method: 'POST', body });
  const r = await send('/api/events', 'POST', body);
  if (r.fail) return r.fail;
  const ref = r.reply && r.reply.reference;
  if (!ref) return answer({ result: 'error', message: "raidres made it but didn't say its link" });
  return answer({ result: 'ok', done: 'created', reference: ref });
}
"""

# The user's saved HR lists, small enough for one line back to the game.
_TEMPLATES_JS = r"""
async (a) => {
""" + _PAGE_HELPERS + r"""
  if (await signedIn() == null) return answer({ result: 'signin' });
  const t = await get('/api/raid-event-templates');
  if (!t.ok) return answer({ result: 'error', message: 'raidres said HTTP ' + t.status });
  const list = Array.isArray(t.body) ? t.body : ((t.body && t.body.data) || []);
  return answer({ result: 'ok', lists: list.filter(x => x && x.id).map(x => ({
    id: x.id, name: String(x.name || '?'), raid: x.raidId,
    hr: (x.raidEventTemplateItems || []).filter(i => i.isHardReserved).length })) });
}
"""

# The user's own earlier events of a raid that had SR+ on -- the list
# raidres's form offers under "Select previous event" -- newest first, with
# the SR+ settings the form copies from the one picked.
_SUGGEST_JS = r"""
async (a) => {
""" + _PAGE_HELPERS + r"""
  if (await signedIn() == null) return answer({ result: 'signin' });
  const t = await get('/api/sr-plus/previous-event-suggestions?raidId=' + a.raid);
  if (!t.ok) return answer({ result: 'error', message: 'raidres said HTTP ' + t.status });
  const list = Array.isArray(t.body) ? t.body : ((t.body && t.body.data) || []);
  const events = list.filter(x => x && typeof x.reference === 'string').map(x => ({
    ref: x.reference,
    start: Math.floor((Date.parse(x.startTime) || 0) / 1000),
    inc: Number(x.defaultSrPlusIncrease) || 0,
    skip: Number(x.srPlusAllowEventSkipCount) || 0,
    input: x.allowSrPlusInput !== false,
    valid: x.requireSrPlusValidation === true }));
  events.sort((p, q) => q.start - p.start);
  return answer({ result: 'ok', events: events.slice(0, 12) });
}
"""

_DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_CLOCK_RE = re.compile(r"^\d{2}:\d{2}$")
ADMIN_LIMIT = 10        # raidres's own form takes no more admins

_OPTION_RE = re.compile(r"^(hr|tpl|inc|skip|input|valid|prev|admins)=(\S*)$")

def event_body(raid_id, day, clock, limit, lock, comments, srplus, dupes, description,
               now=None, options=None):
    """The create form's fields from what the game sent; raises ValueError.

    The date and time are the player's own clock, as the game shows it and
    as raidres's form takes them in a browser on this same machine; raidres
    stores UTC, so they go as UTC, the way the form's toISOString() sends
    them. options are the SR+ settings (inc, skip, input, valid, prev) and
    the admins (raidres user-IDs, comma-separated, kept as text)."""
    from datetime import datetime, timezone
    try:
        raid_id, limit = int(raid_id), int(limit)
    except (TypeError, ValueError):
        raise ValueError("bad raid or limit")
    if raid_id <= 0:
        raise ValueError("bad raid id: %r" % raid_id)
    if not 1 <= limit <= 10:
        raise ValueError("reserves each must be 1 to 10, not %d" % limit)
    if not (_DAY_RE.match(day or "") and _CLOCK_RE.match(clock or "")):
        raise ValueError("bad date or time: %r %r" % (day, clock))
    flags = (lock, comments, srplus, dupes)
    if any(f not in ("0", "1") for f in flags):
        raise ValueError("bad switches: %r" % (flags,))
    try:
        start = datetime.strptime(day + " " + clock, "%Y-%m-%d %H:%M").astimezone()
    except ValueError:
        raise ValueError("no such date or time: %s %s" % (day, clock))
    now = now or datetime.now().astimezone()
    if (start - now).total_seconds() < -300:
        raise ValueError("that time has already passed")
    description = (description or "").strip()
    if len(description) > 500:
        raise ValueError("the description is too long")
    o = options or {}
    try:
        inc, skip = int(o.get("inc", 0)), int(o.get("skip", 0))
    except ValueError:
        raise ValueError("bad SR+ numbers")
    if not (0 <= inc <= 1000 and 0 <= skip <= 10):
        raise ValueError("SR+ numbers out of range")
    prev = o.get("prev") or None
    if prev is not None:
        validate_ref(prev)
    admins = [x for x in (o.get("admins") or "").split(",") if x]
    if any(not x.isdigit() or len(x) > 25 for x in admins):
        raise ValueError("bad raidres user-ID among the admins")
    admins = list(dict.fromkeys(admins))
    if len(admins) > ADMIN_LIMIT:
        raise ValueError("raidres takes at most %d admins" % ADMIN_LIMIT)
    return {
        "raidId": raid_id,
        "description": description,
        "startTime": start.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
        "reservationLimit": limit,
        "allowDuplicateReservation": dupes == "1",
        "lockAtStartTime": lock == "1",
        "lockMinutesBeforeStartTime": 0,
        "locked": None,
        "advancedHrItems": [],
        "extraAdministratorUserIdentifiers": admins,
        "allowComments": comments == "1",
        "minimumAccountAge": 0,
        "forbiddenUserIds": [],
        "allowSrPlus": srplus == "1",
        "previousRaidEventReference": prev if srplus == "1" else None,
        "allowSrPlusInput": o.get("input", "1") != "0",
        "defaultSrPlusIncrease": inc if srplus == "1" else 0,
        "srPlusAllowEventSkipCount": skip if srplus == "1" else 0,
        "requireSrPlusValidation": srplus == "1" and o.get("valid") == "1",
    }

def split_options(words):
    """The key=value words after the switches, then the description."""
    options, rest = {}, list(words)
    while rest and _OPTION_RE.match(rest[0]):
        k, v = _OPTION_RE.match(rest.pop(0)).groups()
        options[k] = v
    return options, " ".join(rest)

def _page_eval(script, args, url="https://raidres.top/"):
    """Run an in-page script in a raidres tab; its answer, or an error line."""
    if not ensure_chrome(url):
        return None, "error: could not start Chrome"
    tab = find_raidres_tab()
    if not tab:
        log("no raidres.top tab in Chrome -- opening one")
        tab = open_raidres_tab()
        if not tab or not tab.get("webSocketDebuggerUrl"):
            return None, "error: could not open a raidres tab in Chrome"
    ws = WebSocket(tab["webSocketDebuggerUrl"])
    try:
        reply = ws.call("Runtime.evaluate", {
            "expression": "(%s)(%s)" % (script, json.dumps(args)),
            "awaitPromise": True,
            "returnByValue": True,
        }, timeout=45)
        value = reply.get("result", {}).get("result", {}).get("value")
        if not isinstance(value, str):
            err = reply.get("result", {}).get("exceptionDetails", {})
            return None, "error: CDP eval failed: %s" % json.dumps(err)[:200]
        answer = json.loads(value)
        if answer.get("result") == "signin":
            expiry = _format_expiry(_get_expiry(ws))
            return None, "signin %s" % expiry if expiry else "signin"
        return answer, None
    finally:
        ws.close()

def create_event(words, dry=False):
    """create RAIDID YYYY-MM-DD HH:MM LIMIT LOCK COMMENTS SRPLUS DUPES
              [hr=ID,ID|tpl=ID] [inc=N] [skip=N] [input=0|1] [valid=0|1] [prev=REF]
              [admins=USERID,USERID] [DESCRIPTION...]"""
    if len(words) < 8:
        return "error: bad command"
    options, description = split_options(words[8:])
    try:
        body = event_body(*(words[:8] + [description]), options=options)
        hr = [int(x) for x in options.get("hr", "").split(",") if x]
        tpl = int(options["tpl"]) if options.get("tpl") else None
    except ValueError as e:
        return "error: %s" % e
    answer, line = _page_eval(_CREATE_JS, {"body": body, "hr": hr, "tpl": tpl, "dry": bool(dry)})
    if line:
        return line
    if answer.get("result") == "ok":
        ref = str(answer.get("reference", ""))
        if not _REF_RE.match(ref):
            return "error: raidres answered with a strange link: %r" % ref[:40]
        return "ok created %s" % ref
    return reserve_line(answer)

def templates():
    """ok templates [{"id":..,"name":..,"raid":..,"hr":N},...] -- one line of JSON."""
    answer, line = _page_eval(_TEMPLATES_JS, {})
    if line:
        return line
    if answer.get("result") == "ok":
        return "ok templates " + json.dumps(answer.get("lists", []), ensure_ascii=False)
    return reserve_line(answer)

def suggest(words):
    """suggest RAIDID -> ok suggest RAIDID [{"ref","start","inc","skip","input","valid"},...]"""
    try:
        raid = int(words[0])
    except (IndexError, ValueError):
        return "error: bad command"
    answer, line = _page_eval(_SUGGEST_JS, {"raid": raid})
    if line:
        return line
    if answer.get("result") == "ok":
        return "ok suggest %d %s" % (raid, json.dumps(answer.get("events", []), ensure_ascii=False))
    return reserve_line(answer)

# ---------------------------------------------------------------------------
# An existing event's hard reserves and SR+
#
# PATCH /api/events/<ref> with only the fields being changed, the way lock
# and unlock already send {reference, locked}: what is left out -- the
# start, the admins, the banned -- stays as it is on raidres.
# ---------------------------------------------------------------------------

_SETTINGS_JS = r"""
async (a) => {
""" + _PAGE_HELPERS + r"""
  if (await signedIn() == null) return answer({ result: 'signin' });
  const ev = await get('/api/events/' + encodeURIComponent(a.ref));
  if (!ev.ok || !ev.body) return answer({ result: 'error', message: 'raidres has no list ' + a.ref });
  const e = ev.body;
  if (e.isAuthor === false && !a.dry)
    return answer({ result: 'error', message: "that list isn't yours to change" });
  const body = { reference: e.reference };
  if (a.tpl) {
    const t = await get('/api/raid-event-templates');
    const list = Array.isArray(t.body) ? t.body : ((t.body && t.body.data) || []);
    const tpl = list.find(x => x && x.id === a.tpl);
    if (!tpl) return answer({ result: 'error', message: "that saved HR list isn't on raidres any more" });
    if (tpl.raidId !== e.raidId) return answer({ result: 'error', message: 'that saved HR list is for another raid' });
    body.advancedHrItems = (tpl.raidEventTemplateItems || [])
      .filter(i => i.isHardReserved || (i.note && i.note.length > 0))
      .map(i => ({ raidItemId: i.raidItemId, isHardReserved: !!i.isHardReserved, note: i.note || null,
                   characterClasses: i.characterClasses || [],
                   characterSpecializations: i.characterSpecializations || [],
                   characterNames: i.characterNames || [] }));
  } else if (a.hr) {
    const raid = await get('/raids/raid_' + e.raidId + '.json');
    if (!raid.ok || !raid.body) return answer({ result: 'error', message: "couldn't load the raid's loot table" });
    // What the site set stays as it set it: an item that stays a hard
    // reserve keeps its class, spec and name limits and its note; one that
    // only had a note or limits becomes a hard reserve with them; every
    // other entry that isn't a hard reserve is left as it is. Only the
    // fields the form itself sends go back.
    const before = e.advancedHrItems || [];
    const entry = i => ({ raidItemId: i.raidItemId, isHardReserved: !!i.isHardReserved,
      note: i.note == null ? null : i.note,
      characterClasses: i.characterClasses || [], characterSpecializations: i.characterSpecializations || [],
      characterNames: i.characterNames || [] });
    const items = [];
    for (const g of a.hr) {
      const it = (raid.body.raidItems || []).find(i => i.gameDbItemId === g);
      if (!it) return answer({ result: 'error', message: 'item ' + g + " isn't in this raid's loot on raidres" });
      const had = before.find(i => i.raidItemId === it.id);
      items.push(had ? Object.assign(entry(had), { isHardReserved: true })
        : { raidItemId: it.id, isHardReserved: true, note: null,
            characterClasses: [], characterSpecializations: [], characterNames: [] });
    }
    const kept = before.filter(i => !i.isHardReserved && !items.some(x => x.raidItemId === i.raidItemId));
    body.advancedHrItems = items.concat(kept.map(entry));
  }
  if (a.sr != null) {
    body.allowSrPlus = a.sr;
    if (a.sr) {
      if (a.inc != null) body.defaultSrPlusIncrease = a.inc;
      if (a.prev !== undefined) body.previousRaidEventReference = a.prev;
      if (a.skip != null) body.srPlusAllowEventSkipCount = a.skip;
      if (a.input != null) body.allowSrPlusInput = a.input;
      if (a.valid != null) body.requireSrPlusValidation = a.valid;
    }
  }
  if (a.dry) return answer({ result: 'plan', method: 'PATCH', body });
  const r = await send('/api/events/' + encodeURIComponent(e.reference), 'PATCH', body);
  if (r.fail) return r.fail;
  return answer({ result: 'ok', done: 'saved' });
}
"""

def event_settings(words, dry=False):
    """settings REF [hr=ID,ID|hr=none|tpl=ID] [srplus=0|1] [inc=N] [prev=REF|prev=none]
                [skip=N] [input=0|1] [valid=0|1]"""
    if not words:
        return "error: bad command"
    try:
        ref = validate_ref(words[0])
        opts = {}
        for w in words[1:]:
            m = re.match(r"^(hr|tpl|srplus|inc|prev|skip|input|valid)=(\S+)$", w)
            if not m:
                raise ValueError("bad setting: %r" % w)
            opts[m.group(1)] = m.group(2)
        args = {"ref": ref, "dry": bool(dry)}
        if "tpl" in opts:
            args["tpl"] = int(opts["tpl"])
        elif "hr" in opts:
            args["hr"] = [] if opts["hr"] == "none" else [int(x) for x in opts["hr"].split(",") if x]
        if "srplus" in opts:
            if opts["srplus"] not in ("0", "1"):
                raise ValueError("srplus must be 0 or 1")
            args["sr"] = opts["srplus"] == "1"
        if "inc" in opts:
            args["inc"] = int(opts["inc"])
            if not 0 <= args["inc"] <= 1000:
                raise ValueError("SR+ increase out of range")
        if "prev" in opts:
            args["prev"] = None if opts["prev"] == "none" else validate_ref(opts["prev"])
        if "skip" in opts:
            args["skip"] = int(opts["skip"])
            if not 0 <= args["skip"] <= 10:
                raise ValueError("SR+ skip count out of range")
        for k in ("input", "valid"):
            if k in opts:
                if opts[k] not in ("0", "1"):
                    raise ValueError("%s must be 0 or 1" % k)
                args[k] = opts[k] == "1"
    except ValueError as e:
        return "error: %s" % e
    answer, line = _page_eval(_SETTINGS_JS, args, "https://raidres.top/res/%s" % ref)
    if line:
        return line
    if answer.get("result") == "ok":
        return "ok saved"
    return reserve_line(answer)

# ---------------------------------------------------------------------------
# One reserve's SR+, set or validated
#
# PUT /api/events/<ref>/sr-plus, as raidres's own SR+ editor sends it: every
# reservation with its current value and validation, the one being changed
# changed. Only the list's owner and its admins may; raidres says so if not.
# ---------------------------------------------------------------------------

_SRPLUS_JS = r"""
async (a) => {
""" + _PAGE_HELPERS + r"""
  if (await signedIn() == null) return answer({ result: 'signin' });
  const ev = await get('/api/events/' + encodeURIComponent(a.ref));
  if (!ev.ok || !ev.body) return answer({ result: 'error', message: 'raidres has no list ' + a.ref });
  const e = ev.body;
  if (!e.allowSrPlus) return answer({ result: 'error', message: "SR+ isn't on for that list" });
  const raid = await get('/raids/raid_' + e.raidId + '.json');
  if (!raid.ok || !raid.body) return answer({ result: 'error', message: "couldn't load the raid's loot table" });
  const ids = (raid.body.raidItems || []).filter(i => i.gameDbItemId === a.item).map(i => i.id);
  const name = a.name.toLocaleLowerCase();
  // Every copy of the item: raidres gives a duplicate reserve the same SR+
  // as the first, so the copies are changed together.
  const rows = (e.reservations || []).filter(r => r.character
    && String(r.character.name).toLocaleLowerCase() === name && ids.includes(r.raidItemId));
  if (rows.length === 0) return answer({ result: 'error', message: a.name + " hasn't reserved that on raidres" });
  // Every reservation, as raidres's own "Update SR+" sends them.
  const list = (e.reservations || []).map(r => ({ reservationId: r.id,
    isValid: !!(r.srPlus && r.srPlus.isValid),
    value: (r.srPlus && Number(r.srPlus.value) > 0) ? Number(r.srPlus.value) : 0 }));
  for (const mine of list.filter(x => rows.some(r => r.id === x.reservationId))) {
    if (a.value != null) mine.value = a.value;
    if (a.valid != null) mine.isValid = a.valid;
  }
  const body = { reference: e.reference, reservations: list };
  if (a.dry) return answer({ result: 'plan', method: 'PUT', body });
  const r = await send('/api/events/' + encodeURIComponent(e.reference) + '/sr-plus', 'PUT', body);
  if (r.fail) return r.fail;
  return answer({ result: 'ok', done: 'srplus' });
}
"""

def set_srplus(words, dry=False):
    """srplus REF ITEMID NAME [value=N] [valid=0|1]"""
    if len(words) < 4:
        return "error: bad command"
    try:
        ref = validate_ref(words[0])
        item = int(words[1])
        name = words[2]
        if not _NAME_RE.match(name):
            raise ValueError("bad character name: %r" % name)
        args = {"ref": ref, "item": item, "name": name, "dry": bool(dry)}
        for w in words[3:]:
            m = re.match(r"^(value|valid)=(\d+)$", w)
            if not m:
                raise ValueError("bad SR+ change: %r" % w)
            if m.group(1) == "value":
                args["value"] = int(m.group(2))
                if args["value"] > 100000:
                    raise ValueError("SR+ too large")
            else:
                if m.group(2) not in ("0", "1"):
                    raise ValueError("valid must be 0 or 1")
                args["valid"] = m.group(2) == "1"
    except ValueError as e:
        return "error: %s" % e
    answer, line = _page_eval(_SRPLUS_JS, args, "https://raidres.top/res/%s" % ref)
    if line:
        return line
    if answer.get("result") == "ok":
        return "ok srplus"
    return reserve_line(answer)

# ---------------------------------------------------------------------------
# A player made an admin of the list, or no longer one
#
# PATCH /api/events/<ref> {reference, extraAdministratorUserIdentifiers}:
# the whole list of admins, as raidres's own edit form sends it, with the one
# added or taken out. A player is known by the raidres user-ID on the rows
# they reserved themselves; a row made "for another player" carries the id
# of whoever made it, so it can't say who they are. For someone not on the
# list, the game sends the id it saved from an earlier one (id=N); the list's
# own rows win over it.
# ---------------------------------------------------------------------------

_ADMIN_JS = r"""
async (a) => {
""" + _PAGE_HELPERS + r"""
  if (await signedIn() == null) return answer({ result: 'signin' });
  const ev = await get('/api/events/' + encodeURIComponent(a.ref));
  if (!ev.ok || !ev.body) return answer({ result: 'error', message: 'raidres has no list ' + a.ref });
  const e = ev.body;
  if (e.isAuthor === false)
    return answer({ result: 'error', message: "only the list's owner can change its admins" });
  const name = a.name.toLocaleLowerCase();
  const rows = (e.reservations || []).filter(r => r.character && r.user
    && String(r.character.name).toLocaleLowerCase() === name);
  const own = rows.filter(r => !r.character.isTemporary);
  if (own.length === 0 && !a.id)
    return answer({ result: 'error', message: rows.length > 0
      ? a.name + ' was reserved for by someone else; they sign up on raidres themselves first'
      : a.name + " isn't signed up on this list, and their raidres account isn't known here" });
  const ids = [...new Set(own.map(r => String(r.user.id)))];
  if (ids.length > 1)
    return answer({ result: 'error', message: 'two raidres accounts signed up as ' + a.name });
  const id = ids.length === 1 ? ids[0] : String(a.id);
  if (e.authorId != null && String(e.authorId) === id)
    return answer({ result: 'error', message: a.name + ' owns the list' });
  const now = (e.extraAdministratorUserIds || []).map(String);
  const has = now.includes(id);
  if (a.add && has) return answer({ result: 'error', message: a.name + ' is already an admin of it' });
  if (!a.add && !has) return answer({ result: 'error', message: a.name + " isn't an admin of it" });
  if (a.add && now.length >= """ + str(ADMIN_LIMIT) + r""")
    return answer({ result: 'error', message: 'the list has ' + now.length + ' admins already, as many as raidres takes' });
  const list = a.add ? now.concat([id]) : now.filter(x => x !== id);
  const body = { reference: e.reference, extraAdministratorUserIdentifiers: list };
  if (a.dry) return answer({ result: 'plan', method: 'PATCH', body });
  const r = await send('/api/events/' + encodeURIComponent(e.reference), 'PATCH', body);
  if (r.fail) return r.fail;
  return answer({ result: 'ok', done: 'admin', count: list.length });
}
"""

_USER_ID_RE = re.compile(r"^id=(\d{1,25})$")

def set_admin(words, dry=False):
    """admin REF NAME add|remove [id=RAIDRES-USER-ID]"""
    if len(words) not in (3, 4) or words[2] not in ("add", "remove"):
        return "error: bad command"
    try:
        ref = validate_ref(words[0])
        name = words[1]
        if not _NAME_RE.match(name):
            raise ValueError("bad character name: %r" % name)
        uid = None
        if len(words) == 4:
            m = _USER_ID_RE.match(words[3])
            if not m:
                raise ValueError("bad raidres user-ID: %r" % words[3])
            uid = m.group(1)            # text: too long for a JS number
    except ValueError as e:
        return "error: %s" % e
    args = {"ref": ref, "name": name, "add": words[2] == "add", "id": uid, "dry": bool(dry)}
    answer, line = _page_eval(_ADMIN_JS, args, "https://raidres.top/res/%s" % ref)
    if line:
        return line
    if answer.get("result") == "ok":
        return "ok admin %d" % answer.get("count", 0)
    return reserve_line(answer)

def signin(ref):
    validate_ref(ref)
    login_url = "https://raidres.top/"
    if not ensure_chrome(login_url, need_visible=True):
        return "error: could not start Chrome"
    tab = find_raidres_tab()
    if tab and tab.get("webSocketDebuggerUrl"):
        ws = WebSocket(tab["webSocketDebuggerUrl"])
        try:
            ws.call("Page.navigate", {"url": login_url})
            ws.call("Page.bringToFront")
        finally:
            ws.close()
    return "ok"


# ---------------------------------------------------------------------------
# CustomData file watcher (for the addon)
# ---------------------------------------------------------------------------

def find_customdata():
    here = os.path.dirname(os.path.abspath(__file__))
    d = here
    for _ in range(6):
        cd = os.path.join(d, "CustomData")
        if os.path.isdir(cd):
            return cd
        wow = os.path.join(d, "WoW.exe")
        if os.path.isfile(wow):
            cd = os.path.join(d, "CustomData")
            os.makedirs(cd, exist_ok=True)
            return cd
        d = os.path.dirname(d)
    return None

CMD_FILE = "RaidResBridge_lock_cmd.txt"
RESULT_FILE = "RaidResBridge_lock_result.txt"

def log(msg):
    print("[%s] %s" % (time.strftime("%H:%M:%S"), msg))

def still_running(pid):
    """A function saying whether process `pid` is still running.

    A handle is taken now and waited on later, so a PID that Windows hands
    to a new process after the game closes can't pass for the game. If the
    process can't be opened for some other reason than being gone, it is
    taken to be running: better a watcher too many than one that quits
    while its game is still open."""
    import ctypes
    from ctypes import wintypes
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.OpenProcess.restype = wintypes.HANDLE
    k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    k32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    SYNCHRONIZE, WAIT_TIMEOUT, ERROR_INVALID_PARAMETER = 0x00100000, 0x102, 87
    handle = k32.OpenProcess(SYNCHRONIZE, False, pid)
    if not handle:
        gone = ctypes.get_last_error() == ERROR_INVALID_PARAMETER
        return lambda: not gone
    return lambda: k32.WaitForSingleObject(handle, 0) == WAIT_TIMEOUT

# Each command from the game may start "#ID ": the answer starts with the
# same, so the game can tell a late answer to a command it gave up on from
# the answer to the one it is waiting for.
_TAG_RE = re.compile(r"^#(\d{1,20}) (.*)$", re.S)

def split_tag(line):
    m = _TAG_RE.match(line)
    return (m.group(1), m.group(2).strip()) if m else (None, line)

def tag_result(tag, result):
    return ("#%s %s" % (tag, result)) if tag else result

def run_command(line):
    """One command line from the game, done; the line to answer with."""
    words = line.split()
    if words and words[0] == "srplus":
        log("%s ..." % line)
        result = set_srplus(words[1:])
        log("  -> %s" % result)
        return result

    if words and words[0] == "admin":
        log("%s ..." % line)
        result = set_admin(words[1:])
        log("  -> %s" % result)
        return result

    if words and words[0] == "settings":
        log("%s ..." % line)
        result = event_settings(words[1:])
        log("  -> %s" % result)
        return result

    if words and words[0] == "suggest":
        result = suggest(words[1:])
        log("suggest -> %s" % result[:80])
        return result

    if words == ["templates"]:
        result = templates()
        log("templates -> %s" % result[:80])
        return result

    # create RAIDID DAY TIME LIMIT LOCK COMMENTS SRPLUS DUPES [DESCRIPTION]
    if words and words[0] == "create":
        log("create %s ..." % " ".join(words[1:4]))
        result = create_event(words[1:])
        log("  -> %s" % result)
        return result

    # reserve REF ITEM NAME CLASS [SPEC]  /  unreserve REF ITEM NAME
    # reserve-for REF ITEM NAME CLASS SPEC  /  unreserve-for REF ITEM NAME:
    # the same for another player, as an admin (spec required)
    if words and words[0] in ("reserve", "unreserve", "reserve-for", "unreserve-for"):
        for_other = words[0].endswith("-for")
        remove = words[0].startswith("unreserve")
        sizes = (4,) if remove else ((6,) if for_other else (5, 6))
        if len(words) not in sizes:
            result = "error: bad command"
        else:
            log("%s ..." % line)
            result = reserve(words[1], words[2], words[3],
                             None if remove else words[4],
                             words[5] if len(words) == 6 else None, remove=remove,
                             for_other=for_other)
        log("  -> %s" % result)
        return result

    parts = line.split(None, 1)
    if len(parts) == 1 and parts[0] == "restart":
        log("restart requested")
        kill_chrome()
        log("Chrome stopped. Will start fresh on next command.")
        return "ok restarted"

    if len(parts) != 2 or parts[0] not in ("lock", "unlock", "open", "signin"):
        log("bad command: %r" % line)
        return "error: bad command"

    action, ref = parts
    log("%s %s ..." % (action, ref))

    if action == "signin":
        result = signin(ref)
    elif action == "open":
        result = open_event(ref)
    else:
        result = lock_unlock(ref, action == "lock")
    log("  -> %s" % result)

    return result

def watch(parent=None):
    cd = find_customdata()
    if not cd:
        print("ERROR: can't find CustomData folder.  Run from inside the WoW tree,")
        print("       or from Interface/AddOns/ZyllaRaidRes/tools/.")
        sys.exit(1)

    cmd_path = os.path.join(cd, CMD_FILE)
    result_path = os.path.join(cd, RESULT_FILE)

    if check_chrome():
        tab = find_raidres_tab()
        if tab:
            log("raidres tab found: %s" % tab.get("url", ""))
        else:
            log("no raidres tab -- one will be opened on the first request")
    else:
        log("Chrome will be started headless on the first request")

    log("watching %s" % cmd_path)
    game_open = still_running(parent) if parent else None
    if game_open:
        log("stopping when process %d (the game) closes" % parent)
    log("press Ctrl+C to stop")

    while True:
        tag = None
        try:
            # The game started this and has gone: go with it, and take the
            # Chrome this started too. One left running would answer the next
            # game's commands with a Chrome nothing will ever close.
            if game_open and not game_open():
                log("the game has closed; stopping")
                if _chrome_proc:
                    kill_chrome()
                break

            if os.path.isfile(cmd_path):
                # UTF-8: the game writes names with accents that way.
                with open(cmd_path, "r", encoding="utf-8", errors="replace") as f:
                    line = f.read().strip()
                os.remove(cmd_path)

                tag, line = split_tag(line)
                result = run_command(line)
                # UTF-8 both ways; the game's id goes back on the answer, so a
                # late one is never taken for the next command's
                with open(result_path, "w", encoding="utf-8") as f:
                    f.write(tag_result(tag, result))

            time.sleep(0.5)

        except KeyboardInterrupt:
            log("stopped")
            if _headless:
                kill_chrome()
                log("headless Chrome stopped.")
            break
        except Exception as e:
            log("error: %s" % e)
            try:
                with open(result_path, "w", encoding="utf-8") as f:
                    f.write(tag_result(tag, "error: %s" % e))
            except Exception:
                pass
            time.sleep(2)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(0)

    cmd = args[0].lower()

    if cmd == "watch":
        parent = None
        if "--parent" in args:
            try:
                parent = int(args[args.index("--parent") + 1])
            except (IndexError, ValueError):
                print("usage: raidres_lock.py watch [--parent PID]")
                sys.exit(1)
        watch(parent)

    elif cmd == "status":
        if check_chrome():
            print("Chrome CDP is reachable on port %d." % CDP_PORT)
            tab = find_raidres_tab()
            if tab:
                print("raidres tab: %s" % tab.get("url", ""))
            else:
                print("no raidres.top tab open in Chrome.")
        else:
            print("Chrome is NOT reachable on port %d." % CDP_PORT)
            print("Start Chrome with:  --remote-debugging-port=%d" % CDP_PORT)

    elif cmd in ("lock", "unlock", "open"):
        if len(args) < 2:
            print("usage: raidres_lock.py %s REF" % cmd)
            sys.exit(1)
        ref = validate_ref(args[1])
        if not ensure_chrome():
            print("ERROR: could not start or reach Chrome on port %d." % CDP_PORT)
            sys.exit(1)
        if cmd == "open":
            result = open_event(ref)
        else:
            result = lock_unlock(ref, cmd == "lock")
        print(result)
        sys.exit(0 if result.startswith("ok") else 1)

    elif cmd in ("reserve", "unreserve", "reserve-for", "unreserve-for"):
        dry = "--dry-run" in args
        words = [w for w in args[1:] if w != "--dry-run"]
        remove = cmd.startswith("unreserve")
        for_other = cmd.endswith("-for")
        if for_other and not remove and len(words) != 5:
            print("usage: raidres_lock.py reserve-for REF ITEMID NAME CLASS SPEC [--dry-run]")
            sys.exit(1)
        if (remove and len(words) != 3) or (not remove and len(words) not in (4, 5)):
            print("usage: raidres_lock.py reserve REF ITEMID NAME CLASS [SPEC] [--dry-run]")
            print("       raidres_lock.py unreserve REF ITEMID NAME [--dry-run]")
            sys.exit(1)
        result = reserve(words[0], words[1], words[2], None if remove else words[3],
                         words[4] if len(words) == 5 else None, remove=remove, dry=dry,
                         for_other=for_other)
        print(result)
        sys.exit(0 if result.startswith(("ok", "plan")) else 1)

    elif cmd == "srplus":
        dry = "--dry-run" in args
        result = set_srplus([w for w in args[1:] if w != "--dry-run"], dry=dry)
        print(result)
        sys.exit(0 if result.startswith(("ok", "plan")) else 1)

    elif cmd == "admin":
        dry = "--dry-run" in args
        words = [w for w in args[1:] if w != "--dry-run"]
        if len(words) not in (3, 4):
            print("usage: raidres_lock.py admin REF NAME add|remove [id=RAIDRES-USER-ID] [--dry-run]")
            sys.exit(1)
        result = set_admin(words, dry=dry)
        print(result)
        sys.exit(0 if result.startswith(("ok", "plan")) else 1)

    elif cmd == "settings":
        dry = "--dry-run" in args
        result = event_settings([w for w in args[1:] if w != "--dry-run"], dry=dry)
        print(result)
        sys.exit(0 if result.startswith(("ok", "plan")) else 1)

    elif cmd == "suggest":
        result = suggest(args[1:])
        print(result)
        sys.exit(0 if result.startswith("ok") else 1)

    elif cmd == "templates":
        result = templates()
        print(result)
        sys.exit(0 if result.startswith("ok") else 1)

    elif cmd == "create":
        dry = "--dry-run" in args
        words = [w for w in args[1:] if w != "--dry-run"]
        if len(words) < 8:
            print("usage: raidres_lock.py create RAIDID YYYY-MM-DD HH:MM LIMIT LOCK COMMENTS "
                  "SRPLUS DUPES [DESCRIPTION...] [--dry-run]")
            print("       LOCK, COMMENTS, SRPLUS and DUPES are 0 or 1; the time is this PC's.")
            sys.exit(1)
        result = create_event(words, dry=dry)
        print(result)
        sys.exit(0 if result.startswith(("ok", "plan")) else 1)

    else:
        print("unknown command: %s" % cmd)
        print("try: watch, status, lock REF, unlock REF, open REF, reserve, unreserve, create")
        sys.exit(1)

if __name__ == "__main__":
    main()
