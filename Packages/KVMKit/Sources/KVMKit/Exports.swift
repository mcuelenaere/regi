// The App links only `KVMKit` (the umbrella) but uses public types from the
// core and backend modules directly — `KVMState`, `DeviceEndpoint`,
// `KVMPowerAction`, input primitives (KVMCore); `ClipboardBridge`,
// `ClipboardSource`, `VideoState` (JetKVMKit); `VNCTextClipboard` (VNCKit).
// Re-export them so a single `import KVMKit` in the App resolves everything.
//
// KVMWebRTC is intentionally NOT re-exported: the App is WebRTC-free and never
// references RTC types, so keeping it out avoids leaking WebRTC into the App's
// namespace.
@_exported import KVMCore
@_exported import JetKVMKit
@_exported import PiKVMKit
@_exported import VNCKit
