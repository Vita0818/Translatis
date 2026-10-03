#!/bin/zsh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_root="$(cd "$script_dir/.." && pwd -P)"
spec="$project_root/Packages/IntatisCodexRuntime/Runtime/codex-runtime/release-spec.json"
architecture="${1:-}"
destination="${2:-}"
cache_root="${TRANSLATIS_RUNTIME_CACHE:-$project_root/.translatis/runtime-build/cache}"
toolchain_root="${TRANSLATIS_RUST_TOOLCHAIN_ROOT:-$project_root/.translatis/runtime-build/toolchains}"
cargo_target_root="${TRANSLATIS_CODEX_CARGO_TARGET_DIR:-$project_root/.translatis/runtime-build/cargo-target/codex-1.95.0}"
work_root=""
final_destination=""
staging_destination=""
build_completed=0
preserve_failed_build="${TRANSLATIS_PRESERVE_FAILED_RUNTIME:-0}"

fail() {
    print -u2 -- "error: $*"
    exit 1
}

cleanup() {
    if [[ "$build_completed" != "1" && "$preserve_failed_build" == "1" ]]; then
        [[ -z "${work_root:-}" ]] \
            || print -u2 -- "Preserved failed Codex work root: $work_root"
        [[ -z "${staging_destination:-}" ]] \
            || print -u2 -- "Preserved failed Codex staging root: $staging_destination"
        return
    fi
    if [[ -n "${work_root:-}" && -d "$work_root" ]]; then
        /bin/rm -rf -- "$work_root"
    fi
    if [[ -n "${staging_destination:-}" \
        && -d "$staging_destination" && ! -L "$staging_destination" ]]; then
        /bin/rm -rf -- "$staging_destination"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "$architecture" == "arm64" || "$architecture" == "x86_64" ]] \
    || fail "usage: scripts/build-codex-runtime.sh <arm64|x86_64> <absolute-destination-root>"
