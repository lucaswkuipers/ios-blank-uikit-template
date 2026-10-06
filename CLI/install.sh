#!/bin/bash
set -euo pipefail

repository="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repository/.build" "$HOME/.local/bin"
binary="$(mktemp "$repository/.build/uikit-app.XXXXXX")"
trap 'rm -f "$binary"' EXIT
xcrun swiftc -O "$repository"/CLI/*.swift -o "$binary"
mv -f "$binary" "$repository/.build/uikit-app"
ln -sfn "$repository/.build/uikit-app" "$HOME/.local/bin/uikit-app"
printf 'Installed %s\n' "$HOME/.local/bin/uikit-app"
