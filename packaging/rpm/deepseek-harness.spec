# deepseek-harness.spec — Fedora RPM for the self-contained DeepSeek Harness runtime.
#
# What this packages
# ------------------
# Upstream ships DeepSeek Harness two ways: an npm dependency tree that needs a
# system Node.js, and a per-platform single-file runtime published inside the
# PyPI wheel `deepseek-harness-runtime-bin`. This spec packages the latter, so
# the RPM carries its own Node.js and needs no `nodejs` package, no npm install
# step, and no network access at install time. The same wheel mechanism feeds
# the portable Windows/macOS bundles built by scripts/build-portable.sh.
#
# Packaging constraints that are NOT optional (see docs/packaging-notes.md)
# ------------------------------------------------------------------------
# * The runtime is a Node SEA carrying a virtual filesystem. binutils strip,
#   including the `strip -g` that rpmbuild's brp-strip runs by default,
#   corrupts that payload: the stripped binary segfaults on startup. All strip
#   brp scripts are therefore disabled, and debuginfo extraction is pointless
#   (there are no symbols worth splitting out of a 274 MB blob).
# * The ripgrep search tool is an external sidecar resolved as
#   `${process.execPath}-rg`, so it must be installed next to the runtime with
#   exactly that name.
# * On first boot the runtime materializes native addons under
#   `$XDG_CACHE_HOME/pkg` (default `~/.cache/pkg`), so $HOME must be writable.
#   The launcher does not and cannot pre-seed that cache system-wide.
# * Upstream 0.1.5rc1 is missing the peer package
#   `@deepseek-ai/dsh-session-title-llm`, which makes every profile composed
#   over `@deepseek-ai/dsh-base` fail to boot with ERR_MODULE_NOT_FOUND. The
#   packaged overlay under the runtime's patches directory disables the one row
#   that imports it. Delete the overlay once upstream ships a fixed runtime.

%global pypi_ver     0.1.5rc1
%global pypi_tag     py3-none-manylinux_2_28_x86_64
%global wheel_name   deepseek_harness_runtime_bin-%{pypi_ver}-%{pypi_tag}.whl
%global cli_version  0.1.5-rc.1

%global _dsh_libexec %{_libexecdir}/dsh

# Never let rpmbuild rewrite the runtime executable. See the note above.
%global __brp_strip %{nil}
%global __brp_strip_comment_note %{nil}
%global __brp_strip_lto %{nil}
%global __brp_strip_static_archive %{nil}
%global debug_package %{nil}

Name:           deepseek-harness
Version:        0.1.5~rc1
Release:        1%{?dist}
Summary:        Self-contained DeepSeek Harness agent CLI and browser UI

License:        MIT
URL:            https://github.com/deepseek-ai/deepseek-harness
Source0:        https://files.pythonhosted.org/packages/bc/ff/632fddc738effdbc8752f02641aba6eaeb96f820367b8cee68397501948d/%{wheel_name}
Source1:        dsh-wrapper.sh
Source2:        io.github.deepseek-harness.desktop
Source3:        io.github.deepseek-harness.metainfo.xml
Source4:        dsh.1
Source5:        00-packaged-workarounds.yml
Source6:        deepseek-harness.svg
Source7:        LICENSE
Source8:        README.md

BuildArch:      x86_64
ExclusiveArch:  x86_64

# bubblewrap is the preferred sandbox backend; the runtime falls back to
# Landlock when it is unusable.
Requires:       bubblewrap
# `dsh web` opens the authenticated URL in the user's browser.
Requires:       xdg-utils
# Optional: `dsh plugin` forwards to pnpm inside a profile directory.
Recommends:     pnpm

BuildRequires:  unzip
BuildRequires:  desktop-file-utils
BuildRequires:  appstream

%description
DeepSeek Harness is an agentic coding assistant: it runs shell and file tools
against your working directory, talks to any configured model provider, and
serves a browser UI.

This package installs the upstream per-platform runtime executable, which
carries its own Node.js and the complete plugin dependency closure, so neither
a system Node.js nor an npm/pnpm install is required. It provides:

  * `dsh`, the profile launcher (web, headless, sdk, acp, and custom profiles)
  * `dsh web`, the browser UI, plus a desktop entry to launch it
  * the ripgrep sidecar used by the file-search tool

Sessions live in $DSH_HOME (default ~/.dsh). Nothing outside that directory and
the user's cache is written to at runtime.

%prep
%setup -q -c -T

