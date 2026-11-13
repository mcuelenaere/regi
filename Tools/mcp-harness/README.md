# MCP harness

Exercise Regi's MCP server (App/MCP) without an LLM, against hosts that can't
be harmed.

- `mcp_client.py`: speaks MCP to `regi-mcp` over stdio and runs a list of tool
  calls. Standard library only.
- `script_check.py`: checks `run_script` end to end (flows, error lines,
  runaway loops, timeouts, ambiguous targets, one script per session,
  disconnects) and prints PASS/FAIL. Standard library only.
- `relay_check.py`: tests `regi-mcp` against a fake Regi on a temporary
  socket: standing in while Regi is away, forwarding once it appears, failing
  a request Regi dropped, reconnecting. Standard library only; no app needed.
- `still_vnc.py`: serves a PNG as a VNC screen, so any screenshot becomes a
  test host. Needs Pillow (`uv run --with pillow still_vnc.py …`).

## Targets

A disk-less QEMU VM gives real BIOS text screens and XVP power control, all on
loopback. Port 5917 rather than 5900, which Screen Sharing may hold:

```sh
qemu-system-x86_64 -display none -vnc 127.0.0.1:17,power-control=on -m 256 -nic none \
  -boot menu=on,splash-time=15000            # SeaBIOS on 127.0.0.1:5917
uv run --with pillow still_vnc.py two_ok.png 5918   # a still screen on 127.0.0.1:5918
```

For the fixture checks, `two_ok.png` is any screenshot showing exactly two
"OK" buttons (say a dialog's and a notification's).

## Launch a test Regi next to yours

Values passed as launch arguments land in the argument domain: they apply to
that process only and are never written back. So the MCP toggle, the socket
directory and a host list made of just the test targets can all be set per
run; your saved hosts stay out of reach, and a Regi you already run keeps its
own socket. The directory must be short: a socket path has a 104-byte limit.

```sh
HOSTS=$(python3 -c 'import json; print("<" + json.dumps([
  {"id": "7E1A0C2B-0000-4000-8000-00000000AA17", "name": "QEMU test", "host": "127.0.0.1", "port": 5917, "useTLS": False, "kind": "vnc", "username": ""},
  {"id": "7E1A0C2B-0000-4000-8000-00000000AA18", "name": "Still desktop", "host": "127.0.0.1", "port": 5918, "useTLS": False, "kind": "vnc", "username": ""},
]).encode().hex() + ">")')
mkdir -p /tmp/regi-mcp
open -n path/to/Regi.app --args -RegiMCPServerEnabled YES \
  -RegiMCPDirectory /tmp/regi-mcp -RegiSavedHosts "$HOSTS"
export REGI_MCP_DIR=/tmp/regi-mcp            # the relay follows
```

An unsigned build (`CODE_SIGNING_ALLOWED=NO`) is linker-signed ad hoc and
launches on the Mac that built it.

## Run

```sh
BRIDGE=path/to/Regi.app/Contents/MacOS/regi-mcp
python3 mcp_client.py $BRIDGE /tmp '[["open_session", {"host": "QEMU test"}], ["open_session", {"host": "Still desktop"}]]'
python3 script_check.py $BRIDGE 127.0.0.1:5917 127.0.0.1:5918
```

A one-off script:

```sh
python3 mcp_client.py $BRIDGE /tmp '[
  ["power", {"session": "127.0.0.1:5917", "action": "reset"}],
  ["run_script", {"session": "127.0.0.1:5917", "script":
    "await screen.waitForText(/press esc/i); await keys.press(\"esc\"); await screen.waitForText(\"Select boot device\"); return (await screen.text()).map(l => l.text);"}]
]'
```

Inside a script, `__call("stable", JSON.stringify({quiet_ms: 500, timeout_s: 5}))`
returns waitStable's raw numbers (`noise`, `peak`): the way to tune
`ScriptOps.stableThreshold` on a real stream.

Not covered here: that the user's own keyboard and mouse are paused during a
script. Check it by hand: run `await sleep(20000)` on the QEMU session, type
and click in its window (nothing should reach the boot menu), press the
banner's Stop Script, and the call fails with "stopped by the user".

Tool calls show up in Regi's MCP Activity window and in
`/usr/bin/log show --predicate 'subsystem == "app.regi.mcp"'`. Call
`/usr/bin/log` by its full path: in zsh, a bare `log` is a shell builtin.
