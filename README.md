# ginga

`ginga` is a pure-Zig image pipeline project with two fronts:

- a Zig engine and CLI for decode, conversion, preview rendering, and core image math
- an Electron shell, authored in TypeScript, that wraps the local Zig binary for interactive preview work

The current v1 state is intentionally narrow:

- PNG decode and encode work end to end
- preview rendering works end to end
- rendering now includes a spectral-aware approximate reprojection path in Zig
- the engine now also exposes a direct spectral raster primitive for native spectrum -> cone -> XYZ -> RGB projection
- JPEG/JPG baseline decode and encode work end to end
- `ginga capabilities` emits a machine-readable engine feature manifest
- CI now includes quality and release gates for mergeable / releasable decisions

Engine documentation lives in [docs/zig-engine.md](docs/zig-engine.md).
Math and implementation scope are tracked in [docs/math-spec.md](docs/math-spec.md).
Current implementation status is tracked in [progress.md](progress.md).
