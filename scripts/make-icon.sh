#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
renderer=$(mktemp -d)
trap 'rm -rf "$renderer"' EXIT
swiftc -module-cache-path "$renderer/cache" Sources/Guillotine/GuillotineGlyph.swift scripts/make-icon.swift -o "$renderer/make-icon"
"$renderer/make-icon"
