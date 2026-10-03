#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
module_cache="${TMPDIR:-/tmp}/translatis-mcp-w10-module-cache"
mkdir -p "$module_cache"

"$script_dir/official/run-official.sh"
"$script_dir/extended/run-extended.sh"

cd "$repository_root"
for suite in \
  MCPStreamableHTTPTests \
  MCPManagedStdioTests \
  MCPImportTests \
  MCPProtocolLifecycleTests \
  MCPTaskStateMachineTests \
  MCPTaskAugmentedToolBindingTests \
  MCPReliabilityTests
do
  CLANG_MODULE_CACHE_PATH="$module_cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
    swift test --disable-sandbox --filter "$suite"
done
