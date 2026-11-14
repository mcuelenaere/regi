<p align="center">
  <img src="docs/logo.png" alt="Regi" width="120">
</p>

# Regi

[![Build](https://github.com/mcuelenaere/regi/actions/workflows/build.yml/badge.svg)](https://github.com/mcuelenaere/regi/actions/workflows/build.yml)

A native macOS client for [JetKVM](https://jetkvm.com) and [PiKVM](https://pikvm.org) hardware, plus any standalone VNC (RFB 3.8) server.

<p align="center">
  <img src="docs/screenshots/hero.jpg" alt="Regi hosts list and a connected session" width="820">
</p>

## What it is

JetKVM and PiKVM both ship web-based control panels that run in a
browser tab and work fine for casual remote-control. But a browser
can't capture macOS system shortcuts — ⌘Tab, ⌘Space, ⌘Q — so they get
eaten by your Mac instead of reaching the host. Regi is a native macOS
app that fixes this and a handful of other rough edges along the way.

It talks each device's native protocol — JetKVM's WebRTC + JSON-RPC +
HID-RPC, PiKVM's Janus WebRTC video + `/api/ws` input, or RFB 3.8 over
TCP for standalone VNC servers — behind one unified UI; the difference
is in the macOS integration around it.

## Features

- **JetKVM, PiKVM and VNC in one app.** Core remote control — video, keyboard,
  mouse, and scroll — works on every backend. Past that they differ: JetKVM
  adds ATX power and codec/quality controls, JetKVM and VNC both do clipboard
  sync and the bandwidth gate, and VNC offers power control when the server
  negotiates XVP. PiKVM sessions are video and input only. Controls that don't
  apply to the connected device are hidden rather than greyed out.
- **Standalone VNC (RFB 3.8).** Connect to any plain VNC server. H.264 (RFB
  encoding 50, decoded via VideoToolbox) is preferred where offered, then
  Tight (JPEG via ImageIO), with ZRLE / Zlib / Hextile / CopyRect / Raw
  fallbacks — all decoded off the main thread, with each `FramebufferUpdate`
  presented atomically (no tearing or per-strip shimmer). Server-driven
  resolution changes (`DesktopSize`), QEMU Extended Key Events for
  layout-independent typing, and UTF-8 clipboard sync via the Extended
  Clipboard pseudo-encoding (falling back to Latin-1 cut text). Power control
  (shutdown / reset) appears when the server negotiates XVP. Security types
  **None**, **VNC Authentication** and **VeNCrypt** (TLS) are supported, with
  the same self-signed trust prompt as the other backends — tick "Encrypted
  (TLS)" when adding the host to reach a VeNCrypt server.
- **Real keyboard capture.** System shortcuts — ⌘Tab, ⌘Space (Spotlight),
  ⌘Q, ⌘H, Mission Control, function keys — route to the remote host via
  `CGEventTap`. Engages automatically when the session window is
  frontmost; suspends the moment you switch apps so your Mac isn't
  fighting you.
- **mDNS / Bonjour discovery.** JetKVM (`_jetkvm._tcp`) and PiKVM
  (`_pikvm._tcp`) devices on your LAN appear in the host list
  automatically — no URL typing, no scanning. VNC servers don't advertise
  themselves, so those are added by host and port.
- **Multi-window, multi-device.** Connect to several devices at once,
  each in its own window with its own video stream, signaling channel,
  and session state.
- **Pointer lock for FPS / CAD work.** Optional mode that pins the
  cursor and delivers raw relative motion, so the host cursor doesn't
  walk away from yours on multi-monitor host setups.
- **In-app TLS trust prompt.** JetKVM and PiKVM both ship self-signed
  certs by default. Regi surfaces a one-time "Trust certificate" prompt
  with the actual failure reason instead of a generic browser warning,
  and remembers your choice per host.
- **Keychain-backed passwords.** Per-host, scoped to the app.
- **Bandwidth gate** *(JetKVM, VNC)*. When the session window is minimised or
  fully covered, Regi pauses the video feed after a 5 s debounce — the device
  stops encoding (JetKVM) or Regi stops requesting framebuffer updates (VNC).
  Saves device CPU and LAN bandwidth while the window's hidden; resumes
  instantly when you bring it back.
- **First-class native UI.** SwiftUI, Mission Control thumbnails,
  Window menu entries with each host's display name, native
  fullscreen, real app icon in the Dock.
- **MCP server** *(off by default)*. Lets an LLM client (Claude Code, Claude
  Desktop, Cursor, …) list your hosts, open sessions, take screenshots, use
  power controls, and above all run scripts: `run_script` takes JavaScript
  that reads the screen with on-device OCR and a UI element detector (for
  icons and other controls without text), types, clicks and waits for text,
  so a whole flow (reset, wait for the BIOS prompt, open the boot menu, pick
  an entry) is one call instead of a screenshot-and-click round trip per step.
  Scripts run in a sandboxed JavaScriptCore context with no network or files.
  While one runs, your own keyboard and mouse on that host are paused and the
  window shows a Stop Script button. Sessions are ordinary Regi windows, with a
  banner while a client is connected and every call listed under
  Window ▸ MCP Activity. Turn it on in Regi ▸ Settings… ▸ MCP and give your
  client the bundled command, `Regi.app/Contents/MacOS/regi-mcp` (no
  arguments), e.g. `claude mcp add regi -- /Applications/Regi.app/Contents/MacOS/regi-mcp`.
  For Claude Desktop, Settings ▸ MCP ▸ Add to Claude Desktop… installs Regi
  as an extension that runs that copy of Regi (add it again if you move
  the app). The client can start before Regi:
  until Regi is up its tools are listed and calls ask you to open it, and
  nothing ever launches Regi for you.


## Differences vs. the JetKVM web frontend

| | JetKVM web UI | Regi |
|---|---|---|
| System shortcuts (⌘Tab, ⌘Q, ⌘Space, …) | macOS swallows them | Forwarded to the host |
| Find devices on the LAN | Type the URL | Auto-discovery via mDNS |
| Multiple devices | One browser tab each | Multiple native windows |
| Self-signed cert | Browser security warning | In-app trust prompt |
| Window minimised / occluded | Keeps streaming | Pauses encoder (5 s debounce) |
| Passwords | Browser autofill (if remembered) | macOS Keychain |
| Pointer lock | HTML5 Pointer Lock API | Native CG APIs |
| Updates | Browser cache | Standalone `.app` |

The same comparison holds for PiKVM's web UI — a browser can't forward
macOS shortcuts there either.

What Regi *doesn't* replace: anything that's not part of an active
remote-control session. The device's setup flow, advanced settings,
firmware updates, and (for PiKVM) ATX power and mass-storage controls
are still done through the web UI. Regi assumes you've configured the
device there at least once.

## Requirements

- macOS 14 (Sonoma) or later
- Something to connect to: a JetKVM or PiKVM device on the network, or any
  reachable VNC server
- **JetKVM**: for HTTPS to default-config devices, firmware that
  produces RFC 5280-compliant certificate serial numbers (recent
  firmware does; older firmware still works over plain HTTP, and the
  in-app trust prompt handles the self-signed CA either way)
- **PiKVM**: H.264 / WebRTC streaming via `kvmd-janus` enabled (the
  default on current PiKVM OS images); the in-app trust prompt handles
  its self-signed certificate. mDNS auto-discovery needs `avahi-daemon`
  running on the device — otherwise add it by host/IP manually.

## Installation

Grab `Regi.dmg` from the [latest release](https://github.com/mcuelenaere/regi/releases/latest) and drag `Regi.app` into `/Applications`. A bare `Regi.zip` is on the same release page if you'd rather skip the disk image.

> [!NOTE]
> Regi isn't currently signed by an Apple-trusted developer ID, so macOS Gatekeeper refuses the first launch with *"can't be opened because Apple cannot check it for malicious software."* Bypass once and macOS remembers your choice:
>
> - **Finder**: right-click `Regi.app` → **Open** → confirm in the dialog. Subsequent double-clicks work normally.
> - **Terminal**: `xattr -d com.apple.quarantine /Applications/Regi.app`

### Building from source

`Regi.xcodeproj` is generated from [`project.yml`](project.yml) by
[XcodeGen](https://xcodegen.com) and is not checked in, so generate it once after
cloning:

The UI element detector's Core ML weights are stored with Git LFS, so install
it before cloning (without it the build has a 130-byte pointer instead of a model):

```sh
brew install git-lfs xcodegen
git lfs install
git clone https://github.com/mcuelenaere/regi.git
cd regi
xcodegen generate
open Regi.xcodeproj
```

Hit ⌘R in Xcode.

`project.yml` is the source of truth for both targets — `Regi` and `RegiProbe`.
Adding a source file needs no project edit: drop it in `App/` or
`Probe/RegiProbe/` and run `xcodegen generate` again. Don't edit the `.xcodeproj`
by hand; the next generate overwrites it.

## About the name

Regi is Esperanto for *to rule*, *to govern*, *to take control* —
which is, roughly, what a KVM client does. You point it at a remote
machine and you're in charge: keyboard, mouse, screen. The name is
short, pronounceable in most languages (*REH-ghee*), and has no prior
tech-product baggage.

## License

GNU Affero General Public License v3.0 or later — see [LICENSE](LICENSE).

In short: you're free to use, study, modify and redistribute Regi, including
commercially. What you can't do is ship a closed-source fork — anything you
distribute, or run as a network service, has to carry the same freedoms and
come with its source.

Bundled dependencies keep their own licenses: `stasel/WebRTC` (BSD-3-Clause
plus the WebRTC patent grant) and `apple/swift-protobuf` (Apache 2.0). Both
are AGPLv3-compatible. The UI element detector is Microsoft OmniParser's
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
- [Microsoft OmniParser](https://github.com/microsoft/OmniParser) for the
  icon detector behind `screen.elements()`.
