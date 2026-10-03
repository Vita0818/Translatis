#!/bin/zsh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_root="$(cd "$script_dir/.." && pwd -P)"
output_dir="${TRANSLATIS_OUTPUT_DIR:-$project_root/dist}"
notary_profile="${TRANSLATIS_NOTARY_PROFILE:-}"
requested_identity="${TRANSLATIS_DEVELOPER_IDENTITY:-}"
pause_before_notarization="${TRANSLATIS_PAUSE_BEFORE_NOTARIZATION:-0}"
notary_timeout="${TRANSLATIS_NOTARY_TIMEOUT:-30m}"
resume_release_dir="${TRANSLATIS_RESUME_RELEASE_DIR:-}"
codex_runtime_arm64_root="${TRANSLATIS_CODEX_RUNTIME_ARM64_ROOT:-}"
codex_runtime_x86_64_root="${TRANSLATIS_CODEX_RUNTIME_X86_64_ROOT:-}"
document_runtime_arm64_root="${TRANSLATIS_DOCUMENT_RUNTIME_ARM64_ROOT:-}"
document_runtime_x86_64_root="${TRANSLATIS_DOCUMENT_RUNTIME_X86_64_ROOT:-}"
browser_runtime_arm64_root="${TRANSLATIS_BROWSER_RUNTIME_ARM64_ROOT:-}"
browser_runtime_x86_64_root="${TRANSLATIS_BROWSER_RUNTIME_X86_64_ROOT:-}"
recovery_parent="$project_root/.translatis/release-recovery"
work_root=""
recovery_dir=""
state_file=""
staged_app=""
version=""
build_number=""
preserve_recovery=0

umask 077

print_resume_instructions() {
    [[ -n "${recovery_dir:-}" ]] || return 0
    print -u2 -- "Release recovery data is preserved at:"
    print -u2 -- "  $recovery_dir"
    if [[ ! -f "${state_file:-}" || ! -d "${staged_app:-}" ]]; then
        print -u2 -- "The preserved directory did not pass recovery validation; inspect it before retrying."
        return 0
    fi
    print -u2 -- "Resume the same Apple submissions on an Apple-reachable network with:"
    print -u2 -- \
        "  TRANSLATIS_NOTARY_PROFILE=\"$notary_profile\" TRANSLATIS_RESUME_RELEASE_DIR=\"$recovery_dir\" scripts/package-macos-release.sh"
}

fail() {
    print -u2 -- "error: $*"
    if [[ "${preserve_recovery:-0}" == "1" ]]; then
        print_resume_instructions
    fi
    exit 1
}

cleanup() {
    if [[ -n "${work_root:-}" && -d "$work_root" ]]; then
        /bin/rm -rf -- "$work_root"
    fi
    if [[ "${preserve_recovery:-0}" == "0" && -n "${recovery_dir:-}" \
        && -d "$recovery_dir" ]]; then
        /bin/rm -rf -- "$recovery_dir"
    fi
}

interrupt_release() {
    if [[ -n "${recovery_dir:-}" && -f "${state_file:-}" \
        && -d "${staged_app:-}" ]]; then
        preserve_recovery=1
        print -u2 -- ""
        print -u2 -- "Release interrupted; the signed artifacts were not deleted."
        print_resume_instructions
    fi
    exit 130
}

terminate_release() {
    if [[ -n "${recovery_dir:-}" && -f "${state_file:-}" \
        && -d "${staged_app:-}" ]]; then
        preserve_recovery=1
        print -u2 -- ""
        print -u2 -- "Release terminated; the signed artifacts were not deleted."
        print_resume_instructions
    fi
    exit 143
}

trap cleanup EXIT
trap interrupt_release INT
trap terminate_release TERM

state_get() {
    local key="$1"
    [[ -f "$state_file" ]] || return 1
    /usr/bin/plutil -extract "$key" raw -o - "$state_file" 2>/dev/null
}

state_set_string() {
    local key="$1"
    local value="$2"
    local next_state="$recovery_dir/.state.$$.plist"
    /bin/cp -p "$state_file" "$next_state"
    if /usr/bin/plutil -extract "$key" raw -o - "$next_state" >/dev/null 2>&1; then
        /usr/bin/plutil -replace "$key" -string "$value" "$next_state"
    else
        /usr/bin/plutil -insert "$key" -string "$value" "$next_state"
    fi
    /bin/chmod 0600 "$next_state"
    /bin/mv -f "$next_state" "$state_file"
}

