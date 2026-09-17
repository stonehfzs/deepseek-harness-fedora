#!/usr/bin/env bash
# Static checks for the packaging repository.
#
# Everything here is cheap and offline: it catches spec/versions drift, the
# anti-strip macros going missing, shell syntax errors, and invalid desktop or
# AppStream metadata — the failures that would otherwise only show up inside a
# full rpmbuild.

set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
dsh_load_versions

failures=0
pass() { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
skip() { printf '  \033[1;33mSKIP\033[0m %s\n' "$*"; }

spec=$DSH_REPO_ROOT/packaging/rpm/deepseek-harness.spec
wrapper=$DSH_REPO_ROOT/packaging/rpm/dsh-wrapper.sh
desktop=$DSH_REPO_ROOT/packaging/rpm/io.github.deepseek-harness.desktop
metainfo=$DSH_REPO_ROOT/packaging/rpm/io.github.deepseek-harness.metainfo.xml

dsh_log "spec <-> versions.env consistency"
spec_version=$(sed -n 's/^Version:[[:space:]]*\(.*\)$/\1/p' "$spec" | head -n1)
spec_release=$(sed -n 's/^Release:[[:space:]]*\([0-9]*\).*/\1/p' "$spec" | head -n1)
spec_pypi=$(sed -n 's/^%global pypi_ver[[:space:]]*\(.*\)$/\1/p' "$spec" | head -n1)
spec_cli=$(sed -n 's/^%global cli_version[[:space:]]*\(.*\)$/\1/p' "$spec" | head -n1)

[ "$spec_version" = "$DSH_RPM_VERSION" ] && pass "spec Version matches versions.env ($spec_version)" \
    || fail "spec Version '$spec_version' != versions.env '$DSH_RPM_VERSION'"
[ "$spec_release" = "$DSH_RPM_RELEASE" ] && pass "spec Release matches versions.env ($spec_release)" \
    || fail "spec Release '$spec_release' != versions.env '$DSH_RPM_RELEASE'"
[ "$spec_pypi" = "$DSH_RUNTIME_VERSION" ] && pass "spec pypi_ver matches versions.env ($spec_pypi)" \
    || fail "spec pypi_ver '$spec_pypi' != versions.env '$DSH_RUNTIME_VERSION'"
[ "$spec_cli" = "$DSH_CLI_VERSION" ] && pass "spec cli_version matches versions.env ($spec_cli)" \
    || fail "spec cli_version '$spec_cli' != versions.env '$DSH_CLI_VERSION'"

# The wheel URL pinned in the spec must be the one versions.env verifies,
# otherwise the RPM would embed bytes nothing ever checksummed. The spec builds
# the URL from macros, so expand it with rpmspec when available.
spec_url=$(sed -n 's/^Source0:[[:space:]]*\(.*\)$/\1/p' "$spec" | head -n1)
if command -v rpmspec >/dev/null 2>&1; then
    expanded=$(rpmspec -P "$spec" 2>/dev/null | sed -n 's/^Source0:[[:space:]]*\(.*\)$/\1/p' | head -n1)
    [ -n "$expanded" ] && spec_url=$expanded
fi
env_url=$(dsh_target_field linux-x64 url)
[ "$spec_url" = "$env_url" ] && pass "spec Source0 is the pinned, checksummed wheel" \
    || fail "spec Source0 does not match versions.env
      spec: $spec_url
      env:  $env_url"

# Every non-URL Source in the spec must be a file build-rpm.sh actually stages
# into SOURCES, otherwise rpmbuild fails late with "cannot stat".
dsh_log "spec sources are staged by build-rpm.sh"
stager=$DSH_REPO_ROOT/scripts/build-rpm.sh
spec_sources=$(rpmspec -P "$spec" 2>/dev/null | sed -n 's/^Source[0-9]*:[[:space:]]*//p')
[ -n "$spec_sources" ] || spec_sources=$(sed -n 's/^Source[0-9]*:[[:space:]]*//p' "$spec")
for src in $spec_sources; do
    case "$src" in
        http://*|https://*|ftp://*) continue ;;   # Source0: the pinned wheel
    esac
    base=$(basename -- "$src")
    if grep -q -- "$base" "$stager"; then
        pass "Source $base is staged"
    else
        fail "Source $base is declared in the spec but never staged into SOURCES by scripts/build-rpm.sh"
    fi
done

dsh_log "hard-won packaging invariants"
for macro in __brp_strip __brp_strip_comment_note __brp_strip_lto __brp_strip_static_archive; do
    grep -q "^%global $macro %{nil}" "$spec" && pass "$macro is disabled (stripping corrupts the runtime)" \
        || fail "$macro is not disabled: rpmbuild would corrupt the runtime payload"
done
grep -q '^%global debug_package %{nil}' "$spec" && pass "debuginfo generation disabled" \
    || fail "debug_package is not disabled"
grep -q 'dsh-runtime-rg' "$spec" && pass "ripgrep sidecar installed under the resolved name" \
    || fail "spec does not install the -rg sidecar next to the runtime"

dsh_log "shell syntax"
sh -n "$wrapper" && pass "packaging/rpm/dsh-wrapper.sh parses as POSIX shell" \
    || fail "packaging/rpm/dsh-wrapper.sh has a shell syntax error"
for s in "$DSH_REPO_ROOT"/scripts/*.sh "$DSH_REPO_ROOT"/scripts/lib/*.sh; do
    bash -n "$s" && pass "$(basename -- "$s") parses" || fail "$s has a syntax error"
done

if command -v shellcheck >/dev/null 2>&1; then
    dsh_log "shellcheck"
    shellcheck -S warning "$wrapper" "$DSH_REPO_ROOT"/scripts/*.sh "$DSH_REPO_ROOT"/scripts/lib/*.sh \
        && pass "shellcheck clean" || fail "shellcheck reported problems"
else
    skip "shellcheck not installed"
fi

dsh_log "desktop and AppStream metadata"
if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$desktop" && pass "desktop entry validates" || fail "desktop entry is invalid"
else
    skip "desktop-file-validate not installed"
fi
if command -v appstreamcli >/dev/null 2>&1; then
    if appstreamcli validate --no-net "$metainfo" >/dev/null 2>&1; then
        pass "AppStream metadata validates"
    else
        fail "AppStream metadata is invalid (run: appstreamcli validate --no-net $metainfo)"
    fi
else
    skip "appstreamcli not installed"
fi

dsh_log "spec parses"
if command -v rpmspec >/dev/null 2>&1; then
    if rpmspec -P "$spec" >/dev/null 2>&1; then
        pass "rpmspec can expand the spec"
    else
        fail "rpmspec cannot expand the spec"
    fi
else
    skip "rpmspec not installed"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '\033[1;32m%s\033[0m\n' "lint passed"
else
    printf '\033[1;31m%s\033[0m\n' "lint failed: $failures check(s)"
fi
exit "$((failures > 0))"
