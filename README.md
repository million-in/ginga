# ginga

`ginga` is a local-first image conversion and preview tool built around a pure Zig engine. It ships as:

- a CLI for inspect, convert, preview, and capability discovery
- a minimal Electron shell that wraps the same local binary instead of reimplementing image logic in JavaScript

## Software Review

`ginga` is opinionated in a way most image tools are not. The project is not trying to be a thin wrapper around system codecs, browser APIs, or third-party rendering engines. The core image path is owned in-repo, in Zig, with the desktop UI acting as a front-end to that engine rather than a second implementation.

That gives the project a few distinctive properties:

- A single engine boundary for both CLI and desktop usage.
- Native support for an external spectral raster format, `.spd`, alongside `png`, `jpg`, `jpeg`, `gif`, and `webp`.
- A desktop preview path that now defaults to spectral reconstruction, while the raw CLI preview contract can still request `none`, `approximate`, or `native`.
- Machine-readable CLI responses that are usable from scripts, tests, and the desktop shell.
- A build flow that installs `ginga` as a normal shell command instead of trapping usage inside the repo directory.

The current release is strongest where the project already owns the full path end to end:

- PNG decode and encode
- baseline JPEG/JPG decode and encode
- GIF inspect, decode, and animated preview (LZW, palette compositing, interlacing, transparency, disposal handling)
- WebP lossy decode and encode (VP8 boolean arithmetic coding, 4x4 DCT, spatial prediction, B_PRED sub-block prediction)
- `.spd` ingest and export
- preview rendering
- folder-based desktop browsing and batch conversion

The current limits are deliberate rather than hidden:

- JPEG support is still baseline sequential, not full-format JPEG coverage.
- GIF conversion is intentionally disabled; GIF is treated as an input/preview format rather than a conversion target.
- PNG output currently prioritizes correctness and ownership over compression ratio.
- Spectral-native external ingest exists through `.spd`; conventional PNG and JPEG inputs remain raster-first.

## Installation

### Requirements

- Zig `0.15.x`
- Bun `1.3+`
- macOS, Linux, or another environment where Bun + Electron and Zig toolchains are available

### Build And Install

From the repository root:

```bash
bun install
bun run build
```

`bun run build` builds the Zig engine, builds the Electron shell, and installs `ginga` into a shell-visible location. By default the install script prefers:

1. `/opt/homebrew/bin`
2. `/usr/local/bin`
3. `~/.local/bin`

If the chosen directory is not already on `PATH`, the installer will add it to `~/.zshrc`.

To force a specific install target:

```bash
GINGA_INSTALL_DIR="$HOME/.local/bin" bun run build
```

### Run

Desktop shell:

```bash
bun run dev
```

CLI:

```bash
ginga --help
ginga inspect /absolute/path/to/input.png
ginga convert /absolute/path/to/input.png /tmp/output.spd
printf '{"command":"preview","imagePath":"/absolute/path/to/input.png"}\n' | ginga preview
```

## Unique APIs

The main public interfaces are intentionally small:

- `ginga inspect <file>`
  Returns machine-readable metadata for `png`, `jpg`, `jpeg`, `gif`, `webp`, and `.spd`.
- `ginga convert <input> <output>`
  Converts across the supported raster and spectral formats, excluding GIF.
- `ginga preview`
  Accepts a JSON request on stdin and returns a JSON payload with preview metadata plus preview bytes encoded as base64. Static previews are returned as PNG; animated GIF previews are returned as GIF.
- `ginga capabilities`
  Exposes a machine-readable feature manifest so tooling can detect supported formats and render modes at runtime.

The Electron app uses those same APIs through the local binary rather than introducing a second image-processing layer, and it now requests the spectral preview path by default.

## Documentation

Technical details live under `docs/`:

- [CLI and build usage](docs/cli.md)
- [Zig engine architecture](docs/zig-engine.md)
- [Math and reconstruction model](docs/math-spec.md)
- [SPD file format](docs/spd-format.md)
- [Implementation status](progress.md)

Contribution guidance lives in [CONTRIBUTING.md](CONTRIBUTING.md).
