#!/bin/zsh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_root="$(cd "$script_dir/.." && pwd -P)"
kit_root="${1:-$project_root/.translatis/runtime-kit/0.66}"

fail() {
    print -u2 -- "error: $*"
    exit 1
}

[[ "$kit_root" == /* ]] || fail "runtime kit root must be an absolute path"
[[ -d "$kit_root" && ! -L "$kit_root" ]] \
    || fail "runtime kit root is missing or is a symlink"
kit_root="$(cd "$kit_root" && pwd -P)"

manifest="$kit_root/runtime-kit.json"
[[ -f "$manifest" && ! -L "$manifest" ]] \
    || fail "runtime kit manifest is missing or unsafe"
/usr/bin/jq -e '
    .schema_version == 1
    and .product_version == "0.66"
    and .runtime_release == "2026.08.27.1"
    and .architectures == ["arm64", "x86_64"]
    and .selection == {
        rule: "active-architecture-only",
        fallback: "forbidden"
    }
    and .layout == {
        codex: "CodexRuntime/{architecture}",
        document: "DocumentRuntime/{architecture}",
        browser: "BrowserRuntime/{architecture}"
    }
    and .distribution == {
        developer_id_signed: false,
        notarized: false,
        intended_use: "local-development-integration"
    }
' "$manifest" >/dev/null \
    || fail "runtime kit manifest does not match the fixed 0.66 contract"

for resource_name in CodexRuntime DocumentRuntime BrowserRuntime; do
    resource_root="$kit_root/$resource_name"
    [[ -d "$resource_root" && ! -L "$resource_root" ]] \
        || fail "$resource_name root is missing or unsafe"
done

for architecture in arm64 x86_64; do
    "$project_root/scripts/validate-codex-runtime.sh" \
        "$kit_root/CodexRuntime/$architecture" "$architecture" "" static
    "$project_root/scripts/validate-document-runtime.sh" \
        "$kit_root/DocumentRuntime/$architecture" "$architecture" "" static
    "$project_root/scripts/validate-browser-runtime.sh" \
        "$kit_root/BrowserRuntime/$architecture" "$architecture" "" static
done

print -- "Validated Translatis runtime kit 0.66 at $kit_root"
