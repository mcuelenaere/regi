import XCTest
@testable import JetKVMTransport

final class SpiceVVConfigTests: XCTestCase {

    // A real self-signed cert, used to check CA (PEM) parsing.
    private static let caPEM = """
    -----BEGIN CERTIFICATE-----
    MIIDlTCCAn2gAwIBAgIUAWrbuYt7ukongTqAFoWxiRycVh8wDQYJKoZIhvcNAQEL
    BQAwWjEkMCIGA1UECgwbUHJveG1veCBWaXJ0dWFsIEVudmlyb25tZW50MRkwFwYD
    VQQLDBBQVkUgQ2x1c3RlciBOb2RlMRcwFQYDVQQDDA5wdmUudGVzdC5sb2NhbDAe
    Fw0yNjA3MDIxOTMyMTVaFw0yNjA3MDMxOTMyMTVaMFoxJDAiBgNVBAoMG1Byb3ht
    b3ggVmlydHVhbCBFbnZpcm9ubWVudDEZMBcGA1UECwwQUFZFIENsdXN0ZXIgTm9k
    ZTEXMBUGA1UEAwwOcHZlLnRlc3QubG9jYWwwggEiMA0GCSqGSIb3DQEBAQUAA4IB
    DwAwggEKAoIBAQCscnF7fhtwbaXryzNeth3psyYBWN7EKR2Ak/KuDDnegMejjH53
    0SoZFamWrX+7uw8bTDGWmvRbsf80EHBjw/2YXWswLusg8RJN4u1RgUWgSTgtvk2Q
    wb0vx360hq0S0L1mA2O49Mo77nZVZP/i/QFDq1IhjD+BH5JGVirDBd9pDhymvwVy
    pGMYV1hncuoQ5RmIMuq3VO1c4R5mCRYR95wmtE/AY9vFltF9a5heynghcXDqFiNN
    Tz+7y9KtFs9PNHpleoQl6oHo9fbNmRv8HA9+7xApneAy9xb5TrgEn5Jh7oSlP+Vb
    Y3G3yoIYnNat6Gj3yffZfR2WHLCWQRF85z9xAgMBAAGjUzBRMB0GA1UdDgQWBBTV
    hw7f7+yfEjgkNkPy+dqQl8ydPjAfBgNVHSMEGDAWgBTVhw7f7+yfEjgkNkPy+dqQ
    l8ydPjAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQBFnt4Rd1JI
    QGyyeAB7DolWN8E/b/p4AyoTc5Basy9HR5aWRAMmgUuCvE8SJ08ynbHCLS7WT1FV
    4m7IDK9ceZzBtx5d1HR8373vgijREjeSLrxKFBNiVZAX6geLAfRBxetjqH3oIzJ7
    1z3Bcvo1+OjlfhtmiQDKAwwFetoqAaEgAiPOlJ4qqnd6tE1yqoO8SrZb8K+nnTGJ
    btY8Op65Zn28nPXj1/vazp04SYWtXgWBzGpVN/EgU3QW+iWX6qctbpbBWl2yhIH8
    F7MhLsEWvYcbQXX2lOYtZ4r5uIj7kwRUyIQMYSJHQNiQI6eVDIITc8qTaOSiHq+J
    vGoA+rAUmfQl
    -----END CERTIFICATE-----
    """

    private func makeVV() -> String {
        let escapedCA = Self.caPEM.replacingOccurrences(of: "\n", with: "\\n") + "\\n"
        return """
        [virt-viewer]
        type=spice
        host=192.0.2.10
        port=0
        tls-port=61000
        password=abc123ticket
        delete-this-file=1
        proxy=http://pve.example.com:3128
        host-subject=OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve.test.local
        ca=\(escapedCA)
        toggle-fullscreen=shift+f11
        """
    }

    func testParsesProxmoxFields() throws {
        let cfg = SpiceVVConfig.parse(makeVV())
        XCTAssertEqual(cfg.type, "spice")
        XCTAssertEqual(cfg.host, "192.0.2.10")
        XCTAssertEqual(cfg.port, 0)
        XCTAssertEqual(cfg.tlsPort, 61000)
        XCTAssertEqual(cfg.password, "abc123ticket")
        XCTAssertEqual(cfg.proxy, "http://pve.example.com:3128")
        XCTAssertEqual(cfg.hostSubject, "OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve.test.local")
    }

    func testCAUnescapesToValidPEM() throws {
        let cfg = SpiceVVConfig.parse(makeVV())
        let pem = try XCTUnwrap(cfg.caPEM)
        XCTAssertTrue(pem.contains("-----BEGIN CERTIFICATE-----"))
        XCTAssertTrue(pem.contains("\n"))
        XCTAssertFalse(pem.contains("\\n"))
        // The parsed CA must yield exactly one usable certificate.
        let certs = try XCTUnwrap(SpiceChannelConnection.certificates(fromPEM: pem))
        XCTAssertEqual(certs.count, 1)
    }

    func testResolvedEndpointPrefersTLS() throws {
        let cfg = SpiceVVConfig.parse(makeVV())
        let ep = try cfg.resolvedEndpoint()
        XCTAssertEqual(ep.host, "192.0.2.10")
        XCTAssertEqual(ep.port, 61000)
        XCTAssertTrue(ep.useTLS)
    }

    func testResolvedEndpointFallsBackToPlainPort() throws {
        var cfg = SpiceVVConfig.parse(makeVV())
        cfg.tlsPort = nil
        cfg.port = 5900
        let ep = try cfg.resolvedEndpoint()
        XCTAssertEqual(ep.port, 5900)
        XCTAssertFalse(ep.useTLS)
    }

    func testMissingHostThrows() {
        let cfg = SpiceVVConfig.parse("[virt-viewer]\ntype=spice\ntls-port=61000\n")
        XCTAssertThrowsError(try cfg.resolvedEndpoint())
    }

    func testGarbagePEMReturnsNil() {
        XCTAssertNil(SpiceChannelConnection.certificates(fromPEM: "not a cert"))
    }
}
