# Ginga SPD Format

`ginga` now accepts external sampled spectral rasters through the binary `.spd` container.

## Version

- magic: `GINGASPD`
- version: `1`

## Byte Layout

All integer and floating-point fields are little-endian.

Header size: `40` bytes.

| Offset | Size | Field |
| --- | ---: | --- |
| `0` | `8` | ASCII magic `GINGASPD` |
| `8` | `2` | version (`u16`, currently `1`) |
| `10` | `2` | header size in bytes (`u16`, currently `40`) |
| `12` | `4` | width in pixels (`u32`) |
| `16` | `4` | height in pixels (`u32`) |
| `20` | `2` | spectral samples per pixel (`u16`) |
| `22` | `2` | sample encoding (`u16`, currently `1` = `f32` little-endian) |
| `24` | `4` | wavelength minimum in nm (`f32`) |
| `28` | `4` | wavelength step in nm (`f32`) |
| `32` | `4` | CRC-32 of the payload bytes (`u32`) |
| `36` | `4` | flags (`u32`, currently `0`) |

Payload:

- pixel-major order
- each pixel stores `sample_count` values
- each sample is one `f32` little-endian value

## Engine Rules

- width and height must be non-zero
- sample count must be non-zero
- wavelength step must be finite and positive
- payload size must exactly match `width * height * sample_count * 4`
- payload CRC must match the header
- non-finite spectral values are rejected
- negative spectral values are clamped to `0`

## Working Grid

The engine working grid is:

- `400nm .. 700nm`
- `10nm` spacing
- `31` samples per pixel

If an `.spd` file already uses that grid, `ginga` copies the spectra directly.

If the file uses another regular wavelength grid, `ginga` linearly resamples it into the engine grid as long as the file’s wavelength coverage fully spans `400nm .. 700nm`.

## CLI Usage

Inspect:

```bash
ginga inspect /absolute/path/to/file.spd
```

Preview:

```bash
printf '{"command":"preview","imagePath":"/absolute/path/to/file.spd"}\n' \
  | ginga preview
```

Convert to raster output:

```bash
ginga convert /absolute/path/to/file.spd /tmp/out.png
ginga convert /absolute/path/to/file.spd /tmp/out.jpg --quality 90
```