initialize_state() {
    local initial_state="$recovery_dir/.state.initial.$$.plist"
    /usr/bin/plutil -create xml1 "$initial_state"
    /usr/bin/plutil -insert schemaVersion -integer 1 "$initial_state"
    /usr/bin/plutil -insert version -string "$version" "$initial_state"
    /usr/bin/plutil -insert buildNumber -string "$build_number" "$initial_state"
    /usr/bin/plutil -insert stage -string "appReady" "$initial_state"
    /bin/chmod 0600 "$initial_state"
    /bin/mv -f "$initial_state" "$state_file"
}

prepare_recovery_parent() {
    local metadata_root="$project_root/.translatis"
    [[ ! -L "$metadata_root" ]] \
        || fail "the Translatis metadata directory must not be a symlink"
    /bin/mkdir -p "$recovery_parent"
    [[ ! -L "$recovery_parent" ]] || fail "release recovery root must not be a symlink"
    local canonical_recovery_parent
    canonical_recovery_parent="$(cd "$recovery_parent" && pwd -P)"
    [[ "$canonical_recovery_parent" == "$project_root/.translatis/release-recovery" ]] \
        || fail "release recovery root must remain inside the canonical Translatis project root"
    /bin/chmod 0700 "$canonical_recovery_parent"
    recovery_parent="$canonical_recovery_parent"
}

