#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_DIR="${REPORT_DIR:-$ROOT/.reports}"
mkdir -p "$REPORT_DIR"

export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.zig-cache/global}"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$ROOT/.zig-cache/local}"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

GINGA_BIN="${GINGA_BIN:-$ROOT/zig-out/bin/ginga}"
SAMPLE_PNG_B64='iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAT0lEQVR4AQFEALv/AAAACP/w/6n/EAAI//D/qf8A8f+p/xAACP/w/6n/EAAA/wAAAAj/8P+p/xAACP/w/6n/APH/qf8QAAj/8P+p/xAAAP/ngiVDf+8vewAAAABJRU5ErkJggg=='

ensure_ginga_built() {
    if [ ! -x "$GINGA_BIN" ]; then
        (cd "$ROOT" && zig build >/dev/null)
    fi
}

write_sample_png() {
    local out_path="$1"
    SAMPLE_PNG_OUT="$out_path" SAMPLE_PNG_B64="$SAMPLE_PNG_B64" bun -e 'await Bun.write(process.env.SAMPLE_PNG_OUT, Buffer.from(process.env.SAMPLE_PNG_B64, "base64"));'
}

prepare_sample_images() {
    local workdir="$1"
    mkdir -p "$workdir"
    write_sample_png "$workdir/sample.png"
    "$GINGA_BIN" convert "$workdir/sample.png" "$workdir/sample.jpg" --quality 90 >/dev/null
}

measure_real_seconds() {
    local tmp
    tmp="$(mktemp)"
    /usr/bin/time -p "$@" >/dev/null 2>"$tmp"
    awk '/^real / { print $2 }' "$tmp"
    rm -f "$tmp"
}

average_command_seconds() {
    local iterations="$1"
    shift
    local sum="0"
    local index=1
    while [ "$index" -le "$iterations" ]; do
        local sample
        sample="$(measure_real_seconds "$@")"
        sum="$(awk -v lhs="$sum" -v rhs="$sample" 'BEGIN { printf "%.6f", lhs + rhs }')"
        index=$((index + 1))
    done
    awk -v total="$sum" -v count="$iterations" 'BEGIN { printf "%.6f", total / count }'
}

measure_max_rss_kb() {
    local tmp
    tmp="$(mktemp)"

    if /usr/bin/time -v true >/dev/null 2>&1; then
        /usr/bin/time -v "$@" >/dev/null 2>"$tmp"
        awk -F': +' '/Maximum resident set size/ { print $2 }' "$tmp"
        rm -f "$tmp"
        return 0
    fi

    if /usr/bin/time -l true >/dev/null 2>&1; then
        /usr/bin/time -l "$@" >/dev/null 2>"$tmp"
        awk '/maximum resident set size/ { print $1 }' "$tmp"
        rm -f "$tmp"
        return 0
    fi

    rm -f "$tmp"
    echo 0
}

json_escape() {
    local value="$1"
    VALUE="$value" bun -e 'process.stdout.write(JSON.stringify(process.env.VALUE));'
}

assert_file_contains() {
    local path="$1"
    local pattern="$2"
    if ! grep -q -- "$pattern" "$path"; then
        echo "expected pattern '$pattern' in $path" >&2
        exit 1
    fi
}
