#!/bin/bash
set -euo pipefail

repository="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repository/.build" "$HOME/.local/bin"
xcrun swiftc -O "$repository/CLI/main.swift" -o "$repository/.build/uikit-app"
ln -sfn "$repository/.build/uikit-app" "$HOME/.local/bin/uikit-app"
printf 'Installed %s\n' "$HOME/.local/bin/uikit-app"
