import XCTest
@testable import IntatisMCP

final class MCPHTTPPolicyTests: XCTestCase {
    func testExactEgressRejectsIPv4MappedLoopbackAndPrivateAddresses()
        throws
    {
        let policy = MCPExactOriginEgressPolicy()
        for address in [
            "::ffff:127.0.0.1",
            "::ffff:10.0.0.1",
            "::ffff:169.254.1.1",
            "::127.0.0.1",
        ] {
            XCTAssertThrowsError(
                try policy.authorize(
                    canonicalOrigin: "https://example.test:443",
                    resolvedAddresses: [address]),
                "unexpectedly admitted \(address)"
            ) { error in
                XCTAssertEqual(
                    error as? MCPHTTPTransportError,
                    .egressDenied)
            }
        }
    }

    func testExactEgressAppliesExplicitPrivateAndLoopbackClassesToMappedIPv4()
        throws
    {
        XCTAssertNoThrow(
            try MCPExactOriginEgressPolicy(
                allowsPrivateAddresses: true)
                .authorize(
                    canonicalOrigin: "https://example.test:443",
                    resolvedAddresses: ["::ffff:10.0.0.1"]))
        XCTAssertNoThrow(
            try MCPExactOriginEgressPolicy(
                allowsLoopback: true)
                .authorize(
                    canonicalOrigin: "https://example.test:443",
                    resolvedAddresses: ["::ffff:127.0.0.1"]))
    }

    func testExactEgressRejectsTransitionAndNonRoutableAddressClasses()
        throws
    {
        let policy = MCPExactOriginEgressPolicy(
            allowsPrivateAddresses: true,
            allowsLoopback: true)
        for address in [
            "0.0.0.0",
            "100.64.0.1",
            "192.0.2.1",
            "198.18.0.1",
            "198.51.100.1",
            "203.0.113.1",
            "::",
            "64:ff9b::7f00:1",
            "2001::1",
            "2001:db8::1",
            "2002:7f00:1::1",
            "fe80::1",
            "ff02::1",
        ] {
            XCTAssertThrowsError(
                try policy.authorize(
                    canonicalOrigin: "https://example.test:443",
                    resolvedAddresses: [address]),
                "unexpectedly admitted \(address)"
            ) { error in
                XCTAssertEqual(
                    error as? MCPHTTPTransportError,
                    .egressDenied)
            }
        }
    }

    func testExactEgressAdmitsOrdinaryPublicIPv4IPv6AndMappedIPv4()
        throws
    {
        XCTAssertNoThrow(
            try MCPExactOriginEgressPolicy().authorize(
                canonicalOrigin: "https://example.test:443",
                resolvedAddresses: [
                    "8.8.8.8",
                    "2606:4700:4700::1111",
                    "::ffff:8.8.4.4",
                ]))
    }

    func testBoundedSystemResolverHasSynchronousNumericPath() throws {
        let addresses =
            try MCPSystemDNSResolver.resolveSynchronously(
                host: "127.0.0.1",
                port: 443,
                timeoutMilliseconds: 1_000)
        XCTAssertEqual(addresses, ["127.0.0.1"])
    }
}
