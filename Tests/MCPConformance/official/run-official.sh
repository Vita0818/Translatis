#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../../.." && pwd)
module_cache="${TMPDIR:-/tmp}/translatis-mcp-conformance-module-cache"
mkdir -p "$module_cache"

node "$script_dir/verify-pins.mjs"

cd "$repository_root"
CLANG_MODULE_CACHE_PATH="$module_cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
  swift build --disable-sandbox --product IntatisMCPConformanceClient
bin_path=$(
  CLANG_MODULE_CACHE_PATH="$module_cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
    swift build --disable-sandbox --show-bin-path
)
client="$bin_path/IntatisMCPConformanceClient"
if [ ! -x "$client" ]; then
  echo "missing conformance client executable: $client" >&2
  exit 1
fi

TRANSLATIS_MCP_CONFORMANCE_CLIENT="$client" \
  node "$script_dir/run.mjs" "${1-}"