load_recovery_directory() {
    prepare_recovery_parent
    [[ "$resume_release_dir" == /* ]] \
        || fail "TRANSLATIS_RESUME_RELEASE_DIR must be an absolute path"
    [[ -d "$resume_release_dir" && ! -L "$resume_release_dir" ]] \
        || fail "release recovery directory is missing or is a symlink"

    local canonical_resume
    canonical_resume="$(cd "$resume_release_dir" && pwd -P)"
    case "$canonical_resume" in
        "$recovery_parent"/*)
            ;;
        *)
            fail "release recovery directory is outside the Translatis recovery root"
            ;;
    esac

    local owner mode state_owner state_mode state_links app_owner
    owner="$(/usr/bin/stat -f '%u' "$canonical_resume")"
    mode="$(/usr/bin/stat -f '%Lp' "$canonical_resume")"
    [[ "$owner" == "$(/usr/bin/id -u)" ]] \
        || fail "release recovery directory is not owned by the current user"
    [[ "$mode" == "700" ]] || fail "release recovery directory must have mode 0700"

    recovery_dir="$canonical_resume"
    state_file="$recovery_dir/state.plist"
    staged_app="$recovery_dir/Translatis.app"
    preserve_recovery=1
    [[ -f "$state_file" && ! -L "$state_file" ]] \
        || fail "release recovery state is missing or unsafe"
    [[ -d "$staged_app" && ! -L "$staged_app" ]] \
        || fail "recovery directory does not contain a safe staged Translatis.app"
    state_owner="$(/usr/bin/stat -f '%u' "$state_file")"
    state_mode="$(/usr/bin/stat -f '%Lp' "$state_file")"
    state_links="$(/usr/bin/stat -f '%l' "$state_file")"
    app_owner="$(/usr/bin/stat -f '%u' "$staged_app")"
    [[ "$state_owner" == "$(/usr/bin/id -u)" && "$state_mode" == "600" \
        && "$state_links" == "1" ]] \
        || fail "release recovery state must be owner-only, single-link, and mode 0600"
    [[ "$app_owner" == "$(/usr/bin/id -u)" ]] \
        || fail "staged Translatis.app is not owned by the current user"
    /usr/bin/plutil -lint "$state_file" >/dev/null
    [[ "$(state_get schemaVersion)" == "1" ]] \
        || fail "unsupported release recovery state schema"
}

create_recovery_directory() {
    local source_app="$1"
    prepare_recovery_parent
    recovery_dir="$(/usr/bin/mktemp -d \
        "$recovery_parent/Translatis-${version}-${build_number}.XXXXXX")"
    /bin/chmod 0700 "$recovery_dir"
    state_file="$recovery_dir/state.plist"
    staged_app="$recovery_dir/Translatis.app"
    /usr/bin/ditto "$source_app" "$staged_app"
    initialize_state
    preserve_recovery=1
    print -- "Signed release recovery data created at:"
    print -- "  $recovery_dir"
}

inspect_release_app() {
    local app="$1"
    [[ -d "$app" ]] || fail "Release App is missing: $app"
    local executable="$app/Contents/MacOS/TranslatisMac"
    [[ -f "$executable" ]] || fail "Release executable is missing"

    local architectures
    architectures="$(/usr/bin/lipo -archs "$executable")"
    [[ " $architectures " == *" arm64 "* ]] || fail "Release executable is missing arm64"
    [[ " $architectures " == *" x86_64 "* ]] || fail "Release executable is missing x86_64"

    version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
        "$app/Contents/Info.plist")"
    build_number="$(/usr/bin/plutil -extract CFBundleVersion raw -o - \
        "$app/Contents/Info.plist")"
    [[ -n "$version" && -n "$build_number" ]] || fail "Release bundle has invalid version metadata"
    [[ "$version" != *[^A-Za-z0-9._-]* ]] \
        || fail "Release version contains unsafe filename characters"
    [[ "$build_number" != *[^A-Za-z0-9._-]* ]] \
        || fail "Release build number contains unsafe filename characters"

    local runtime_name runtime_bundle
    for runtime_name in CodexRuntime DocumentRuntime BrowserRuntime; do
        runtime_bundle="$app/Contents/Resources/$runtime_name"
        for architecture in arm64 x86_64; do
            [[ -f "$runtime_bundle/$architecture/runtime-manifest.json" ]] \
                || fail "Release App is missing $runtime_name/$architecture"
        done
    done
}

validate_codex_runtime() {
    local root="$1"
    local architecture="$2"
    local identity="$3"
    local validation_mode="${4:-static}"
    "$project_root/scripts/validate-codex-runtime.sh" \
        "$root" "$architecture" "$identity" "$validation_mode"
}

validate_document_runtime() {
    local root="$1"
    local architecture="$2"
    local identity="$3"
    local validation_mode="${4:-static}"
    "$project_root/scripts/validate-document-runtime.sh" \
        "$root" "$architecture" "$identity" "$validation_mode"
}

validate_browser_runtime() {
    local root="$1"
    local architecture="$2"
    local identity="$3"
    local validation_mode="${4:-static}"
    "$project_root/scripts/validate-browser-runtime.sh" \
        "$root" "$architecture" "$identity" "$validation_mode"
}

stage_runtime_pair() {
    local app="$1"
    local resource_name="$2"
    local validator="$3"
    local arm64_root="$4"
    local x86_64_root="$5"
    local arm64_variable="$6"
    local x86_64_variable="$7"
    [[ -n "$arm64_root" && -n "$x86_64_root" ]] \
        || fail "$arm64_variable and $x86_64_variable are required"

    "$validator" "$arm64_root" arm64 "" static
    "$validator" "$x86_64_root" x86_64 "" static

    local destination="$app/Contents/Resources/$resource_name"
    [[ ! -e "$destination" && ! -L "$destination" ]] \
        || fail "Release build unexpectedly already contains $resource_name"
    /bin/mkdir -p "$destination/arm64" "$destination/x86_64"
    /usr/bin/ditto "$arm64_root" "$destination/arm64"
    /usr/bin/ditto "$x86_64_root" "$destination/x86_64"

    "$validator" "$destination/arm64" arm64 "" static
    "$validator" "$destination/x86_64" x86_64 "" static
}

stage_all_runtimes() {
    local app="$1"
    stage_runtime_pair \
        "$app" CodexRuntime validate_codex_runtime \
        "$codex_runtime_arm64_root" "$codex_runtime_x86_64_root" \
        TRANSLATIS_CODEX_RUNTIME_ARM64_ROOT TRANSLATIS_CODEX_RUNTIME_X86_64_ROOT
    stage_runtime_pair \
        "$app" DocumentRuntime validate_document_runtime \
        "$document_runtime_arm64_root" "$document_runtime_x86_64_root" \
        TRANSLATIS_DOCUMENT_RUNTIME_ARM64_ROOT TRANSLATIS_DOCUMENT_RUNTIME_X86_64_ROOT
    stage_runtime_pair \
        "$app" BrowserRuntime validate_browser_runtime \
        "$browser_runtime_arm64_root" "$browser_runtime_x86_64_root" \
        TRANSLATIS_BROWSER_RUNTIME_ARM64_ROOT TRANSLATIS_BROWSER_RUNTIME_X86_64_ROOT
}

sign_staged_runtime_path() {
    local code_path="$1"
    typeset -a preserve entitlement_arguments
    preserve=()
    entitlement_arguments=()
    case "$code_path" in
        */Contents/Resources/BrowserRuntime/*/bin/node|\
        */Contents/Resources/BrowserRuntime/*/chromium/Chromium.app|\
        */Contents/Resources/BrowserRuntime/*/chromium/Chromium.app/Contents/MacOS/Chromium|\
        */Contents/Resources/BrowserRuntime/*/chromium/Chromium.app/Contents/Frameworks/*/Helpers/Chromium\ Helper*.app|\
        */Contents/Resources/BrowserRuntime/*/chromium/Chromium.app/Contents/Frameworks/*/Helpers/Chromium\ Helper*.app/Contents/MacOS/*)
            entitlement_arguments=(--entitlements "$browser_runtime_entitlements")
            ;;
    esac
    if /usr/bin/codesign -d "$code_path" >/dev/null 2>&1; then
        if (( ${#entitlement_arguments[@]} > 0 )); then
            preserve=(--preserve-metadata=requirements,identifier)
        else
            preserve=(--preserve-metadata=entitlements,requirements,identifier)
        fi
    fi
    /usr/bin/codesign \
        --force \
        --sign "$signing_identity" \
        --options runtime \
        --timestamp \
        $entitlement_arguments \
        $preserve \
        "$code_path"
}

is_bundle_main_executable() {
    local candidate="$1"
    local bundle=""
    local info_plist=""
    local executable_name=""

    case "$candidate" in
        */Contents/MacOS/*)
            bundle="${candidate:h:h:h}"
            case "$bundle" in
                *.app|*.xpc|*.appex)
                    info_plist="$bundle/Contents/Info.plist"
                    executable_name="$(
                        /usr/bin/plutil -extract CFBundleExecutable raw -o - \
                            "$info_plist" 2>/dev/null || true
                    )"
                    [[ -n "$executable_name" \
                        && "$candidate" == "$bundle/Contents/MacOS/$executable_name" ]] \
                        && return 0
                    ;;
            esac
            ;;
    esac

    local version_root="${candidate:h}"
    local versions_directory="${version_root:h}"
    local framework="${versions_directory:h}"
    if [[ "${versions_directory:t}" == "Versions" && "$framework" == *.framework ]]; then
        info_plist="$version_root/Resources/Info.plist"
        executable_name="$(
            /usr/bin/plutil -extract CFBundleExecutable raw -o - \
                "$info_plist" 2>/dev/null || true
        )"
        [[ -n "$executable_name" && "${candidate:t}" == "$executable_name" ]] \
            && return 0
    fi
    return 1
}

sign_staged_runtime_code() {
    local app="$1"
    local resources="$app/Contents/Resources"
    local runtime_root candidate bundle
    for runtime_root in \
        "$resources/CodexRuntime" \
        "$resources/DocumentRuntime" \
        "$resources/BrowserRuntime"; do
        while IFS= read -r candidate; do
            file_description="$(/usr/bin/file -b "$candidate")"
            case "$file_description" in
                *Mach-O*executable*|*Mach-O*'dynamically linked shared library'*|*Mach-O*bundle*)
                    is_bundle_main_executable "$candidate" && continue
                    sign_staged_runtime_path "$candidate"
                    ;;
            esac
        done < <(/usr/bin/find "$runtime_root" -type f \
            \( -perm -111 -o -name '*.so' -o -name '*.dylib*' \
               -o -name '*.jnilib' -o -name '*.bundle' -o -name '*.a' \
               -o -name '*.o' \) -print)
    done
    for runtime_root in \
        "$resources/CodexRuntime" \
        "$resources/DocumentRuntime" \
        "$resources/BrowserRuntime"; do
        while IFS= read -r bundle; do
            sign_staged_runtime_path "$bundle"
        done < <(/usr/bin/find "$runtime_root" -depth -type d \
            \( -name '*.app' -o -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \) \
            -print)
    done
}

refresh_staged_runtime_integrity() {
    local app="$1"
    local resources="$app/Contents/Resources"
    local architecture codex_root next_manifest runtime_root
    for architecture in arm64 x86_64; do
        codex_root="$resources/CodexRuntime/$architecture"
        next_manifest="$codex_root/.runtime-manifest.$$.json"
        /usr/bin/jq \
            --arg binary_sha256 "$(/usr/bin/shasum -a 256 "$codex_root/codex" | /usr/bin/awk '{print $1}')" \
            '.binary_sha256 = $binary_sha256' \
            "$codex_root/runtime-manifest.json" > "$next_manifest"
        /bin/mv "$next_manifest" "$codex_root/runtime-manifest.json"
    done
    for runtime_root in \
        "$resources/CodexRuntime/arm64" \
        "$resources/CodexRuntime/x86_64" \
        "$resources/DocumentRuntime/arm64" \
        "$resources/DocumentRuntime/x86_64" \
        "$resources/BrowserRuntime/arm64" \
        "$resources/BrowserRuntime/x86_64"; do
        (
            cd "$runtime_root"
            /usr/bin/find . -type f ! -path './SHA256SUMS.txt' \
                -exec /usr/bin/shasum -a 256 {} + \
                | LC_ALL=C /usr/bin/sort \
                > SHA256SUMS.txt
        )
    done
}

validate_staged_runtimes() {
    local app="$1"
    local validation_mode="${2:-static}"
    local architecture
    for architecture in arm64 x86_64; do
        validate_codex_runtime \
            "$app/Contents/Resources/CodexRuntime/$architecture" \
            "$architecture" "$signing_identity" "$validation_mode"
        validate_document_runtime \
            "$app/Contents/Resources/DocumentRuntime/$architecture" \
            "$architecture" "$signing_identity" "$validation_mode"
        validate_browser_runtime \
            "$app/Contents/Resources/BrowserRuntime/$architecture" \
            "$architecture" "$signing_identity" "$validation_mode"
    done
}

require_current_project_version() {
    local canonical_version canonical_build_number
    canonical_version="$(/usr/bin/awk -F'"' \
        '/^[[:space:]]*MARKETING_VERSION:/ { print $2; exit }' "$project_root/project.yml")"
    canonical_build_number="$(/usr/bin/awk -F'"' \
        '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$project_root/project.yml")"
    [[ "$version" == "$canonical_version" ]] \
        || fail "built app version $version does not match project.yml $canonical_version"
    [[ "$build_number" == "$canonical_build_number" ]] \
        || fail "built app build number $build_number does not match project.yml $canonical_build_number"
}

verify_signed_release_app() {
    local app="$1"
    /usr/bin/codesign --verify --deep --strict --verbose=4 "$app"
    local signature_info
    signature_info="$(/usr/bin/codesign -dv --verbose=4 "$app" 2>&1)"
    [[ "$signature_info" == *"Authority=Developer ID Application:"* ]] \
        || fail "signed bundle is not anchored by a Developer ID Application identity"
    [[ "$signature_info" == *"runtime"* ]] || fail "signed bundle is missing Hardened Runtime"
    [[ "$signature_info" != *"TeamIdentifier=not set"* ]] || fail "signed bundle has no TeamIdentifier"

    local signed_entitlements="$work_root/signed-entitlements.plist"
    /usr/bin/codesign --display --entitlements "$signed_entitlements" --xml "$app" \
        >/dev/null 2>&1
    /usr/bin/plutil -lint "$signed_entitlements" >/dev/null
    if /usr/bin/plutil -convert json -o - "$signed_entitlements" \
        | /usr/bin/jq -e '.["com.apple.security.app-sandbox"] == true' \
            >/dev/null; then
        fail "signed Developer ID bundle unexpectedly enables the App Sandbox"
    fi
}

is_submission_id() {
    print -r -- "$1" | /usr/bin/grep -Eq \
        '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
}

extract_submission_id() {
    local log_path="$1"
    [[ -f "$log_path" ]] || return 0
    /usr/bin/sed -nE \
        's/.*([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}).*/\1/p' \
        "$log_path" | /usr/bin/tail -n 1
}

submit_artifact_if_needed() {
    local artifact="$1"
    local slug="$2"
    local display_name="$3"
    local state_key="$4"
    local submitted_stage="$5"
    local submit_log="$recovery_dir/$slug-submit.log"
    local submission_id=""

    submission_id="$(state_get "$state_key" || true)"
    if [[ -z "$submission_id" ]]; then
        if [[ -e "$submit_log" || -L "$submit_log" ]]; then
            validate_recovery_artifact "$submit_log" "$display_name submit log"
            local recovered_id
            recovered_id="$(extract_submission_id "$submit_log")"
            if [[ -n "$recovered_id" ]] && is_submission_id "$recovered_id"; then
                submission_id="$recovered_id"
                state_set_string "$state_key" "$submission_id"
                state_set_string stage "$submitted_stage"
                print -- "Recovered the existing $display_name submission from its upload log."
            else
                fail "a prior $display_name submit attempt exists without a reliable submission ID; inspect notarytool history before any new upload"
            fi
        fi
    fi

    if [[ -z "$submission_id" ]]; then
        print -- "Uploading $display_name to Apple; upload progress will remain visible..."
        local submit_completed=0
        if /usr/bin/xcrun notarytool submit "$artifact" \
            --keychain-profile "$notary_profile" \
            --no-wait \
            --progress 2>&1 | /usr/bin/tee "$submit_log"; then
            submit_completed=1
        fi

        submission_id="$(extract_submission_id "$submit_log")"
        [[ -n "$submission_id" ]] && is_submission_id "$submission_id" \
            || fail "Apple did not return a valid submission ID for $display_name"
        state_set_string "$state_key" "$submission_id"
        state_set_string stage "$submitted_stage"
        print -- "$display_name submission ID: $submission_id"

        if [[ "$submit_completed" != "1" ]]; then
            print -u2 -- \
                "warning: notarytool reported an upload error after returning a submission ID; checking Apple status before deciding whether to retry"
        fi
    else
        is_submission_id "$submission_id" \
            || fail "recovery state contains an invalid $display_name submission ID"
        print -- "Reusing existing $display_name submission ID: $submission_id"
    fi

    REPLY="$submission_id"
}

wait_for_submission() {
    local submission_id="$1"
    local slug="$2"
    local display_name="$3"
    local accepted_stage="$4"
    local info_path="$recovery_dir/$slug-notary-info.json"

    print -- "Waiting up to $notary_timeout for $display_name processing."
    print -- "Apple will keep processing after this local wait times out."
    if ! /usr/bin/xcrun notarytool wait "$submission_id" \
        --keychain-profile "$notary_profile" \
        --timeout "$notary_timeout"; then
        print -u2 -- "warning: the live wait ended before a final result; querying Apple once more"
    fi

    if ! /usr/bin/xcrun notarytool info "$submission_id" \
        --keychain-profile "$notary_profile" \
        --output-format json > "$info_path"; then
        fail "could not query Apple for $display_name submission status; no new upload was made"
    fi
    local status
    status="$(/usr/bin/plutil -extract status raw -o - "$info_path" 2>/dev/null || true)"
    [[ -n "$status" ]] \
        || fail "Apple returned an unreadable $display_name submission status"

    case "$status" in
        Accepted)
            state_set_string stage "$accepted_stage"
            print -- "$display_name notarization status: Accepted"
            ;;
        "In Progress")
            preserve_recovery=1
            print -u2 -- ""
            print -u2 -- "$display_name is still In Progress at Apple."
            print -u2 -- "No new upload is needed; the signed artifacts and submission ID are preserved."
            print_resume_instructions
            exit 75
            ;;
        Invalid)
            local log_path="$recovery_dir/$slug-notary-log.json"
            /usr/bin/xcrun notarytool log "$submission_id" "$log_path" \
                --keychain-profile "$notary_profile" >/dev/null 2>&1 || true
            fail "$display_name notarization status is Invalid; Apple log saved at $log_path"
            ;;
        *)
            fail "$display_name notarization returned unexpected status: $status"
            ;;
    esac
}

