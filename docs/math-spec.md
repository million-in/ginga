# Ginga Math Spec

## Engine Contract

The engine owns the image math in Zig. The desktop shell is only a wrapper over the local Zig binary.

The intended flow is:

1. Accept image data as either:
   - a raster image (`png`, `jpg`, `jpeg`) decoded into RGBA8
   - a spectral raster represented as sampled spectra per pixel
2. Map spectral data into cone responses.
3. Map cone responses into XYZ.
4. Reproject XYZ into the linear RGB working space used by preview rendering.
5. Reconstruct the preview image with a Whittaker-Shannon-inspired windowed-sinc kernel.
6. Convolve the reconstructed image with the display panel point-spread model.
7. Quantize to 8-bit RGB output for preview display.

## Current Mathematical Surface

Implemented now:

- sampled spectra over `400nm..700nm` in `10nm` steps
- RGB -> spectrum reconstruction with a daylight-weighted basis
- direct spectrum -> XYZ integration
- XYZ <-> cone response mapping
- XYZ -> linear RGB reprojection
- direct spectral raster storage and analysis
- windowed-sinc reconstruction
- panel-aware blur / point-spread modeling
- baseline JPEG block transform, quantization, zigzag, Huffman, and marker handling
- PNG lossless filtering and zlib-wrapped stored deflate blocks

## Current Approximations

The current spectral paths are:

- `approximate`
  RGB input is reconstructed into a sampled spectrum before XYZ/cone reprojection.
- `native`
  A `SpectralRaster` or external `.spd` file can carry sampled spectra directly through the render path.

The raw CLI preview request currently defaults to `none` when `spectralMode` is omitted. The desktop shell now requests `approximate` by default for raster inputs, while `.spd` inputs enter as direct sampled spectra and render through the native spectral path.

## Rendering Notes

The renderer treats source samples as point samples and reconstructs onto the preview grid with a compact windowed-sinc kernel. The panel stage then distributes each reconstructed sample through the configured RGB stripe model. This is the current practical interpretation of the point-sample and point-spread math specified earlier.

## Codec Notes

PNG:

- lossless decode / encode
- row filtering
- CRC validation
- explicit color-type handling

JPEG:

- baseline sequential decode / encode
- YCbCr transform
- 8x8 DCT / IDCT
- scalar quantization
- canonical Huffman coding

Not implemented yet:

- progressive JPEG
- arithmetic JPEG
- lossless JPEG
- chroma-subsampling options on encode

SPD file ingest:

- binary `.spd` container
- validated dimensions, wavelength grid, and payload checksum
- resampling into the engine working grid when the source sample grid differs
- direct `.spd` export from native spectra and RGB-derived spectral reconstruction

## Maintainability Rules

- keep the math modules small and explicit
- prefer stable structs over clever metaprogramming
- keep the CLI boundary machine-readable
- expose capabilities and limits directly instead of hiding them
