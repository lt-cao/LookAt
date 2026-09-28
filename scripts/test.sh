#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"
mkdir -p work/cache/clang work/cache/swiftpm work/config work/security
CLANG_MODULE_CACHE_PATH="$ROOT_DIR/work/cache/clang" swift test \
    --disable-sandbox \
    --cache-path "$ROOT_DIR/work/cache/swiftpm" \
    --config-path "$ROOT_DIR/work/config" \
    --security-path "$ROOT_DIR/work/security" \
    --scratch-path "$ROOT_DIR/work/stability-build" \
    -c release "$@"
