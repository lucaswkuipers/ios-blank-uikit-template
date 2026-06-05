#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Developer/Xcode/Templates/Project Templates/iOS/Application"

mkdir -p "$DEST"
rm -rf "$DEST/Programmatic UIKit App.xctemplate"
cp -R "$SCRIPT_DIR/iOS/Application/Programmatic UIKit App.xctemplate" "$DEST/"

echo "Installed Programmatic UIKit App template to:"
echo "  $DEST/Programmatic UIKit App.xctemplate"
echo ""
echo "Quit and reopen Xcode, then choose:"
echo "  File → New → Project → iOS → Application → Programmatic UIKit App"
