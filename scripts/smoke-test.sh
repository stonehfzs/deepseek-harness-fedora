#!/usr/bin/env bash
# Smoke-test a built RPM without installing it.
#
# Extracts the package payload into build/smoke/root, then proves, in order:
#   1. the packaged files and RPM metadata are what the spec promises
#   2. the runtime starts and reports the pinned version — which also proves the
#      binary survived the build unstripped, since a stripped one segfaults
#   3. the ripgrep sidecar sits where the runtime resolves it ("<exe>-rg")
#   4. the launcher is valid POSIX shell
#   5. `dsh web` really boots and serves the UI, and the browser-trust fence
#      answers 401 on an unauthenticated request
#
# Usage:
#   scripts/smoke-test.sh [path/to.rpm] [--probe-overlay]
#
# --probe-overlay additionally asserts that the packaged overlay is still
# required, i.e. that booting without it still fails. This is the maintenance
# check for retiring the workaround after an upstream fix.

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
dsh_load_versions

rpm=""
probe_overlay=0
for arg in "$@"; do
    case "$arg" in
        --probe-overlay) probe_overlay=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) rpm=$arg ;;
    esac
done

if [ -z "$rpm" ]; then
    rpm=$(ls -t "$DSH_BUILD_DIR"/rpmbuild/RPMS/*/*.rpm 2>/dev/null | head -n1 || true)
fi
[ -n "$rpm" ] && [ -f "$rpm" ] || dsh_die "no RPM given and none built; run scripts/build-rpm.sh first"

for tool in rpm2cpio cpio curl; do
    command -v "$tool" >/dev/null 2>&1 || dsh_die "$tool not found, needed to unpack and probe the RPM"
done

work=$DSH_BUILD_DIR/smoke
root=$work/root
rm -rf -- "$work"
mkdir -p -- "$root"

failures=0
pass() { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
skip() { printf '  \033[1;33mSKIP\033[0m %s\n' "$*"; }

dsh_log "unpacking $(basename -- "$rpm")"
( cd "$root" && rpm2cpio "$rpm" | cpio -idm --quiet )

runtime=$root/usr/libexec/dsh/dsh-runtime
sidecar=$root/usr/libexec/dsh/dsh-runtime-rg
wrapper=$root/usr/bin/dsh
overlay=$root/usr/libexec/dsh/patches/00-packaged-workarounds.yml

export HOME=$work/home
mkdir -p -- "$HOME"
export XDG_CACHE_HOME=$HOME/.cache
export DSH_HOME=$HOME/.dsh
export DSH_LIBEXEC=$root/usr/libexec/dsh

dsh_log "package contents"
[ -x "$runtime" ]  && pass "runtime installed at /usr/libexec/dsh/dsh-runtime"   || fail "runtime missing"
[ -x "$sidecar" ]  && pass "ripgrep sidecar installed as dsh-runtime-rg"          || fail "ripgrep sidecar missing"
[ -x "$wrapper" ]  && pass "launcher installed at /usr/bin/dsh"                   || fail "launcher missing"
[ -f "$overlay" ]  && pass "packaged overlay installed"                           || fail "overlay missing"
[ -f "$root/usr/share/applications/io.github.deepseek-harness.desktop" ] \
    && pass "desktop entry installed" || fail "desktop entry missing"
[ -f "$root/usr/share/metainfo/io.github.deepseek-harness.metainfo.xml" ] \
    && pass "AppStream metadata installed" || fail "AppStream metadata missing"
[ -f "$root/usr/share/man/man1/dsh.1" ] || [ -f "$root/usr/share/man/man1/dsh.1.gz" ] \
    && pass "man page installed" || fail "man page missing"

dsh_log "RPM metadata"
if command -v rpm >/dev/null 2>&1; then
    rpm_name=$(rpm -qp --qf '%{NAME}' "$rpm")
    rpm_version=$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$rpm")
    [ "$rpm_name" = deepseek-harness ] && pass "package name is deepseek-harness" || fail "unexpected name: $rpm_name"
    case "$rpm_version" in
        "$DSH_RPM_VERSION"-*) pass "RPM version is $rpm_version" ;;
        *) fail "RPM version $rpm_version does not match versions.env ($DSH_RPM_VERSION)" ;;
    esac
    if rpm -qp --requires "$rpm" | grep -q '^bubblewrap'; then
        pass "declares bubblewrap (preferred sandbox backend)"
    else
        fail "bubblewrap is not declared as a dependency"
    fi
else
    skip "rpm tooling unavailable, metadata checks skipped"
fi

dsh_log "runtime behaviour"
if version_out=$("$runtime" --version 2>&1); then
    case "$version_out" in
        *"$DSH_CLI_VERSION"*) pass "runtime starts and reports $DSH_CLI_VERSION" ;;
        *) fail "runtime reported '$version_out', expected $DSH_CLI_VERSION" ;;
    esac
else
    fail "runtime failed to start (is the binary stripped?): $version_out"
fi

if sh -n "$wrapper" 2>/dev/null; then
    pass "launcher parses as POSIX shell"
else
    fail "launcher is not valid POSIX shell"
fi

# --- end-to-end: boot the browser UI through the installed launcher ----------

dsh_log "booting the web profile (this takes a few seconds)"
if command -v python3 >/dev/null 2>&1; then
    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
else
    port=$((20000 + RANDOM % 20000))
fi

web_pid=""
cleanup() {
    [ -n "$web_pid" ] && kill "$web_pid" 2>/dev/null || true
    wait "$web_pid" 2>/dev/null || true
}
trap cleanup EXIT

"$wrapper" web --port "$port" --no-open >"$work/web.log" 2>&1 &
web_pid=$!

manifest=000
for _ in $(seq 1 90); do
    manifest=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/manifest.webmanifest" 2>/dev/null || echo 000)
    [ "$manifest" = 200 ] && break
    kill -0 "$web_pid" 2>/dev/null || break
    sleep 1
done

if [ "$manifest" = 200 ]; then
    pass "web UI is served on http://127.0.0.1:$port (manifest 200)"
else
    fail "web UI did not come up (manifest HTTP $manifest)"
    sed 's/^/    | /' "$work/web.log" | tail -n 25 || true
fi

root_code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null || echo 000)
if [ "$root_code" = 401 ]; then
    pass "browser-trust fence answers 401 to an unauthenticated request"
else
    fail "expected 401 from the trust fence, got $root_code"
fi

cleanup
trap - EXIT

# --- maintenance probe: is the overlay still needed? ------------------------

if [ "$probe_overlay" = 1 ]; then
    dsh_log "probing whether the packaged overlay is still required"
    set +e
    DSH_PACKAGED_PATCH=0 "$wrapper" web --port "$port" --no-open >"$work/web-nopatch.log" 2>&1
    nopatch_status=$?
    set -e
    if [ "$nopatch_status" -ne 0 ] && grep -q 'dsh-session-title-llm' "$work/web-nopatch.log"; then
        pass "overlay is still required (upstream closure still misses dsh-session-title-llm)"
    elif [ "$nopatch_status" -eq 0 ]; then
        fail "boot succeeds without the overlay: upstream fixed the closure, retire packaging/rpm/00-packaged-workarounds.yml"
    else
        fail "boot failed without the overlay for an unexpected reason (exit $nopatch_status)"
        sed 's/^/    | /' "$work/web-nopatch.log" | tail -n 15 || true
    fi
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '\033[1;32m%s\033[0m\n' "smoke test passed"
else
    printf '\033[1;31m%s\033[0m\n' "smoke test failed: $failures check(s)"
fi
exit "$((failures > 0))"
