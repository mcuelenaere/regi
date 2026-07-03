import Foundation
import KVMKit

/// A KVM device discovered via mDNS / Bonjour. Distinct from
/// SavedHost — discovered entries are ephemeral (vanish when the
/// device leaves the network) and not user-named.
struct DiscoveredHost: Hashable, Identifiable {
    /// Bonjour service instance name (user-visible label set by the
    /// device, e.g. "JetKVM (a1b2)" or "pikvm-DEADBEEF.local").
    let instanceName: String
    /// Resolved hostname without trailing dot, e.g. "jetkvm-abcd.local".
    let host: String
    /// TCP port. JetKVM publishes 443 when TLS is on, 80 otherwise;
    /// PiKVM publishes 443.
    let port: Int
    /// True iff the published port is 443.
    let useTLS: Bool
    /// Which device family advertised this service (`_jetkvm._tcp` vs
    /// `_pikvm._tcp`).
    let kind: DeviceKind
    /// `id` TXT record from the advertisement (JetKVM). Optional in case
    /// older firmware doesn't publish it; nil for PiKVM (which publishes
    /// `serial` instead).
    let deviceID: String?
    /// `version` TXT record. nil for PiKVM (not advertised).
    let version: String?
    /// `setup` TXT record. False means the device isn't provisioned
    /// yet — connecting to it would land on the setup wizard. Always
    /// true for PiKVM (no such flag; it's always reachable).
    let isSetup: Bool

    var id: String { instanceName }

    var displayName: String { instanceName }
}
