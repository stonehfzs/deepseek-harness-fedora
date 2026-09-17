#!/bin/sh
# dsh — launcher for the packaged DeepSeek Harness runtime.
#
# Installed by the deepseek-harness RPM as /usr/bin/dsh, and reused verbatim by
# the portable Linux/macOS bundles, where it sits next to the runtime payload.
#
# What it does:
#   1. locate the runtime (next to this script for portable bundles, otherwise
#      the system libexec directory)
#   2. default DSH_HOME the way upstream does (~/.dsh)
#   3. apply the packaged patch overlay on profile boots, because the shipped
#      profiles do not boot on upstream 0.1.5rc1 without it
#      (see docs/packaging-notes.md)
#   4. exec the runtime, preserving argv, stdio, exit status, and signals
#
# Escape hatches:
#   DSH_LIBEXEC=/path      use a different runtime directory
#   DSH_PACKAGED_PATCH=0   never inject the packaged overlay
#   DSH_PACKAGED_PATCH=/p  inject a different overlay file
#
# `--patch` is a launcher ("parent") flag, and commander rejects parent flags in
# front of the `web` subcommand:
#     dsh --patch x web      -> error: web takes none of parent --patch ...
#     dsh --patch x --profile web   -> fine
# so the `web` alias is rewritten to its documented `--profile web` equivalent
# instead of being prefixed.

set -u

self_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

if [ -n "${DSH_LIBEXEC:-}" ]; then
    libexec=$DSH_LIBEXEC
elif [ -x "$self_dir/dsh-runtime" ]; then
    # Portable bundle: the payload sits next to this script. Prefer it over any
    # system install so a bundle never silently runs a different runtime.
    libexec=$self_dir
elif [ -x /usr/libexec/dsh/dsh-runtime ]; then
    # RPM install: /usr/bin/dsh with the payload in the libexec directory.
    libexec=/usr/libexec/dsh
else
    libexec=$self_dir
fi

runtime=$libexec/dsh-runtime
if [ ! -x "$runtime" ]; then
    echo "dsh: runtime executable not found at $runtime" >&2
    echo "dsh: install the deepseek-harness package, or set DSH_LIBEXEC" >&2
    exit 127
fi

: "${DSH_HOME:=$HOME/.dsh}"
export DSH_HOME

overlay=${DSH_PACKAGED_PATCH:-$libexec/patches/00-packaged-workarounds.yml}

# Classify the invocation by scanning the launcher's own leading flag prefix.
# Only profile boots compose a plugin tree; `plugin` forwards to pnpm and
# --version/--help never boot, so none of those get the overlay.
kind=none
if [ "${1:-}" = web ]; then
    kind=web
else
    skip_next=no
    for arg in "$@"; do
        if [ "$skip_next" = yes ]; then
            skip_next=no
            continue
        fi
        case "$arg" in
            -V|--version|-h|--help) kind=noop; break ;;
            plugin) kind=noop; break ;;
            --profile|--from-default-profile) kind=profile; break ;;
            --dump-config|--dump-default-config) kind=dump; break ;;
            --patch) skip_next=yes; continue ;;
            -*) continue ;;
            *) kind=noop; break ;;
        esac
    done
fi

if [ "$kind" != none ] && [ "$kind" != noop ]; then
    if [ "$overlay" = 0 ]; then
        :
    elif [ ! -f "$overlay" ]; then
        echo "dsh: packaged overlay $overlay is missing; booting without it" >&2
    elif [ "$kind" = web ]; then
        shift                       # drop the `web` alias
        set -- --profile web --patch "$overlay" "$@"
    else
        set -- --patch "$overlay" "$@"
    fi
fi

exec "$runtime" "$@"
