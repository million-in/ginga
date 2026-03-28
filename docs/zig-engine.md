# Ginga Zig Engine

## Purpose

The Zig engine is the production core of `ginga`. It owns:

- image I/O boundaries
- raster storage
- color transforms
- reconstruction and panel-aware preview rendering
- CLI entrypoints used by both terminal workflows and the desktop shell

The design target is a pure-Zig implementation with explicit algorithm ownership in-repo.

## Current Scope

Implemented now:

- PNG decode
- PNG encode
- JPEG/JPG baseline decode
- JPEG/JPG baseline encode
- raster model for RGBA8 storage
- spectral raster model for direct sampled-spectrum storage
- color utilities for sRGB, linear RGB, and YCbCr
- spectral approximation utilities for SPD-like reprojection, cone responses, XYZ, and chromaticity
- orthonormal 8x8 DCT helpers
- Whittaker-Shannon-inspired windowed-sinc reconstruction
- RGB stripe panel spread model
- CLI commands: `help`, `inspect`, `convert`, `preview`
- CLI command: `capabilities`
- JPEG/JPG metadata parsing

The current codec surface is real for `png`, `jpg`, and `jpeg`. The JPEG slice is still intentionally narrow: baseline sequential 8-bit streams are supported, while progressive/arithmetic/lossless variants are still rejected.

## Repository Layout

### Entry Points

- `src/main.zig`
  Runs the CLI.
- `src/root.zig`
  Re-exports the engine modules as the package surface.

### Core Engine Modules

- `src/ginga/cli.zig`
  CLI parsing and command dispatch.
- `src/ginga/codec.zig`
  Format inference and high-level decode/encode/convert orchestration.
- `src/ginga/raster.zig`
  The dense in-memory image type used across the engine.
- `src/ginga/png.zig`
  PNG reader and writer.
- `src/ginga/jpeg.zig`
  JPEG baseline reader and writer.
- `src/ginga/color.zig`
  Color conversions and transfer functions.
- `src/ginga/spectral.zig`
  Spectral approximation, cone response integration, XYZ conversion, and chromaticity math.
- `src/ginga/spectral_raster.zig`
  Direct sampled-spectrum image storage and spectrum analysis helpers.
- `src/ginga/dct.zig`
  8x8 DCT, inverse DCT, and quantization helpers.
- `src/ginga/sampling.zig`
  Windowed-sinc reconstruction kernel.
- `src/ginga/panel.zig`
  Subpixel and panel spread model.
- `src/ginga/render.zig`
  Preview reconstruction and panel simulation.
- `src/ginga/testing.zig`
  Test helpers and deterministic fixture utilities.

## Data Model

### Raster

`src/ginga/raster.zig` defines:

- `Pixel`
  RGBA8 pixel storage.
- `Raster`
  Dense row-major image storage with explicit width, height, and owned pixel buffer.

This is the engine’s canonical transport format between codecs and rendering stages.

### Why RGBA8 Internally Right Now

The long-term math story includes spectral inputs, cone responses, chroma transforms, and lossy/lossless codec stages. The current implemented slice is narrower:

- decode into a stable RGBA8 image
- reconstruct preview samples from that image
- re-encode PNG losslessly or JPEG baseline from that same raster

That keeps the first runnable version simple while preserving clean seams for deeper spectral and codec work later.

For direct spectral work, the engine now also exposes `SpectralRaster` so spectrum-native tests and render paths do not have to round-trip through RGBA first.

## Render Pipeline

The current preview renderer is a two-stage approximation:

1. Reproject source RGB through an approximate spectral pipeline.
2. Reconstruct the source raster into the preview grid with a windowed-sinc kernel.
3. Convolve the reconstructed image with a display-panel point-spread model.

### Spectral Stage

`src/ginga/spectral.zig` currently implements an approximate spectral path:

