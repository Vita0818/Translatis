# Swift Crypto portable backend

Intatis uses the official Apple `swift-crypto` package only on Linux targets
that need the CryptoKit-compatible `Crypto` module. Darwin targets continue to
compile against the operating-system CryptoKit framework; the Linux-only target
conditions prevent the swift-crypto/BoringSSL implementation from entering the
macOS or iOS release linkage graph.

## Exact dependency inventory

| Component | Exact source | Use | License and notice |
|---|---|---|---|
| Apple Swift Crypto 4.5.1 | `apple/swift-crypto` commit `47d3869a7291f085c1fb9fb1e6d3b97a793f45c6` | Linux implementation of SHA-256, HMAC, AES-GCM, P-256 and other CryptoKit-compatible primitives used by the CLI/MCP client | Apache-2.0; [license](Licenses/SwiftCrypto-4.5.1-LICENSE.txt), [notice](Licenses/SwiftCrypto-4.5.1-NOTICE.txt) |
| Apple Swift ASN.1 1.7.1 | `apple/swift-asn1` commit `a9a5efd40eaf558a2bcd48d64b1d1646be686008` | Transitive swift-crypto dependency | Apache-2.0; [license](Licenses/SwiftASN1-1.7.1-LICENSE.txt), [notice](Licenses/SwiftASN1-1.7.1-NOTICE.txt) |
| BoringSSL | `google/boringssl` commit `0226f30467f540a3f62ef48d453f93927da199b6`, identified by the swift-crypto 4.5.1 manifest | Vendored cryptographic backend inside swift-crypto on non-Darwin platforms | Combined upstream terms and attributions in the exact [BoringSSL license](Licenses/BoringSSL-0226f30467f540a3f62ef48d453f93927da199b6-LICENSE.txt) |
| XKCP | `XKCP/XKCP` commit `11297f566178023faba59ff14b6b399241488283`, recorded by the swift-crypto vendoring commit as `heads/master-0-g11297f5` | Vendored SHA-3 implementation inside swift-crypto | Per-file public-domain/CC0 and exception terms in the exact [XKCP license](Licenses/XKCP-11297f566178023faba59ff14b6b399241488283-LICENSE.txt) |

The Swift Crypto NOTICE also preserves the required attributions for Google
Wycheproof test vectors and SwiftNIO-derived files. The Swift ASN.1 NOTICE
preserves the SwiftNIO and Swift OpenAPI Generator derivation attributions.

## Integration and verification

- Root SwiftPM dependency: exact version `4.5.1`; `Package.resolved` fixes the
  full commit above.
- The vendored client-only MCP SDK declares the same exact version and uses
  `Crypto` only on Linux.
- Intatis sources select `CryptoKit` when available, otherwise `Crypto`, and
  fail compilation when neither reviewed backend exists. No plaintext or
  home-grown cryptographic fallback is present.
- Known-answer tests cover SHA-256, HMAC-SHA256, AES-GCM authentication, and
  OAuth PKCE S256. The encrypted CLI credential-store tests additionally cover
  round trip, wrong-passphrase, tamper, and owner-only file behavior.

## Integrity records

The distributed texts were copied byte-for-byte from the exact checkouts or
the exact component commits:

- Swift Crypto license SHA-256:
  `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`
- Swift Crypto notice SHA-256:
  `b3ddc2ae068e76b3beb71be03c0400f90090f9469aa491bf7b1ac42320af37b8`
- Swift ASN.1 license SHA-256:
  `8c6db340475136df3c1201d458fa5755698eace76e510471ecc9d857d6083dac`
- Swift ASN.1 notice SHA-256:
  `11dd3b3b783e6ec26098dd38ebc962986ea109b85447e28e62867b83bd0f8c5b`
- BoringSSL license SHA-256:
  `827c8d8fc207c2392794eef9e00fe246f9f61fdcc132556c275be3dd8c3cd97f`
- XKCP license SHA-256:
  `ca8251255577682511dca2835e33a14ae43a49492a5c9818a6148eb4a678e6b9`
