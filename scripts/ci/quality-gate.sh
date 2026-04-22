#!/usr/bin/env bash
set -euo pipefail

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MICROBENCH_MAX_SECONDS="${MICROBENCH_MAX_SECONDS:-1.000}"
STARTUP_MAX_SECONDS="${STARTUP_MAX_SECONDS:-0.500}"
E2E_LATENCY_MAX_SECONDS="${E2E_LATENCY_MAX_SECONDS:-1.000}"
MAX_RSS_KB="${MAX_RSS_KB:-262144}"
BINARY_SIZE_MAX_BYTES="${BINARY_SIZE_MAX_BYTES:-5000000}"
THROUGHPUT_MIN_OPS_PER_SECOND="${THROUGHPUT_MIN_OPS_PER_SECOND:-2.000}"

hash_file() {
    local file="$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
        return
    fi
    sha256sum "$file" | awk '{print $1}'
}

check_max() {
    local name="$1"
    local actual="$2"
    local limit="$3"
    if ! awk -v actual="$actual" -v limit="$limit" 'BEGIN { exit !(actual <= limit) }'; then
        echo "$name exceeded limit: actual=$actual limit=$limit" >&2
        exit 1
    fi
}

check_min() {
    local name="$1"
    local actual="$2"
    local limit="$3"
    if ! awk -v actual="$actual" -v limit="$limit" 'BEGIN { exit !(actual >= limit) }'; then
        echo "$name below limit: actual=$actual limit=$limit" >&2
        exit 1
    fi
}

ensure_ginga_built

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
prepare_sample_images "$workdir"

png_path="$workdir/sample.png"
jpg_path="$workdir/sample.jpg"
spd_path="$workdir/sample.spd"
request_path="$workdir/preview-request.json"
printf '{"command":"preview","imagePath":"%s"}\n' "$png_path" > "$request_path"

(cd "$ROOT" && zig build test)
(cd "$ROOT" && ./qa/smoke.sh)
(cd "$ROOT" && GINGA_BIN="$GINGA_BIN" ./qa/regression.sh)

png_inspect="$("$GINGA_BIN" inspect "$png_path")"
printf '%s\n' "$png_inspect" | bun "$ROOT/scripts/ci/assert-schema.mjs" "$ROOT/schemas/inspect-png.schema.json"

jpg_inspect="$("$GINGA_BIN" inspect "$jpg_path")"
printf '%s\n' "$jpg_inspect" | bun "$ROOT/scripts/ci/assert-schema.mjs" "$ROOT/schemas/inspect-jpeg.schema.json"

spd_inspect="$("$GINGA_BIN" inspect "$spd_path")"
printf '%s\n' "$spd_inspect" | bun "$ROOT/scripts/ci/assert-schema.mjs" "$ROOT/schemas/inspect-spd.schema.json"

preview_output_path="$workdir/preview-first.json"
"$GINGA_BIN" preview < "$request_path" > "$preview_output_path"
preview_json="$(cat "$preview_output_path")"
printf '%s\n' "$preview_json" | bun "$ROOT/scripts/ci/assert-schema.mjs" "$ROOT/schemas/preview.schema.json"

spd_preview_path="$workdir/preview-spd.json"
printf '{"command":"preview","imagePath":"%s"}\n' "$spd_path" | "$GINGA_BIN" preview > "$spd_preview_path"
printf '%s\n' "$(cat "$spd_preview_path")" | bun "$ROOT/scripts/ci/assert-schema.mjs" "$ROOT/schemas/preview.schema.json"

"$GINGA_BIN" convert "$spd_path" "$workdir/from-spd.png" >/dev/null
spd_convert_inspect="$("$GINGA_BIN" inspect "$workdir/from-spd.png")"
printf '%s\n' "$spd_convert_inspect" | bun "$ROOT/scripts/ci/assert-schema.mjs" "$ROOT/schemas/inspect-png.schema.json"

"$GINGA_BIN" convert "$png_path" "$workdir/from-png.spd" >/dev/null
png_to_spd_inspect="$("$GINGA_BIN" inspect "$workdir/from-png.spd")"
printf '%s\n' "$png_to_spd_inspect" | bun "$ROOT/scripts/ci/assert-schema.mjs" "$ROOT/schemas/inspect-spd.schema.json"
printf '{"command":"preview","imagePath":"%s"}\n' "$workdir/from-png.spd" | "$GINGA_BIN" preview > "$workdir/preview-from-png-spd.json"
printf '%s\n' "$(cat "$workdir/preview-from-png-spd.json")" | bun "$ROOT/scripts/ci/assert-schema.mjs" "$ROOT/schemas/preview.schema.json"

capabilities_json="$("$GINGA_BIN" capabilities)"
printf '%s\n' "$capabilities_json" | bun "$ROOT/scripts/ci/assert-schema.mjs" "$ROOT/schemas/capabilities.schema.json"

if printf '{}' | "$GINGA_BIN" preview >/dev/null 2>"$workdir/error.json"; then
    echo "invalid preview request unexpectedly succeeded" >&2
    exit 1
