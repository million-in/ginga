# CLI And Build Usage

## Build

From the repository root:

```bash
bun install
bun run build
```

`bun run build`:

1. builds the Zig engine
2. builds the Electron shell
3. installs `ginga` into a shell-visible location

The install step prefers:

1. `/opt/homebrew/bin`
2. `/usr/local/bin`
3. `~/.local/bin`

To force a specific install location:

```bash
GINGA_INSTALL_DIR="$HOME/.local/bin" bun run build
```

## Desktop

```bash
bun run dev
```

## CLI

Show help:

```bash
ginga --help
```

Inspect a file:

```bash
ginga inspect /absolute/path/to/input.png
ginga inspect /absolute/path/to/input.gif
ginga inspect /absolute/path/to/input.webp
ginga inspect /absolute/path/to/input.spd
```

Convert files:

```bash
ginga convert /absolute/path/to/input.png /tmp/output.jpg --quality 90
ginga convert /absolute/path/to/input.png /tmp/output.webp --quality 80
ginga convert /absolute/path/to/input.webp /tmp/output.png
ginga convert /absolute/path/to/input.png /tmp/output.spd
ginga convert /absolute/path/to/input.spd /tmp/output.png
```

Notes:

- GIF conversion is intentionally disabled; GIF is supported for `inspect` and animated `preview`
- animated GIF previews return `previewMimeType: "image/gif"` and `animated: true`
- other preview paths return `previewMimeType: "image/png"`

Render preview through the engine:

```bash
printf '{"command":"preview","imagePath":"/absolute/path/to/input.png"}\n' | ginga preview
```

Render preview with explicit spectral mode:

```bash
printf '{"command":"preview","imagePath":"/absolute/path/to/input.png","spectralMode":"approximate"}\n' | ginga preview
printf '{"command":"preview","imagePath":"/absolute/path/to/input.spd","spectralMode":"native"}\n' | ginga preview
```

Notes:

- raw CLI preview defaults to `spectralMode: "none"` when the field is omitted
- the desktop shell requests `spectralMode: "approximate"` by default
- direct `.spd` inputs render through the native spectral path inside the engine

Inspect feature support:

```bash
ginga capabilities
```
