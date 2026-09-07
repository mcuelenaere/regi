# Backlog

Things we've consciously deferred. Each entry should carry enough context
to be picked up cold without re-litigating the original investigation.

---

## VNC: VeNCrypt / TLS — remaining nuances

**Where:** `VNCVeNCryptFramer.swift`, `VNCConnection` (`makeTLSOptions` verify
block), `VeNCryptTests`.

**What's implemented:** VeNCrypt (security type 19) with an in-band TLS upgrade.
An `NWProtocolFramer` below `NWProtocolTLS` runs the plaintext RFB version +
security + VeNCrypt subtype negotiation, then goes transparent so TLS wraps the
rest (inner auth + session). We prefer X509→anonymous-TLS subtypes with Plain →
VncAuth → None inner auth, and refuse the unencrypted `plain` subtype. Cert
trust reuses the self-signed override (`TrustedHostStore` / `awaitingTrustOverride`).
The host form has an "Encrypted (TLS)" toggle + username for `.vnc`.

**Nuances / possible follow-ups:**
- We accept **anonymous TLS** subtypes (TLSNone/Vnc/Plain) when offered — these
  encrypt but give no server authentication. Could restrict to X509 only.
- Trust is system-eval + self-signed override; there's no per-host **cert
  pinning** (accept-this-exact-cert). The override trusts any cert for the host
  once accepted, like the HTTPS backends.
- The VeNCrypt framer path can't be exercised by the loopback `FakeRFBServer`
  (no TLS there) — the negotiation logic is unit-tested (`VeNCryptTests`) but
  the end-to-end TLS path is validated manually against PiKVM.
- A server that offers VeNCrypt but no subtype we accept (or rejects our
  version) makes the framer stop without `markReady()`; there's no framer API
  to fail the connection, so the error only surfaces after the 8 s connect
  timeout instead of immediately. Acceptable for a misconfiguration path.

## VNC: QEMU server features we don't implement yet

**Where:** `VNCBackend.encodings` (the advertised `SetEncodings` list) and
`VNCStreamEngine` for anything that arrives as a pseudo-encoding rect.

Audited against QEMU's `ui/vnc.h` / `set_encodings()`. We now decode all of
QEMU's efficient frame encodings (Tight preferred; ZRLE/Zlib/Hextile/CopyRect/Raw
fallbacks) and implement XVP power control. ZYWRLE (lossy wavelet ZRLE) and
TightPNG are intentionally skipped — niche, and Tight+JPEG already covers the
lossy case. The remaining unimplemented *features* QEMU exposes, roughly by value:

- **Cursor pseudo-encodings** (`RICH_CURSOR` 0xFFFFFF11, `ALPHA_CURSOR`,
  `XCURSOR`). Server ships the cursor sprite so the client renders it locally
  instead of it being baked into the framebuffer — removes the double-cursor
  look and cuts perceived pointer latency. Needs a cursor overlay composited
  over the presented IOSurface (track hotspot + alpha).
- **LED state** (`VNC_ENCODING_LED_STATE`, 0xFFFFFEFB) — caps/num/scroll-lock
  sync. Minor for a forward-only KVM.
- **Desktop resize ext / ExtendedDesktopSize** (`DESKTOP_RESIZE_EXT`) —
  *client-initiated* resize (ask the guest to match the window). We only handle
  server-driven `DesktopSize` today.
- **Audio** (`VNC_ENCODING_AUDIO`) — playback redirection. Large, separate feature.

Not supported by QEMU's server (so not worth implementing for the QEMU target):
Fence / ContinuousUpdates, RRE/CoRRE/TRLE/ZlibHex.

## VNC: H.264 decoder — single-context limitation

**Where:** `Packages/KVMKit/Sources/VNCKit/H264Decoder.swift`.

