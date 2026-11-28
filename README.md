<p align="center">
  <img src="docs/logo.png" alt="Regi" width="120">
</p>

# Regi

[![Build](https://github.com/mcuelenaere/regi/actions/workflows/build.yml/badge.svg)](https://github.com/mcuelenaere/regi/actions/workflows/build.yml)

A native macOS client for [JetKVM](https://jetkvm.com) and [PiKVM](https://pikvm.org) hardware, plus any standalone VNC (RFB 3.8) server.

<p align="center">
  <img src="docs/screenshots/hero.jpg" alt="Regi hosts list and a connected session" width="820">
</p>

## Install

```sh
brew install --cask mcuelenaere/tap/regi
```

Or download `Regi.dmg` from the [latest release](https://github.com/mcuelenaere/regi/releases/latest) and drag `Regi.app` into `/Applications`. A bare `Regi.zip` is on the same page.

Releases are signed with a Developer ID and notarized by Apple, so they open without a Gatekeeper prompt. Regi needs macOS 14 (Sonoma) or later; see [Requirements](#requirements) for the device side, or [build it from source](#building-from-source).

## Why Regi

JetKVM and PiKVM ship web control panels that work fine in a browser tab. But
a browser can't capture macOS system shortcuts, so ⌘Tab, ⌘Space and ⌘Q are
eaten by your Mac instead of reaching the host. Regi is a native app that
fixes this and a handful of other rough edges.

It speaks each device's own protocol behind one UI: JetKVM's WebRTC +
JSON-RPC + HID-RPC, PiKVM's Janus WebRTC video + `/api/ws` input, and RFB 3.8
over TCP for standalone VNC servers.

## Features

- **Real keyboard capture.** System shortcuts (⌘Tab, ⌘Space, ⌘Q, ⌘H, Mission
  Control, function keys) go to the remote host via `CGEventTap`. Capture
  engages when the session window is frontmost and stops the moment you
  switch apps.
- **mDNS / Bonjour discovery.** JetKVM (`_jetkvm._tcp`) and PiKVM
  (`_pikvm._tcp`) devices on your LAN appear in the host list on their own.
  VNC servers don't advertise themselves, so add those by host and port.
- **Multi-window, multi-device.** Each device gets its own window, video
  stream and session state.
- **Pointer lock.** An optional mode for FPS / CAD work that pins the cursor
  and sends raw relative motion, so the host cursor doesn't walk away from
  yours on multi-monitor hosts.
- **Clipboard and file transfer** *(JetKVM)*. With the JetKVM Helper on the
  host, text, HTML, images and files sync both ways, and files dragged onto
  the video drop where you release them. With OS Services firmware instead,
  text syncs both ways and dropped files land in the host's Downloads folder,
  each with its own cancel button. The Helper wins when both are present.
- **Bandwidth gate** *(JetKVM, VNC)*. Once the session window has been
  minimised or fully covered for 5 s, video pauses: the device stops encoding
  (JetKVM) or Regi stops requesting framebuffer updates (VNC). It resumes
  instantly when the window is back.
- **Connection stats** (⌘I). Round-trip time, jitter, packet loss, FPS, decode
  time, input latency and playback delay with history graphs, plus traffic in
  both directions split by category.
- **In-app TLS trust prompt.** JetKVM and PiKVM ship self-signed certificates.
  Regi shows a one-time "Trust certificate" prompt with the actual failure
  reason and remembers your choice per host.
- **Keychain-backed passwords.** Per host, scoped to the app.
- **Native UI.** SwiftUI, Mission Control thumbnails, Window menu entries
  with each host's display name, a Dock menu that connects straight to a
  saved host, native fullscreen.
- **MCP server** *(off by default)*. Lets an LLM client operate your hosts
  with scripts that read the screen. See [MCP server](#mcp-server).

## Backend support

| | JetKVM | PiKVM | VNC |
|---|---|---|---|
| Video, keyboard, mouse, scroll | ✓ | ✓ | ✓ |
| LAN discovery | ✓ | ✓ | — |
| Power control | ATX | — | XVP, if the server offers it |
| Clipboard sync | ✓ | — | Text |
| File transfer | ✓ | — | — |
| Bandwidth gate | ✓ | — | ✓ |
| Link to the device's web interface | ✓ | ✓ | — |

Controls that don't apply to the connected device are hidden rather than
greyed out.

Regi doesn't replace the device's web UI for anything outside an active
session: setup, video and network settings, firmware updates, and (for PiKVM)
ATX power and mass storage. Controls ▸ Open Web Interface… takes you there.
Regi assumes you've configured the device there at least once.

### VNC

- **Encodings.** H.264 (RFB encoding 50, decoded via VideoToolbox) is
  preferred where offered, then Tight (JPEG via ImageIO), with ZRLE / Zlib /
  Hextile / CopyRect / Raw fallbacks. All are decoded off the main thread,
  and each `FramebufferUpdate` is presented atomically, so there is no
  tearing or per-strip shimmer.
- **Display and typing.** Server-driven resolution changes (`DesktopSize`)
  and QEMU Extended Key Events for layout-independent typing.
- **Clipboard.** UTF-8 text via the Extended Clipboard pseudo-encoding,
  falling back to Latin-1 cut text.
- **Security.** None, VNC Authentication and VeNCrypt (TLS), with the same
  self-signed trust prompt as the other backends. Tick "Encrypted (TLS)" when
  adding the host to reach a VeNCrypt server.
- **Power.** Shutdown and reset appear when the server negotiates XVP.

## MCP server

Off by default. It lets an LLM client (Claude Code, Claude Desktop, Cursor, …)
operate the hosts you've saved in Regi. Sessions are ordinary Regi windows,
so you see everything the client does.

### Setup

1. Turn it on in Regi ▸ Settings… ▸ MCP.
2. Give your client the bundled `regi-mcp` command, which takes no arguments:

   ```sh
   claude mcp add regi -- /Applications/Regi.app/Contents/MacOS/regi-mcp
   ```

   For Claude Desktop, Settings ▸ MCP ▸ Add to Claude Desktop… installs Regi
   as an extension that runs that copy of Regi (add it again if you move the
   app).

### Tools

| Tool | What it does |
|---|---|
| `list_hosts` | Lists your saved hosts and whether each has an open session |
| `open_session` | Opens a host in a Regi window and connects. A password or certificate prompt is still yours to answer |
| `close_session` | Closes the window, which disconnects |
| `list_sessions` | Lists open sessions: state, framebuffer size, power actions, power LED, whether a script is running |
| `screenshot` | Returns the current frame as PNG or JPEG, at full resolution or scaled down |
| `power` | Runs one of the session's power actions |
| `run_script` | Runs JavaScript against one session |

### Scripts

`run_script` is where the work happens. A script reads the screen, types,
clicks and waits, so a whole flow is one call instead of a
screenshot-and-click round trip per step:

```js
await keys.press("ctrl+alt+delete");
await screen.waitForText(/press (del|f2)/i, { timeoutS: 60 });
await keys.press("delete");
await screen.waitForText("Boot");
await pointer.click("Boot");
return (await screen.text()).map(l => l.text);
```

What a script can call:

| Function | What it does |
|---|---|
| `screen.text()`, `screen.find()` | On-device OCR (Vision). Each line comes with its box and a centre to click |
| `screen.elements()` | A Core ML detector (OmniParser's `icon_detect`) for buttons, icons, fields and rows, including ones with no text |
| `screen.waitForText()` | Waits for text to appear, or to disappear |
| `screen.waitStable()` | Waits for the picture to stop changing |
| `screen.snapshot()` | Attaches a JPEG to the reply, optionally with numbered marks on candidate elements. At most 3 per run |
| `keys.press()`, `keys.type()` | Key chords, and text typed as US-layout keystrokes |
| `pointer.click()`, `.move()`, `.drag()`, `.scroll()` | A target is text, a regex, an OCR line, an element, or `{x, y}` in framebuffer pixels |
| `sleep()`, `log()` | Pause, and write to the log returned with the result |

How a script runs:

- **Sandbox.** Each call gets a fresh JavaScriptCore context with no network
  or file access. Only the functions above exist in it.
- **Time limit.** 60 s by default, 600 s at most.
- **Your input is paused.** While a script runs, your own keyboard and mouse
  on that host are paused and the window shows a Stop Script button.
- **Result.** A script returns `{ok, result, log, elapsed_s}`. A failure
  comes back as `ok: false` with the error, the script line, a timed trace of
  every action, the text on screen and a screenshot of that moment.

### How it's wired

- **In-app server.** The MCP protocol runs inside Regi, on a Unix socket under
  `~/Library/Application Support/Regi/` that only your user can open. There
  is no TCP port and no token.
- **Stdio relay.** `regi-mcp` only passes messages between the client and
  that socket. It never launches Regi: until Regi is up, it lists the tools
  Regi last advertised and answers calls with a request to open Regi.
- **Visible activity.** Session windows show a banner while a client is
  connected, and every call is listed under Window ▸ MCP Activity.
- **Bandwidth gate.** A session a client has used keeps its video running
  while its window is hidden, until no client is connected.

## Requirements

- macOS 14 (Sonoma) or later.
- Something to connect to: a JetKVM (the Mini included) or PiKVM device on
  the network, or any reachable VNC server.
- **JetKVM over HTTPS**: firmware that produces RFC 5280-compliant
  certificate serial numbers, which recent firmware does. Older firmware
  still works over plain HTTP.
- **PiKVM**: H.264 / WebRTC streaming via `kvmd-janus`, the default on
  current PiKVM OS images. mDNS discovery needs `avahi-daemon` running on the
  device; otherwise add it by host or IP.

## Building from source

`Regi.xcodeproj` is generated from [`project.yml`](project.yml) by
[XcodeGen](https://xcodegen.com) and is not checked in, so generate it once after
cloning. The UI element detector's Core ML weights are stored with Git LFS, so
install it before cloning (without it the build has a 130-byte pointer instead
of a model):

```sh
brew install git-lfs xcodegen
git lfs install
git clone https://github.com/mcuelenaere/regi.git
cd regi
xcodegen generate
open Regi.xcodeproj
```

Hit ⌘R in Xcode.

`project.yml` is the source of truth for all three targets: `Regi`, the
`regi-mcp` relay it bundles, and `RegiProbe`. Adding a source file needs no
project edit: drop it in `App/`, `MCPBridge/` or `Probe/RegiProbe/` and run
`xcodegen generate` again. Don't edit the `.xcodeproj` by hand; the next
generate overwrites it.

## About the name

Regi is Esperanto for *to rule*, *to govern*, *to take control*, which is
roughly what a KVM client does. It's pronounced *REH-ghee*.

## License

GNU Affero General Public License v3.0 or later — see [LICENSE](LICENSE).

In short: you're free to use, study, modify and redistribute Regi, including
commercially. What you can't do is ship a closed-source fork — anything you
distribute, or run as a network service, has to carry the same freedoms and
come with its source.

Bundled dependencies keep their own licenses: `stasel/WebRTC` (BSD-3-Clause
plus the WebRTC patent grant), `apple/swift-protobuf` (Apache 2.0) and
`modelcontextprotocol/swift-sdk` (MIT, moving to Apache 2.0), which brings
in `apple/swift-log` and `apple/swift-system` (Apache 2.0) and
`mattt/eventsource` (MIT). All are AGPLv3-compatible; [NOTICE](NOTICE) has
the full list. The UI element detector is Microsoft OmniParser's
`icon_detect` model (AGPL-3.0, `App/MCP/UIElementDetector.LICENSE`),
converted to Core ML by `Tools/ui-detector/convert.py`.

## Acknowledgements

- The [JetKVM project](https://github.com/jetkvm/kvm) for the hardware
  and the open firmware Regi talks to.
- The [PiKVM project](https://github.com/pikvm/kvmd) for KVMD and its
  documented HTTP / WebSocket / Janus interfaces.
- [`stasel/WebRTC`](https://github.com/stasel/WebRTC) for the
  WebRTC.framework SwiftPM distribution.
- [`apple/swift-protobuf`](https://github.com/apple/swift-protobuf) for the
  clipboard transfer wire format.
- The [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) for
  the MCP server's protocol layer.
- [Microsoft OmniParser](https://github.com/microsoft/OmniParser) for the
  icon detector behind `screen.elements()`.
