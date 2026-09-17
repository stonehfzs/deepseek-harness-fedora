#!/usr/bin/env bash
# Shared helpers for the DeepSeek Harness packaging scripts.
#
# This file is sourced, never executed. It stays portable across GNU/Linux and
# macOS (bash 3.2) so the portable-bundle builder can run on a macOS runner.

set -euo pipefail

# --- paths -------------------------------------------------------------------

dsh_repo_root() {
    local here
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    (cd "$here/../.." && pwd)
}

DSH_REPO_ROOT=${DSH_REPO_ROOT:-$(dsh_repo_root)}
DSH_VERSIONS_FILE=$DSH_REPO_ROOT/scripts/versions.env
DSH_CACHE_DIR=${DSH_CACHE_DIR:-$DSH_REPO_ROOT/.cache/downloads}
DSH_BUILD_DIR=${DSH_BUILD_DIR:-$DSH_REPO_ROOT/build}

# --- output ------------------------------------------------------------------

dsh_log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
dsh_warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
dsh_die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- versions.env accessors --------------------------------------------------

dsh_load_versions() {
    [ -f "$DSH_VERSIONS_FILE" ] || dsh_die "missing $DSH_VERSIONS_FILE"
    # shellcheck source=versions.env
    . "$DSH_VERSIONS_FILE"
}

# dsh_target_field <target> <name|sha256|url>
dsh_target_field() {
    local target=$1 field=$2 var value
    case "$target" in
        linux-x64|linux-arm64|macos-arm64|macos-x64|windows-x64) ;;
        *) dsh_die "unknown target '$target' (known: $DSH_TARGETS)" ;;
    esac
    var="DSH_TARGET_${target//-/_}"
    value=${!var:-}
    [ -n "$value" ] || dsh_die "no versions.env row for target '$target'"
    case "$field" in
        name)   printf '%s\n' "${value%%|*}" ;;
        sha256) printf '%s\n' "$value" | cut -d'|' -f2 ;;
        url)    printf '%s\n' "${value##*|}" ;;
        *)      dsh_die "unknown field '$field'" ;;
    esac
}

# --- portable primitives -----------------------------------------------------

dsh_file_size() {
    if stat -c %s "$1" >/dev/null 2>&1; then
        stat -c %s "$1"
    else
        stat -f %z "$1"
    fi
}

dsh_sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# --- upstream payload --------------------------------------------------------

# dsh_fetch_wheel <target> [destdir] -> prints the verified wheel path
dsh_fetch_wheel() {
    local target=$1 dest=${2:-$DSH_CACHE_DIR}
    local name sha url file got
    name=$(dsh_target_field "$target" name)
    sha=$(dsh_target_field "$target" sha256)
    url=$(dsh_target_field "$target" url)

    mkdir -p "$dest"
    file=$dest/$name

    if [ -f "$file" ] && [ "$(dsh_sha256_file "$file")" = "$sha" ]; then
        dsh_log "cached  $name"
    else
        dsh_log "fetch   $name"
        rm -f "$file" "$file.part"
        curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
            --progress-bar -o "$file.part" "$url" || dsh_die "download failed: $url"
        mv "$file.part" "$file"
    fi

    got=$(dsh_sha256_file "$file")
    [ "$got" = "$sha" ] || dsh_die "sha256 mismatch for $name
  expected $sha
  got      $got"
    printf '%s\n' "$file"
}

# dsh_extract_payload <wheel> <outdir>
# Flattens deepseek_harness_runtime/runtime/* out of the wheel.
dsh_extract_payload() {
    local wheel=$1 out=$2
    rm -rf "$out"
    mkdir -p "$out"
    unzip -q -j "$wheel" 'deepseek_harness_runtime/runtime/*' -d "$out" \
        || dsh_die "could not extract runtime payload from $wheel"
    [ -n "$(ls -A "$out")" ] || dsh_die "no files under deepseek_harness_runtime/runtime/ in $wheel"
}

# dsh_payload_main <outdir> -> prints the main executable
# The main executable is the largest file that is not a known sidecar.
dsh_payload_main() {
    local out=$1 f best= bestsize=-1 size
    for f in "$out"/*; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
            *-rg|*-rg.exe|*-spawn-helper) continue ;;
        esac
        size=$(dsh_file_size "$f")
        if [ "$size" -gt "$bestsize" ]; then
            best=$f
            bestsize=$size
        fi
    done
    [ -n "$best" ] || dsh_die "no executable payload in $out"
    printf '%s\n' "$best"
}

# dsh_payload_sidecars <outdir> -> prints every sidecar path, one per line
dsh_payload_sidecars() {
    local out=$1 f
    for f in "$out"/*; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
            *-rg|*-rg.exe|*-spawn-helper) printf '%s\n' "$f" ;;
        esac
    done
}

# dsh_payload_rg <outdir> -> prints the ripgrep sidecar, which is mandatory
dsh_payload_rg() {
    local out=$1 f
    for f in "$out"/*; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
            *-rg|*-rg.exe) printf '%s\n' "$f"; return 0 ;;
        esac
    done
    dsh_die "no ripgrep sidecar (*-rg) in $out"
}

# dsh_canonical_names <target> -> echoes "<main-name>|<rg-name>"
# The runtime resolves its ripgrep as "${process.execPath}-rg", so the sidecar
# name must track the main executable name.
dsh_canonical_names() {
    local target=$1
    case "$target" in
        windows-x64) printf '%s\n' 'dsh-runtime.exe|dsh-runtime-rg.exe' ;;
        *)           printf '%s\n' 'dsh-runtime|dsh-runtime-rg' ;;
    esac
}
