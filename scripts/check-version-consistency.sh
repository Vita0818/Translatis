#!/bin/zsh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_root="$(cd "$script_dir/.." && pwd -P)"
project_file="$project_root/project.yml"

fail() {
    print -u2 -- "error: $*"
    exit 1
}

yaml_quoted_value() {
    local key="$1"
    /usr/bin/awk -F'"' -v key="$key" \
        '$0 ~ "^[[:space:]]*" key ":[[:space:]]*\\\"" { print $2; exit }' \
        "$project_file"
}

require_marker() {
    local file="$1"
    local marker="$2"
    /usr/bin/grep -Fq -- "$marker" "$file" \
        || fail "$file does not declare the canonical version marker: $marker"
}

marketing_version="$(yaml_quoted_value MARKETING_VERSION)"
build_number="$(yaml_quoted_value CURRENT_PROJECT_VERSION)"

[[ "$marketing_version" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] \
    || fail "project.yml has an invalid MARKETING_VERSION"
[[ "$build_number" =~ '^[0-9]+$' ]] \
    || fail "project.yml has a non-numeric CURRENT_PROJECT_VERSION"

for plist in \
    "$project_root/Apps/TranslatisMac/Info.plist" \
    "$project_root/Apps/TranslatisiOS/Info.plist"; do
    plist_marketing="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$plist")"
    plist_build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$plist")"
    [[ "$plist_marketing" == "$marketing_version" ]] \
        || fail "$plist has CFBundleShortVersionString=$plist_marketing, expected $marketing_version"
    [[ "$plist_build" == "$build_number" ]] \
        || fail "$plist has CFBundleVersion=$plist_build, expected $build_number"
done

require_marker "$project_root/README.md" \
    "当前版本：**v${marketing_version}**（build ${build_number}）"
require_marker "$project_root/ARCHITECTURE.md" \
    "当前产品基线：v${marketing_version}（build ${build_number}）"
require_marker "$project_root/docs/README.md" \
    "当前产品基线：**v${marketing_version}**（build ${build_number}）"
require_marker "$project_root/docs/VERSIONING.md" \
    "产品版本：\`${marketing_version}\`"
require_marker "$project_root/docs/VERSIONING.md" \
    "构建号：\`${build_number}\`"

current_documents=(
    ARCHITECTURE.md
    CURRENT_STATE.md
    MACOS_DISTRIBUTION.md
    PROJECT_MAP.md
    DO_NOT_BREAK.md
    OPEN_SOURCE_REUSE.md
    TESTING.md
    COWORK_PRINCIPLES.md
    PER_AGENT_INFERENCE_PROFILES.md
    CURRENT_UI_COLOR_SYSTEM.md
    CHAT_HOSTED_SEARCH.md
)
for document in "${current_documents[@]}"; do
    require_marker "$project_root/docs/$document" \
        "产品基线：v${marketing_version}（build ${build_number}）"
done
if [[ -f "$project_root/docs/NEXT_TARGET.md" ]]; then
    require_marker "$project_root/docs/NEXT_TARGET.md" \
        "产品基线：v${marketing_version}（build ${build_number}）"
fi

generated_project="$project_root/Translatis.xcodeproj/project.pbxproj"
if [[ -f "$generated_project" ]]; then
    /usr/bin/grep -Fq -- "MARKETING_VERSION = $marketing_version;" "$generated_project" \
        || fail "generated Xcode project has a stale MARKETING_VERSION; run xcodegen generate"
    /usr/bin/grep -Fq -- "CURRENT_PROJECT_VERSION = $build_number;" "$generated_project" \
        || fail "generated Xcode project has a stale CURRENT_PROJECT_VERSION; run xcodegen generate"
fi

print -- "Translatis version is consistent: ${marketing_version} (build ${build_number})"
