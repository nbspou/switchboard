#!/bin/sh
# Compiles tool/aot_smoke.dart to a native executable and runs it.
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/switchboard_aot_smoke"
dart compile exe tool/aot_smoke.dart -o "$out"
"$out"