pause_for_notarization_network_if_requested() {
    [[ "$pause_before_notarization" == "1" ]] || return 0

    local probe_result="$work_root/notary-connectivity.json"
    print -- "Build and Developer ID signing are complete."
    print -- "Keep this terminal open, then switch to a network that can reach Apple notarization."
    print -- "GitHub is no longer used after this point."
    print -n -- "Press Return after turning off the VPN/proxy path that blocks Apple: "
    IFS= read -r _

    until /usr/bin/xcrun notarytool history \
        --keychain-profile "$notary_profile" \
        --output-format json > "$probe_result"; do
        print -u2 -- "Apple notarization is still unreachable."
        print -u2 -- "Adjust the network and press Return to retry; the signed build remains staged."
        print -n -- "Press Return to retry (or Control-C to preserve and exit): "
        IFS= read -r _
    done

    print -- "Apple notarization connectivity verified; continuing without rebuilding."
}

validate_recovery_artifact() {
    local path="$1"
    local label="$2"
    [[ -f "$path" && ! -L "$path" ]] \
        || fail "$label in the recovery directory is missing or unsafe"
    local owner links
    owner="$(/usr/bin/stat -f '%u' "$path")"
    links="$(/usr/bin/stat -f '%l' "$path")"
    [[ "$owner" == "$(/usr/bin/id -u)" && "$links" == "1" ]] \
        || fail "$label in the recovery directory must be current-user owned and single-link"
}

