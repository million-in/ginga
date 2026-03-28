# Ginga Progress

## Done

- Pure Zig raster core with row-major RGBA8 image storage.
- PNG decode/encode path in Zig.
- PNG decoder now supports:
  - grayscale
  - RGB
  - indexed palette
  - grayscale+alpha
  - RGBA
  - `PLTE`
  - `tRNS`
  - non-interlaced streams
- Preview renderer in Zig with:
  - windowed-sinc reconstruction
  - panel/subpixel spread model
  - spectral-aware approximate reprojection path
- Direct spectral raster primitive in Zig:
  - sampled spectrum storage per pixel
  - spectrum -> cone -> XYZ -> RGB analysis
  - native spectral render input path
- CLI commands:
  - `help`
  - `inspect`
  - `convert`
  - `preview`
  - `capabilities`
- Stable JSON error envelope for CLI failures.
- Electron shell, now TypeScript-first, that wraps the Zig binary instead of owning render logic.
- CI and release automation:
  - `scripts/ci/quality-gate.sh`
  - `scripts/ci/release-gate.mjs`
  - JSON schema compatibility checks
  - release policy and feature-flag metadata
  - GitHub workflows for mergeable and releasable gates
  - stress / concurrency checks
  - microbenchmark timing
  - end-to-end latency checks
  - startup timing
  - memory usage checks
  - binary size tracking
  - throughput checks
  - reproducibility checks
  - schema compatibility checks
  - security scanning
  - release-note and rollout-metadata generation
  - canary eligibility decision
  - simulated crash / dependency-unavailable / corrupted-cache / disk-full / high-latency / partial-write probes
- JPEG/JPG baseline codec path in Zig:
  - marker parsing
  - frame metadata extraction
  - quantization table parsing
  - Huffman table parsing
  - restart interval parsing
  - JFIF / Adobe marker detection
  - baseline entropy decode
  - dequantization and IDCT
  - MCU assembly for 1x1 sampled grayscale and YCbCr images
  - baseline encode
  - JFIF marker emission
  - quality-scaled quantization tables
  - canonical Huffman bitstream emission

## Verified Locally

- `zig build test`
- `zig build`
- `./qa/smoke.sh`
- `GINGA_BIN="$PWD/zig-out/bin/ginga" ./qa/regression.sh`
- `GINGA_BENCH_ITERATIONS=1 ./qa/bench.sh`
- `bun run check`
- `bun run desktop:build`
- `bash scripts/ci/quality-gate.sh`
- `bun scripts/ci/release-gate.mjs mergeable`
- `bun scripts/ci/release-gate.mjs releasable`

## Current Limits

- Spectral pipeline is integrated as an approximate basis-spectrum -> cone-response -> XYZ -> RGB path.
- Spectrum-native in-memory rendering exists, but file ingest is still raster-first for PNG/JPEG.
- JPEG is limited to the baseline sequential subset with 1x1 sampling per component.
- The partial-write fault simulation is deliberately approximate and uses a killed FIFO writer/reader pair rather than a full block-device harness.

## Remaining

- Replace the approximate spectral basis model with a more rigorous spectral reconstruction model.
- Add explicit SPD-native input representation rather than only RGB-derived approximation.
- Add file-level ingest for spectral data instead of only the in-memory `SpectralRaster` path.
- Extend JPEG decode beyond the current baseline slice:
  - sampling-factor-aware chroma upsampling
  - restart-heavy streams beyond the current tested coverage
  - progressive JPEG decode or explicit policy rejection paths
- Extend JPEG encode:
  - chroma subsampling options
  - grayscale-specialized output path
  - custom quantization tables
- Add progressive JPEG policy:
  - decode or explicit rejection with better metadata-based diagnostics
- Add golden-image render regression tests with real PNG and JPEG fixtures.
- Add performance benchmarks for render and codec hot loops.

## Current Truth

- Rendering is genuinely engine-owned in Zig.
- Spectral math now exists in the engine and participates in rendering, but it is still an approximation layered on RGB inputs, not a full SPD-native renderer.
- JPEG/JPG baseline conversion and preview now work, but the codec is not yet a full JPEG implementation.
