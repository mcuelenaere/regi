#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Check regi-mcp against a fake Regi, so the relay's offline and reconnect
behaviour is tested without the app.

    relay_check.py path/to/regi-mcp

Points the relay at a temporary socket (REGI_MCP_DIR) and checks it: answers
the handshake and lists the cached tools while nothing listens; forwards once
the fake Regi starts, after replaying the client's handshake; fails a request
the fake Regi drops; reconnects when it comes back. Standard library only.
"""
import json
import os
import queue
import socket
import subprocess
import sys
import tempfile
import threading

relay_path = sys.argv[1]
directory = tempfile.mkdtemp()
sock_path = os.path.join(directory, "mcp.sock")
with open(os.path.join(directory, "mcp-tools.json"), "w") as f:
    json.dump({"serverInfo": {"name": "Regi", "version": "1.2.3"}, "instructions": "cached instructions",
               "tools": [{"name": "cached_tool", "inputSchema": {"type": "object"}}]}, f)


class FakeRegi:
    """Answers initialize, tools/list and an echo tool; never answers "hang"."""

    def __init__(self):
        self.seen, self.conns = [], []
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(sock_path)
        self.listener.listen()
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while True:
            try:
                conn, _ = self.listener.accept()
            except OSError:
                return
            self.conns.append(conn)
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def serve(self, conn):
        for line in conn.makefile("rb"):
            message = json.loads(line)
            self.seen.append(message)
            method, rid = message.get("method"), message.get("id")
            if method == "initialize":
                reply = {"protocolVersion": message["params"]["protocolVersion"], "capabilities": {"tools": {}},
                         "serverInfo": {"name": "fake-regi", "version": "9"}}
            elif method == "tools/list":
                reply = {"tools": [{"name": "echo", "inputSchema": {"type": "object"}}]}
            elif method == "tools/call" and message["params"]["name"] == "echo":
                reply = {"content": [{"type": "text", "text": message["params"]["arguments"]["text"]}]}
            else:
                continue
            conn.sendall((json.dumps({"jsonrpc": "2.0", "id": rid, "result": reply}) + "\n").encode())

    def stop(self):
        self.listener.close()
        for conn in self.conns:
            try:
                conn.shutdown(socket.SHUT_RDWR)   # wakes its serve() thread
            except OSError:
                pass                              # the relay already hung up
            conn.close()
        os.unlink(sock_path)


relay = subprocess.Popen([relay_path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         env={**os.environ, "REGI_MCP_DIR": directory})
replies = queue.Queue()
threading.Thread(target=lambda: [replies.put(json.loads(line)) for line in relay.stdout], daemon=True).start()
failures = 0


def send(message):
    relay.stdin.write((json.dumps({"jsonrpc": "2.0", **message}) + "\n").encode())
    relay.stdin.flush()


def call(rid, method, params=None):
    send({"id": rid, "method": method, **({"params": params} if params is not None else {})})
    reply = replies.get(timeout=5)
    assert reply["id"] == rid, f"reply for {reply['id']!r}, expected {rid!r}"
    return reply


def check(label, condition):
    global failures
    print(("ok   " if condition else "FAIL ") + label)
    failures += not condition


def tool_text(reply):
    return reply["result"]["content"][0]["text"]


# Nothing listening: the relay stands in.
hello = call(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                               "clientInfo": {"name": "relay-check", "version": "1"}})["result"]
send({"method": "notifications/initialized"})
check("offline handshake answers from the cache",
      hello["serverInfo"]["version"] == "1.2.3" and hello["instructions"] == "cached instructions"
      and hello["protocolVersion"] == "2025-06-18")
check("offline tools/list is the cached list",
      [t["name"] for t in call(2, "tools/list")["result"]["tools"]] == ["cached_tool"])
offline_call = call(3, "tools/call", {"name": "cached_tool", "arguments": {}})
check("offline tools/call says to open Regi", offline_call["result"]["isError"] and "open Regi" in tool_text(offline_call))
check("offline ping", call(4, "ping")["result"] == {})

# Regi appears: the next call connects, replays the handshake, forwards.
regi = FakeRegi()
check("forwards once Regi is up", tool_text(call(5, "tools/call", {"name": "echo", "arguments": {"text": "hi"}})) == "hi")
methods = [m.get("method") for m in regi.seen]
check("replays the client's handshake first",
      methods[:3] == ["initialize", "notifications/initialized", "tools/call"]
      and regi.seen[0]["params"]["clientInfo"]["name"] == "relay-check")
check("tools/list comes from Regi now", [t["name"] for t in call(6, "tools/list")["result"]["tools"]] == ["echo"])

# Regi dies with a request outstanding: that request still gets an answer.
send({"id": "h1", "method": "tools/call", "params": {"name": "hang", "arguments": {}}})
while not any(m.get("id") == "h1" for m in regi.seen):
    pass
regi.stop()
owed = replies.get(timeout=5)
check("a request Regi dropped is failed", owed["id"] == "h1" and "error" in owed)
check("offline again afterwards", call(7, "tools/call", {"name": "echo", "arguments": {"text": "x"}})["result"]["isError"])

# Regi comes back: reconnects without restarting the relay.
regi = FakeRegi()
check("reconnects", tool_text(call(8, "tools/call", {"name": "echo", "arguments": {"text": "again"}})) == "again")

relay.stdin.close()
check("exits when the client hangs up", relay.wait(timeout=5) == 0)
regi.stop()
print("all checks passed" if not failures else f"{failures} check(s) failed")
sys.exit(1 if failures else 0)