- RGB-derived smooth basis spectra
- three cone-response integrals
- cone-response to XYZ mapping
- XYZ to linear RGB reprojection
- chromaticity extraction

This is a real engine-owned spectral stage, but it is not yet a true SPD-native renderer. The current input to that stage is still RGB-derived approximation, not measured spectral power data per pixel.

`src/ginga/spectral_raster.zig` adds the missing in-memory primitive for direct sampled spectra. That means the renderer can now accept a spectrum-native source in-core even though the file codecs still decode ordinary image formats into RGB rasters.

### Sampling Kernel

`src/ginga/sampling.zig` implements `WindowedSinc`.

The weight function is:

- `sinc(x) * sinc(x / support)`

with finite support defined by the kernel radius. This is a practical Whittaker-Shannon-inspired reconstruction kernel: exact sinc behavior near the center with a compact window to keep the renderer bounded and numerically usable.

### Panel Model

`src/ginga/panel.zig` models a display as:

- RGB or BGR stripe layout
- explicit subpixel offsets
- Gaussian horizontal and vertical spread

This lets preview rendering simulate how a lit pixel is distributed by a physical panel rather than treating the raster as a perfectly sharp rectangular grid.

### Preview Rendering

`src/ginga/render.zig`:

- samples source pixels through the kernel
- reconstructs the preview raster in linear space
- optionally applies horizontal per-channel panel spread
- applies vertical spread
- quantizes back to 8-bit display output

The preview output is returned as an owned `PreviewImage` buffer.

## PNG Implementation

`src/ginga/png.zig` provides a self-contained PNG path.

### Decode Path

The decoder:

- validates the PNG signature
- parses chunk headers
- validates chunk CRCs
- reads `IHDR`
- concatenates `IDAT`
- inflates zlib-compressed scanlines
- reverses PNG filters
- reconstructs RGBA pixels into `Raster`

Supported now:

- grayscale color type `0` with bit depths `1`, `2`, `4`, `8`, `16`
- truecolor color type `2` with bit depths `8`, `16`
- indexed color type `3` with bit depths `1`, `2`, `4`, `8`
- grayscale+alpha color type `4` with bit depths `8`, `16`
- RGBA color type `6` with bit depths `8`, `16`
- `PLTE` palette decoding for indexed PNGs
- `tRNS` transparency handling for grayscale, RGB, and indexed PNGs
- compression method `0`
- filter method `0`
- interlace method `0`

Unsupported inputs fail explicitly.

### Encode Path

The encoder:

- converts the raster into raw RGBA scanlines
- evaluates PNG filters per row
- picks the cheapest row filter by absolute residual score
- writes zlib-wrapped stored deflate blocks
- writes `IHDR`, `IDAT`, and `IEND`

The compressor path uses stored zlib blocks right now. That keeps the implementation reliable in pure Zig without depending on partially broken stdlib compression internals in this Zig release. Compression ratio is not yet a focus; correctness and ownership are.

## Color And Transform Modules

### `color.zig`

This module currently implements:

- sRGB to linear conversion
- linear to sRGB conversion
- `Pixel <-> LinearRgb`
- `Pixel <-> YCbCr`

This is the foundation for future:

- chroma subsampling stages
- codec-specific color rotation
- perceptual error shaping

### `dct.zig`

This module implements:

- forward 8x8 DCT
- inverse 8x8 DCT
- scalar quantization
- dequantization
- zigzag index table

It is now part of the live JPEG path for both encode and decode.

### `jpeg.zig`

This module now implements a baseline JPEG/JPG slice:

- SOI / EOI validation
- frame parsing
- baseline/progressive/lossless/arithmetic flags
- quantization-table parsing
- Huffman-table parsing
- restart interval parsing
- JFIF / Adobe marker detection
- baseline entropy decode
- dequantization and IDCT
- RGB/YCbCr output reconstruction
- baseline entropy encode
- JFIF marker emission
- quality-scaled quantization-table generation

