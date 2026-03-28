#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/fixtures/manifest.sha256"

hash_file() {
    local file="$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
        return
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
        return
    fi
    if command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" | awk '{print $2}'
        return
    fi

    echo "no sha256 tool found (need shasum, sha256sum, or openssl)" >&2
    exit 1
}

check_manifest() {
    local expected actual path
    while read -r expected path; do
        [ -z "${expected:-}" ] && continue
        case "$expected" in
            \#*) continue ;;
        esac

        actual="$(hash_file "$ROOT/$path")"
        if [ "$actual" != "$expected" ]; then
            echo "fixture hash mismatch: $path" >&2
            echo "expected: $expected" >&2
            echo "actual:   $actual" >&2
            return 1
        fi
    done < "$MANIFEST"
}

if [ ! -f "$MANIFEST" ]; then
    echo "missing manifest: $MANIFEST" >&2
    exit 1
fi

check_manifest
echo "fixture manifest verified"

if [ -n "${GINGA_BIN:-}" ] && [ -x "${GINGA_BIN:-}" ]; then
    echo "cli hook available at $GINGA_BIN"
    echo "add golden-output comparisons here once encode/decode commands exist"
else
    echo "cli hook not enabled; set GINGA_BIN once the binary is built"
fi