[[ "$destination" == /* ]] || fail "destination must be an absolute path"
[[ ! -e "$destination" && ! -L "$destination" ]] \
    || fail "destination already exists: $destination"
final_destination="$destination"
staging_destination="$final_destination.building.$$"
[[ ! -e "$staging_destination" && ! -L "$staging_destination" ]] \
    || fail "staging destination already exists: $staging_destination"
destination="$staging_destination"
[[ -f "$spec" && ! -L "$spec" ]] || fail "Codex runtime release spec is missing"

json_value() {
    /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null \
        || fail "missing JSON field $2 in ${1:t}"
}

case "$architecture" in
    arm64)
        target="aarch64-apple-darwin"
        rusty_v8_archive_name="librusty_v8_release_aarch64-apple-darwin.a.gz"
        ;;
    x86_64)
        target="x86_64-apple-darwin"
        rusty_v8_archive_name="librusty_v8_release_x86_64-apple-darwin.a.gz"
        ;;
esac

/bin/mkdir -p "$cache_root/codex" "$toolchain_root/rustup" "$toolchain_root/cargo"
/bin/mkdir -p "$cargo_target_root"
cache_root="$(cd "$cache_root" && pwd -P)"
toolchain_root="$(cd "$toolchain_root" && pwd -P)"
cargo_target_root="$(cd "$cargo_target_root" && pwd -P)"
archive="$cache_root/codex/openai-codex-$(json_value "$spec" upstream.commit).tar.gz"
if [[ ! -f "$archive" ]]; then
    /usr/bin/curl -fL --retry 12 --retry-all-errors --connect-timeout 30 \
        -o "$archive.partial" "$(json_value "$spec" upstream.archive_url)"
    /bin/mv "$archive.partial" "$archive"
fi
actual_archive_sha="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
[[ "$actual_archive_sha" == "$(json_value "$spec" upstream.archive_sha256)" ]] \
    || fail "Codex upstream archive SHA-256 does not match the release spec"

rusty_v8_archive="$cache_root/codex/$rusty_v8_archive_name"
rusty_v8_url="$(json_value "$spec" "rusty_v8.$architecture.archive_url")"
rusty_v8_expected_sha="$(json_value "$spec" "rusty_v8.$architecture.archive_sha256")"
if [[ ! -f "$rusty_v8_archive" ]]; then
    /usr/bin/curl -fL --retry 12 --retry-all-errors --connect-timeout 30 \
        -o "$rusty_v8_archive.partial" "$rusty_v8_url"
    /bin/mv "$rusty_v8_archive.partial" "$rusty_v8_archive"
fi
rusty_v8_actual_sha="$(
    /usr/bin/shasum -a 256 "$rusty_v8_archive" | /usr/bin/awk '{print $1}'
)"
[[ "$rusty_v8_actual_sha" == "$rusty_v8_expected_sha" ]] \
    || fail "rusty_v8 $architecture archive SHA-256 does not match the release spec"
export RUSTY_V8_ARCHIVE="$rusty_v8_archive"

export RUSTUP_HOME="$toolchain_root/rustup"
export CARGO_HOME="$toolchain_root/cargo"
export CARGO_NET_GIT_FETCH_WITH_CLI=true
export CARGO_HTTP_MULTIPLEXING=false
export CARGO_NET_RETRY=20
export CARGO_HTTP_TIMEOUT=600
export CARGO_HTTP_LOW_SPEED_LIMIT=1
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=http.version
export GIT_CONFIG_VALUE_0=HTTP/1.1
rust_toolchain="$(json_value "$spec" components.rust)"
rustup_succeeded=0
for attempt in {1..12}; do
    if /opt/homebrew/bin/rustup toolchain install "$rust_toolchain" \
        --profile minimal \
        --target aarch64-apple-darwin \
        --target x86_64-apple-darwin; then
        rustup_succeeded=1
        break
    fi
    [[ "$attempt" == "12" ]] || /bin/sleep 2
done
[[ "$rustup_succeeded" == "1" ]] \
    || fail "could not install the exact Rust toolchain after bounded retries"
targets_succeeded=0
for attempt in {1..12}; do
    if /opt/homebrew/bin/rustup target add \
        --toolchain "$rust_toolchain" \
        aarch64-apple-darwin x86_64-apple-darwin; then
        targets_succeeded=1
        break
    fi
    [[ "$attempt" == "12" ]] || /bin/sleep 2
done
[[ "$targets_succeeded" == "1" ]] \
    || fail "could not install both targets for the exact Rust toolchain"
installed_targets="$(
    /opt/homebrew/bin/rustup target list \
        --toolchain "$rust_toolchain" --installed
)"
[[ "$installed_targets" == *"aarch64-apple-darwin"* \
    && "$installed_targets" == *"x86_64-apple-darwin"* ]] \
    || fail "the exact Rust toolchain does not contain both release targets"
cargo_executable="$(
    /opt/homebrew/bin/rustup which cargo \
        --toolchain "$rust_toolchain"
)"
rustc_executable="$(
    /opt/homebrew/bin/rustup which rustc \
        --toolchain "$rust_toolchain"
)"
rustdoc_executable="$(
    /opt/homebrew/bin/rustup which rustdoc \
        --toolchain "$rust_toolchain"
)"
[[ -x "$cargo_executable" ]] \
    || fail "rustup did not expose Cargo for the fixed Rust toolchain"
[[ -x "$rustc_executable" && -x "$rustdoc_executable" ]] \
    || fail "rustup did not expose rustc/rustdoc for the fixed Rust toolchain"
[[ "$("$rustc_executable" --version | /usr/bin/awk '{print $2}')" == "$rust_toolchain" ]] \
    || fail "rustup resolved the wrong rustc version"
export RUSTC="$rustc_executable"
export RUSTDOC="$rustdoc_executable"

    work_root="$(/usr/bin/mktemp -d /private/tmp/translatis-codex-runtime-build.XXXXXX)"
/bin/chmod 0700 "$work_root"
source_root="$work_root/source"
/bin/mkdir -p "$source_root"
/usr/bin/tar -xzf "$archive" --strip-components 1 -C "$source_root"
upstream_lock_sha="$(/usr/bin/shasum -a 256 "$source_root/codex-rs/Cargo.lock" | /usr/bin/awk '{print $1}')"
[[ "$upstream_lock_sha" == "$(json_value "$spec" upstream.cargo_lock_sha256)" ]] \
    || fail "upstream Cargo.lock does not match the release spec"
rust_toolchain_sha="$(/usr/bin/shasum -a 256 "$source_root/codex-rs/rust-toolchain.toml" | /usr/bin/awk '{print $1}')"
[[ "$rust_toolchain_sha" == "$(json_value "$spec" upstream.rust_toolchain_file_sha256)" ]] \
    || fail "upstream rust-toolchain.toml does not match the release spec"

patches=(
    "$project_root/ThirdPartyPatches/OpenAICodexRuntime/0001-responses-provider-passthrough.patch"
    "$project_root/ThirdPartyPatches/OpenAICodexRuntime/0002-openrouter-strict-routing-shape.patch"
    "$project_root/ThirdPartyPatches/OpenAICodexRuntime/0003-cowork-subagent-reconnection.patch"
)
index=1
for patch in $patches; do
    key="$(printf '%04d' "$index")"
    actual_patch_sha="$(/usr/bin/shasum -a 256 "$patch" | /usr/bin/awk '{print $1}')"
    [[ "$actual_patch_sha" == "$(json_value "$spec" "patch_sha256.$key")" ]] \
        || fail "Codex patch $key does not match the release spec"
    (
        cd "$source_root"
        /usr/bin/git apply --no-index --check "$patch"
        /usr/bin/git apply --no-index "$patch"
    )
    index=$((index + 1))
done
derived_lock_sha="$(/usr/bin/shasum -a 256 "$source_root/codex-rs/Cargo.lock" | /usr/bin/awk '{print $1}')"
[[ "$derived_lock_sha" == "$(json_value "$spec" derived_cargo_lock_sha256)" ]] \
    || fail "derived Cargo.lock does not match the release spec"

# The peeled release commit sets workspace.package.version to 0.145.0 after
# generating its lock, leaving 130 workspace-only entries at 0.0.0. Normalize
# only that metadata (no dependency/source/checksum changes), then require the
# exact resulting lock hash before Cargo is allowed to resolve or build.
workspace_version_entries="$(
    /usr/bin/grep -c '^version = "0\.0\.0"$' "$source_root/codex-rs/Cargo.lock"
)"
[[ "$workspace_version_entries" == "130" ]] \
    || fail "unexpected number of stale workspace versions in derived Cargo.lock"
/usr/bin/sed -i '' 's/^version = "0\.0\.0"$/version = "0.145.0"/' \
    "$source_root/codex-rs/Cargo.lock"
build_lock_sha="$(/usr/bin/shasum -a 256 "$source_root/codex-rs/Cargo.lock" | /usr/bin/awk '{print $1}')"
[[ "$build_lock_sha" == "$(json_value "$spec" build_cargo_lock_sha256)" ]] \
    || fail "normalized build Cargo.lock does not match the release spec"

export CARGO_TARGET_DIR="$cargo_target_root"
export INTATIS_CODEX_DERIVATION_ID="$(json_value "$spec" derivation_id)"
(
    cd "$source_root/codex-rs"
    "$cargo_executable" \
        build --locked --release -p codex-cli --target "$target"
    "$cargo_executable" \
        metadata --locked --filter-platform "$target" --format-version 1 \
        > "$work_root/cargo-metadata.json"
)

binary="$CARGO_TARGET_DIR/$target/release/codex"
[[ -x "$binary" ]] || fail "Cargo did not produce the Codex executable"
/bin/mkdir -p "$destination/ThirdPartyNotices/licenses/cargo"
/bin/cp -p "$binary" "$destination/codex"
/bin/chmod 0755 "$destination/codex"

/usr/bin/jq -r '.packages[] | [.name, .version, (.license // "NOASSERTION"), (.source // "workspace"), .manifest_path] | @tsv' \
    "$work_root/cargo-metadata.json" \
    | LC_ALL=C /usr/bin/sort -u > "$destination/ThirdPartyNotices/LICENSES.txt"
while IFS=$'\t' read -r package_name package_version package_license package_source manifest_path; do
    package_dir="${manifest_path:h}"
    license_destination="$destination/ThirdPartyNotices/licenses/cargo/${package_name}-${package_version}"
    /bin/mkdir -p "$license_destination"
    copied=0
    while IFS= read -r license_file; do
        /bin/cp -p "$license_file" "$license_destination/${license_file:t}" \
            || fail "could not copy Cargo license for $package_name $package_version: $license_file"
        copied=1
    done < <(/usr/bin/find "$package_dir" -maxdepth 1 -type f \
        \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) -print)
    if [[ "$copied" == "0" && "$package_source" == "workspace" ]]; then
        /bin/cp -p "$source_root/LICENSE" "$license_destination/OpenAI-Codex-LICENSE"
        /bin/cp -p "$source_root/NOTICE" "$license_destination/OpenAI-Codex-NOTICE"
    fi
done < "$destination/ThirdPartyNotices/LICENSES.txt"

/usr/bin/jq \
    --arg architecture "$architecture" \
    --arg namespace "https://vitemis.com/spdx/translatis-codex-runtime/2026.08.27.1/$architecture" \
    '{
      spdxVersion: "SPDX-2.3",
      dataLicense: "CC0-1.0",
      SPDXID: "SPDXRef-DOCUMENT",
      name: ("Translatis Codex Runtime 2026.08.27.1 " + $architecture),
      documentNamespace: $namespace,
      creationInfo: {
        created: "2026-08-27T00:00:00Z",
        creators: ["Tool: Translatis build-codex-runtime.sh"]
      },
      packages: [
        .packages[] | {
          name: .name,
          SPDXID: ("SPDXRef-Package-" + ((.name + "-" + .version) | gsub("[^A-Za-z0-9.-]"; "-"))),
          versionInfo: .version,
          downloadLocation: (.source // "NOASSERTION"),
          filesAnalyzed: false,
          licenseConcluded: "NOASSERTION",
          licenseDeclared: (.license // "NOASSERTION"),
          copyrightText: "NOASSERTION"
        }
      ]
    }' "$work_root/cargo-metadata.json" \
    > "$destination/ThirdPartyNotices/runtime.spdx.json"

/usr/bin/jq \
    --arg architecture "$architecture" \
    --arg binary_sha256 "$(/usr/bin/shasum -a 256 "$destination/codex" | /usr/bin/awk '{print $1}')" \
    '. + {architecture: $architecture, binary_sha256: $binary_sha256}' \
    "$spec" > "$destination/runtime-manifest.json"
(
    cd "$destination"
    /usr/bin/find . -type f ! -path './SHA256SUMS.txt' \
        -exec /usr/bin/shasum -a 256 {} + \
        | LC_ALL=C /usr/bin/sort \
        > SHA256SUMS.txt
)

"$project_root/scripts/validate-codex-runtime.sh" \
    "$destination" "$architecture" "" static
/bin/mv "$destination" "$final_destination"
staging_destination=""
build_completed=1
print -- "Built fixed Codex runtime $architecture at $final_destination"
