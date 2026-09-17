# DeepSeek Harness — Fedora packaging

Build a Fedora RPM (and portable Windows/macOS bundles) for
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`), the
agentic coding assistant with a browser UI.

The package is **self-contained**: it carries its own Node.js and the complete
plugin dependency closure, so installing it needs no `nodejs`, no `npm`, no
`pnpm`, and no network access. Install the RPM, run `dsh`, or launch
*DeepSeek Harness* from the application menu and the browser UI opens.

```console
$ make rpm          # build build/rpmbuild/RPMS/x86_64/deepseek-harness-*.rpm
$ make smoke        # unpack the RPM and prove it works (no root needed)
$ sudo dnf install ./build/rpmbuild/RPMS/x86_64/deepseek-harness-*.rpm
$ dsh web           # or: dsh --profile headless "summarize this repository"
```

## What gets installed

| Path | Purpose |
| --- | --- |
| `/usr/bin/dsh` | Launcher: locates the runtime, defaults `DSH_HOME`, applies the packaged overlay, `exec`s the runtime |
| `/usr/libexec/dsh/dsh-runtime` | The upstream self-contained runtime (~262 MiB, its own Node.js + virtual filesystem) |
| `/usr/libexec/dsh/dsh-runtime-rg` | ripgrep sidecar, resolved by the runtime as `<exe>-rg` |
| `/usr/libexec/dsh/patches/00-packaged-workarounds.yml` | Patch overlay that makes the shipped profiles boot on 0.1.5rc1 |
| `/usr/share/applications/io.github.deepseek-harness.desktop` | Menu entry that runs `dsh web` |
| `/usr/share/icons/hicolor/scalable/apps/deepseek-harness.svg` | Icon (upstream frontend asset) |
| `/usr/share/metainfo/io.github.deepseek-harness.metainfo.xml` | AppStream metadata |
| `/usr/share/man/man1/dsh.1` | Man page |

Runtime state lives in `$DSH_HOME` (default `~/.dsh`); the only other directory
the runtime writes is `$XDG_CACHE_HOME/pkg` (default `~/.cache/pkg`), where it
materializes native addons on first boot. Nothing else outside your workspace is
touched.

The built RPM is **56 MiB** on disk and installs 267 MiB — almost all of it the
runtime binary, which is a Node.js single-file application carrying the whole
plugin closure. It is packaged unstripped, deliberately: stripping it corrupts
the embedded filesystem and the result segfaults (see
[docs/packaging-notes.md](docs/packaging-notes.md#1-the-runtime-must-never-be-stripped)).

## How it works

Upstream publishes DeepSeek Harness two ways: an npm dependency tree that needs a
system Node.js, and a **per-platform single-file runtime** inside the PyPI wheel
[`deepseek-harness-runtime-bin`](https://pypi.org/project/deepseek-harness-runtime-bin/).
This repository packages the second one, because it gives the same
download-and-run experience on Fedora that the official Windows/macOS builds give
elsewhere — no toolchain, no dependency resolution at install time.

```
scripts/versions.env          pinned release + per-target URL/SHA256
        │
        ├─ scripts/build-rpm.sh ──► rpmbuild ──► deepseek-harness-<v>.fc44.x86_64.rpm
        │        spec extracts deepseek_harness_runtime/runtime/* from the wheel
        │
        └─ scripts/build-portable.sh ──► dist/deepseek-harness-<v>-<target>.tar.gz|.zip
```

The spec is the single source of truth for what lands on disk, and it stays
usable standalone for COPR or `rpmbuild` without this repository's scripts. It
extracts the payload straight from the checksum-pinned wheel, so the same bytes
that the RPM ships are the ones upstream published.

## Repository layout

```
packaging/rpm/          RPM assets: spec, launcher, desktop entry, AppStream, man page, overlay, icon
packaging/portable/     Windows/macOS launchers and portable-bundle README
scripts/versions.env    single source of truth: version + 5 target URL/SHA256 rows
scripts/fetch-runtime.sh    download + verify the pinned wheel (cached, re-verified)
scripts/build-rpm.sh        build binary RPM / SRPM / rebuild from SRPM
scripts/build-portable.sh   assemble a portable bundle for any target
scripts/smoke-test.sh       extract a built RPM and prove it runs end to end
scripts/lint.sh             spec↔versions drift, invariants, shell/desktop/AppStream checks
docs/                   design, packaging constraints, cross-platform notes, testing
```

## Requirements

* **Building the RPM** — Fedora (tested on Fedora 44): `rpm-build`, `unzip`,
  `desktop-file-utils`, `appstream`. Building needs ~1 GiB of free space and a
  few minutes for the 262 MiB payload.
* **Running it** — Fedora 40+ / any glibc ≥ 2.28 x86_64. `bubblewrap` (hard
  dependency: the preferred sandbox backend) and `xdg-utils` (opens the browser)
  are pulled in automatically. `pnpm` is recommended only for `dsh plugin`.
* **Building portable bundles** — Linux or macOS with `curl`, `unzip`, `tar`;
  `zip` for the Windows target.

## Cross-platform

The same pinned wheel mechanism produces bundles for five upstream targets:

| Target | Artifact |
| --- | --- |
| `linux-x64` | RPM, or `dist/*-linux-x64.tar.gz` |
| `linux-arm64` | `dist/*-linux-arm64.tar.gz` |
| `macos-arm64` | `dist/*-macos-arm64.tar.gz` (double-clickable `DeepSeek Harness.command`) |
| `macos-x64` | `dist/*-macos-x64.tar.gz` |
| `windows-x64` | `dist/*-windows-x64.zip` (`dsh.cmd`) |

```console
$ make portable TARGET=windows-x64
```

See [docs/cross-platform.md](docs/cross-platform.md) for what is verified and
what is not.

## Known upstream issues worked around here

Upstream 0.1.5rc1 has a gap that makes **every** shipped profile fail to boot:
the runtime closure is missing the peer package
`@deepseek-ai/dsh-session-title-llm`, which
`@deepseek-ai/dsh-session-title-first-prompt-llm` imports at load time.

* The packaged overlay disables that single row, falling back to non-LLM session
  titles. Everything else is untouched.
* `scripts/smoke-test.sh --probe-overlay` asserts the workaround is still needed,
  so a future fixed release fails loudly instead of leaving dead weight.
* Set `DSH_PACKAGED_PATCH=0` to boot without the overlay.

[docs/packaging-notes.md](docs/packaging-notes.md) documents this and every other
non-obvious constraint found while packaging, including the one that matters most:
**the runtime must never be stripped** — rpmbuild's default `brp-strip` corrupts
the embedded filesystem and the resulting binary segfaults.

## Packaging a new upstream release

1. Update `scripts/versions.env`: `DSH_RUNTIME_VERSION`, `DSH_CLI_VERSION`,
   `DSH_RPM_VERSION`, and the target rows (name, SHA256, URL).
2. Mirror the version macros in `packaging/rpm/deepseek-harness.spec`
   (`Version:`, `%global pypi_ver`, `%global cli_version`, `Source0`).
3. `make lint && make rpm && make smoke -- --probe-overlay`.

`make lint` fails if the spec and `versions.env` disagree, so step 2 cannot be
half-done. If the overlay probe now passes, upstream fixed the closure: delete
`packaging/rpm/00-packaged-workarounds.yml`, drop the `Source5` line and its
install step from the spec, and remove the launcher's injection logic.

## Troubleshooting

**`dsh` exits with a segfault or "cannot execute binary file".** The runtime was
stripped. Confirm the spec still disables `__brp_strip*` and rebuild.

**Boot fails with `ERR_MODULE_NOT_FOUND: @deepseek-ai/dsh-session-title-llm`.**
The overlay was not applied — check that
`/usr/libexec/dsh/patches/00-packaged-workarounds.yml` exists and that
`DSH_PACKAGED_PATCH` is not set to `0`.

**Boot fails with `ENOENT: mkdir '.../.cache/pkg/...'`.** `$HOME` (or
`$XDG_CACHE_HOME`) is not writable; the runtime needs it to materialize native
addons on first boot.

**The browser shows `dsh web authentication required`.** The web UI is behind a
browser-trust fence: plain requests get 401 and you must use the tokenized URL
`dsh web` prints (it opens it for you). Launch it via the desktop entry or
`dsh web`, not by visiting the port directly.

## License and trademarks

Packaging here is MIT (see [LICENSE](LICENSE)). The bundled runtime is upstream's
MIT-licensed artifact, redistributed unmodified. DeepSeek, the DeepSeek whale
mark, and Harness/DSH are trademarks of their respective owners and are used only
to identify the packaged software.
