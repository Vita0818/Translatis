# External MCP HTTP transport third-party notices

This notice covers the native `IntatisCurlTransport` dependency used by the
external MCP Server **client**. It does not cover an MCP Server implementation,
and it does not authorize any server target, server binary, server protocol
handler, or hosting API.

## Platform and distribution boundary

### Apple platforms

`Package.swift` links `IntatisCurlTransport` with `.linkedLibrary("curl")`.
For the macOS DeveloperID and App Store products this resolves to the libcurl
provided by the Apple SDK/operating system. Intatis does not vendor a Darwin
libcurl archive or copy libcurl into an App bundle. This system-library use is
therefore recorded for build provenance, but it does not add a separately
redistributed libcurl payload to the Apple application.

The iOS product does not link `IntatisMCP` or `IntatisCurlTransport`.

### Linux CLI

The Linux CLI is built with the official Swift Static Linux SDK. Static
linking means the required object code is incorporated into the distributed
CLI executable, so the following component notices must remain readable with
that executable even though Intatis does not redistribute the SDK archives as
standalone files.

- Official artifact:
  `swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz`
- Official download:
  <https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz>
- Official archive SHA-256 published by Swift.org:
  `87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b`
- Extracted SPDX 2.3 SBOM SHA-256:
  `bef245e3aa47c9623dfc7e5d4df01510f283722b6e8d9a80a38cc3c1cb4040a0`
- SBOM document namespace:
  `urn:uuid:0eb41bf5-3da3-44ed-9b19-000f089a9272`
- Artifact metadata SHA-256:
  `b338fe251fb1d3d82fd6d27f78eab52b22231bbbf077cebb75f2ede889d315a1`

Swift.org documents that the Static Linux SDK is fully statically linked, that
it includes an SPDX SBOM, and that bundled C libraries can enter a final
executable when their functionality is used:
<https://www.swift.org/documentation/articles/static-linux-getting-started.html>.

## Direct native closure

Both SDK architectures contain the same declared native closure:

```text
libcurl.pc
Requires: openssl,zlib
Libs: -lcurl -lssl -lcrypto -lz
```

The SDK headers identify `libssl.a` and `libcrypto.a` as BoringSSL
(`OPENSSL_IS_BORINGSSL`); there is no separately identified OpenSSL release in
the SDK SBOM. “openssl” in `libcurl.pc` is the pkg-config interface name, not a
claim that the archives contain an OpenSSL 3.x distribution.

| Component | Evidence in the official SDK and Swift build recipe | License conclusion used for distribution |
|---|---|---|
| curl | SBOM: `8.15.0`, `MIT`; `curlver.h` and `libcurl.pc`: `8.15.0-DEV`; pkg-config header: `SPDX-License-Identifier: curl`; Swift recipe checkout: tag `curl-8_15_0`, commit `cfbfb65047e85e6b08af65fe9cdbcf68e9ad496a` | Conservative authoritative component terms: SPDX `curl`; preserve the exact curl 8.15.0 `COPYING` text |
| BoringSSL (`libssl` + `libcrypto`) | SBOM version is empty and license expression is `OpenSSL AND ISC AND MIT`; Swift recipe checkout: commit `817ab07ebb53da35afea409ab9328f578492832d`; headers define `OPENSSL_IS_BORINGSSL` and API version 34 | Preserve the exact pinned revision's full `LICENSE`; the linked-library closure carries the combined OpenSSL, Original SSLeay, ISC, and fiat-crypto MIT terms |
| zlib | SBOM and `zlib.h`: `1.3.1`; Swift recipe checkout: tag `v1.3.1`, commit `51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf`; license `Zlib` | Preserve the zlib notice; do not misrepresent origin or an altered source |

The SDK SBOM's generic `MIT` label for curl conflicts with curl's own shipped
pkg-config SPDX identifier. Intatis resolves that ambiguity in the
license-holder-favorable direction by distributing the upstream `curl`
license rather than weakening it to a generic MIT label.

## Source identity resolution

