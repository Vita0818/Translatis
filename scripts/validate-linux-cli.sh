#!/bin/sh
set -eu

# Reproducible cross-build gate for the shipped Linux CLI.
#
# Required inputs are explicit so this script never depends on one developer's
# home directory, Swiftly layout, or temporary installation path.
: "${TRANSLATIS_SWIFT_BIN:?set TRANSLATIS_SWIFT_BIN to the validated Swift executable}"
: "${TRANSLATIS_LINUX_SDKS_PATH:?set TRANSLATIS_LINUX_SDKS_PATH to the directory containing the validated artifact bundles}"
: "${TRANSLATIS_LINUX_SDK_AARCH64:?set TRANSLATIS_LINUX_SDK_AARCH64 to the aarch64-swift-linux-musl SDK selector}"
: "${TRANSLATIS_LINUX_SDK_X86_64:?set TRANSLATIS_LINUX_SDK_X86_64 to the x86_64-swift-linux-musl SDK selector}"
: "${TRANSLATIS_LINUX_VALIDATION_ROOT:?set TRANSLATIS_LINUX_VALIDATION_ROOT to an empty or reusable output directory}"

case "$TRANSLATIS_LINUX_VALIDATION_ROOT" in
    ""|"/"|"."|"..")
        echo "unsafe TRANSLATIS_LINUX_VALIDATION_ROOT" >&2
        exit 2
        ;;
esac

if [ ! -x "$TRANSLATIS_SWIFT_BIN" ]; then
    echo "TRANSLATIS_SWIFT_BIN is not executable" >&2
    exit 2
fi
if [ ! -d "$TRANSLATIS_LINUX_SDKS_PATH" ]; then
    echo "TRANSLATIS_LINUX_SDKS_PATH is not a directory" >&2
    exit 2
fi

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$TRANSLATIS_LINUX_VALIDATION_ROOT"

build_one() {
    architecture=$1
    target_triple=$2
    sdk_selector=$3
    if [ "$sdk_selector" != "$target_triple" ]; then
        echo "SDK selector must be the exact target triple: expected $target_triple, got $sdk_selector" >&2
        exit 2
    fi
    scratch="$TRANSLATIS_LINUX_VALIDATION_ROOT/$architecture"
    CLANG_MODULE_CACHE_PATH="$scratch/module-cache/clang"
    SWIFTPM_MODULECACHE_OVERRIDE="$scratch/module-cache/swiftpm"
    export CLANG_MODULE_CACHE_PATH SWIFTPM_MODULECACHE_OVERRIDE
    mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

    "$TRANSLATIS_SWIFT_BIN" build \
        --package-path "$repository_root" \
        --disable-sandbox \
        --swift-sdks-path "$TRANSLATIS_LINUX_SDKS_PATH" \
        --swift-sdk "$sdk_selector" \
        --triple "$target_triple" \
        --scratch-path "$scratch" \
        --product translatis

    binary_directory=$(
        "$TRANSLATIS_SWIFT_BIN" build \
            --package-path "$repository_root" \
            --disable-sandbox \
            --swift-sdks-path "$TRANSLATIS_LINUX_SDKS_PATH" \
            --swift-sdk "$sdk_selector" \
            --triple "$target_triple" \
            --scratch-path "$scratch" \
            --show-bin-path
    )
    binary="$binary_directory/translatis"
    if [ ! -f "$binary" ]; then
        echo "missing translatis product for $architecture" >&2
        exit 1
    fi

    file_output=$(file "$binary")
    case "$file_output" in
        *ELF*statically\ linked*|*ELF*static-pie\ linked*)
            ;;
        *)
            echo "expected a static ELF for $architecture: $file_output" >&2
            exit 1
            ;;
    esac
    case "$architecture:$file_output" in
        aarch64:*ARM\ aarch64*|aarch64:*aarch64*)
            ;;
        x86_64:*x86-64*|x86_64:*x86_64*)
            ;;
        *)
            echo "ELF architecture mismatch for $architecture: $file_output" >&2
            exit 1
            ;;
    esac

    digest=$(shasum -a 256 "$binary" | awk '{print $1}')
    echo "BUILT_STATIC_ELF architecture=$architecture sha256=$digest path=$binary"
}

build_one aarch64 aarch64-swift-linux-musl "$TRANSLATIS_LINUX_SDK_AARCH64"
build_one x86_64 x86_64-swift-linux-musl "$TRANSLATIS_LINUX_SDK_X86_64"

host_system=$(uname -s)
host_architecture=$(uname -m)
echo "RUNTIME_EXECUTION=NOT_RUN host=$host_system/$host_architecture reason=cross_build_gate_only"
echo "Linux execution, bwrap behavior, and endpoint integration require a matching Linux host and are not implied by successful static ELF generation."
