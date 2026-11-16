#!/bin/bash
# PhoneLogic.swift 단위 테스트: ./mac/tests/run.sh
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -swift-version 5 "$ROOT/mac/PhoneLogic.swift" "$ROOT/mac/tests/main.swift" -o "$TMP/tests"
"$TMP/tests"
