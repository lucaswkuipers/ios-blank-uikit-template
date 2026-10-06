#!/bin/bash
set -euo pipefail
repository="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repository/.build"
xcrun swiftc "$repository/CLI/Support.swift" "$repository/CLI/AppleHTTP.swift" "$repository/CLI/AppRegistration.swift" "$repository/CLI/TestFlight.swift" "$repository/CLI/GitHub.swift" "$repository/CLI/CI.swift" "$repository/CLI/Direct.swift" "$repository/CLI/Shelf.swift" "$repository/Tests/main.swift" -o "$repository/.build/testflight-tests"
"$repository/.build/testflight-tests"
if [[ "${1:-}" == "--interactive" ]]; then
    xcrun swiftc "$repository/CLI/Support.swift" "$repository/Tests/InteractiveLogin/main.swift" -o "$repository/.build/interactive-login-tests"
    "$repository/.build/interactive-login-tests"
fi
