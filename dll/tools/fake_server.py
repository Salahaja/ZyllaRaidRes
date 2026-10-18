#!/usr/bin/env python3
"""A raidres stand-in that misbehaves on purpose, for test_local.exe.

    python fake_server.py [port]        (default 8765, 127.0.0.1 only)

    /ok      answers at once
    /slow    answers after 1.5 seconds
    /hang    takes the request and never answers
    /drip    sends a header, then one byte every half second, forever
    /stats   the most connections it has had open at once, then resets it

/hang and /drip are the two ways a real server can keep a request thread
alive with no end: never answering, or answering just often enough that no
single wait ever times out.
"""

import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lock = threading.Lock()
open_now = 0
most_open = 0


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, code, body):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        global open_now, most_open
        if self.path == "/stats":
            with lock:
                seen = most_open
                most_open = 0
            self.reply(200, str(seen))
            return
        with lock:
            open_now += 1
            most_open = max(most_open, open_now)
        try:
            if self.path == "/ok":
                self.reply(200, "hello")
            elif self.path == "/slow":
                time.sleep(1.5)
                self.reply(200, "slow")
            elif self.path == "/hang":
                time.sleep(60)
            elif self.path == "/drip":
                self.send_response(200)
                self.send_header("Content-Length", "1000000")
                self.end_headers()
                for _ in range(120):
                    self.wfile.write(b"x")
                    self.wfile.flush()
                    time.sleep(0.5)
            else:
                self.reply(404, "no")
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass
        finally:
            with lock:
                open_now -= 1


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    print("listening on 127.0.0.1:%d" % port, flush=True)
    server.serve_forever()