# The wheel stores the runtime under deepseek_harness_runtime/runtime/. Flatten
# it and give the two payload files canonical names: the main executable is the
# largest file, and the ripgrep sidecar is the one whose name ends in -rg. The
# runtime resolves that sidecar as "${process.execPath}-rg", so renaming both
# together is required and sufficient.
mkdir -p runtime
unzip -q -j %{SOURCE0} 'deepseek_harness_runtime/runtime/*' -d runtime

main=$(find runtime -maxdepth 1 -type f ! -name '*-rg' -printf '%s %p\n' | sort -rn | head -n1 | cut -d' ' -f2-)
side=$(find runtime -maxdepth 1 -type f -name '*-rg' | head -n1)

if [ -z "$main" ] || [ -z "$side" ]; then
    echo "deepseek-harness: unexpected wheel layout in %{SOURCE0}" >&2
    echo "  main executable found: '${main:-<none>}'" >&2
    echo "  -rg sidecar found:     '${side:-<none>}'" >&2
    exit 1
fi

mv "$main" dsh-runtime
mv "$side" dsh-runtime-rg
chmod 0755 dsh-runtime dsh-runtime-rg

%build
# Nothing to compile: the payload is upstream's prebuilt runtime.

%install
install -d %{buildroot}%{_dsh_libexec}/patches
install -m 0755 dsh-runtime    %{buildroot}%{_dsh_libexec}/dsh-runtime
install -m 0755 dsh-runtime-rg %{buildroot}%{_dsh_libexec}/dsh-runtime-rg
install -m 0644 %{SOURCE5}     %{buildroot}%{_dsh_libexec}/patches/00-packaged-workarounds.yml

install -d %{buildroot}%{_bindir}
install -m 0755 %{SOURCE1} %{buildroot}%{_bindir}/dsh

install -d %{buildroot}%{_datadir}/applications
install -m 0644 %{SOURCE2} %{buildroot}%{_datadir}/applications/io.github.deepseek-harness.desktop

install -d %{buildroot}%{_datadir}/icons/hicolor/scalable/apps
install -m 0644 %{SOURCE6} %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/deepseek-harness.svg

install -d %{buildroot}%{_datadir}/metainfo
install -m 0644 %{SOURCE3} %{buildroot}%{_datadir}/metainfo/io.github.deepseek-harness.metainfo.xml

install -d %{buildroot}%{_mandir}/man1
install -m 0644 %{SOURCE4} %{buildroot}%{_mandir}/man1/dsh.1

install -d %{buildroot}%{_licensedir}/%{name}
install -m 0644 %{SOURCE7} %{buildroot}%{_licensedir}/%{name}/LICENSE
install -d %{buildroot}%{_docdir}/%{name}
install -m 0644 %{SOURCE8} %{buildroot}%{_docdir}/%{name}/README.md

%check
# 1. The runtime must start and report upstream's version. This also proves the
#    binary survived the build unstripped, because a stripped one segfaults.
export HOME="$PWD/check-home"
mkdir -p "$HOME"
DSH_HOME="$HOME/.dsh" XDG_CACHE_HOME="$HOME/.cache" \
    %{buildroot}%{_dsh_libexec}/dsh-runtime --version | tee "$HOME/version.txt"
grep -q '%{cli_version}' "$HOME/version.txt"

# 2. The sidecar must sit exactly where the runtime looks for it.
test -x "%{buildroot}%{_dsh_libexec}/dsh-runtime-rg"

# 3. Desktop integration metadata must be valid.
desktop-file-validate %{buildroot}%{_datadir}/applications/io.github.deepseek-harness.desktop
appstreamcli validate --no-net %{buildroot}%{_datadir}/metainfo/io.github.deepseek-harness.metainfo.xml || :
# 4. The launcher must be syntactically valid POSIX shell.
sh -n %{buildroot}%{_bindir}/dsh

%files
%license %{_licensedir}/%{name}/LICENSE
%doc %{_docdir}/%{name}/README.md
%{_bindir}/dsh
%{_dsh_libexec}/dsh-runtime
%{_dsh_libexec}/dsh-runtime-rg
%{_dsh_libexec}/patches/00-packaged-workarounds.yml
%{_datadir}/applications/io.github.deepseek-harness.desktop
%{_datadir}/icons/hicolor/scalable/apps/deepseek-harness.svg
%{_datadir}/metainfo/io.github.deepseek-harness.metainfo.xml
%{_mandir}/man1/dsh.1*

%changelog
* Thu Sep 17 2026 Jingyu Sun <965388214@qq.com> - 0.1.5~rc1-1
- Initial package: upstream 0.1.5rc1 self-contained runtime, launcher,
  desktop entry, AppStream metadata, man page, and the session-title overlay
  workaround for the upstream closure gap.
