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
- approximate RGB -> spectrum lifting
- direct spectrum -> cone response integration
- cone response -> XYZ mapping
- XYZ -> linear RGB reprojection
- direct spectral raster storage and analysis
- windowed-sinc reconstruction
- panel-aware blur / point-spread modeling
- baseline JPEG block transform, quantization, zigzag, Huffman, and marker handling
- PNG lossless filtering and zlib-wrapped stored deflate blocks

## Current Approximations

The engine is not yet a full SPD-native ingest pipeline from file formats. The current spectral paths are:

- `approximate`
  RGB input is lifted to a smooth basis spectrum before cone/XYZ reprojection.
- `native`
  A `SpectralRaster` can carry sampled spectra directly through the render path.

That means the renderer can now operate on direct spectra in-core, but the file codecs still decode into raster RGB data first.

## Rendering Notes

The renderer treats source samples as point samples and reconstructs onto the preview grid with a compact windowed-sinc kernel. The panel stage then distributes each reconstructed sample through the configured RGB stripe model. This is the current practical interpretation of the point-sample and point-spread math you specified earlier.

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
- direct spectral file formats

## Maintainability Rules

- keep the math modules small and explicit
- prefer stable structs over clever metaprogramming
- keep the CLI boundary machine-readable
- expose capabilities and limits directly instead of hiding them
