#!/bin/zsh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_root="$(cd "$script_dir/.." && pwd -P)"
architecture="${1:-}"
destination="${2:-}"
cache_root="${TRANSLATIS_RUNTIME_CACHE:-$project_root/.translatis/runtime-build/cache}"
cmake_executable="${TRANSLATIS_CMAKE_EXECUTABLE:-/opt/homebrew/bin/cmake}"
work_root=""

fail() {
    print -u2 -- "error: $*"
    exit 1
}

cleanup() {
    if [[ -n "${work_root:-}" && -d "$work_root" ]]; then
        /bin/rm -rf -- "$work_root"
    fi
}
trap cleanup EXIT

[[ "$architecture" == "arm64" || "$architecture" == "x86_64" ]] \
    || fail "usage: scripts/build-tesseract-component.sh <arm64|x86_64> <absolute-destination-root>"
[[ "$destination" == /* ]] || fail "destination must be an absolute path"
[[ ! -e "$destination" && ! -L "$destination" ]] \
    || fail "destination already exists: $destination"

typeset -A urls hashes
urls[libpng]='https://downloads.sourceforge.net/project/libpng/libpng16/1.6.58/libpng-1.6.58.tar.xz'
hashes[libpng]='28eb403f51f0f7405249132cecfe82ea5c0ef97f1b32c5a65828814ae0d34775'
urls[leptonica]='https://github.com/DanBloomberg/leptonica/releases/download/1.87.0/leptonica-1.87.0.tar.gz'
hashes[leptonica]='c73363397f96eb1295602bf44d708a994ad42046c791bf03ea0505d829bdb6a7'
urls[tesseract]='https://github.com/tesseract-ocr/tesseract/archive/refs/tags/5.5.3.tar.gz'
hashes[tesseract]='9218e62793116d42a9f6d14cd9348518b27f382096eea3d0f2d1a24616bb5884'

/bin/mkdir -p "$cache_root/document"
cache_root="$(cd "$cache_root" && pwd -P)"
download_source() {
    local key="$1"
    local filename="$2"
    local artifact="$cache_root/document/$filename"
    if [[ ! -f "$artifact" ]]; then
        /usr/bin/curl -fL --retry 12 --retry-all-errors --connect-timeout 30 \
            -o "$artifact.partial" "$urls[$key]"
        /bin/mv "$artifact.partial" "$artifact"
    fi
    actual_sha="$(/usr/bin/shasum -a 256 "$artifact" | /usr/bin/awk '{print $1}')"
    [[ "$actual_sha" == "$hashes[$key]" ]] \
        || fail "$key source archive SHA-256 does not match the fixed build contract"
    REPLY="$artifact"
}
download_source libpng libpng-1.6.58.tar.xz
libpng_archive="$REPLY"
download_source leptonica leptonica-1.87.0.tar.gz
leptonica_archive="$REPLY"
download_source tesseract tesseract-5.5.3.tar.gz
tesseract_archive="$REPLY"

    work_root="$(/usr/bin/mktemp -d /private/tmp/translatis-tesseract-build.XXXXXX)"
/bin/chmod 0700 "$work_root"
for component in libpng leptonica tesseract; do
    /bin/mkdir -p "$work_root/source/$component" "$work_root/build/$component"
done
/usr/bin/tar -xJf "$libpng_archive" --strip-components 1 -C "$work_root/source/libpng"
/usr/bin/tar -xzf "$leptonica_archive" --strip-components 1 -C "$work_root/source/leptonica"
/usr/bin/tar -xzf "$tesseract_archive" --strip-components 1 -C "$work_root/source/tesseract"
prefix="$work_root/prefix"

typeset -a toolchain_arguments
toolchain_arguments=()
typeset -a tesseract_cross_arguments
tesseract_cross_arguments=()
if [[ "$architecture" == "x86_64" ]]; then
    toolchain_file="$work_root/x86_64-apple-darwin.cmake"
    {
        print -- 'set(CMAKE_SYSTEM_NAME Darwin)'
        print -- 'set(CMAKE_SYSTEM_PROCESSOR x86_64)'
        print -- 'set(CMAKE_OSX_ARCHITECTURES x86_64)'
        print -- 'set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0)'
    } > "$toolchain_file"
    toolchain_arguments=(-DCMAKE_TOOLCHAIN_FILE="$toolchain_file")
    # The fixed Leptonica build deliberately excludes TIFF. CMake cannot run
    # its target-architecture probe while cross-compiling on Apple Silicon, so
    # freeze the same non-zero result produced by that official stub locally.
    tesseract_cross_arguments=(-DLEPT_TIFF_RESULT=1)
fi

common_cmake=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$prefix"
    -DCMAKE_OSX_ARCHITECTURES="$architecture"
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
    -DCMAKE_IGNORE_PREFIX_PATH='/opt/homebrew;/usr/local'
    -DBUILD_SHARED_LIBS=OFF
    $toolchain_arguments
)

"$cmake_executable" \
    -S "$work_root/source/libpng" \
    -B "$work_root/build/libpng" \
    $common_cmake \
    -DPNG_SHARED=OFF \
    -DPNG_STATIC=ON \
    -DPNG_FRAMEWORK=OFF \
    -DPNG_TESTS=OFF \
    -DPNG_TOOLS=OFF
"$cmake_executable" --build "$work_root/build/libpng" --parallel
"$cmake_executable" --install "$work_root/build/libpng"

"$cmake_executable" \
    -S "$work_root/source/leptonica" \
    -B "$work_root/build/leptonica" \
    $common_cmake \
    -DCMAKE_PREFIX_PATH="$prefix" \
    -DBUILD_PROG=OFF \
    -DENABLE_ZLIB=ON \
    -DENABLE_PNG=ON \
    -DENABLE_GIF=OFF \
    -DENABLE_JPEG=OFF \
    -DENABLE_TIFF=OFF \
    -DENABLE_WEBP=OFF \
    -DENABLE_OPENJPEG=OFF
"$cmake_executable" --build "$work_root/build/leptonica" --parallel
"$cmake_executable" --install "$work_root/build/leptonica"

"$cmake_executable" \
    -S "$work_root/source/tesseract" \
    -B "$work_root/build/tesseract" \
    $common_cmake \
    -DCMAKE_PREFIX_PATH="$prefix" \
    -DLeptonica_DIR="$prefix/lib/cmake/leptonica" \
    -DOPENMP_BUILD=OFF \
    -DGRAPHICS_DISABLED=ON \
    -DBUILD_TRAINING_TOOLS=OFF \
    -DBUILD_TESTS=OFF \
    -DDISABLE_TIFF=ON \
    -DDISABLE_ARCHIVE=ON \
    -DDISABLE_CURL=ON \
    -DINSTALL_CONFIGS=OFF \
    -DENABLE_CCACHE=OFF \
    $tesseract_cross_arguments
"$cmake_executable" --build "$work_root/build/tesseract" --parallel
"$cmake_executable" --install "$work_root/build/tesseract"

/bin/mkdir -p "$destination/bin" "$destination/licenses"
/bin/cp -p "$prefix/bin/tesseract" "$destination/bin/tesseract"
/bin/chmod 0755 "$destination/bin/tesseract"
/bin/cp -p "$work_root/source/libpng/LICENSE" "$destination/licenses/libpng-1.6.58-LICENSE.txt"
/bin/cp -p "$work_root/source/leptonica/leptonica-license.txt" "$destination/licenses/leptonica-1.87.0-LICENSE.txt"
/bin/cp -p "$work_root/source/tesseract/LICENSE" "$destination/licenses/tesseract-5.5.3-LICENSE.txt"

architectures="$(/usr/bin/lipo -archs "$destination/bin/tesseract")"
[[ " $architectures " == *" $architecture "* ]] \
    || fail "built Tesseract is missing $architecture"
linked_libraries="$(/usr/bin/otool -L "$destination/bin/tesseract")"
while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
        /System/Library/*|/usr/lib/*) ;;
        *) fail "built Tesseract has an external non-system dependency: $dependency" ;;
    esac
done < <(print -r -- "$linked_libraries" | /usr/bin/awk 'NR > 1 { print $1 }')
version_output="$(/usr/bin/arch -"$architecture" "$destination/bin/tesseract" --version 2>&1)"
[[ "${version_output%%$'\n'*}" == "tesseract 5.5.3" ]] \
    || fail "built Tesseract does not report version 5.5.3"

print -- "Built fixed static Tesseract component $architecture at $destination"
