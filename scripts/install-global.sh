#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY_PATH="${1:-$ROOT/zig-out/bin/ginga}"

if [ ! -x "$BINARY_PATH" ]; then
    echo "ginga binary not found at $BINARY_PATH" >&2
    exit 1
fi

choose_install_dir() {
    if [ -n "${GINGA_INSTALL_DIR:-}" ]; then
        printf '%s\n' "$GINGA_INSTALL_DIR"
        return
    fi

    if [ -n "${CI:-}" ]; then
        printf '%s\n' "$ROOT/.bin"
        return
    fi

    if [ -d "/opt/homebrew/bin" ] && [ -w "/opt/homebrew/bin" ]; then
        printf '%s\n' "/opt/homebrew/bin"
        return
    fi

    if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
        printf '%s\n' "/usr/local/bin"
        return
    fi

    printf '%s\n' "${HOME}/.local/bin"
}

ensure_path_export() {
    local install_dir="$1"

    if [ -n "${GINGA_INSTALL_DIR:-}" ] || [ "${GINGA_SKIP_SHELL_EXPORT:-0}" = "1" ]; then
        return
    fi

    case ":${PATH:-}:" in
        *":$install_dir:"*) return ;;
    esac

    if [ -z "${HOME:-}" ]; then
        return
    fi

    local rc_file="${HOME}/.zshrc"
    local export_line="export PATH=\"$install_dir:\$PATH\""

    if ! touch "$rc_file" 2>/dev/null; then
        printf 'warning: could not update %s; add %s to PATH manually\n' "$rc_file" "$install_dir" >&2
        return
    fi

    if ! grep -Fqx "$export_line" "$rc_file"; then
        printf '\n# ginga CLI\n%s\n' "$export_line" >>"$rc_file"
    fi
}

install_dir="$(choose_install_dir)"
mkdir -p "$install_dir"
cp "$BINARY_PATH" "$install_dir/ginga"
chmod 755 "$install_dir/ginga"
ensure_path_export "$install_dir"

printf 'installed ginga to %s\n' "$install_dir/ginga"