**What's there now:** the RFB "Open H.264" encoding (50) is decoded via
VideoToolbox (PiKVM `kvmd-vnc` and TigerVNC 1.13+ interoperate on it, as does
the still-unmerged QEMU GStreamer patch). We keep **one** decoder context, which
is correct for the way PiKVM/QEMU stream H.264 (a single full-frame rect per
update). TigerVNC keys contexts per rectangle geometry and can run several
concurrent H.264 regions; a server doing that would make us reset our single
context on every geometry switch (functional but wasteful — each switch drops
the reference frames and forces a keyframe wait).

**What "better" looks like:** a small context cache keyed by rect geometry
(mirroring TigerVNC's `contexts` deque), each with its own
`VTDecompressionSession`, honouring the per-rect `resetContext` (0x1) vs
`resetAllContexts` (0x2) flags independently instead of collapsing both to a
full reset. Only worth it if a real server multiplexes H.264 regions.

---

## Fine-grained trackpad gestures (pinch-zoom, rotate) aren't forwarded

**Where:** `App/KVMVideoView.swift` — `scrollWheel(with:)` and its two paths
(`handleTrackpadScroll` / `handleWheelScroll`), plus `WheelAccumulator`. The
wire path is `Session.sendWheelReport(wheelY:wheelX:)` →
`KVMBackend.sendWheelReport` (`KVMCore/KVMBackend.swift`) →
`JetKVMBackend.sendWheelReport` (binary HID-RPC opcode `0x04` on firmware
≥ 0.5.9, JSON-RPC `wheelReport` below that).

**What's there now:** only *scroll* is forwarded, and everything collapses into
a pair of `Int8` wheel detents. The trackpad path is reasonably careful about it
— fractional `scrollingDelta` accumulation, throttled emit, momentum/inertia
phases, flush-on-gesture-end, `.cancelled` discards — but the vocabulary at the
end is still just "wheel up/down/left/right".

macOS delivers the richer gestures as *separate* `NSEvent`s that
`KVMVideoView` does not override at all, so they're dropped on the floor:

- `magnify(with:)` — pinch zoom (`event.magnification`)
- `smartMagnify(with:)` — two-finger double-tap zoom
- `rotate(with:)` — two-finger rotate (`event.rotation`)

**Repro:** open Figma (or any zoomable app) on the target host, pinch-zoom on
the Mac trackpad — nothing reaches the guest. Physically holding ⌃ and
two-finger scrolling *does* zoom, because that goes out as a real modifier via
the keyboard path plus ordinary wheel detents.

**Why it isn't purely a client fix:** a USB HID boot-protocol mouse has no zoom
or rotate axis, so there's nothing to put a magnification value into. Two tiers:

1. **Client-only, no firmware change:** translate `magnify(with:)` into
   ⌃+wheel detents — the de-facto cross-platform zoom idiom (Figma, browsers,
   VS Code, most editors on Windows/Linux honour it). Accumulate
   `event.magnification` the way `WheelAccumulator` accumulates scroll, then
   emit `Ctrl` down → wheel detents → `Ctrl` up. The fiddly part is not
   corrupting real modifier state: `handleFlagsChanged` / the held-key tracking
   own the keyboard's view of ⌃, so a synthetic press has to be reconciled with
   a ⌃ the user may already be holding (and must not leave it stuck if the
   gesture is cancelled or the window loses focus mid-pinch). Rotate has no
   comparable universal idiom — probably leave it unmapped.
2. **Proper, needs JetKVM-side work (tracked separately):** expose a richer HID
   device from the firmware — a digitizer / Windows Precision Touchpad
   descriptor — so the guest OS interprets real multi-touch contacts natively
   and per-app gesture handling works the way it does locally. That needs the
   USB gadget + report descriptor on the device, a new HID-RPC opcode carrying
   touch contacts, and a client path that sends contact points instead of
   synthesised wheel ticks.

Tier 1 is worth doing on its own — it fixes the common "zoom in Figma" case
without waiting on firmware.
