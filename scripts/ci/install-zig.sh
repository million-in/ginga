#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <zig-version>" >&2
    exit 1
fi

version="$1"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$os" in
    linux|darwin) ;;
    *)
        echo "unsupported OS for Zig install: $os" >&2
        exit 1
        ;;
esac

arch="$(uname -m)"
case "$arch" in
    x86_64|amd64)
        arch="x86_64"
        ;;
    arm64|aarch64)
        arch="aarch64"
        ;;
    *)
        echo "unsupported architecture for Zig install: $arch" >&2
        exit 1
        ;;
esac

archive_name="zig-${os}-${arch}-${version}.tar.xz"
download_url="https://ziglang.org/download/${version}/${archive_name}"
temp_root="${RUNNER_TEMP:-$(mktemp -d)}"
archive_path="$temp_root/$archive_name"
install_dir="$temp_root/zig-$version"

rm -rf "$install_dir"
mkdir -p "$install_dir"

curl -fsSL \
    --retry 5 \
    --retry-delay 2 \
    --retry-all-errors \
    "$download_url" \
    -o "$archive_path"

tar -xJf "$archive_path" -C "$install_dir" --strip-components=1

if [ -n "${GITHUB_PATH:-}" ]; then
    printf '%s\n' "$install_dir" >> "$GITHUB_PATH"
else
    export PATH="$install_dir:$PATH"
fi

"$install_dir/zig" version
