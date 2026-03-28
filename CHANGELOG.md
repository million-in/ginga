# Changelog

All notable changes to `ginga` will be documented in this file.

The format follows Keep a Changelog and the project uses semantic versioning.

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
