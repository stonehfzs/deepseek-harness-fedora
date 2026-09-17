#!/usr/bin/env bash
# Build the Fedora RPM for the self-contained DeepSeek Harness runtime.
#
# The build is hermetic apart from the pinned, SHA256-verified wheel download:
# the spec extracts the runtime straight out of the wheel, so no Node.js, npm,
# pnpm, or network-accessible build dependency is involved.
#
# Usage:
#   scripts/build-rpm.sh                 # binary RPM
#   scripts/build-rpm.sh --srpm          # source RPM (embeds the wheel)
#   scripts/build-rpm.sh --from-srpm     # rebuild the newest SRPM offline
#   scripts/build-rpm.sh --no-check      # skip %check smoke steps
#
# Environment:
#   RPM_TOPDIR   build tree location (default build/rpmbuild)
#   DSH_CACHE_DIR  wheel cache (default .cache/downloads)

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
dsh_load_versions

mode=build
for arg in "$@"; do
    case "$arg" in
        --srpm)      mode=srpm ;;
        --from-srpm) mode=rebuild ;;
        --no-check)  DSH_SKIP_CHECK=1 ;;
        -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
        *)           dsh_die "unknown option: $arg" ;;
    esac
done

command -v rpmbuild >/dev/null 2>&1 || dsh_die "rpmbuild not found (dnf install rpm-build)"

topdir=${RPM_TOPDIR:-$DSH_BUILD_DIR/rpmbuild}
sources=$topdir/SOURCES
spec=$DSH_REPO_ROOT/packaging/rpm/deepseek-harness.spec

mkdir -p -- "$topdir"/{BUILD,BUILDROOT,RPMS,SRPMS,SOURCES,SPECS} "$DSH_BUILD_DIR/tmp"
# rpmbuild runs its scriptlets under %_tmppath (default /var/tmp) and its
# scratch tree under %_builddir. Point both inside the checkout so the build
# works in containers and sandboxes that expose no writable /var/tmp; the
# exported TMPDIR covers everything else that honours it.
export TMPDIR=$DSH_BUILD_DIR/tmp
rpm_macros=(
    --define "_topdir $topdir"
    --define "_tmppath $DSH_BUILD_DIR/tmp"
)

if [ "$mode" = rebuild ]; then
    srpm=$(ls -t "$topdir"/SRPMS/*.src.rpm 2>/dev/null | head -n1 || true)
    [ -n "$srpm" ] || dsh_die "no SRPM in $topdir/SRPMS; run scripts/build-rpm.sh --srpm first"
    dsh_log "rebuilding $(basename -- "$srpm")"
    rpmbuild --rebuild "${rpm_macros[@]}" "$srpm"
else
    dsh_log "fetching pinned runtime wheel (linux-x64)"
    wheel=$(dsh_fetch_wheel linux-x64 "$DSH_CACHE_DIR")
    cp -f -- "$wheel" "$sources/"

    # Stage the packaging assets under the names Source1..Source8 declare. The
    # spec stays self-contained and COPR-usable, so it references plain file
    # names rather than repository paths.
    dsh_log "staging packaging assets"
    install -m 0644 -- "$DSH_REPO_ROOT/packaging/rpm/dsh-wrapper.sh"                     "$sources/dsh-wrapper.sh"
    install -m 0644 -- "$DSH_REPO_ROOT/packaging/rpm/io.github.deepseek-harness.desktop" "$sources/io.github.deepseek-harness.desktop"
    install -m 0644 -- "$DSH_REPO_ROOT/packaging/rpm/io.github.deepseek-harness.metainfo.xml" "$sources/io.github.deepseek-harness.metainfo.xml"
    install -m 0644 -- "$DSH_REPO_ROOT/packaging/rpm/dsh.1"                              "$sources/dsh.1"
    install -m 0644 -- "$DSH_REPO_ROOT/packaging/rpm/00-packaged-workarounds.yml"        "$sources/00-packaged-workarounds.yml"
    install -m 0644 -- "$DSH_REPO_ROOT/packaging/rpm/icons/deepseek-harness.svg"         "$sources/deepseek-harness.svg"
    install -m 0644 -- "$DSH_REPO_ROOT/LICENSE"                                          "$sources/LICENSE"
    install -m 0644 -- "$DSH_REPO_ROOT/README.md"                                        "$sources/README.md"
    cp -f -- "$spec" "$sources/deepseek-harness.spec"

    rpmbuild_args=("${rpm_macros[@]}")
    if [ "${DSH_SKIP_CHECK:-0}" = 1 ]; then
        rpmbuild_args+=(--nocheck)
    fi

    if [ "$mode" = srpm ]; then
        dsh_log "building source RPM"
        rpmbuild "${rpmbuild_args[@]}" -bs "$sources/deepseek-harness.spec"
    else
        dsh_log "building binary RPM"
        rpmbuild "${rpmbuild_args[@]}" -bb "$sources/deepseek-harness.spec"
    fi
fi

if [ "$mode" = srpm ]; then
    out=$(ls -t "$topdir"/SRPMS/*.src.rpm 2>/dev/null | head -n1 || true)
else
    out=$(ls -t "$topdir"/RPMS/*/*.rpm 2>/dev/null | head -n1 || true)
fi
[ -n "$out" ] || dsh_die "rpmbuild finished but no RPM was produced"

dsh_log "artifact: $out"
printf '%s\n' "$out"
