# ginga fixtures

This directory holds small, deterministic reference assets for QA.

The current corpus uses ASCII PPM so the pixels are human-readable and the
files stay stable under source control. These are not a substitute for the real
PNG/JPEG codec pipeline; they exist so the QA layer has canonical pixel data to
compare against while the engine is still being built.

## Layout

- `rasters/` contains tiny reference images.
- `manifest.sha256` records the expected hashes of every fixture file.

