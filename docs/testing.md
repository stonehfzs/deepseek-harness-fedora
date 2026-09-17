# Testing

Three layers, cheapest first. `make lint` is seconds, `make smoke` is about a
minute, and both are meant to run on every change.

## 1. `scripts/lint.sh` — static invariants

Offline and fast. It fails when:

* the spec's `Version`, `Release`, `%global pypi_ver`, `%global cli_version`, or
  `Source0` URL drift from `scripts/versions.env`;
* a `SourceN` is declared in the spec but never staged into `SOURCES` by
  `build-rpm.sh` (this caught a real rename bug during development);
* any `__brp_strip*` macro or `debug_package %{nil}` goes missing — the
  guarantee that the runtime is not corrupted;
* a shell script has a syntax error, or `shellcheck` (when installed) complains;
* the desktop entry or AppStream metadata is invalid;
* `rpmspec` cannot expand the spec.

## 2. `%check` during `rpmbuild` — build-time proof

Runs inside the build:

1. `dsh-runtime --version` and asserts it matches `%{cli_version}`. A stripped
   runtime segfaults here, so this is the guard for the most damaging packaging
   mistake;
2. asserts the `-rg` sidecar exists under the name the runtime resolves;
3. `desktop-file-validate` and `appstreamcli validate --no-net`;
4. `sh -n` on the installed launcher.

`rpmbuild --nocheck` (or `scripts/build-rpm.sh --no-check`) skips these for quick
iteration, at the cost of the guarantees above.

## 3. `scripts/smoke-test.sh` — end-to-end, no root required

Unpacks the built RPM into `build/smoke/root` with `rpm2cpio | cpio` and then:

| Check | Proves |
| --- | --- |
| Runtime, sidecar, launcher, overlay, desktop entry, AppStream, man page all present | the file list matches the documented layout |
| `rpm -qp` name/version, `bubblewrap` declared | package metadata is what the spec promises |
| `dsh-runtime --version` matches the pinned CLI version | the payload starts and was not stripped |
| `sh -n` on the installed launcher | the launcher is valid POSIX shell |
| `dsh web --port <free> --no-open` serves `manifest.webmanifest` with HTTP 200 | the whole chain works: launcher → overlay injection → profile boot → HTTP |
| `curl /` returns 401 | the browser-trust fence is intact (this is correct behaviour, not a failure) |

```console
$ make smoke
$ scripts/smoke-test.sh build/rpmbuild/RPMS/x86_64/deepseek-harness-*.rpm
```

### The overlay probe

```console
$ scripts/smoke-test.sh --probe-overlay
```

This additionally boots with `DSH_PACKAGED_PATCH=0` and asserts that boot still
**fails** with the missing-package error. It is the maintenance tripwire: when
upstream ships a runtime whose closure contains
`@deepseek-ai/dsh-session-title-llm`, the probe fails and tells you to retire
`packaging/rpm/00-packaged-workarounds.yml` and the launcher's injection logic.

## What has actually been verified

On Fedora 44 (KDE), x86_64, glibc 2.41, `rpmbuild` 6.0.2:

* Upstream wheel `deepseek-harness-runtime-bin 0.1.5rc1` (manylinux_2_28_x86_64)
  downloaded and SHA256-verified.
* `scripts/build-rpm.sh` produces
  `deepseek-harness-0.1.5~rc1-1.fc44.x86_64.rpm`: **56 MiB** on disk,
  280,347,859 bytes installed, with `%check` green (`--version` →
  `0.1.5-rc.1`, sidecar present, desktop entry and AppStream metadata valid).
* `scripts/smoke-test.sh` passes every check, including the two that matter most:
  `dsh web` boots and serves `manifest.webmanifest` with HTTP 200 through the
  installed launcher, and an unauthenticated `/` returns 401 from the trust
  fence.
* `scripts/smoke-test.sh --probe-overlay` confirms the overlay is still required:
  booting with `DSH_PACKAGED_PATCH=0` still fails with the missing-package error.
* The installed file list is exactly: `/usr/bin/dsh`,
  `/usr/libexec/dsh/{dsh-runtime,dsh-runtime-rg,patches/00-packaged-workarounds.yml}`,
  the desktop entry, AppStream metadata, icon, `dsh.1.gz`, doc, and license.
* Stripping the runtime (`strip --strip-all`, `strip --strip-debug`, and
  rpmbuild's `brp-strip`) reliably produces a segfaulting binary — the reason the
  anti-strip macros exist.
* The launcher's `web` → `--profile web --patch` rewrite works, and its refusal to
  inject for `plugin`/`--version`/`--help` follows the verified upstream grammar
  (`error: web takes none of parent ... --patch`).

Not verified here, and stated as such in [cross-platform.md](cross-platform.md):
executing the non-x64 payloads, and the Windows batch launcher (it needs a
Windows host or CI runner).

## Continuous integration

`.github/workflows/build.yml` runs the same entry points in a Fedora container
(RPM + smoke) and on macOS and Windows runners (portable bundles). CI cannot
execute the macOS/Windows runtimes to the same depth as Linux, so those jobs
verify packaging, checksums, and archive layout rather than a live boot.
