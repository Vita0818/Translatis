#!/bin/zsh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_root="$(cd "$script_dir/.." && pwd -P)"
spec="$project_root/Packages/IntatisTools/Runtime/browser-runtime/release-spec.json"
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
    || fail "usage: scripts/validate-browser-runtime.sh <runtime-root> <arm64|x86_64> [Developer ID identity|-] [static|execute|execute-local]"
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
[[ -f "$spec" && ! -L "$spec" ]] || fail "browser runtime release spec is missing"
[[ -f "$manifest" && ! -L "$manifest" ]] || fail "runtime manifest is missing or unsafe"
[[ -f "$inventory" && ! -L "$inventory" ]] || fail "runtime SHA-256 inventory is missing or unsafe"
/usr/bin/plutil -convert xml1 -o /dev/null "$spec" \
    || fail "browser runtime release spec is not valid JSON"
/usr/bin/plutil -convert xml1 -o /dev/null "$manifest" \
    || fail "runtime manifest is not valid JSON"

json_value() {
    /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null \
        || fail "missing JSON field $2 in ${1:t}"
}

keys=(
    schema_version layout_version runtime_release
    components.node components.playwright components.playwright_core
    components.chromium components.chromium_revision
    upstream.playwright_chromium_revision upstream.chromium_commit
    source_artifacts.node_arm64.url source_artifacts.node_arm64.sha256
    source_artifacts.node_x86_64.url source_artifacts.node_x86_64.sha256
    source_artifacts.playwright.url source_artifacts.playwright.sha256
    source_artifacts.playwright_core.url source_artifacts.playwright_core.sha256
    source_artifacts.chromium_arm64.url source_artifacts.chromium_arm64.sha256
    source_artifacts.chromium_x86_64.url source_artifacts.chromium_x86_64.sha256
    source_artifacts.chromium_license.url source_artifacts.chromium_license.sha256
    source_artifacts.chromium_license.decoded_sha256
)
for key in $keys; do
    [[ "$(json_value "$manifest" "$key")" == "$(json_value "$spec" "$key")" ]] \
        || fail "runtime manifest $key does not match the release spec"
done
[[ "$(json_value "$manifest" architecture)" == "$expected_architecture" ]] \
    || fail "runtime manifest architecture does not match $expected_architecture"

required_files=(
    bin/node
    node_modules/playwright/package.json
    node_modules/playwright-core/package.json
    chromium/Chromium.app/Contents/MacOS/Chromium
    ThirdPartyNotices/runtime.spdx.json
    ThirdPartyNotices/LICENSES.txt
    ThirdPartyNotices/licenses/Node-LICENSE.txt
    ThirdPartyNotices/licenses/Playwright-LICENSE.txt
    ThirdPartyNotices/licenses/Chromium-LICENSE.txt
    ThirdPartyNotices/licenses/Chromium-ThirdParty-Credits.html
)
for relative_path in $required_files; do
    [[ -f "$runtime_root/$relative_path" && ! -L "$runtime_root/$relative_path" ]] \
        || fail "runtime is missing required regular file $relative_path"
done
[[ -x "$runtime_root/bin/node" ]] || fail "bundled Node.js is not executable"
[[ -x "$runtime_root/chromium/Chromium.app/Contents/MacOS/Chromium" ]] \
    || fail "bundled Chromium is not executable"
[[ -s "$runtime_root/ThirdPartyNotices/LICENSES.txt" \
    && -s "$runtime_root/ThirdPartyNotices/licenses/Chromium-ThirdParty-Credits.html" ]] \
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
[[ "$spdx_package_count" == "4" ]] \
    || fail "runtime SBOM must contain the four fixed distribution packages"