create_app_zip_if_missing() {
    local source_app="$1"
    local destination="$2"
    local label="$3"
    if [[ -e "$destination" || -L "$destination" ]]; then
        validate_recovery_artifact "$destination" "$label"
        return 0
    fi

    local staging_dir staged_archive
    staging_dir="$(/usr/bin/mktemp -d "$recovery_dir/.archive.XXXXXX")"
    /bin/chmod 0700 "$staging_dir"
    staged_archive="$staging_dir/${destination:t}"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$source_app" "$staged_archive"
    /bin/chmod 0600 "$staged_archive"
    /bin/mv "$staged_archive" "$destination"
    /bin/rmdir "$staging_dir"
    validate_recovery_artifact "$destination" "$label"
}

[[ -n "$notary_profile" ]] || fail \
    "TRANSLATIS_NOTARY_PROFILE is required and must name a notarytool Keychain profile"

case "$pause_before_notarization" in
    0|1)
        ;;
    *)
        fail "TRANSLATIS_PAUSE_BEFORE_NOTARIZATION must be 0 or 1"
        ;;
esac

if ! print -r -- "$notary_timeout" | /usr/bin/grep -Eq '^[1-9][0-9]*(s|m|h)?$'; then
    fail "TRANSLATIS_NOTARY_TIMEOUT must be a positive duration such as 30m or 2h"