Current limits:

- 8-bit baseline sequential JPEG only
- 1x1 component sampling in the encoder
- decoder coverage is strongest on grayscale and 3-component baseline YCbCr/RGB images
- progressive, arithmetic-coded, and lossless JPEG are still rejected

## CLI Contract

`src/ginga/cli.zig` exposes:

### `ginga help`

Prints usage.

### `ginga inspect <image>`

Returns structured JSON with:

- inferred format
- width
- height

For JPEG/JPG it also reports parser metadata such as:

- baseline/progressive flags
- component count
- quantization table count
- Huffman table counts
- restart interval
- JFIF / Adobe markers

### `ginga convert <input> <output> [--quality N]`

Current behavior:

- PNG to PNG works
- PNG to JPEG/JPG works through the baseline encoder
- JPEG/JPG to PNG works through the baseline decoder
- JPEG/JPG to JPEG/JPG re-encode works through decode + baseline encode

### `ginga capabilities`

Returns machine-readable engine metadata including:

- decode/encode formats
- preview limits
- supported spectral modes
- the current JPEG capability slice
- direct spectral raster availability

### `ginga preview`

Reads a JSON request from stdin:

```json
{
  "command": "preview",
  "imagePath": "/absolute/path/to/image.png"
}
```

Returns JSON to stdout with:

- source format
- source dimensions
- preview dimensions
- base64-encoded preview PNG

The Electron shell uses this command as the engine boundary. That is the intended architecture: the desktop shell remains thin and the Zig binary stays authoritative.

On failure, the CLI now emits a stable JSON error envelope to stderr:

```json
{
  "ok": false,
  "error": {
    "code": "UnsupportedColorType",
    "message": "this PNG color model is not supported by the current decoder"
  }
}
```

That keeps the desktop shell and Bun bridge on a deterministic error contract instead of relying on raw Zig stack traces.

## Test Strategy

### Unit Tests

There are in-module tests for:

- raster operations
- color round trips
- DCT round trips
- PNG round trips
- sampling behavior
- panel response behavior
- render behavior

### QA Layer

`qa/` contains shell-level checks:

- `qa/smoke.sh`
- `qa/regression.sh`
- `qa/bench.sh`

`scripts/ci/` contains the heavier automation surface used by merge/release gates:

- `scripts/ci/quality-gate.sh`
- `scripts/ci/release-gate.mjs`
- `scripts/ci/assert-schema.mjs`

`schemas/` defines the machine-readable CLI response contracts used by the schema-compatibility checks.

`fixtures/` contains small deterministic raster fixtures and manifest validation.

### Practical Validation Commands

From repo root:

```bash
export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global"
export ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local"

zig build
zig build test
./qa/smoke.sh
./qa/regression.sh
GINGA_BENCH_ITERATIONS=1 ./qa/bench.sh
```

## Limitations

Current limitations are deliberate and should be treated as open work, not hidden behavior:

- JPEG/JPG support is limited to the baseline sequential subset
- PNG compression uses stored deflate blocks, not an optimized compressor
- the engine does not yet ingest SPD-native per-pixel spectral inputs
- there is no chroma subsampling pipeline wired into output codecs yet
- spectral rendering is still RGB-derived approximation rather than true measured SPD input

## Recommended Next Work

The next technically coherent milestones are:

1. Replace the RGB-derived spectral approximation with a stronger spectral reconstruction model.
2. Add SPD-native input support for the render pipeline.
3. Extend JPEG to chroma-subsampled and progressive streams.
4. Introduce a richer linear working image representation beyond RGBA8.
5. Add golden-image regression tests for render output and codec round trips.

## Design Principle

The engine is structured so that:

- CLI behavior is thin and explicit
- codecs own byte-level correctness
- rendering owns reconstruction and panel simulation
- math modules stay reusable and independently testable

That separation is the main architectural asset of the current v1 codebase.