The official Swift Static Linux SDK build recipe audited at
[`swiftlang/swift-docker@cdfdf30bef6f1529ad34662274db00781d87ab61`](https://github.com/swiftlang/swift-docker/blob/cdfdf30bef6f1529ad34662274db00781d87ab61/swift-ci/sdks/static-linux/scripts/fetch-source.sh)
fixes `CURL_VERSION=8.15.0`,
`BORINGSSL_VERSION=817ab07ebb53da35afea409ab9328f578492832d`, and
`ZLIB_VERSION=1.3.1`, then checks out `curl-8_15_0`, that exact BoringSSL
commit, and `v1.3.1`. The recipe file's Git blob is
`5410d5d14d9b515afd5990ecca06fc2767447bf4`.

The source pins were independently checked against both architecture SDK
trees. `git hash-object` over the installed headers produced the same Git
blob identity for `aarch64` and `x86_64`, and each identity equals the
corresponding upstream file at the pinned source revision:

| Component | Upstream source pin | Header used for byte check | Upstream and both SDK Git blob SHA-1 |
|---|---|---|---|
| curl | [`curl-8_15_0` / `cfbfb65047e85e6b08af65fe9cdbcf68e9ad496a`](https://github.com/curl/curl/commit/cfbfb65047e85e6b08af65fe9cdbcf68e9ad496a) | `include/curl/curlver.h` | `b3fc29b91c3496ad49024fc87147037afa780a2b` |
| BoringSSL | [`817ab07ebb53da35afea409ab9328f578492832d`](https://github.com/google/boringssl/commit/817ab07ebb53da35afea409ab9328f578492832d) | `include/openssl/base.h` | `d8cb34408bc89b855d6fb86dcf491cac255ae803` |
| zlib | [`v1.3.1` / `51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf`](https://github.com/madler/zlib/commit/51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf) | `zlib.h` | `8d4b932eaf6a0fbb8133b3ab49ba5ef587059fa0` |

This evidence resolves the SBOM's empty BoringSSL `versionInfo` and the
header-facing curl `8.15.0-DEV` label without substituting an unrelated
dependency. The archive and source evidence are kept separately: the SDK
does not include a signed source-commit attestation or a reproducible-build
statement for these individual archives, so the header match must not be
misrepresented as a bit-for-bit reproduction of the `.a` files.

## Archive integrity

The exact static archives inspected for this integration are:

| Architecture | Archive | Bytes | SHA-256 |
|---|---:|---:|---|
| `aarch64-swift-linux-musl` | `libcurl.a` | 9,071,144 | `88c56c6523feabf739c2a9550ca5e92e3bb62bdb7de0fae5870b76e32ed5526c` |
| `aarch64-swift-linux-musl` | `libssl.a` | 6,071,170 | `e7e2f64c42a6a0e8e8700b5fac4fef642b65b8e57548fa20fb545fc2124b1cbd` |
| `aarch64-swift-linux-musl` | `libcrypto.a` | 16,612,056 | `4fe66671adfaa6b4cb54cde6dbbeec15f4eceebca3be2e5bed9306856495e4eb` |
| `aarch64-swift-linux-musl` | `libz.a` | 133,996 | `c05aba63d753b54ba6f355ac547658ab38e0943add3c5081edc06ea00bdf4a49` |
| `x86_64-swift-linux-musl` | `libcurl.a` | 9,071,968 | `3c6e704d40c0b5e2f6834663186e9b9268672f823e5c2c5d69308cc77b0cca7f` |
| `x86_64-swift-linux-musl` | `libssl.a` | 6,141,178 | `d6fb9ea9d449ee1eac6552b41d079ae0f9068830a02124b8d6f76aaebb7a2016` |
| `x86_64-swift-linux-musl` | `libcrypto.a` | 17,062,646 | `4a7d8f01f984359db27673b84d70d5b943761b6a2de08f1377e18ba988e044be` |
| `x86_64-swift-linux-musl` | `libz.a` | 138,684 | `46d962bb53b6f89eb39d13793b58f3b5bb5129f5649af7ca7a74dd781fdf1280` |

These archive hashes are architecture-specific and are not interchangeable
with the official compressed artifact checksum.

## Complete terms and required attribution

- curl 8.15.0 `COPYING`:
  `ThirdPartyNotices/Licenses/curl-8.15.0-COPYING.txt`
- zlib 1.3.1 license:
  `ThirdPartyNotices/Licenses/zlib-1.3.1-LICENSE.txt`
- BoringSSL license at
  `817ab07ebb53da35afea409ab9328f578492832d`:
  `ThirdPartyNotices/Licenses/BoringSSL-817ab07ebb53da35afea409ab9328f578492832d-LICENSE.txt`

The license-text provenance is:

| Local file | Official source used for the text | Local SHA-256 |
|---|---|---|
| `curl-8.15.0-COPYING.txt` | <https://github.com/curl/curl/blob/curl-8_15_0/COPYING> | `e18f1989333b70044b2adfb7dc2f905d0119dbdcac3bc9f4bc9d540e3a29de5b` |
| `zlib-1.3.1-LICENSE.txt` | <https://github.com/madler/zlib/blob/v1.3.1/LICENSE> | `845efc77857d485d91fb3e0b884aaa929368c717ae8186b66fe1ed2495753243` |
| `BoringSSL-817ab07ebb53da35afea409ab9328f578492832d-LICENSE.txt` | <https://github.com/google/boringssl/blob/817ab07ebb53da35afea409ab9328f578492832d/LICENSE>; seven instances of trailing horizontal whitespace normalized, with no text or terms removed | `bed7465f4e9faa86586ac2226d0154c306584c2438f5bb78c597ffabb7fff308` |

The BoringSSL combined text contains the OpenSSL Project and Eric Young
acknowledgments required for binary redistribution, the Original SSLeay
conditions, Google's ISC terms, and the fiat-crypto MIT terms. Those notices
must be reproduced in documentation or other readable materials distributed
with the Linux CLI. The full upstream license content is retained with only
trailing horizontal whitespace normalized. Its support-code sections explain
that those test/build sources are not included in `libcrypto` or `libssl` and
therefore are not asserted to be part of the linked CLI. All applicable
no-endorsement restrictions in the bundled texts must be followed.

Required acknowledgments retained for the Linux CLI distribution:

> This product includes software developed by the OpenSSL Project for use in
> the OpenSSL Toolkit. (http://www.openssl.org/)

> This product includes cryptographic software written by Eric Young
> (eay@cryptsoft.com).

## Provenance boundary and upgrade gate

The official 6.3.3 SDK SBOM leaves the BoringSSL version empty, and the curl
headers expose a `-DEV` label. The official Swift build recipe plus the
two-architecture byte-identical header checks resolve the source pins recorded
above. The pinned official artifact checksum, extracted SBOM hash, source
recipe and pins, header/pkg-config metadata, and architecture-specific archive
hashes together form the recorded provenance chain.

Swift Crypto 4.5.1 uses a different BoringSSL commit,
`0226f30467f540a3f62ef48d453f93927da199b6`; it must not be substituted for
the Static Linux SDK's
`817ab07ebb53da35afea409ab9328f578492832d` identity, or vice versa.

Any Swift toolchain/Static Linux SDK update, archive replacement, or change to
the native link flags must repeat the SBOM/pkg-config/header audit, recompute
all hashes, compare licenses, update this notice, and rebuild both Linux
architectures. A release bundle must include `NOTICE.md`, this file, and the
three referenced license texts in a user-readable third-party notices
location.