fi
cat "$workdir/error.json" | bun "$ROOT/scripts/ci/assert-schema.mjs" "$ROOT/schemas/error.schema.json"

bench_output="$(cd "$ROOT" && GINGA_BENCH_ITERATIONS="${GINGA_BENCH_ITERATIONS:-3}" ./qa/bench.sh "$GINGA_BIN" capabilities)"
microbench_seconds="$(printf '%s\n' "$bench_output" | awk '/average real:/ { gsub(/s/, "", $3); print $3 }')"

startup_seconds="$(average_command_seconds 3 "$GINGA_BIN" --help)"
preview_latency_seconds="$(average_command_seconds 3 bash -lc '"$0" preview < "$1" >/dev/null' "$GINGA_BIN" "$request_path")"
max_rss_kb="$(measure_max_rss_kb bash -lc '"$0" preview < "$1" >/dev/null' "$GINGA_BIN" "$request_path")"
binary_size_bytes="$(wc -c < "$GINGA_BIN" | tr -d ' ')"

throughput_iterations=8
throughput_total_seconds="$(measure_real_seconds bash -lc '
    i=0
    while [ "$i" -lt "$2" ]; do
        "$0" preview < "$1" >/dev/null
        i=$((i + 1))
    done
' "$GINGA_BIN" "$request_path" "$throughput_iterations")"
throughput_ops_per_second="$(awk -v ops="$throughput_iterations" -v seconds="$throughput_total_seconds" 'BEGIN {
    if (seconds <= 0.0) { print "0.000"; exit }
    printf "%.3f", ops / seconds
}')"

preview_hash_a="$(hash_file "$preview_output_path")"
"$GINGA_BIN" preview < "$request_path" > "$workdir/preview-b.json"
preview_hash_b="$(hash_file "$workdir/preview-b.json")"
if [ "$preview_hash_a" != "$preview_hash_b" ]; then
    echo "preview output is not reproducible across repeated runs" >&2
    exit 1
fi

repro_a="$workdir/repro-a"
repro_b="$workdir/repro-b"
global_a="$workdir/global-a"
local_a="$workdir/local-a"
global_b="$workdir/global-b"
local_b="$workdir/local-b"
mkdir -p "$global_a" "$local_a" "$global_b" "$local_b"
(cd "$ROOT" && ZIG_GLOBAL_CACHE_DIR="$global_a" ZIG_LOCAL_CACHE_DIR="$local_a" zig build -Doptimize=ReleaseSafe --prefix "$repro_a" >/dev/null)
(cd "$ROOT" && ZIG_GLOBAL_CACHE_DIR="$global_b" ZIG_LOCAL_CACHE_DIR="$local_b" zig build -Doptimize=ReleaseSafe --prefix "$repro_b" >/dev/null)

"$repro_a/bin/ginga" capabilities > "$workdir/repro-cap-a.json"
"$repro_b/bin/ginga" capabilities > "$workdir/repro-cap-b.json"
if [ "$(hash_file "$workdir/repro-cap-a.json")" != "$(hash_file "$workdir/repro-cap-b.json")" ]; then
    echo "release builds are not functionally reproducible across fresh caches" >&2
    exit 1
fi
"$repro_a/bin/ginga" preview < "$request_path" > "$workdir/repro-preview-a.json"
"$repro_b/bin/ginga" preview < "$request_path" > "$workdir/repro-preview-b.json"
if [ "$(hash_file "$workdir/repro-preview-a.json")" != "$(hash_file "$workdir/repro-preview-b.json")" ]; then
    echo "release preview output is not reproducible across fresh caches" >&2
    exit 1
fi

mkdir -p "$workdir/concurrency"
seq 1 4 | xargs -I{} -P4 bash -lc '"$0" preview < "$1" > "$2/preview-{}.json"' "$GINGA_BIN" "$request_path" "$workdir/concurrency"
reference_hash="$(hash_file "$workdir/concurrency/preview-1.json")"
for candidate in "$workdir"/concurrency/preview-*.json; do
    if [ "$(hash_file "$candidate")" != "$reference_hash" ]; then
        echo "parallel preview output diverged across concurrent runs" >&2
        exit 1
    fi
done

security_hits="$(grep -RInE '(eval\(|Function\(|child_process\.exec\(|shell:[[:space:]]*true|curl .*\|[[:space:]]*(sh|bash)|wget .*\|[[:space:]]*(sh|bash))' "$ROOT/src" "$ROOT/electron" "$ROOT/scripts" | grep -v "$ROOT/scripts/ci/quality-gate.sh" || true)"
if [ -n "$security_hits" ]; then
    printf '%s\n' "$security_hits"
    echo "security scan found forbidden execution patterns" >&2
    exit 1
