#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Drive Regi's MCP server through regi-mcp, without an LLM, and print compact results.

    mcp_client.py BRIDGE OUTDIR 'STEPS'

BRIDGE is Regi.app/Contents/MacOS/regi-mcp. STEPS is a JSON list; each step is
["tools/list"], ["sleep", seconds] or ["<tool>", {arguments}]. Screenshots are
written to OUTDIR as shot1.png, shot2.jpg, ... Standard library only.
"""
import base64
import json
import subprocess
import sys
import time

bridge, outdir, steps = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
proc = subprocess.Popen([bridge], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
last_id = 0


def send(message):
    proc.stdin.write((json.dumps(message) + "\n").encode())
    proc.stdin.flush()


def request(method, params=None):
    """Send one request and return its response, echoing any notifications in between."""
    global last_id
    last_id += 1
    send({"jsonrpc": "2.0", "id": last_id, "method": method, **({"params": params} if params is not None else {})})
    while True:
        line = proc.stdout.readline()
        if not line:
            sys.exit(f"regi-mcp closed the connection: {proc.stderr.read().decode().strip()}")
        message = json.loads(line)
        if message.get("id") == last_id:
            return message
        print("   (notification)", json.dumps(message)[:200])


started = time.time()
init = request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                              "clientInfo": {"name": "mcp-harness", "version": "1.0"}})["result"]
print(f"initialize: {init['serverInfo']} protocol={init['protocolVersion']} "
      f"capabilities={init['capabilities']} ({(time.time() - started) * 1000:.0f} ms)")
send({"jsonrpc": "2.0", "method": "notifications/initialized"})

shots = 0
for step in steps:
    if step[0] == "sleep":
        time.sleep(step[1])
        continue
    started = time.time()
    if step[0] == "tools/list":
        tools = request("tools/list")["result"]["tools"]
        print(f"tools/list: {len(tools)} tools: {', '.join(t['name'] for t in tools)}")
        continue
    response = request("tools/call", {"name": step[0], "arguments": step[1] if len(step) > 1 else {}})
    elapsed = (time.time() - started) * 1000
    if "error" in response:
        print(f"{step[0]}: JSON-RPC error {response['error']}")
        continue
    result, parts = response["result"], []
    for content in result.get("content", []):
        if content["type"] == "text":
            parts.append(content["text"][:1600])
        elif content["type"] == "image":
            data = base64.b64decode(content["data"])
            shots += 1
            path = f"{outdir}/shot{shots}.{'png' if content['mimeType'].endswith('png') else 'jpg'}"
            with open(path, "wb") as file:
                file.write(data)
            size = ""
            if data[:8] == b"\x89PNG\r\n\x1a\n":
                size = f" {int.from_bytes(data[16:20], 'big')}x{int.from_bytes(data[20:24], 'big')}"
            parts.append(f"[{content['mimeType']}{size}, {len(data) // 1024} KB -> {path}]")
    print(f"{step[0]} ({elapsed:.0f} ms){' ERROR' if result.get('isError') else ''}: {' | '.join(parts)}")

proc.stdin.close()
proc.wait(timeout=5)
print("regi-mcp exit code:", proc.returncode)
