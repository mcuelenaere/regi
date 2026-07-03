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

## VNC: Open H.264 encoding (RFB encoding 50)

**Where:** `VNCStreamEngine.handleFramebufferUpdate` (the per-rect encoding
switch) and `VNCBackend.encodings` (the advertised `SetEncodings` list).

**What's there now:** we decode Raw / CopyRect / Tight only. The RFB "Open
H.264" encoding (50) exists in the rfbproto registry and noVNC can decode it,
but **no shipping server emits it**: the QEMU patch series ("Add VNC Open H.264
Encoding", Dietmar Maurer / Proxmox, April 2025, GStreamer x264) never merged —
QEMU master's `ui/meson.build` has no `vnc-enc-h264.c`, and Proxmox's `pve-qemu`
carries no downstream VNC/H.264 patches. Adding a decoder now would be dead,
untestable code.

**What "fixed" looks like:** once the QEMU series lands upstream (watch
`ui/vnc*` in qemu.git and the `pve-qemu` patch series), add a VideoToolbox
decoder path — encoding 50 rects carry an Annex-B H.264 stream; feed it to a
`VTDecompressionSession` producing `CVPixelBuffer`s that drop straight into the
existing `VideoFramePresenter` (IOSurface) path — and advertise encoding 50 in
`SetEncodings`.

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
