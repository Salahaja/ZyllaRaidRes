#!/usr/bin/env python3
"""Lock and unlock raidres events from inside WoW, through Chrome.

Chrome manages its own cookies -- this script never sees, stores or touches the
raidres session cookie.  It connects to Chrome's DevTools Protocol (CDP) and
runs a one-line fetch() in a tab that has raidres.top open.  Chrome sends the
cookie itself, the same way it would if you clicked the button on the page.

Requirements
  Python 3           (already needed for the watcher)
  Chrome             running with  --remote-debugging-port=9222
  A raidres.top tab  signed in (the script opens one if there isn't one)

No pip packages.  The WebSocket client is 80 lines of stdlib.

Usage
  python raidres_lock.py watch          watch CustomData for addon requests
  python raidres_lock.py lock   REF    lock event REF and exit
  python raidres_lock.py unlock REF    unlock event REF and exit
  python raidres_lock.py open   REF    open event REF in Chrome and exit
  python raidres_lock.py status         check Chrome and the raidres tab
"""

import http.client, json, os, socket, struct, sys, time, re

CDP_PORT = 9222
CDP_HOST = "127.0.0.1"

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
    import glob
    for pattern in [
        os.path.join(os.environ.get("ProgramFiles", ""), "Google", "Chrome", "Application", "chrome.exe"),
        os.path.join(os.environ.get("ProgramFiles(x86)", ""), "Google", "Chrome", "Application", "chrome.exe"),
        os.path.join(os.environ.get("LocalAppData", ""), "Google", "Chrome", "Application", "chrome.exe"),
    ]:
        if os.path.isfile(pattern):
            return pattern
    return None

def start_chrome():
    exe = find_chrome_exe()
    if not exe:
        log("Chrome not found in the usual places.")
        return False
    profile = os.path.join(os.environ.get("LocalAppData", ""), "chrome-cdp-raidres")
    args = [exe, "--remote-debugging-port=%d" % CDP_PORT,
            "--user-data-dir=%s" % profile, "https://raidres.top"]
    log("starting Chrome with CDP...")
    import subprocess
    subprocess.Popen(args, close_fds=True)
    for _ in range(20):
        time.sleep(1)
        if check_chrome():
            log("Chrome CDP is ready.")
            return True
    log("Chrome started but CDP not reachable after 20s.")
    return False

def ensure_chrome():
    if check_chrome():
        return True
    return start_chrome()


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
    if not ensure_chrome():
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
    if not ensure_chrome():
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
    finally:
        ws.close()

    value = (result.get("result", {}).get("result", {}).get("value", "")
             if "result" in result else "")

    if not value:
        err = result.get("result", {}).get("exceptionDetails", {})
        return "error: CDP eval failed: %s" % json.dumps(err)

    if value == "200":
        return "ok"
    elif value.startswith("error:"):
        return "error: " + value[6:]
    else:
        status = value
        if status in ("401", "403"):
            return "error: not signed in to raidres in Chrome (HTTP %s)" % status
        return "error: raidres returned HTTP %s" % status


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

def watch():
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
        log("Chrome is not running yet -- it will be started on the first request")

    log("watching %s" % cmd_path)
    log("press Ctrl+C to stop")

    while True:
        try:
            if os.path.isfile(cmd_path):
                with open(cmd_path, "r") as f:
                    line = f.read().strip()
                os.remove(cmd_path)

                parts = line.split(None, 1)
                if len(parts) != 2 or parts[0] not in ("lock", "unlock", "open"):
                    log("bad command: %r" % line)
                    with open(result_path, "w") as f:
                        f.write("error: bad command")
                    continue

                action, ref = parts
                log("%s %s ..." % (action, ref))

                if action == "open":
                    result = open_event(ref)
                else:
                    result = lock_unlock(ref, action == "lock")
                log("  -> %s" % result)

                with open(result_path, "w") as f:
                    f.write(result)

            time.sleep(0.5)

        except KeyboardInterrupt:
            log("stopped")
            break
        except Exception as e:
            log("error: %s" % e)
            try:
                with open(result_path, "w") as f:
                    f.write("error: %s" % e)
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
        watch()

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
        sys.exit(0 if result == "ok" else 1)

    else:
        print("unknown command: %s" % cmd)
        print("try: watch, status, lock REF, unlock REF, open REF")
        sys.exit(1)

if __name__ == "__main__":
    main()