fi
secret_hits="$(grep -RInE '(BEGIN RSA PRIVATE KEY|BEGIN OPENSSH PRIVATE KEY|OPENAI_API_KEY|AWS_SECRET_ACCESS_KEY)' "$ROOT/src" "$ROOT/electron" "$ROOT/scripts" "$ROOT/release" "$ROOT/.github" | grep -v "$ROOT/scripts/ci/quality-gate.sh" || true)"
if [ -n "$secret_hits" ]; then
    printf '%s\n' "$secret_hits"
    echo "security scan found secret-like material" >&2
    exit 1
fi
if [ "${CI_NETWORK_AUDIT:-0}" = "1" ]; then
    (cd "$ROOT" && bun audit)
fi

HTTP_PROXY="http://127.0.0.1:9" HTTPS_PROXY="http://127.0.0.1:9" "$GINGA_BIN" inspect "$png_path" >/dev/null
bash -lc 'sleep 0.1; cat "$1" | "$0" preview >/dev/null' "$GINGA_BIN" "$request_path"

missing_bin_failed=false
if (
    cd "$ROOT"
    bun scripts/electron-bridge.ts preview --binary "$ROOT/missing/ginga" --image "$png_path"
) >/dev/null 2>"$workdir/missing-bin.log"; then
    echo "missing dependency probe unexpectedly succeeded" >&2
    exit 1
else
    missing_bin_failed=true
fi

if [ -e /dev/full ]; then
    if "$GINGA_BIN" convert "$png_path" /dev/full >/dev/null 2>"$workdir/dev-full.log"; then
        echo "disk-full probe unexpectedly succeeded" >&2
        exit 1
    fi
fi

mkdir -p "$workdir/corrupt-global" "$workdir/corrupt-local"
printf 'corrupt-cache' > "$workdir/corrupt-global/not-a-cache-entry"
printf 'corrupt-cache' > "$workdir/corrupt-local/not-a-cache-entry"
(cd "$ROOT" && ZIG_GLOBAL_CACHE_DIR="$workdir/corrupt-global" ZIG_LOCAL_CACHE_DIR="$workdir/corrupt-local" zig build >/dev/null)

if command -v mkfifo >/dev/null 2>&1; then
    {
        fifo_path="$workdir/partial-write.fifo"
        mkfifo "$fifo_path"
        head -c 16 < "$fifo_path" >/dev/null 2>/dev/null &
        fifo_reader_pid="$!"
        "$GINGA_BIN" convert "$png_path" "$fifo_path" >/dev/null 2>"$workdir/partial-write.log" &
        fifo_writer_pid="$!"
        sleep 1
        kill "$fifo_writer_pid" >/dev/null 2>&1 || true
        kill "$fifo_reader_pid" >/dev/null 2>&1 || true
        wait "$fifo_writer_pid" >/dev/null 2>&1 || true
        wait "$fifo_reader_pid" >/dev/null 2>&1 || true
    } 2>/dev/null
fi

bash -lc 'sleep 5; exec "$0" preview < "$1" >/dev/null' "$GINGA_BIN" "$request_path" &
crash_pid="$!"
sleep 0.1
kill -KILL "$crash_pid" >/dev/null 2>&1 || true
wait "$crash_pid" >/dev/null 2>&1 || true

SOURCE_DATE_EPOCH=1 bun "$ROOT/scripts/ci/release-gate.mjs" mergeable >/dev/null

check_max microbench_seconds "$microbench_seconds" "$MICROBENCH_MAX_SECONDS"
check_max startup_seconds "$startup_seconds" "$STARTUP_MAX_SECONDS"
check_max preview_latency_seconds "$preview_latency_seconds" "$E2E_LATENCY_MAX_SECONDS"
check_max max_rss_kb "$max_rss_kb" "$MAX_RSS_KB"
check_max binary_size_bytes "$binary_size_bytes" "$BINARY_SIZE_MAX_BYTES"
check_min throughput_ops_per_second "$throughput_ops_per_second" "$THROUGHPUT_MIN_OPS_PER_SECOND"

printf '{\n' > "$REPORT_DIR/quality-gate.json"
printf '  "ok": true,\n' >> "$REPORT_DIR/quality-gate.json"
printf '  "microbenchSeconds": %s,\n' "$microbench_seconds" >> "$REPORT_DIR/quality-gate.json"
printf '  "startupSeconds": %s,\n' "$startup_seconds" >> "$REPORT_DIR/quality-gate.json"
printf '  "previewLatencySeconds": %s,\n' "$preview_latency_seconds" >> "$REPORT_DIR/quality-gate.json"
printf '  "maxRssKb": %s,\n' "$max_rss_kb" >> "$REPORT_DIR/quality-gate.json"
printf '  "binarySizeBytes": %s,\n' "$binary_size_bytes" >> "$REPORT_DIR/quality-gate.json"
printf '  "throughputOpsPerSecond": %s,\n' "$throughput_ops_per_second" >> "$REPORT_DIR/quality-gate.json"
printf '  "dependencyUnavailableHandled": %s\n' "$missing_bin_failed" >> "$REPORT_DIR/quality-gate.json"
printf '}\n' >> "$REPORT_DIR/quality-gate.json"

echo "quality gate passed"
