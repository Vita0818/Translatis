#!/bin/zsh

set -euo pipefail
setopt typesetsilent

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_root="$(cd "$script_dir/.." && pwd -P)"
contract_root="$project_root/Packages/IntatisTools/Runtime/document-runtime"
spec="$contract_root/release-spec.json"
requirements_lock=""
architecture="${1:-}"
destination="${2:-}"
cache_root="${TRANSLATIS_RUNTIME_CACHE:-$project_root/.translatis/runtime-build/cache}"
uv_executable="${TRANSLATIS_UV_EXECUTABLE:-$(command -v uv || true)}"
tesseract_components_root="${TRANSLATIS_TESSERACT_COMPONENTS_ROOT:-$project_root/.translatis/runtime-build/components/tesseract}"
work_root=""
mounted_libreoffice=""
final_destination=""
staging_destination=""
build_completed=0
preserve_failed_build="${TRANSLATIS_PRESERVE_FAILED_RUNTIME:-0}"

fail() {
    print -u2 -- "error: $*"
    exit 1
}

cleanup() {
    if [[ -n "${mounted_libreoffice:-}" && -d "$mounted_libreoffice" ]]; then
        /usr/bin/hdiutil detach "$mounted_libreoffice" >/dev/null 2>&1 || true
    fi
    if [[ "$build_completed" != "1" && "$preserve_failed_build" == "1" ]]; then
        [[ -z "${work_root:-}" ]] \
            || print -u2 -- "Preserved failed document work root: $work_root"
        [[ -z "${staging_destination:-}" ]] \
            || print -u2 -- "Preserved failed document staging root: $staging_destination"
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
    || fail "usage: scripts/build-document-runtime.sh <arm64|x86_64> <absolute-destination-root>"
[[ "$destination" == /* ]] || fail "destination must be an absolute path"
[[ ! -e "$destination" && ! -L "$destination" ]] \
    || fail "destination already exists: $destination"
final_destination="$destination"
staging_destination="$final_destination.building.$$"
[[ ! -e "$staging_destination" && ! -L "$staging_destination" ]] \
    || fail "staging destination already exists: $staging_destination"
destination="$staging_destination"
[[ -f "$spec" && ! -L "$spec" ]] \
    || fail "document runtime release spec is missing"
[[ -x "$uv_executable" ]] || fail "the fixed document build requires uv"

json_value() {
    /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null \
        || fail "missing JSON field $2 in ${1:t}"
}

uv_version="$("$uv_executable" --version | /usr/bin/awk '{print $2}')"
[[ "$uv_version" == "$(json_value "$spec" build_tools.uv)" ]] \
    || fail "document runtime build requires the exact uv version from the release spec"

download_artifact() {
    local key="$1"
    local filename="$2"
    local artifact="$cache_root/document/$filename"
    local expected_sha="$(json_value "$spec" "source_artifacts.$key.sha256")"
    [[ "$expected_sha" =~ '^[0-9a-f]{64}$' ]] \
        || fail "release spec has no final SHA-256 for $key"
    if [[ ! -f "$artifact" ]]; then
        [[ -f "$artifact.partial" ]] || : > "$artifact.partial"
        while ! /usr/bin/curl --http1.1 -fL -C - \
            --connect-timeout 30 --max-time 600 \
            -o "$artifact.partial" \
            "$(json_value "$spec" "source_artifacts.$key.url")"; do
            print -u2 -- "resuming fixed document artifact $key"
        done
        /bin/mv "$artifact.partial" "$artifact"
    fi
    local actual_sha
    actual_sha="$(/usr/bin/shasum -a 256 "$artifact" | /usr/bin/awk '{print $1}')"
    [[ "$actual_sha" == "$expected_sha" ]] \
        || fail "document artifact $key does not match the release spec"
    REPLY="$artifact"
}

download_priority_wheel() {
    local key="$1"
    local filename="$(json_value "$spec" "source_artifacts.$key.filename")"
    local wheelhouse="$cache_root/document/wheels/$architecture"
    local artifact="$wheelhouse/$filename"
    local expected_sha="$(json_value "$spec" "source_artifacts.$key.sha256")"
    [[ "$expected_sha" =~ '^[0-9a-f]{64}$' ]] \
        || fail "release spec has no final SHA-256 for $key"
    /bin/mkdir -p "$wheelhouse"
    if [[ ! -f "$artifact" ]]; then
        [[ -f "$artifact.partial" ]] || : > "$artifact.partial"
        while ! /usr/bin/curl --http1.1 -fL -C - \
            --connect-timeout 30 --max-time 600 \
            -o "$artifact.partial" \
            "$(json_value "$spec" "source_artifacts.$key.url")"; do
            print -u2 -- "resuming fixed document wheel $key"
        done
        /bin/mv "$artifact.partial" "$artifact"
    fi
    [[ ! -L "$artifact" ]] || fail "document wheel must not be a symlink: $artifact"
    local actual_sha
    actual_sha="$(/usr/bin/shasum -a 256 "$artifact" | /usr/bin/awk '{print $1}')"
    [[ "$actual_sha" == "$expected_sha" ]] \
        || fail "document wheel $key does not match the release spec"
    REPLY="$artifact"
}

/bin/mkdir -p "$cache_root/document"
cache_root="$(cd "$cache_root" && pwd -P)"
download_artifact python_universal2_pkg python-3.11.9-macos11.pkg
python_package="$REPLY"
download_artifact tectonic_source tectonic-0.15.0-source.tar.gz
tectonic_source="$REPLY"
download_artifact tesseract_source tesseract-5.5.3.tar.gz
download_artifact leptonica_source leptonica-1.87.0.tar.gz
download_artifact libpng_source libpng-1.6.58.tar.xz
download_artifact docling_parse_sdist docling_parse-7.8.1.tar.gz
download_artifact heron_config heron-config.json
heron_config="$REPLY"
download_artifact heron_model heron-model.safetensors
heron_model="$REPLY"
download_artifact heron_preprocessor_config heron-preprocessor_config.json
heron_preprocessor="$REPLY"
download_artifact heron_model_card heron-README.md
heron_model_card="$REPLY"
download_artifact tessdata_eng eng.traineddata
tessdata_eng="$REPLY"
download_artifact tessdata_license tessdata-fast-4.1.0-LICENSE
tessdata_license="$REPLY"

case "$architecture" in
    arm64)
        target_platform="aarch64-apple-darwin"
        tectonic_key="tectonic_arm64"
        tectonic_filename="tectonic-0.15.0-aarch64-apple-darwin.tar.gz"
        libreoffice_key="libreoffice_arm64"
        libreoffice_filename="LibreOfficeDev_26.8.0.0.beta1_MacOS_aarch64.dmg"
        priority_wheel_keys=(
            numpy_arm64_wheel
            scipy_arm64_wheel
            opencv_python_arm64_wheel
            rapidocr_wheel
            torch_arm64_wheel
            transformers_wheel
        )
        ;;
    x86_64)
        target_platform="x86_64-apple-darwin"
        tectonic_key="tectonic_x86_64"
        tectonic_filename="tectonic-0.15.0-x86_64-apple-darwin.tar.gz"
        libreoffice_key="libreoffice_x86_64"
        libreoffice_filename="LibreOfficeDev_26.8.0.0.beta1_MacOS_x86-64.dmg"
        priority_wheel_keys=(
            numpy_x86_64_wheel
            scipy_x86_64_wheel
            opencv_python_x86_64_wheel
            rapidocr_wheel
            torch_x86_64_wheel
            transformers_wheel
        )
        ;;
esac
download_artifact "$tectonic_key" "$tectonic_filename"
tectonic_archive="$REPLY"
download_artifact "$libreoffice_key" "$libreoffice_filename"
libreoffice_dmg="$REPLY"

typeset -a priority_wheels
priority_wheels=()
for priority_wheel_key in "${priority_wheel_keys[@]}"; do
    download_priority_wheel "$priority_wheel_key"
    priority_wheels+=("$REPLY")
done

tectonic_cache="$cache_root/document/tectonic-cache-2026.08.27.1.zip"
[[ -f "$tectonic_cache" && ! -L "$tectonic_cache" ]] \
    || fail "the fixed generated Tectonic offline cache is missing"
[[ "$(/usr/bin/shasum -a 256 "$tectonic_cache" | /usr/bin/awk '{print $1}')" \
    == "$(json_value "$spec" source_artifacts.tectonic_offline_cache.sha256)" ]] \
    || fail "the generated Tectonic offline cache does not match the release spec"

requirements_lock="$contract_root/python-lock-$architecture.txt"
[[ -f "$requirements_lock" && ! -L "$requirements_lock" ]] \
    || fail "the $architecture Python wheel lock is missing"

    work_root="$(/usr/bin/mktemp -d /private/tmp/translatis-document-runtime-build.XXXXXX)"
/bin/chmod 0700 "$work_root"
/bin/mkdir -p "$work_root/tectonic" \
    "$work_root/tectonic-source" "$work_root/tectonic-cache" \
    "$work_root/libreoffice-mount"

/usr/sbin/pkgutil --expand-full "$python_package" "$work_root/python-package"
python_version_source="$work_root/python-package/Python_Framework.pkg/Payload/Versions/3.11"
[[ -d "$python_version_source" && ! -L "$python_version_source" ]] \
    || fail "official Python package has no 3.11 framework payload"

/bin/mkdir -p \
    "$destination/bin" \
    "$destination/python/Python.framework/Versions" \
    "$destination/models/docling/docling-project--docling-layout-heron" \
    "$destination/share/tessdata" \
    "$destination/share/tectonic" \
    "$destination/libreoffice/26.8.0.0.beta1" \
    "$destination/ThirdPartyNotices/licenses/Python" \
    "$destination/ThirdPartyNotices/licenses/Python-wheels" \
    "$destination/ThirdPartyNotices/licenses/Tectonic" \
    "$destination/ThirdPartyNotices/licenses/LibreOffice" \
    "$destination/ThirdPartyNotices/licenses/Docling-Heron"

/usr/bin/ditto "$python_version_source" \
    "$destination/python/Python.framework/Versions/3.11"
python_framework="$destination/python/Python.framework"
python_version="$python_framework/Versions/3.11"
/bin/rm -rf -- "$python_version/_CodeSignature"
/bin/rm -rf -- "$python_version/lib/python3.11/site-packages"
/bin/mkdir -p "$python_version/lib/python3.11/site-packages"
if [[ "$architecture" == "arm64" ]]; then
    /bin/rm -f -- \
        "$python_version/bin/python3.11-intel64" \
        "$python_version/bin/python3-intel64"
fi
/bin/ln -s 3.11 "$python_framework/Versions/Current"
/bin/ln -s Versions/Current/Python "$python_framework/Python"
/bin/ln -s Versions/Current/Headers "$python_framework/Headers"
/bin/ln -s Versions/Current/Resources "$python_framework/Resources"
/bin/cp -p "$python_version/bin/python3.11" "$destination/bin/python3"
/bin/chmod 0755 "$destination/bin/python3"

/usr/bin/tar -xzf "$tectonic_archive" -C "$work_root/tectonic"
[[ -x "$work_root/tectonic/tectonic" ]] \
    || fail "Tectonic archive does not contain the fixed executable"
/bin/cp -p "$work_root/tectonic/tectonic" "$destination/bin/tectonic"
/bin/chmod 0755 "$destination/bin/tectonic"
/usr/bin/tar -xzf "$tectonic_source" -C "$work_root/tectonic-source"
tectonic_license="$(/usr/bin/find "$work_root/tectonic-source" -maxdepth 2 \
    -type f -name LICENSE -print -quit)"
[[ -n "$tectonic_license" ]] || fail "Tectonic source license is missing"
/bin/cp -p "$tectonic_license" \
    "$destination/ThirdPartyNotices/licenses/Tectonic/LICENSE"
/usr/bin/ditto -x -k "$tectonic_cache" "$work_root/tectonic-cache"
[[ -d "$work_root/tectonic-cache/tectonic-cache" ]] \
    || fail "Tectonic cache archive has an unexpected layout"
/usr/bin/ditto "$work_root/tectonic-cache/tectonic-cache" \
    "$destination/share/tectonic/cache"

tesseract_component="$tesseract_components_root/$architecture"
[[ -d "$tesseract_component" && ! -L "$tesseract_component" ]] \
    || fail "the fixed $architecture Tesseract component is missing"
tesseract_binary="$tesseract_component/bin/tesseract"
[[ -x "$tesseract_binary" && ! -L "$tesseract_binary" ]] \
    || fail "the fixed $architecture Tesseract executable is missing"
[[ "$(/usr/bin/shasum -a 256 "$tesseract_binary" | /usr/bin/awk '{print $1}')" \
    == "$(json_value "$spec" "component_artifacts.tesseract.${architecture}_binary_sha256")" ]] \
    || fail "the fixed $architecture Tesseract executable hash is wrong"
for license_check in \
    'tesseract-5.5.3-LICENSE.txt|tesseract_license_sha256' \
    'leptonica-1.87.0-LICENSE.txt|leptonica_license_sha256' \
    'libpng-1.6.58-LICENSE.txt|libpng_license_sha256'; do
    license_name="${license_check%%|*}"
    license_key="${license_check#*|}"
    license_path="$tesseract_component/licenses/$license_name"
    [[ -f "$license_path" && ! -L "$license_path" ]] \
        || fail "the fixed Tesseract component license is missing: $license_name"
    [[ "$(/usr/bin/shasum -a 256 "$license_path" | /usr/bin/awk '{print $1}')" \
        == "$(json_value "$spec" "component_artifacts.tesseract.$license_key")" ]] \
        || fail "the fixed Tesseract component license hash is wrong: $license_name"
done
[[ "$(/usr/bin/lipo -archs "$tesseract_binary")" == "$architecture" ]] \
    || fail "the fixed Tesseract component has the wrong architecture"
while IFS= read -r dependency; do
    case "$dependency" in
        /System/Library/*|/usr/lib/*) ;;
        *) fail "the fixed Tesseract component has a non-system dependency: $dependency" ;;
    esac
done < <(/usr/bin/otool -L "$tesseract_binary" | /usr/bin/awk 'NR > 1 { print $1 }')
/usr/bin/ditto "$tesseract_component" "$work_root/tesseract"
/bin/cp -p "$work_root/tesseract/bin/tesseract" "$destination/bin/tesseract"
/bin/chmod 0755 "$destination/bin/tesseract"
/usr/bin/ditto "$work_root/tesseract/licenses" \
    "$destination/ThirdPartyNotices/licenses/Tesseract-build"

/bin/cp -p "$heron_config" \
    "$destination/models/docling/docling-project--docling-layout-heron/config.json"
/bin/cp -p "$heron_model" \
    "$destination/models/docling/docling-project--docling-layout-heron/model.safetensors"
/bin/cp -p "$heron_preprocessor" \
    "$destination/models/docling/docling-project--docling-layout-heron/preprocessor_config.json"
/bin/cp -p "$heron_model_card" \
    "$destination/ThirdPartyNotices/licenses/Docling-Heron/MODEL-CARD.md"
/bin/cp -p "$work_root/tesseract/licenses/tesseract-5.5.3-LICENSE.txt" \
    "$destination/ThirdPartyNotices/licenses/Docling-Heron/Apache-2.0.txt"
/bin/cp -p "$tessdata_eng" "$destination/share/tessdata/eng.traineddata"
/bin/cp -p "$tessdata_license" \
    "$destination/ThirdPartyNotices/licenses/tessdata-fast-4.1.0-LICENSE"

/bin/cp -p "$work_root/python-package/Resources/License.rtf" \
    "$destination/ThirdPartyNotices/licenses/Python/Installer-License.rtf"
/bin/cp -p "$python_version/lib/python3.11/LICENSE.txt" \
    "$destination/ThirdPartyNotices/licenses/Python/Standard-Library-LICENSE.txt"

mounted_libreoffice="$work_root/libreoffice-mount"
/usr/bin/hdiutil attach \
    -nobrowse -readonly -mountpoint "$mounted_libreoffice" \
    "$libreoffice_dmg" >/dev/null
libreoffice_source="$(/usr/bin/find "$mounted_libreoffice" -maxdepth 2 \
    -type d -name 'LibreOffice*.app' -print -quit)"
[[ -n "$libreoffice_source" && -d "$libreoffice_source" ]] \
    || fail "LibreOffice DMG contains no application bundle"
/usr/bin/ditto "$libreoffice_source" \
    "$destination/libreoffice/26.8.0.0.beta1/LibreOffice.app"
libreoffice_license_count=0
while IFS= read -r license_file; do
    relative_path="${license_file#$libreoffice_source/}"
    # License files can live below a real upstream code-bundle directory. Keep
    # their relative provenance without creating an incomplete directory whose
    # name makes codesign treat the notice copy as loadable code.
    for code_bundle_suffix in .app .framework .xpc .appex .bundle; do
        relative_path="${relative_path//$code_bundle_suffix/$code_bundle_suffix-licenses}"
    done
    license_destination="$destination/ThirdPartyNotices/licenses/LibreOffice/$relative_path"
    /bin/mkdir -p "${license_destination:h}"
    /bin/cp -p "$license_file" "$license_destination"
    libreoffice_license_count=$((libreoffice_license_count + 1))
done < <(/usr/bin/find "$libreoffice_source" -type f \
    \( -iname 'LICENSE*' -o -iname 'NOTICE*' -o -iname 'CREDITS*' \
       -o -iname 'COPYING*' \) -print)
[[ "$libreoffice_license_count" -gt 0 ]] \
    || fail "LibreOffice bundle has no discoverable license inventory"
/usr/bin/hdiutil detach "$mounted_libreoffice" >/dev/null
mounted_libreoffice=""

site_packages="$python_version/lib/python3.11/site-packages"
typeset -a find_links_arguments
find_links_arguments=()
wheelhouse="$cache_root/document/wheels/$architecture"
if [[ -d "$wheelhouse" && ! -L "$wheelhouse" ]]; then
    find_links_arguments=(--find-links "$wheelhouse")
fi
if [[ "$architecture" == "x86_64" ]]; then
    docling_parse_wheel="$wheelhouse/$(json_value "$spec" source_artifacts.docling_parse_x86_64_wheel.filename)"
    [[ -f "$docling_parse_wheel" && ! -L "$docling_parse_wheel" ]] \
        || fail "the fixed x86_64 docling-parse wheel is missing"
    [[ "$(/usr/bin/shasum -a 256 "$docling_parse_wheel" | /usr/bin/awk '{print $1}')" \
        == "$(json_value "$spec" source_artifacts.docling_parse_x86_64_wheel.sha256)" ]] \
        || fail "the fixed x86_64 docling-parse wheel does not match the release spec"
    priority_wheels+=("$docling_parse_wheel")
fi
MACOSX_DEPLOYMENT_TARGET=14.0 "$uv_executable" pip install \
    --target "$site_packages" \
    --python-version 3.11.9 \
    --python-platform "$target_platform" \
    --offline \
    --no-index \
    --no-deps \
    --no-compile-bytecode \
    --cache-dir "$cache_root/uv" \
    "${priority_wheels[@]}"
MACOSX_DEPLOYMENT_TARGET=14.0 "$uv_executable" pip install \
    --target "$site_packages" \
    --python-version 3.11.9 \
    --python-platform "$target_platform" \
    --require-hashes \
    --only-binary :all: \
    --no-compile-bytecode \
    --cache-dir "$cache_root/uv" \
    $find_links_arguments \
    -r "$requirements_lock"

thin_macho_tree() {
    local root="$1"
    while IFS= read -r candidate; do
        [[ "$(/usr/bin/file -b "$candidate")" == *"Mach-O"* ]] || continue
        local architectures mode temporary
        architectures="$(/usr/bin/lipo -archs "$candidate")" \
            || fail "could not inspect Mach-O architectures: $candidate"
        [[ " $architectures " == *" $architecture "* ]] \
            || fail "runtime Mach-O does not contain $architecture: $candidate"
        if [[ "$architectures" == *" "* ]]; then
            mode="$(/usr/bin/stat -f '%Lp' "$candidate")"
            temporary="$candidate.translatis-thin.$$"
            /usr/bin/lipo "$candidate" -thin "$architecture" -output "$temporary"
            /bin/chmod "$mode" "$temporary"
            /bin/mv "$temporary" "$candidate"
        fi
        /usr/bin/codesign --remove-signature "$candidate" >/dev/null 2>&1 || true
    done < <(/usr/bin/find "$root" -type f \
        \( -perm -111 -o -name '*.so' -o -name '*.dylib*' \
           -o -name '*.jnilib' -o -name '*.bundle' -o -name '*.a' \
           -o -name '*.o' \) -print)
}

thin_macho_tree "$destination"

macho_inspection_index=0
while IFS= read -r candidate; do
    [[ "$(/usr/bin/file -b "$candidate")" == *"Mach-O"* ]] || continue
    inspection_candidate="$candidate"
    if [[ "$candidate" == *'('* || "$candidate" == *')'* ]]; then
        macho_inspection_index=$((macho_inspection_index + 1))
        inspection_candidate="$work_root/macho-inspection-$macho_inspection_index"
        /bin/ln -sf "$candidate" "$inspection_candidate"
    fi
    linked_libraries="$(/usr/bin/otool -L "$inspection_candidate")" \
        || fail "could not inspect Mach-O dependencies: $candidate"
    while IFS= read -r dependency; do
        case "$dependency" in
            /Library/Frameworks/Python.framework/Versions/3.11/*)
                suffix="${dependency#/Library/Frameworks/Python.framework/Versions/3.11/}"
                target="$python_version/$suffix"
                [[ -e "$target" || -L "$target" ]] \
                    || fail "Python dependency target is absent: $dependency"
                relative="$(/usr/bin/python3 -c \
                    'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' \
                    "$target" "${candidate:h}")"
                /usr/bin/install_name_tool \
                    -change "$dependency" "@loader_path/$relative" "$candidate"
                ;;
        esac
    done < <(print -r -- "$linked_libraries" | /usr/bin/awk 'NR > 1 { print $1 }')
    load_commands="$(/usr/bin/otool -l "$inspection_candidate")" \
        || fail "could not inspect Mach-O load commands: $candidate"
    while IFS= read -r runtime_search_path; do
        [[ -n "$runtime_search_path" ]] || continue
        case "$runtime_search_path" in
            /System/Library/*|/usr/lib/*|@loader_path*|@executable_path*)
                ;;
            *)
                /usr/bin/install_name_tool \
                    -delete_rpath "$runtime_search_path" "$candidate" \
                    >/dev/null 2>&1 \
                    || fail "could not remove non-bundle LC_RPATH from $candidate: $runtime_search_path"
                ;;
        esac
    done < <(print -r -- "$load_commands" | /usr/bin/awk '
        $1 == "cmd" && $2 == "LC_RPATH" { awaiting_path = 1; next }
        awaiting_path && $1 == "path" { print $2; awaiting_path = 0 }
    ')
done < <(/usr/bin/find "$destination" -type f \
    \( -perm -111 -o -name '*.so' -o -name '*.dylib*' \
       -o -name '*.jnilib' -o -name '*.bundle' -o -name '*.a' \
       -o -name '*.o' \) -print)

# lipo and install_name_tool invalidate the upstream signatures. Apple Silicon
# refuses to map modified unsigned native modules, so give only the Python
# smoke-test surface temporary ad-hoc signatures. Do not enable Hardened
# Runtime here: ad-hoc code has no Team ID, and library validation would reject
# the separately signed framework/extensions. App packaging replaces these
# signatures bottom-up with the selected local or Developer ID policy.
while IFS= read -r candidate; do
    file_description="$(/usr/bin/file -b "$candidate")"
    case "$file_description" in
        *Mach-O*executable*|*Mach-O*'dynamically linked shared library'*|*Mach-O*bundle*)
            /usr/bin/codesign --force --sign - --timestamp=none \
                "$candidate" >/dev/null 2>&1 \
                || fail "could not ad-hoc sign Python smoke dependency: $candidate"
            ;;
    esac
done < <(/usr/bin/find "$destination/bin" "$destination/python" -depth -type f \
    \( -perm -111 -o -name '*.so' -o -name '*.dylib*' \
       -o -name '*.jnilib' -o -name '*.bundle' \) -print)

run_python_for_architecture() {
    /usr/bin/env -i \
        HOME="$work_root/home" \
        TMPDIR="$work_root/tmp/" \
        PATH=/usr/bin:/bin \
        LANG=C LC_ALL=C \
        PYTHONHOME="$python_version" \
        PYTHONNOUSERSITE=1 \
        PYTHONDONTWRITEBYTECODE=1 \
        /usr/bin/arch -"$architecture" "$destination/bin/python3" -I -B "$@"
}
/bin/mkdir -p "$work_root/home" "$work_root/tmp"
/bin/chmod 0700 "$work_root/home" "$work_root/tmp"
for python_module in \
    docling docling_parse lxml.etree numpy pypdfium2 torch torchvision; do
    run_python_for_architecture -c \
        "import importlib; importlib.import_module('$python_module')" \
        || fail "fixed Python document dependency import failed: $python_module"
done

wheel_packages="$work_root/python-wheel-packages.json"
run_python_for_architecture \
    "$project_root/scripts/document-runtime-python-metadata.py" \
    --format spdx-packages > "$wheel_packages"
{
    print -- $'Component\tVersion\tDeclared license'
    print -- $'CPython\t3.11.9\tPSF-2.0 AND LicenseRef-Python-Bundled'
    print -- $'Tesseract\t5.5.3\tApache-2.0'
    print -- $'Leptonica\t1.87.0\tBSD-2-Clause'
    print -- $'libpng\t1.6.58\tLibpng-2.0'
    print -- $'tessdata_fast eng\t4.1.0\tApache-2.0'
    print -- $'Tectonic\t0.15.0\tMIT'
    print -- $'Tectonic offline resource cache\t2026.08.27.1\tNOASSERTION'
    print -- $'LibreOfficeDev\t26.8.0.0.beta1\tMPL-2.0 AND LicenseRef-LibreOffice-Bundled'
    print -- $'docling-layout-heron\t8f39ad3c0b4c58e9c2d2c84a38465abf757272d8\tApache-2.0'
    run_python_for_architecture \
        "$project_root/scripts/document-runtime-python-metadata.py" \
        --format license-inventory
} > "$destination/ThirdPartyNotices/LICENSES.txt"

while IFS= read -r license_file; do
    relative_path="${license_file#$site_packages/}"
    distribution_root="${relative_path%%/*}"
    case "$distribution_root" in
        *.dist-info) ;;
        *) continue ;;
    esac
    license_destination="$destination/ThirdPartyNotices/licenses/Python-wheels/$relative_path"
    /bin/mkdir -p "${license_destination:h}"
    /bin/cp -p "$license_file" "$license_destination"
done < <(/usr/bin/find "$site_packages" -type f \
    \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) -print)
/bin/cp -p "$requirements_lock" \
    "$destination/ThirdPartyNotices/python-lock-$architecture.txt"

/usr/bin/jq -n \
    --arg architecture "$architecture" \
    --arg namespace "https://vitemis.com/spdx/translatis-document-runtime/2026.08.27.1/$architecture" \
    --slurpfile wheels "$wheel_packages" \
    '{
      spdxVersion: "SPDX-2.3",
      dataLicense: "CC0-1.0",
      SPDXID: "SPDXRef-DOCUMENT",
      name: ("Translatis Document Runtime 2026.08.27.1 " + $architecture),
      documentNamespace: $namespace,
      creationInfo: {
        created: "2026-08-27T00:00:00Z",
        creators: ["Tool: Translatis build-document-runtime.sh"]
      },
      packages: ([
        {name:"CPython",SPDXID:"SPDXRef-CPython",versionInfo:"3.11.9",downloadLocation:"https://www.python.org/ftp/python/3.11.9/",filesAnalyzed:false,licenseConcluded:"NOASSERTION",licenseDeclared:"PSF-2.0 AND LicenseRef-Python-Bundled",copyrightText:"NOASSERTION"},
        {name:"Tesseract",SPDXID:"SPDXRef-Tesseract",versionInfo:"5.5.3",downloadLocation:"https://github.com/tesseract-ocr/tesseract/releases/tag/5.5.3",filesAnalyzed:false,licenseConcluded:"NOASSERTION",licenseDeclared:"Apache-2.0",copyrightText:"NOASSERTION"},
        {name:"Leptonica",SPDXID:"SPDXRef-Leptonica",versionInfo:"1.87.0",downloadLocation:"https://github.com/DanBloomberg/leptonica/releases/tag/1.87.0",filesAnalyzed:false,licenseConcluded:"NOASSERTION",licenseDeclared:"BSD-2-Clause",copyrightText:"NOASSERTION"},
        {name:"libpng",SPDXID:"SPDXRef-libpng",versionInfo:"1.6.58",downloadLocation:"https://sourceforge.net/projects/libpng/files/libpng16/1.6.58/",filesAnalyzed:false,licenseConcluded:"NOASSERTION",licenseDeclared:"Libpng-2.0",copyrightText:"NOASSERTION"},
        {name:"tessdata_fast-eng",SPDXID:"SPDXRef-tessdata-fast-eng",versionInfo:"4.1.0",downloadLocation:"https://github.com/tesseract-ocr/tessdata_fast/tree/4.1.0",filesAnalyzed:false,licenseConcluded:"NOASSERTION",licenseDeclared:"Apache-2.0",copyrightText:"NOASSERTION"},
        {name:"Tectonic",SPDXID:"SPDXRef-Tectonic",versionInfo:"0.15.0",downloadLocation:"https://github.com/tectonic-typesetting/tectonic/releases/tag/tectonic%400.15.0",filesAnalyzed:false,licenseConcluded:"NOASSERTION",licenseDeclared:"MIT",copyrightText:"NOASSERTION"},
        {name:"Tectonic-offline-resource-cache",SPDXID:"SPDXRef-Tectonic-cache",versionInfo:"2026.08.27.1",downloadLocation:"NOASSERTION",filesAnalyzed:false,licenseConcluded:"NOASSERTION",licenseDeclared:"NOASSERTION",copyrightText:"NOASSERTION"},
        {name:"LibreOfficeDev",SPDXID:"SPDXRef-LibreOfficeDev",versionInfo:"26.8.0.0.beta1",downloadLocation:"https://downloadarchive.documentfoundation.org/libreoffice/old/26.8.0.0.beta1/",filesAnalyzed:false,licenseConcluded:"NOASSERTION",licenseDeclared:"MPL-2.0 AND LicenseRef-LibreOffice-Bundled",copyrightText:"NOASSERTION"},
        {name:"docling-layout-heron",SPDXID:"SPDXRef-docling-layout-heron",versionInfo:"8f39ad3c0b4c58e9c2d2c84a38465abf757272d8",downloadLocation:"https://huggingface.co/docling-project/docling-layout-heron/commit/8f39ad3c0b4c58e9c2d2c84a38465abf757272d8",filesAnalyzed:false,licenseConcluded:"NOASSERTION",licenseDeclared:"Apache-2.0",copyrightText:"NOASSERTION"}
      ] + $wheels[0]),
      hasExtractedLicensingInfos: [
        {licenseId:"LicenseRef-Python-Bundled",name:"CPython macOS installer bundled licenses",extractedText:"See ThirdPartyNotices/licenses/Python in this runtime root."},
        {licenseId:"LicenseRef-LibreOffice-Bundled",name:"LibreOffice bundled notices",extractedText:"See ThirdPartyNotices/licenses/LibreOffice in this runtime root."}
      ]
    }' > "$destination/ThirdPartyNotices/runtime.spdx.json"

/usr/bin/jq \
    --arg architecture "$architecture" \
    --arg python_lock_sha256 "$(/usr/bin/shasum -a 256 "$requirements_lock" | /usr/bin/awk '{print $1}')" \
    '. + {architecture: $architecture, python_lock_sha256: $python_lock_sha256}' \
    "$spec" > "$destination/runtime-manifest.json"
(
    cd "$destination"
    /usr/bin/find . -type f ! -path './SHA256SUMS.txt' \
        -exec /usr/bin/shasum -a 256 {} + \
        | LC_ALL=C /usr/bin/sort \
        > SHA256SUMS.txt
)

"$project_root/scripts/validate-document-runtime.sh" \
    "$destination" "$architecture" "" static
/bin/mv "$destination" "$final_destination"
staging_destination=""
build_completed=1
print -- "Built fixed document runtime $architecture at $final_destination"
