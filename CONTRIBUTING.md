# Contributing

## Scope

`ginga` is built around a simple rule: the Zig engine owns the image logic. The desktop shell is a front-end to that engine, not a parallel implementation.

When contributing:

- keep image-processing logic in Zig unless there is a strong reason not to
- keep the CLI boundary machine-readable
- prefer small, explicit modules over clever abstractions
- avoid adding third-party codec or rendering dependencies

## Setup

```bash
bun install
export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global"
export ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
```

## Build And Test

```bash
zig build test
bun run check
bash scripts/ci/quality-gate.sh
```

If you are changing the desktop shell, also run:

```bash
bun run desktop:build
```

If you are changing engine or CLI behavior, also probe the binary directly:

```bash
ginga --help
ginga capabilities
```

## Code Expectations

- Keep code readable and direct.
- Do not hide limits; expose them through errors, capabilities, or documentation.
- Preserve the Zig engine as the source of truth for decode, convert, preview, and spectral behavior.
- Keep Electron TypeScript thin and UI-focused.
- Add or update tests when behavior changes.

## Documentation Expectations

- Product-facing overview belongs in `README.md`.
- Technical behavior belongs in `docs/`.
- Status tracking belongs in `progress.md`.

## Pull Requests

A good pull request should include:

- a clear summary of the behavior change
- test coverage or an explanation of why tests were not changed
- documentation updates when user-facing behavior changed
- explicit notes on limits, tradeoffs, or unsupported cases

