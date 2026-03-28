#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-/tmp/ginga-zig-global-cache}"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-/tmp/ginga-zig-local-cache}"

echo "running zig helper tests"
zig test src/ginga/testing.zig

GINGA_BIN="${GINGA_BIN:-$ROOT/zig-out/bin/ginga}"
if [ -x "$GINGA_BIN" ]; then
    echo "probing cli binary: $GINGA_BIN --help"
    "$GINGA_BIN" --help >/dev/null
else
    echo "skipping cli probe: $GINGA_BIN is not built yet"
fi