fi

if [[ -z "$resume_release_dir" && "$pause_before_notarization" == "1" && ! -t 0 ]]; then
    fail "TRANSLATIS_PAUSE_BEFORE_NOTARIZATION=1 requires an interactive terminal"
fi

entitlements="$project_root/Apps/TranslatisMac/TranslatisMac.DeveloperID.entitlements"
browser_runtime_entitlements="$project_root/Apps/TranslatisMac/TranslatisBrowserRuntime.entitlements"
/usr/bin/plutil -lint "$entitlements" >/dev/null
/usr/bin/plutil -lint "$browser_runtime_entitlements" >/dev/null
if /usr/bin/plutil -convert json -o - "$entitlements" \
    | /usr/bin/jq -e '.["com.apple.security.app-sandbox"] == true' \
        >/dev/null; then
    fail "Developer ID entitlements unexpectedly enable the App Sandbox"
fi

identity_lines="$(
    /usr/bin/security find-identity -v -p codesigning \
        | /usr/bin/sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p'
)"

typeset -a identities
identities=()
while IFS= read -r identity; do
    [[ -n "$identity" ]] && identities+=("$identity")
done <<< "$identity_lines"

if [[ -n "$requested_identity" ]]; then
    if ! print -r -- "$identity_lines" | /usr/bin/grep -Fqx -- "$requested_identity"; then
        fail "TRANSLATIS_DEVELOPER_IDENTITY is not an available Developer ID Application identity"
    fi
    signing_identity="$requested_identity"
