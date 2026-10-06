#!/bin/bash
set -euo pipefail
repository="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repository/.build"
xcrun swiftc "$repository/CLI/Support.swift" "$repository/CLI/TestFlight.swift" "$repository/Tests/main.swift" -o "$repository/.build/testflight-tests"
"$repository/.build/testflight-tests"
