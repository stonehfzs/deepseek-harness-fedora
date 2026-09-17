#!/usr/bin/env bash
# Build a portable, self-contained DeepSeek Harness bundle for one target.
#
# Same upstream payload as the RPM, without a package manager: a directory with
# the runtime, its sidecars, the packaged overlay, and a launcher, packed into
# a .tar.gz (Linux/macOS) or .zip (Windows). Unpack and run — no Node.js, no
# npm, no installer.
#
# Usage:
#   scripts/build-portable.sh <target>
#   targets: linux-x64 linux-arm64 macos-arm64 macos-x64 windows-x64
#
# Output: dist/deepseek-harness-<version>-<target>.tar.gz|.zip

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
dsh_load_versions

target=${1:-}
[ -n "$target" ] || dsh_die "usage: build-portable.sh <target>  (targets: $DSH_TARGETS)"

dist=$DSH_REPO_ROOT/dist
work=$DSH_BUILD_DIR/portable/$target
stage=$work/deepseek-harness-$DSH_RUNTIME_VERSION-$target

dsh_log "fetching pinned runtime wheel ($target)"
wheel=$(dsh_fetch_wheel "$target" "$DSH_CACHE_DIR")

dsh_log "extracting payload"
dsh_extract_payload "$wheel" "$work/payload"

main=$(dsh_payload_main "$work/payload")
rg=$(dsh_payload_rg "$work/payload")
IFS='|' read -r main_name rg_name <<<"$(dsh_canonical_names "$target")"

rm -rf -- "$stage"
mkdir -p -- "$stage/patches"

dsh_log "assembling bundle"
cp -f -- "$main" "$stage/$main_name"
cp -f -- "$rg"   "$stage/$rg_name"
chmod 0755 -- "$stage/$main_name" "$stage/$rg_name"

# Any further sidecar keeps its upstream name; on macOS that is node-pty's
# spawn-helper, which the runtime expects next to itself. The ripgrep sidecar
# was already copied under its canonical name, so skip the original.
while IFS= read -r extra; do
    [ -n "$extra" ] || continue
    case "$(basename -- "$extra")" in
        "$(basename -- "$main")"|"$(basename -- "$rg")") continue ;;
    esac
    cp -f -- "$extra" "$stage/$(basename -- "$extra")"
    chmod 0755 -- "$stage/$(basename -- "$extra")"
done < <(dsh_payload_sidecars "$work/payload")

cp -f -- "$DSH_REPO_ROOT/packaging/rpm/00-packaged-workarounds.yml" \
       "$stage/patches/00-packaged-workarounds.yml"

case "$target" in
    windows-x64)
        cp -f -- "$DSH_REPO_ROOT/packaging/portable/windows/dsh.cmd" "$stage/dsh.cmd"
        cp -f -- "$DSH_REPO_ROOT/packaging/portable/README.md"       "$stage/README.md"
        ;;
    macos-*)
        cp -f -- "$DSH_REPO_ROOT/packaging/rpm/dsh-wrapper.sh" "$stage/dsh"
        cp -f -- "$DSH_REPO_ROOT/packaging/portable/macos/dsh.command" "$stage/DeepSeek Harness.command"
        chmod 0755 -- "$stage/dsh" "$stage/DeepSeek Harness.command"
        cp -f -- "$DSH_REPO_ROOT/packaging/portable/README.md" "$stage/README.md"
        ;;
    *)
        cp -f -- "$DSH_REPO_ROOT/packaging/rpm/dsh-wrapper.sh" "$stage/dsh"
        chmod 0755 -- "$stage/dsh"
        cp -f -- "$DSH_REPO_ROOT/packaging/portable/README.md" "$stage/README.md"
        ;;
esac

mkdir -p -- "$dist"
case "$target" in
    windows-x64)
        out=$dist/deepseek-harness-$DSH_RUNTIME_VERSION-$target.zip
        rm -f -- "$out"
        # `zip` is not guaranteed on Windows CI runners; python3 is.
        if command -v zip >/dev/null 2>&1; then
            (cd "$work" && zip -q -r "$out" "$(basename -- "$stage")")
        elif command -v python3 >/dev/null 2>&1; then
            (cd "$work" && python3 -m zipfile -c "$out" "$(basename -- "$stage")")
        else
            dsh_die "need either zip or python3 to build the Windows bundle"
        fi
        ;;
    *)
        out=$dist/deepseek-harness-$DSH_RUNTIME_VERSION-$target.tar.gz
        rm -f -- "$out"
        tar -C "$work" -czf "$out" "$(basename -- "$stage")"
        ;;
esac

dsh_log "artifact: $out"
printf '%s\n' "$out"
