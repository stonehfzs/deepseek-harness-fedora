#!/bin/sh
# DeepSeek Harness — double-clickable launcher for macOS.
#
# Finder runs .command files in Terminal. This simply boots the browser UI from
# the directory the bundle was unpacked into.

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$here/dsh" web
