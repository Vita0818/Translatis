#!/bin/zsh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_root="$(cd "$script_dir/.." && pwd -P)"
spec="$project_root/Packages/IntatisCodexRuntime/Runtime/codex-runtime/release-spec.json"
runtime_root="${1:-}"
expected_architecture="${2:-}"
expected_signing_identity="${3:-}"
validation_mode="${4:-static}"
temporary_root=""

fail() {
    print -u2 -- "error: $*"
    exit 1
}

cleanup() {
    if [[ -n "${temporary_root:-}" && -d "$temporary_root" ]]; then
        /bin/rm -rf -- "$temporary_root"
    fi
}
trap cleanup EXIT

[[ -n "$runtime_root" && -n "$expected_architecture" ]] \
    || fail "usage: scripts/validate-codex-runtime.sh <runtime-root> <arm64|x86_64> [Developer ID identity|-] [static|execute|execute-local]"
[[ "$expected_architecture" == "arm64" || "$expected_architecture" == "x86_64" ]] \
    || fail "runtime architecture must be arm64 or x86_64"
[[ "$validation_mode" == "static" || "$validation_mode" == "execute" \
    || "$validation_mode" == "execute-local" ]] \
    || fail "validation mode must be static, execute, or execute-local"
[[ "$runtime_root" == /* ]] || fail "runtime root must be an absolute path"
[[ -d "$runtime_root" && ! -L "$runtime_root" ]] \
    || fail "runtime root is missing or is a symlink"
runtime_root="$(cd "$runtime_root" && pwd -P)"

manifest="$runtime_root/runtime-manifest.json"
inventory="$runtime_root/SHA256SUMS.txt"
[[ -f "$spec" && ! -L "$spec" ]] || fail "Codex runtime release spec is missing"
[[ -f "$manifest" && ! -L "$manifest" ]] || fail "runtime manifest is missing or unsafe"
[[ -f "$inventory" && ! -L "$inventory" ]] || fail "runtime SHA-256 inventory is missing or unsafe"
/usr/bin/plutil -convert xml1 -o /dev/null "$spec" \
    || fail "Codex runtime release spec is not valid JSON"
/usr/bin/plutil -convert xml1 -o /dev/null "$manifest" \
    || fail "runtime manifest is not valid JSON"

json_value() {
    /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null \
        || fail "missing JSON field $2 in ${1:t}"
}

for key in \
    schema_version layout_version runtime_release derivation_id \
    components.codex_cli components.rust components.rusty_v8 \
    upstream.release upstream.commit upstream.archive_url \
    upstream.archive_sha256 upstream.cargo_lock_sha256 \
    rusty_v8.release \
    derived_cargo_lock_sha256 patch_sha256.0001 patch_sha256.0002 \
    patch_sha256.0003; do
    [[ "$(json_value "$manifest" "$key")" == "$(json_value "$spec" "$key")" ]] \
        || fail "runtime manifest $key does not match the release spec"
done
for key in archive_url archive_sha256; do
    [[ "$(json_value "$manifest" "rusty_v8.$expected_architecture.$key")" \
        == "$(json_value "$spec" "rusty_v8.$expected_architecture.$key")" ]] \
        || fail "runtime manifest rusty_v8.$expected_architecture.$key does not match the release spec"
done
[[ "$(json_value "$manifest" architecture)" == "$expected_architecture" ]] \
    || fail "runtime manifest architecture does not match $expected_architecture"
actual_binary_sha="$(/usr/bin/shasum -a 256 "$runtime_root/codex" 2>/dev/null \
    | /usr/bin/awk '{print $1}')"
[[ -n "$actual_binary_sha" \
    && "$(json_value "$manifest" binary_sha256)" == "$actual_binary_sha" ]] \
    || fail "runtime manifest binary_sha256 does not match the Codex executable"

required_files=(
    codex
    ThirdPartyNotices/runtime.spdx.json
    ThirdPartyNotices/LICENSES.txt
)
for relative_path in $required_files; do
    [[ -f "$runtime_root/$relative_path" && ! -L "$runtime_root/$relative_path" ]] \
        || fail "runtime is missing required regular file $relative_path"
done
[[ -x "$runtime_root/codex" ]] || fail "Codex runtime executable is not executable"
[[ -d "$runtime_root/ThirdPartyNotices/licenses" \
    && ! -L "$runtime_root/ThirdPartyNotices/licenses" ]] \
    || fail "runtime license directory is missing or unsafe"
[[ -n "$(/usr/bin/find "$runtime_root/ThirdPartyNotices/licenses" -type f -print -quit)" ]] \
    || fail "runtime license directory is empty"
[[ -s "$runtime_root/ThirdPartyNotices/LICENSES.txt" ]] \
    || fail "runtime license inventory is empty"

runtime_spdx="$runtime_root/ThirdPartyNotices/runtime.spdx.json"
/usr/bin/plutil -convert xml1 -o /dev/null "$runtime_spdx" \
    || fail "runtime SPDX SBOM is not valid JSON"
[[ "$(json_value "$runtime_spdx" spdxVersion)" == "SPDX-2.3" ]] \
    || fail "runtime SBOM must use SPDX-2.3"
[[ "$(json_value "$runtime_spdx" dataLicense)" == "CC0-1.0" ]] \
    || fail "runtime SBOM dataLicense must be CC0-1.0"
[[ "$(json_value "$runtime_spdx" SPDXID)" == "SPDXRef-DOCUMENT" ]] \
    || fail "runtime SBOM must identify SPDXRef-DOCUMENT"
spdx_package_count="$(
    /usr/bin/plutil -extract packages raw -expect array -o - "$runtime_spdx" 2>/dev/null
)" || fail "runtime SBOM packages field is missing or invalid"
[[ "$spdx_package_count" == <-> && "$spdx_package_count" -gt 0 ]] \
    || fail "runtime SBOM contains no packages"

while IFS= read -r link; do
    resolved="$(/bin/realpath "$link")" || fail "runtime symlink cannot be resolved: $link"
    case "$resolved" in
        "$runtime_root"/*) ;;
        *) fail "runtime symlink escapes its architecture root: $link" ;;
    esac
done < <(/usr/bin/find "$runtime_root" -type l -print)

temporary_root="$(/usr/bin/mktemp -d /private/tmp/translatis-codex-runtime-validation.XXXXXX)"
/bin/chmod 0700 "$temporary_root"
actual_paths="$temporary_root/actual-paths.txt"
inventory_paths="$temporary_root/inventory-paths.txt"
(
    cd "$runtime_root"
    /usr/bin/find . -type f ! -path './SHA256SUMS.txt' -print \
        | LC_ALL=C /usr/bin/sort > "$actual_paths"
)
: > "$inventory_paths"
while IFS= read -r line; do
    [[ "$line" =~ '^[0-9a-f]{64}  \./[^/].*$' ]] \
        || fail "runtime inventory contains a malformed entry"
    relative_path="${line[67,-1]}"
    print -r -- "$relative_path" >> "$inventory_paths"
done < "$inventory"
LC_ALL=C /usr/bin/sort -u -o "$inventory_paths" "$inventory_paths"
/usr/bin/cmp -s "$actual_paths" "$inventory_paths" \
    || fail "runtime SHA-256 inventory is incomplete or lists unknown files"
(
    cd "$runtime_root"
    /usr/bin/shasum -a 256 --check SHA256SUMS.txt >/dev/null
) || fail "runtime SHA-256 inventory verification failed"

macho_inspection_index=0
while IFS= read -r candidate; do
    file_description="$(/usr/bin/file -b "$candidate")"
    [[ "$file_description" == *"Mach-O"* ]] || continue
    macho_inspection_index=$((macho_inspection_index + 1))
    inspection_candidate="$candidate"
    if [[ "$candidate" == *'('* || "$candidate" == *')'* ]]; then
        inspection_candidate="$temporary_root/macho-inspection-$macho_inspection_index"
        /bin/ln -s "$candidate" "$inspection_candidate"
    fi
    architectures="$(/usr/bin/lipo -archs "$candidate")" \
        || fail "could not inspect Mach-O architecture: $candidate"
    [[ " $architectures " == *" $expected_architecture "* ]] \
        || fail "Mach-O is missing $expected_architecture: $candidate"
    linked_libraries="$(/usr/bin/otool -L "$inspection_candidate")" \
        || fail "could not inspect Mach-O dependencies: $candidate"
    install_name="$(/usr/bin/otool -D "$inspection_candidate" 2>/dev/null \
        | /usr/bin/awk 'NR == 2 { print; exit }')"
    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        [[ -z "$install_name" || "$dependency" != "$install_name" ]] || continue
        case "$dependency" in
            /System/Library/*|/usr/lib/*|@loader_path/*|@executable_path/*|@rpath/*) ;;
            *) fail "Mach-O has a non-system, non-bundle-relative dependency: $candidate -> $dependency" ;;
        esac
    done < <(print -r -- "$linked_libraries" | /usr/bin/awk 'NR > 1 { print $1 }')
    if [[ -n "$expected_signing_identity" ]]; then
        /usr/bin/codesign --verify --strict "$candidate" >/dev/null 2>&1 \
            || fail "runtime Mach-O has no valid strict signature: $candidate"
        signature_info="$(/usr/bin/codesign -dv --verbose=4 "$candidate" 2>&1)"
        if [[ "$expected_signing_identity" == "-" ]]; then
            [[ "$signature_info" == *"Signature=adhoc"* ]] \
                || fail "runtime Mach-O is not ad-hoc signed: $candidate"
        else
            [[ "$signature_info" == *"Authority=$expected_signing_identity"* ]] \
                || fail "runtime Mach-O is not signed by the selected Developer ID identity: $candidate"
        fi
    fi
done < <(/usr/bin/find "$runtime_root" -type f -print)

if [[ "$validation_mode" != "static" ]]; then
    if [[ "$validation_mode" == "execute" ]]; then
        [[ -n "$expected_signing_identity" && "$expected_signing_identity" != "-" ]] \
            || fail "execute validation requires an exact Developer ID identity"
    else
        [[ "$expected_signing_identity" == "-" ]] \
            || fail "execute-local validation requires the ad-hoc identity marker '-'"
    fi
    sealed_app="$(cd "$runtime_root/../../../.." && pwd -P)"
    [[ "$sealed_app" == *.app \
        && "$runtime_root" == "$sealed_app/Contents/Resources/CodexRuntime/$expected_architecture" ]] \
        || fail "execute validation is allowed only inside the final App layout"
    /usr/bin/codesign --verify --deep --strict "$sealed_app" >/dev/null 2>&1 \
        || fail "execute validation requires a valid outer App resource seal"
    sealed_signature="$(/usr/bin/codesign -dv --verbose=4 "$sealed_app" 2>&1)"
    [[ "$sealed_signature" == *"runtime"* ]] \
        || fail "outer App is missing Hardened Runtime"
    if [[ "$validation_mode" == "execute" ]]; then
        [[ "$sealed_signature" == *"Authority=$expected_signing_identity"* ]] \
            || fail "outer App is not signed by the selected Developer ID identity"
    else
        [[ "$sealed_signature" == *"Signature=adhoc"* ]] \
            || fail "outer App is not ad-hoc signed"
    fi

    /bin/mkdir -p "$temporary_root/home" "$temporary_root/tmp"
    /bin/chmod 0700 "$temporary_root/home" "$temporary_root/tmp"
    run_for_architecture() {
        /usr/bin/env -i \
            HOME="$temporary_root/home" \
            TMPDIR="$temporary_root/tmp/" \
            PATH=/usr/bin:/bin \
            LANG=C LC_ALL=C \
            /usr/bin/arch -"$expected_architecture" "$@"
    }
    version_output="$(run_for_architecture "$runtime_root/codex" --version)" \
        || fail "Codex runtime version probe failed"
    [[ "$version_output" == "codex-cli 0.145.0-intatis.4" ]] \
        || fail "Codex runtime version does not match the release spec"
    derivation_output="$(run_for_architecture "$runtime_root/codex" --intatis-derivation-id)" \
        || fail "Codex runtime derivation probe failed"
    [[ "$derivation_output" == "$(json_value "$spec" derivation_id)" ]] \
        || fail "Codex runtime derivation does not match the release spec"
    app_server_smoke="$(
        /usr/bin/env -i \
            HOME="$temporary_root/home" \
            TMPDIR="$temporary_root/tmp/" \
            PATH=/usr/bin:/bin \
            LANG=C LC_ALL=C \
            CODEX_HOME="$temporary_root/home" \
            /usr/bin/python3 - "$expected_architecture" "$runtime_root/codex" <<'PY'
import json
import os
import subprocess
import sys

architecture, executable = sys.argv[1:]
request = {
    "method": "initialize",
    "id": 42,
    "params": {
        "clientInfo": {
            "name": "translatis-runtime-validator",
            "title": "Translatis Runtime Validator",
            "version": "0.66.0",
        },
        "capabilities": {"experimentalApi": True},
    },
}
process = subprocess.Popen(
    ["/usr/bin/arch", "-" + architecture, executable, "app-server", "--stdio"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=os.environ,
)
try:
    stdout, stderr = process.communicate(json.dumps(request) + "\n", timeout=20)
except subprocess.TimeoutExpired:
    process.kill()
    process.communicate()
    raise SystemExit("app-server initialize timed out")
responses = []
for line in stdout.splitlines():
    try:
        responses.append(json.loads(line))
    except json.JSONDecodeError:
        pass
if not any(item.get("id") == 42 and "result" in item for item in responses):
    raise SystemExit("app-server did not return an initialize result")
print("initialized")
PY
    )" || fail "Codex app-server stdio initialize smoke failed"
    [[ "$app_server_smoke" == "initialized" ]] \
        || fail "Codex app-server stdio initialize smoke returned unexpected output"
fi

print -- "Validated Codex runtime $expected_architecture ($validation_mode) at $runtime_root"
