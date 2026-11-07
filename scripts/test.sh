#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Keep build caches local, including when the home directory is read-only.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift test --disable-sandbox --cache-path "$PWD/.build/package-cache" "$@"
