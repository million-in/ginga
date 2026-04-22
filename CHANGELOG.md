# Changelog

All notable changes to `ginga` will be documented in this file.

The format follows Keep a Changelog and the project uses semantic versioning.

## [0.3.0] - 2026-04-06

### Added

- Pure Zig GIF decode and animated preview pipeline with LZW compression, palette compositing, interlacing, transparency, and disposal support.
- Pure Zig WebP decode and encode pipeline with VP8 lossy codec (boolean arithmetic coding, 4x4 integer DCT/IDCT, Walsh-Hadamard Transform, spatial prediction, YUV 4:2:0) and VP8L lossless decode support.
- GIF and WebP integrated into codec layer, CLI, capabilities, Electron desktop shell, and bridge.
- End-to-end round-trip conversion tests for both GIF and WebP through the codec pipeline.

### Changed

- GIF is no longer exposed as a conversion target. The engine now treats GIF as an inspect-and-preview input format, and animated GIF preview is returned as an actual animated GIF payload to the desktop shell.

### Fixed

- WebP VP8 keyframe decoding now uses the correct Y-mode root branch, real B_PRED sub-block mode decoding, and real 4x4 intra prediction instead of the previous fixed-bit/fallback implementation that corrupted many lossy WebP images.

## [0.2.0] - 2026-04-05

### Fixed

- PNG inspect no longer reads the entire file into memory; only the 33-byte IHDR header is read from disk.
- Replaced per-row `memset` in horizontal resampling with a generation counter, eliminating O(width × height) redundant cache invalidation.
- Replaced `anyerror` type aliases in PNG, JPEG, SPD, and codec modules with Zig inferred error sets for compile-time error path optimization.
- Precomputed CIE 1931 matching functions and basis reflectance spectra at comptime, removing ~200 redundant `exp()` and `smoothStep` calls per pixel in the spectral pipeline.
- Gallery navigation now debounces render calls (120 ms) so rapid swiping or arrow-key holds no longer spawn a child process per frame.
- Stale preview renders are discarded via a generation counter, preventing out-of-order UI updates when navigating quickly.
- Batch convert now runs up to 4 conversions concurrently instead of processing files one at a time.
- Removed duplicate O(n) batch format validation that ran identically at selection time and again at convert time.
- Preview base64 payload is now released from the response object after extraction, reducing transient memory pressure during gallery browsing.

## [0.1.0] - 2026-03-28

### Added

- Pure Zig PNG decode and encode pipeline.
- Baseline JPEG/JPG decode and encode pipeline.
- Windowed-sinc preview renderer with panel-aware spread modeling.
- Native in-memory spectral raster support alongside the RGB-derived spectral approximation path.
- Bun-driven Electron desktop shell authored in TypeScript.
- Machine-readable `ginga capabilities` command.
- CI, quality gating, release gating, and fault-injection automation.

### Changed

- Desktop build artifacts are now treated as generated output rather than source-of-truth files.
- Repo hygiene now ignores generated metrics, report, benchmark, and desktop build output.
