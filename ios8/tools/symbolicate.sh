#!/usr/bin/env bash
#
# Symbolicate Moonlight frames from an iOS crash report (.ips) using the
# binaries and dSYMs of the build in ios8/build.
#
# usage: ios8/tools/symbolicate.sh <arch> <image base> <address>...
#
#   arch        armv7 or arm64 ("Code Type" / Binary Images line of the report)
#   image base  load address of Moonlight from the "Binary Images" section
#   address     addresses of Moonlight frames from the backtrace
#
# Example, for "0xbe000 - 0x295fff Moonlight armv7" and frame "0x00179a0a":
#   ios8/tools/symbolicate.sh armv7 0xbe000 0x00179a0a 0x000c4550
#
# Only meaningful if the report's slice_uuid matches the UUID printed below,
# i.e. the report comes from this exact build.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/ios8/build}"

find_tool() {
    local name="$1" candidate
    if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return; fi
    for candidate in /usr/lib/llvm-*/bin/"$name"; do
        if [ -x "$candidate" ]; then echo "$candidate"; return; fi
    done
    echo "error: $name not found" >&2
    exit 1
}

if [ $# -lt 3 ]; then
    sed -n '3,16p' "$0" >&2
    exit 1
fi

arch="$1" base="$2"
shift 2
case "$arch" in
    armv7|arm64) ;;
    *) echo "error: unknown architecture '$arch'" >&2; exit 1 ;;
esac
for value in "$base" "$@"; do
    if ! [[ "$value" =~ ^0x[0-9a-fA-F]+$ ]]; then
        echo "error: '$value' is not a hex address" >&2
        exit 1
    fi
done

binary="$BUILD_DIR/obj/$arch/Moonlight"
dsym="$BUILD_DIR/dSYM/Moonlight.$arch.dSYM"
OTOOL="$(find_tool llvm-otool)"
SYMBOLIZER="$(find_tool llvm-symbolizer)"

uuid=$("$OTOOL" -l "$binary" | awk '/LC_UUID/ { getline; getline; print $2 }')
text_vmaddr=$("$OTOOL" -l "$binary" | awk '/segname __TEXT$/ { getline; print $2; exit }')
echo "Build UUID ($arch): $uuid"
echo "__TEXT vmaddr: $text_vmaddr, image base in report: $base"
echo

for address in "$@"; do
    unslid=$(printf '0x%x' $(( address - base + text_vmaddr )))
    echo "$address -> $unslid"
    "$SYMBOLIZER" --obj="$binary" --dsym-hint="$dsym" --inlining --pretty-print "$unslid" | sed 's/^/    /'
done
