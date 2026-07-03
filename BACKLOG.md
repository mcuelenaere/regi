# Backlog

Things we've consciously deferred. Each entry should carry enough context
to be picked up cold without re-litigating the original investigation.

---

## VNC: VeNCrypt / TLS support

**Where:** `Packages/JetKVMTransport/Sources/JetKVMTransport/VNC/` —
`VNCConnection` (transport) and `VNCBackend` (security-type negotiation);
`App/HostFormSheet.swift` currently pins `useTLS = false` for the `.vnc` kind.

**What's there now:** the VNC backend speaks plain RFB 3.8 over TCP with
security types **None** (1) and **VNC Authentication** (2, DES challenge). No
transport encryption. Fine on a trusted LAN or through an SSH tunnel, but a
VeNCrypt-only server (common on hardened libvirt/oVirt setups) can't be
reached, and the VNC password crosses the wire under weak DES.

**What "fixed" looks like:** add the VeNCrypt security type (19) — after the
RFB handshake selects it, the client picks a sub-type, and for the TLS/X509
variants wraps the socket in `NWProtocolTLS` (reuse the trust-override plumbing
in `TLSDelegate` / `TrustedHostStore`, keyed by host) before continuing the RFB
sub-handshake. Then let the host form offer a "TLS" toggle for `.vnc` instead
of forcing it off.

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

**Where:** `Packages/JetKVMTransport/Sources/JetKVMTransport/VNC/H264Decoder.swift`.

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

## Move WebRTC pin back to upstream `stasel/WebRTC` once M148+ releases

**Where:** `Packages/JetKVMTransport/Package.swift` and
`Regi.xcodeproj/project.pbxproj` (the project carries its
own `XCRemoteSwiftPackageReference` — both pins have to match or
SPM errors on conflicting package identity).

**What's there now:** both pins point at
`https://github.com/AttilaTheFun/WebRTC.git` at `148.0.0`. That's
a personal fork carrying the fix from
[stasel/WebRTC#147](https://github.com/stasel/WebRTC/pull/147) —
the missing per-class headers on the macOS slice that broke every
release from M141 to M147 (see stasel/WebRTC#145). The fork
builds clean, runtime smoke test against real hardware works.

**Why move back:** depending on a personal fork is a supply-chain
wart — no guarantee `AttilaTheFun` keeps publishing future
milestones, repo could disappear, no community review of any
behavioral changes vs. upstream. Cleanest fix is for #147 to
merge upstream and `stasel/WebRTC` to ship M148 (or higher) from
the merged tree.

**What "fixed" looks like:**

1. Track stasel/WebRTC tags. When 148.0.0 (or 149+) lands on
   `stasel/WebRTC`, swap both pins back:
   - `Packages/JetKVMTransport/Package.swift` — restore the
     `https://github.com/stasel/WebRTC.git` URL.
   - `Regi.xcodeproj/project.pbxproj` — same URL +
     version on the `XCRemoteSwiftPackageReference`.
2. Delete the `Package.resolved` files (both the workspace one
   under `.../swiftpm/Package.resolved` and the package-level
   one under `Packages/JetKVMTransport/`) and re-resolve so the
   new revision hash is recorded.
3. Build + run the same smoke test (status → device → login →
   WS → ICE → video) to confirm parity.
4. Drop the "Temporarily on AttilaTheFun's fork" TODO comment
   in `Packages/JetKVMTransport/Package.swift`.
