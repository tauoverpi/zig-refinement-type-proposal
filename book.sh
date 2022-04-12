#!/bin/sh

check() {
    acpi
    zangle call proposal.md --file="$l" > /tmp/tmp.zig
    zig fmt --ast-check /tmp/tmp.zig
}

zangle ls README.md | sed '/\.prf/d' | while read -r l; do check "$l"; done
