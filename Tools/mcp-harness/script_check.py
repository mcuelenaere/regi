#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Check run_script end to end, through regi-mcp, against a test Regi.

    script_check.py BRIDGE QEMU_SESSION [FIXTURE_SESSION]

BRIDGE is Regi.app/Contents/MacOS/regi-mcp (set REGI_MCP_DIR to match the test
Regi's -RegiMCPDirectory). QEMU_SESSION is the disk-less QEMU VM's session id;
FIXTURE_SESSION, if given, a still_vnc.py screen showing two "OK" buttons.
Both must be open in the test Regi already. Prints PASS/FAIL per check and
exits non-zero on any failure. Standard library only.
"""
import base64
import json
import subprocess
import sys
import threading
import time

bridge, qemu = sys.argv[1], sys.argv[2]
fixture = sys.argv[3] if len(sys.argv) > 3 else None
failures = 0


class Client:
    """One MCP client, over its own regi-mcp process."""

    def __init__(self, name):
        self.proc = subprocess.Popen([bridge], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, bufsize=0)
        self.last = 0
        self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": name, "version": "1.0"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, message):
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()

    def request(self, method, params=None):
        self.last += 1
        self.send({"jsonrpc": "2.0", "id": self.last, "method": method,
                   **({"params": params} if params is not None else {})})
        while True:
            line = self.proc.stdout.readline()
            if not line:
                sys.exit(f"regi-mcp closed: {self.proc.stderr.read().decode().strip()}")
            message = json.loads(line)
            if message.get("id") == self.last:
                return message

    def call(self, tool, **arguments):
        """(is_error, body, seconds); body is parsed JSON when the text is JSON."""
        started = time.time()
        result = self.request("tools/call", {"name": tool, "arguments": arguments})["result"]
        self.content = result["content"]   # every part, images included
        text = next((c["text"] for c in result["content"] if c["type"] == "text"), "")
        try:
            body = json.loads(text)
        except ValueError:
            body = text
        return result.get("isError", False), body, time.time() - started

    def script(self, session, source, **extra):
        return self.call("run_script", session=session, script=source, **extra)


def check(name, ok, detail=""):
    global failures
    failures += 0 if ok else 1
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""), flush=True)


def in_background(work):
    box = {}
    thread = threading.Thread(target=lambda: box.setdefault("result", work()))
    thread.start()
    return lambda: (thread.join(), box["result"])[1]


def jpeg_size(content):
    """(width, height) of a base64 JPEG image part, from its SOF marker."""
    data, i = base64.b64decode(content["data"]), 2
    while i < len(data):
        marker, length = data[i + 1], int.from_bytes(data[i + 2:i + 4], "big")
        if marker in (0xC0, 0xC2):
            return int.from_bytes(data[i + 7:i + 9], "big"), int.from_bytes(data[i + 5:i + 7], "big")
        i += 2 + length
    return None


def images(client):
    return [jpeg_size(c) for c in client.content if c["type"] == "image"]


def short(value, limit=300):
    text = value if isinstance(value, str) else json.dumps(value)
    return text if len(text) <= limit else text[:limit] + "…"


a, b = Client("script-check"), Client("script-check-2")

tools = sorted(t["name"] for t in a.request("tools/list")["result"]["tools"])
expected = sorted(["list_hosts", "open_session", "close_session", "list_sessions", "screenshot", "run_script", "power"])
check("exactly the 7 tools", tools == expected, ", ".join(tools))

# A whole flow in one call: reset, wait for SeaBIOS's prompt, open the menu.
a.call("power", session=qemu, action="reset")
err, body, secs = a.script(qemu, """
await screen.waitForText(/press esc/i, { timeoutS: 30 });
await keys.press("esc");
const title = await screen.waitForText(/select boot device/i, { timeoutS: 10 });
log("menu:", title.text);
return (await screen.text()).map(l => l.text);
""", timeout_s=60)
menu = body.get("result") if isinstance(body, dict) else None
check("boot menu reached in one call", not err and isinstance(menu, list) and body.get("log"),
      f"{secs:.1f} s: {short(body)}")

err, body, _ = a.script(qemu, "await pointer.click(/^\\d+\\. /);")
check("a RegExp matching several lines refuses to click", err and "lines match" in str(body.get("error")),
      short(body.get("error") if isinstance(body, dict) else body))

err, body, _ = a.script(qemu, 'return JSON.parse(await __call("stable", JSON.stringify({ quiet_ms: 500, timeout_s: 5 })));')
check("waitStable settles on the boot menu", not err and body["result"]["stable"], short(body.get("result")))

# Runaway JavaScript is stopped, and Regi keeps answering meanwhile.
finish = in_background(lambda: a.script(qemu, "while (true) {}"))
time.sleep(0.3)
_, _, list_secs = b.call("list_sessions")
err, body, secs = finish()
check("an endless loop is stopped", err and "endless loop" in body["error"] and secs < 3, f"{secs:.1f} s")
check("Regi answers during the loop", list_secs < 0.5, f"list_sessions took {list_secs * 1000:.0f} ms")

err, body, secs = a.script(qemu, "await new Promise(() => {});", timeout_s=2)
check("a script that never settles times out", err and "timed out" in body["error"] and 1.8 < secs < 4, f"{secs:.1f} s")

err, body, _ = a.script(qemu, "const a = 1;\nconst b = 2;\nthrow new Error('boom');")
check("a throw reports its line and the screen",
      err and body["error"] == "boom" and body.get("line") == 3 and isinstance(body.get("screen"), list), short(body))

err, body, _ = a.script(qemu, "await sleep(1);\nawait pointer.click('no such text anywhere');")
check("an API failure points at the calling line",
      err and body.get("line") == 2 and body["error"].startswith("no text on screen matches"), short(body))

err, body, _ = a.script(qemu, 'await keys.press("shift");\nawait pointer.click("no such text anywhere");')
check("a failure carries the trace and a screenshot",
      err and any("press shift" in line for line in body.get("trace", [])) and len(images(a)) == 1,
      short(body.get("trace")) + f", images {images(a)}")

err, body, _ = a.script(qemu, 'await pointer.move(/select boot device/i);\nreturn 1;', trace=True)
check("trace: true traces a success, with where a target landed",
      not err and any(line.endswith(")") and "→" in line for line in body.get("trace", [])), short(body.get("trace")))

err, body, _ = a.script(qemu, "await screen.snapshot('menu', { region: { x: 0, y: 0, width: 300, height: 120 } });\n"
                              "await screen.snapshot({ maxWidth: 360 });\nreturn 1;")
check("snapshots attach images, a region at full resolution", not err and images(a) == [(300, 120), (360, 200)],
      f"images {images(a)}")

err, body, _ = a.script(qemu, "for (let i = 0; i < 4; i++) await screen.snapshot({ maxWidth: 100 });")
check("snapshots are capped at 3", err and "at most 3" in body["error"] and body.get("line") == 1, body["error"])

err, body, _ = a.script(qemu, "let x = ;")
check("a syntax error reports its line", err and "SyntaxError" in body["error"] and body.get("line") == 1, short(body))

err, body, _ = a.script(qemu, 'await keys.press("ctrl+nope");')
check("an unknown key fails before anything is sent", err and '"nope"' in body["error"] and body.get("line") == 1,
      short(body["error"], 80))

err, body, _ = a.script(qemu, 'await __call("power", JSON.stringify({ action: "reset" }));')
check("power is out of a script's reach", err and "unknown operation" in body["error"], body["error"])

err, body, _ = a.script(qemu, 'keys.press("shift");\nreturn 1;')
check("a call not awaited before return is dropped and reported",
      not err and body["result"] == 1 and "warning" in body, short(body))

err, body, _ = a.script(qemu, 'console.log("hi", { n: 1 });\nawait new Promise(r => setTimeout(r, 50));\nreturn { a: [1, "x"], b: null };')
check("console.log, setTimeout and JSON results", not err and body["log"] == ['hi {"n":1}'] and body["result"] == {"a": [1, "x"], "b": None},
      short(body))

# One script per session; others are refused, not queued.
finish = in_background(lambda: a.script(qemu, "await sleep(2000); return 'slept';"))
time.sleep(0.5)
err, body, _ = b.script(qemu, "return 1;")
check("a second script on a busy session is refused", err and "already running" in str(body), short(body))
err, body, _ = finish()
check("the first script is unaffected", not err and body["result"] == "slept", short(body))

# A client that goes away takes its script with it.
c = Client("script-check-3")
c.send({"jsonrpc": "2.0", "id": 99, "method": "tools/call",
        "params": {"name": "run_script", "arguments": {"session": qemu, "script": "await sleep(30000);"}}})
time.sleep(1)
_, before, _ = b.call("list_sessions")
c.proc.kill()
time.sleep(1)
_, after, _ = b.call("list_sessions")
running = lambda sessions: next(s["script_running"] for s in sessions if s["id"] == qemu)
check("a disconnecting client's script stops", running(before) and not running(after))

if fixture:
    err, body, _ = a.script(fixture, 'return (await screen.find("OK")).map(l => [l.text, l.x, l.y]);')
    check("both OK buttons are found", not err and len(body["result"]) == 2, short(body))
    err, body, _ = a.script(fixture, 'await pointer.click("OK");')
    check("clicking an ambiguous OK lists both", err and body["error"].startswith("2 lines match"), short(body.get("error")))
    err, body, _ = a.script(fixture, 'return JSON.parse(await __call("stable", JSON.stringify({ quiet_ms: 500, timeout_s: 5 })));')
    check("waitStable settles on a still screen", not err and body["result"]["stable"], short(body.get("result")))

print(f"\n{failures} failed" if failures else "\nall passed")
for client in (a, b):
    client.proc.stdin.close()
sys.exit(1 if failures else 0)
