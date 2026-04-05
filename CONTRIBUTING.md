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

## AI-Assisted Contributions

We are open to AI-assisted contributions on issues and pull requests. The bar is the same as any other contribution: you must understand and be able to defend the code you submit.

If you used an AI tool (Claude, Copilot, Cursor, etc.) to write or modify code:

- You are expected to explain every change in your PR when asked.
- You should be able to describe why a particular approach was chosen over alternatives.
- If you cannot explain a block of code you submitted, the PR will be closed.
- Letting an agent run unsupervised and opening a PR against the output is not a contribution. Review what it wrote, understand it, then submit.
- You must verify that the parts of the codebase affected by your changes still work correctly. Run `zig build test` for engine changes, `bun run check` for desktop changes, and confirm your edits do not break neighboring code paths. "The AI wrote it and the tests pass" is not sufficient — you need to understand why a change is correct and what else it could have affected.
- If your change touches a module (e.g., a codec, the render pipeline, the spectral path), you should be able to explain the data flow through that module and how your change fits into it. Reviewers will ask.

The goal is not to gatekeep tooling. The goal is to keep the codebase in a state where every contributor can reason about every line. If you can do that with AI help, great.

## Pull Requests

A good pull request should include:

- a clear summary of the behavior change
- test coverage or an explanation of why tests were not changed
- documentation updates when user-facing behavior changed
- explicit notes on limits, tradeoffs, or unsupported cases