while IFS= read -r link; do
    resolved="$(/bin/realpath "$link")" || fail "runtime symlink cannot be resolved: $link"
    case "$resolved" in
        "$runtime_root"/*) ;;
        *) fail "runtime symlink escapes its architecture root: $link" ;;
    esac
done < <(/usr/bin/find "$runtime_root" -type l -print)

temporary_root="$(/usr/bin/mktemp -d /private/tmp/translatis-browser-runtime-validation.XXXXXX)"
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
    print -r -- "${line[67,-1]}" >> "$inventory_paths"
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

if [[ -n "$expected_signing_identity" ]]; then
    typeset -a jit_code_paths
    jit_code_paths=(
        "$runtime_root/bin/node"
        "$runtime_root/chromium/Chromium.app"
    )
    while IFS= read -r helper_app; do
        jit_code_paths+=("$helper_app")
    done < <(/usr/bin/find \
        "$runtime_root/chromium/Chromium.app/Contents/Frameworks" \
        -type d -name 'Chromium Helper*.app' -print)
    [[ "${#jit_code_paths[@]}" -ge 3 ]] \
        || fail "browser runtime has no signed Chromium helper bundles"
    entitlement_index=0
    for jit_code_path in $jit_code_paths; do
        entitlement_index=$((entitlement_index + 1))
        entitlement_plist="$temporary_root/jit-entitlements-$entitlement_index.plist"
        /usr/bin/codesign --display \
            --entitlements "$entitlement_plist" --xml "$jit_code_path" \
            >/dev/null 2>&1 \
            || fail "could not read browser JIT entitlements: $jit_code_path"
        /usr/bin/plutil -lint "$entitlement_plist" >/dev/null \
            || fail "browser JIT entitlements are not a valid plist: $jit_code_path"
        for entitlement_key in \
            com.apple.security.cs.allow-jit \
            com.apple.security.cs.allow-unsigned-executable-memory \
            com.apple.security.cs.disable-library-validation; do
            /usr/bin/plutil -convert json -o - "$entitlement_plist" \
                | /usr/bin/jq -e --arg key "$entitlement_key" '.[$key] == true' \
                    >/dev/null \
                || fail "browser runtime is missing required JIT entitlement $entitlement_key: $jit_code_path"
        done
    done
fi

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
        && "$runtime_root" == "$sealed_app/Contents/Resources/BrowserRuntime/$expected_architecture" ]] \
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
            CFFIXED_USER_HOME="$temporary_root/home" \
            TMPDIR="$temporary_root/tmp/" \
            PATH=/usr/bin:/bin \
            LANG=C LC_ALL=C \
            /usr/bin/arch -"$expected_architecture" "$@"
    }
    node_version="$(run_for_architecture "$runtime_root/bin/node" --version)" \
        || fail "bundled Node.js version probe failed"
    [[ "$node_version" == "v24.20.0" ]] \
        || fail "bundled Node.js version does not match the release spec"
    package_versions="$(
        run_for_architecture "$runtime_root/bin/node" -e \
            'const root=process.argv[1]; console.log(require(root+"/node_modules/playwright/package.json").version+"\n"+require(root+"/node_modules/playwright-core/package.json").version)' \
            "$runtime_root"
    )" || fail "bundled Playwright package probe failed"
    [[ "$package_versions" == $'1.56.1\n1.56.1' ]] \
        || fail "bundled Playwright versions do not match the release spec"
    chromium_version="$(
        run_for_architecture \
            "$runtime_root/chromium/Chromium.app/Contents/MacOS/Chromium" --version
    )" || fail "bundled Chromium version probe failed"
    [[ "$chromium_version" == *"141.0.7390.37"* ]] \
        || fail "bundled Chromium version does not match the release spec"
    browser_smoke="$(
        run_for_architecture "$runtime_root/bin/node" -e '
          const root = process.argv[1];
          const { chromium } = require(root + "/node_modules/playwright");
          (async () => {
            let browser;
            try {
              browser = await chromium.launch({
                executablePath: root + "/chromium/Chromium.app/Contents/MacOS/Chromium",
                headless: true,
                args: ["--disable-breakpad", "--disable-crashpad-for-testing"]
              });
              const page = await browser.newPage();
              await page.setContent("<!doctype html><title>Translatis browser runtime</title><main>closed</main>");
              const result = [await page.title(), await page.textContent("main")].join("|");
              console.log(result);
            } finally {
              if (browser) await browser.close();
            }
          })().catch((error) => {
            console.error(error && error.stack ? error.stack : String(error));
            process.exit(1);
          });
        ' "$runtime_root"
    )" || fail "bundled Playwright/Chromium launch smoke failed"
    [[ "$browser_smoke" == "Translatis browser runtime|closed" ]] \
        || fail "bundled Playwright/Chromium launch smoke returned unexpected output"
fi

print -- "Validated browser runtime $expected_architecture ($validation_mode) at $runtime_root"