else
    case "${#identities[@]}" in
        0)
            fail "no valid Developer ID Application identity is available in the current Keychain"
            ;;
        1)
            signing_identity="${identities[1]}"
            ;;
        *)
            fail "multiple Developer ID Application identities are available; set TRANSLATIS_DEVELOPER_IDENTITY to one exact common name"
            ;;
    esac
fi

work_root="$(/usr/bin/mktemp -d /private/tmp/translatis-direct-release.XXXXXX)"

if [[ -n "$resume_release_dir" ]]; then
    load_recovery_directory
    expected_version="$(state_get version)"
    expected_build_number="$(state_get buildNumber)"
    [[ -n "$expected_version" && -n "$expected_build_number" ]] \
        || fail "release recovery state has no version metadata"

    "$project_root/scripts/check-version-consistency.sh"
    inspect_release_app "$staged_app"
    [[ "$version" == "$expected_version" ]] \
        || fail "recovery App version does not match its state"
    [[ "$build_number" == "$expected_build_number" ]] \
        || fail "recovery App build number does not match its state"
    require_current_project_version
    verify_signed_release_app "$staged_app"
    validate_staged_runtimes "$staged_app" execute
    print -- "Resuming preserved Translatis $version (build $build_number) release state."
else
    xcodegen_path="$(command -v xcodegen || true)"
    [[ -n "$xcodegen_path" ]] || fail "xcodegen is required"

    derived_data="$work_root/DerivedData"
    build_staging_root="$work_root/build-staging"
    build_staged_app="$build_staging_root/Translatis.app"
    /bin/mkdir -p "$build_staging_root"

    print -- "Generating Translatis.xcodeproj..."
    (
        cd "$project_root"
        "$xcodegen_path" generate
    )
    "$project_root/scripts/check-version-consistency.sh"

    print -- "Building the TranslatisMac universal Release target..."
    /usr/bin/xcodebuild -quiet \
        -project "$project_root/Translatis.xcodeproj" \
        -scheme TranslatisMac \
        -configuration Release \
        -destination 'platform=macOS' \
        -derivedDataPath "$derived_data" \
        ARCHS='arm64 x86_64' \
        ONLY_ACTIVE_ARCH=NO \
        COMPILER_INDEX_STORE_ENABLE=NO \
        CODE_SIGNING_ALLOWED=NO \
        build

    source_app="$derived_data/Build/Products/Release/TranslatisMac.app"
    [[ -d "$source_app" ]] || fail "Release build did not produce TranslatisMac.app"
    /usr/bin/ditto "$source_app" "$build_staged_app"
    stage_all_runtimes "$build_staged_app"
    inspect_release_app "$build_staged_app"
    require_current_project_version

    print -- "Signing fixed runtime closure with Developer ID and Hardened Runtime..."
    sign_staged_runtime_code "$build_staged_app"
    refresh_staged_runtime_integrity "$build_staged_app"

    print -- "Signing Translatis.app with Developer ID and Hardened Runtime..."
    /usr/bin/codesign \
        --force \
        --sign "$signing_identity" \
        --options runtime \
        --timestamp \
        --entitlements "$entitlements" \
        "$build_staged_app"
    verify_signed_release_app "$build_staged_app"
    validate_staged_runtimes "$build_staged_app" execute

    create_recovery_directory "$build_staged_app"
    inspect_release_app "$staged_app"
    require_current_project_version
    verify_signed_release_app "$staged_app"
    validate_staged_runtimes "$staged_app" execute
    pause_for_notarization_network_if_requested
