#!/usr/bin/env bash
# Download and verify the pinned upstream runtime wheel.
#
# The wheel is the only artifact upstream publishes that contains the
# self-contained runtime; both the RPM spec and the portable-bundle builder
# derive from it. Downloads are cached in .cache/downloads and re-verified on
# every use, so a corrupted or truncated file can never reach a package.
#
# Usage:
#   scripts/fetch-runtime.sh [target|all]
#
# Prints the wheel path on the last line. With `all`, prints every target's path.

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
dsh_load_versions

target=${1:-linux-x64}

if [ "$target" = all ]; then
    for t in $DSH_TARGETS; do
        dsh_fetch_wheel "$t"
    done
    exit 0
fi

dsh_fetch_wheel "$target"
