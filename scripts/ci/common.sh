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
    (cd "$ROOT" && zig build -Doptimize=ReleaseSafe >/dev/null)
}

write_sample_png() {
    local out_path="$1"
    SAMPLE_PNG_OUT="$out_path" SAMPLE_PNG_B64="$SAMPLE_PNG_B64" bun -e 'await Bun.write(process.env.SAMPLE_PNG_OUT, Buffer.from(process.env.SAMPLE_PNG_B64, "base64"));'
}

write_sample_spd() {
    local out_path="$1"
    SAMPLE_SPD_OUT="$out_path" bun -e '
const outPath = process.env.SAMPLE_SPD_OUT;
const width = 2;
const height = 1;
const sampleCount = 31;
const lambdaMin = 400.0;
const lambdaStep = 10.0;
const headerSize = 40;
const payload = Buffer.alloc(width * height * sampleCount * 4);
const gaussian = (lambda, center, sigma) => {
  const delta = (lambda - center) / sigma;
  return Math.exp(-0.5 * delta * delta);
};
let offset = 0;
for (const center of [620.0, 540.0]) {
  for (let i = 0; i < sampleCount; i += 1) {
    const lambda = lambdaMin + lambdaStep * i;
    payload.writeFloatLE(gaussian(lambda, center, 18.0), offset);
    offset += 4;
  }
}
const crcTable = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) {
      c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[n] = c >>> 0;
  }
  return table;
})();
const crc32 = (buffer) => {
  let c = 0xffffffff;
  for (const byte of buffer) {
    c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
};
const file = Buffer.alloc(headerSize + payload.length);
file.write("GINGASPD", 0, "ascii");
file.writeUInt16LE(1, 8);
file.writeUInt16LE(headerSize, 10);
file.writeUInt32LE(width, 12);
file.writeUInt32LE(height, 16);
file.writeUInt16LE(sampleCount, 20);
file.writeUInt16LE(1, 22);
file.writeFloatLE(lambdaMin, 24);
file.writeFloatLE(lambdaStep, 28);
file.writeUInt32LE(crc32(payload), 32);
file.writeUInt32LE(0, 36);
payload.copy(file, headerSize);
await Bun.write(outPath, file);
'
}

prepare_sample_images() {
    local workdir="$1"
    mkdir -p "$workdir"
    write_sample_png "$workdir/sample.png"
    write_sample_spd "$workdir/sample.spd"
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
        awk '/maximum resident set size/ { printf "%.0f\n", $1 / 1024.0 }' "$tmp"
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
