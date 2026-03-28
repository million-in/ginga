#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-/tmp/ginga-zig-global-cache}"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-/tmp/ginga-zig-local-cache}"

iterations="${GINGA_BENCH_ITERATIONS:-5}"

if [ "$#" -gt 0 ]; then
    command=( "$@" )
else
    command=( zig test src/ginga/testing.zig )
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "benchmarking: ${command[*]}"
echo "iterations: $iterations"

iteration=1
while [ "$iteration" -le "$iterations" ]; do
    /usr/bin/time -p "${command[@]}" >/dev/null 2>>"$tmp"
    iteration=$((iteration + 1))
done

awk '
    /^real / { sum += $2; count += 1 }
    END {
        if (count == 0) {
            print "no timing samples captured" > "/dev/stderr"
            exit 1
        }
        printf "average real: %.4fs\n", sum / count
    }
' "$tmp"