fi

zip_name="Translatis-${version}-${build_number}-macOS-universal.zip"
dmg_name="Translatis-${version}-${build_number}-macOS-universal.dmg"
manifest_name="Translatis-${version}-${build_number}-SHA256SUMS.txt"
zip_path="$recovery_dir/$zip_name"
dmg_path="$recovery_dir/$dmg_name"
manifest_path="$recovery_dir/$manifest_name"

pre_notary_zip="$recovery_dir/Translatis-notary-upload.zip"
create_app_zip_if_missing "$staged_app" "$pre_notary_zip" "pre-notarization ZIP"

submit_artifact_if_needed \
    "$pre_notary_zip" \
    "app" \
    "signed App" \
    "appSubmissionID" \
    "appSubmitted"
app_submission_id="$REPLY"
wait_for_submission "$app_submission_id" "app" "signed App" "appAccepted"

/usr/bin/xcrun stapler staple "$staged_app"
/usr/bin/xcrun stapler validate "$staged_app"
/usr/bin/codesign --verify --deep --strict --verbose=4 "$staged_app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$staged_app"
state_set_string stage "appStapled"

create_app_zip_if_missing "$staged_app" "$zip_path" "release ZIP"

if [[ -e "$dmg_path" || -L "$dmg_path" ]]; then
    validate_recovery_artifact "$dmg_path" "release DMG"
else
    dmg_staging_root="$work_root/dmg-staging"
    /bin/mkdir -p "$dmg_staging_root"
    /usr/bin/ditto "$staged_app" "$dmg_staging_root/Translatis.app"
    /bin/ln -s /Applications "$dmg_staging_root/Applications"

    dmg_recovery_staging="$(/usr/bin/mktemp -d "$recovery_dir/.dmg.XXXXXX")"
    /bin/chmod 0700 "$dmg_recovery_staging"
    staged_dmg="$dmg_recovery_staging/$dmg_name"
    /usr/sbin/diskutil image create from \
        --format UDZO \
        --volumeName "Translatis $version" \
        "$dmg_staging_root" \
        "$staged_dmg" >/dev/null

    print -- "Signing the DMG with Developer ID..."
    /usr/bin/codesign \
        --force \
        --sign "$signing_identity" \
        --timestamp \
        "$staged_dmg"
    /bin/chmod 0600 "$staged_dmg"
    /bin/mv "$staged_dmg" "$dmg_path"
    /bin/rmdir "$dmg_recovery_staging"
    validate_recovery_artifact "$dmg_path" "release DMG"
fi
/usr/bin/codesign --verify --verbose=4 "$dmg_path"
state_set_string stage "dmgReady"

submit_artifact_if_needed \
    "$dmg_path" \
    "dmg" \
    "DMG" \
    "dmgSubmissionID" \
    "dmgSubmitted"
dmg_submission_id="$REPLY"
wait_for_submission "$dmg_submission_id" "dmg" "DMG" "dmgAccepted"

/usr/bin/xcrun stapler staple "$dmg_path"
/usr/bin/xcrun stapler validate "$dmg_path"
/usr/bin/codesign --verify --verbose=4 "$dmg_path"
/usr/sbin/spctl --assess \
    --type open \
    --context context:primary-signature \
    --verbose=4 \
    "$dmg_path"
state_set_string stage "dmgStapled"

(
    cd "$recovery_dir"
    /usr/bin/shasum -a 256 "$zip_name" "$dmg_name" > "$manifest_name"
)

/bin/mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
[[ ! -e "$output_dir/$zip_name" ]] || fail "output already exists: $output_dir/$zip_name"
[[ ! -e "$output_dir/$dmg_name" ]] || fail "output already exists: $output_dir/$dmg_name"
[[ ! -e "$output_dir/$manifest_name" ]] || fail "output already exists: $output_dir/$manifest_name"

/usr/bin/ditto "$zip_path" "$output_dir/$zip_name"
/usr/bin/ditto "$dmg_path" "$output_dir/$dmg_name"
/usr/bin/ditto "$manifest_path" "$output_dir/$manifest_name"
/bin/chmod 0644 \
    "$output_dir/$zip_name" \
    "$output_dir/$dmg_name" \
    "$output_dir/$manifest_name"

state_set_string stage "complete"
preserve_recovery=0

print -- "Release artifacts are ready:"
print -- "  $output_dir/$zip_name"
print -- "  $output_dir/$dmg_name"
print -- "  $output_dir/$manifest_name"
