# Packaging notes: constraints found the hard way

Everything below was discovered by running the real upstream artifact on Fedora
44 (glibc 2.41, x86_64). Each entry states the symptom, the evidence, and the
rule this repository follows. Reproduction commands assume the pinned wheel has
been fetched with `scripts/fetch-runtime.sh linux-x64`.

## 1. The runtime must never be stripped

**Symptom.** A stripped runtime segfaults immediately:

```console
$ cp <runtime> /tmp/dsh && strip --strip-all /tmp/dsh
$ DSH_HOME=/tmp/home /tmp/dsh --version
Segmentation fault (core dumped)
```

`strip --strip-debug` (equivalently `strip -g`) breaks it too, and that is
exactly what rpmbuild does by default. `/usr/lib/rpm/brp-strip` runs
`strip -g` over every single-linked ELF file in the build root that `file`
reports as "not stripped":

```console
$ grep -n 'strip -g' /usr/lib/rpm/brp-strip
    xargs -I\{\} $STRIP -g \{\}" ARG0
```

The runtime is a Node SEA carrying a virtual filesystem; rewriting its section
layout corrupts that payload. Sizes are a useful tell: 274,599,104 bytes
unstripped, 271,845,432 after `--strip-debug`, and the smaller binary is dead.

**Rule.** Disable every strip brp step in the spec, plus debuginfo extraction:

```spec
%global __brp_strip %{nil}
%global __brp_strip_comment_note %{nil}
%global __brp_strip_lto %{nil}
%global __brp_strip_static_archive %{nil}
%global debug_package %{nil}
```

`%check` runs `dsh-runtime --version` precisely so a stripped payload fails the
build instead of shipping.

## 2. The ripgrep sidecar is resolved by path convention

The file-search tool resolves ripgrep from the running executable's own path
(`node_modules/@deepseek-ai/dsh-tool-fs-search/lib/index.js`):

```js
const executableSidecar = process.platform === "win32"
    ? join(executable.dir, `${executable.name}-rg.exe`)
    : `${process.execPath}-rg`;
```

**Rule.** Installing the runtime as `dsh-runtime` requires the sidecar to be
`dsh-runtime-rg`. The spec renames both together out of the wheel, and `%check`
asserts the sidecar exists. macOS additionally ships a `-spawn-helper` for
node-pty, which keeps its upstream name next to the executable.

## 3. First boot extracts native addons into the user's cache

**Symptom.** Booting as a user whose `$HOME` is not writable fails with
`ENOENT: no such file or directory, mkdir '/home/<user>/.cache/pkg/<hash>'`, and
several plugins report they could not load (`sharp`, `dsh-subprocess-local`,
`dsh-sandbox-local`).

The runtime materializes native addons under `$XDG_CACHE_HOME/pkg` (default
`~/.cache/pkg`) on first use, keyed by content hash.

**Rule.** Nothing to package — but do not assume an immutable or read-only home
works, and point `XDG_CACHE_HOME` somewhere writable in tests and containers.
This also means a system-wide, read-only install cannot pre-warm the cache for
all users.

## 4. Upstream 0.1.5rc1 is missing a peer package, so no profile boots

**Symptom.** Every profile boot fails before anything starts:

```console
$ DSH_HOME=/tmp/h <runtime> --profile web --no-open
Error: failed to import loader entry session-title-llm
  (@deepseek-ai/dsh-session-title-first-prompt-llm):
  Cannot find package '@deepseek-ai/dsh-session-title-llm' imported from
  /snapshot/.../node_modules/@deepseek-ai/dsh-session-title-first-prompt-llm/lib/index.js
```

The row comes from the `@deepseek-ai/dsh-base` bundle patch, which every shipped
profile composes, so `web`, `headless`, `sdk`, and `acp` are all affected.

**Why it cannot be patched by adding the package.** The runtime resolves bare
specifiers through its embedded virtual filesystem via a resolve hook. Dropping
a real copy of the package into `$DSH_HOME/profiles/node_modules/@deepseek-ai/`
does **not** help: the hook consults the VFS and the generated proxy packages,
never a plain sibling directory. It failed identically with the package present.

**Fix used here.** A patch overlay that disables the one offending row:

```yaml
- id: session-title-llm
  disabled: true
```

The launcher injects it on profile boots. Verified in the composed tree:

```console
$ <runtime> --profile web --dump-config | grep -A9 'id: session-title-llm'
- id: session-title-llm
  name: '@deepseek-ai/dsh-session-title-first-prompt-llm'
  ...
  disabled: true
```

Session titles fall back to the non-LLM `session-title` plugin (first prompt,
truncated). `scripts/smoke-test.sh --probe-overlay` fails when a future release
boots fine without the overlay, which is the signal to delete it.

## 5. `--patch` cannot precede the `web` subcommand

`web` is a commander subcommand, and parent flags are rejected in front of it:

```console
$ <runtime> --patch overlay.yml web --help
error: web takes none of parent --profile, --from-default-profile, --patch,
--dump-config, or --dump-default-config
```

But the documented equivalent works, because it is a profile boot:

```console
$ <runtime> --patch overlay.yml --profile web --help     # OK
```

**Rule.** The launcher rewrites `<runtime> web <args>` into
`<runtime> --profile web --patch <overlay> <args>`, and for every other profile
boot simply prepends `--patch <overlay>`. The Windows `dsh.cmd` mirrors this.
`sh -n` plus the end-to-end boot in `smoke-test.sh` cover the rewrite.

## 6. Launcher grammar: only the leading prefix belongs to `dsh`

The launcher parses its own flags and hands everything after the first
unrecognized token to the booted app, so app flags must follow the profile
selection (`dsh web --port 8080`). The wrapper therefore classifies an
invocation by scanning only that leading prefix, and leaves `plugin`,
`--version`, and `--help` alone — `plugin` forwards its arguments to `pnpm`.

## 7. The web UI is behind a browser-trust fence

A bare request to the listening port is rejected, by design:

```console
$ curl -i http://127.0.0.1:3080/
HTTP/1.1 401 Unauthorized
dsh web authentication required; reopen the URL printed by dsh web.
```

Static assets are fenced too, so a health check must use a path the fence allows
(`/manifest.webmanifest` answers 200) or the tokenized URL. The desktop entry
runs plain `dsh web`, which prints and opens the tokenized URL — do not add
`--no-open` to it.

## 8. Sandboxing: bubblewrap first, Landlock as fallback

`@deepseek-ai/dsh-sandbox-local` probes for `bwrap` and falls back to Landlock
(`linux: ["bwrap", "landlock"]` in its runner chain). Fedora ships bubblewrap,
so the spec declares `Requires: bubblewrap` to keep the strongest backend
available.

## 9. Payload and build facts

| Fact | Value |
| --- | --- |
| Runtime executable | 274,599,104 bytes (262 MiB) |
| ripgrep sidecar | 5,728,032 bytes |
| Wheel (deflate-compressed) | 80,720,547 bytes |
| Built RPM (zstd payload) | 56 MiB |
| Installed size | 280,347,859 bytes (~267 MiB) |
| `gzip -6` of the executable | ~78.5 MB, so zstd still buys ~30% over the wheel |
| `DSH_HOME` default | `$HOME/.dsh` (the raw runtime falls back itself) |
| glibc requirement | manylinux_2_28 → glibc ≥ 2.28 |
| Dynamic libraries | libc, libdl, libm, libstdc++, libgcc_s, libpthread; no RPATH |
| RPM metadata | 56 MiB on disk, 280,347,859 bytes installed, `Provides: application()`, `metainfo()` |

Two build-time rewrites are expected and harmless: `brp-mangle-shebangs` changes
the launcher's `#!/bin/sh` to `#!/usr/bin/sh` (Fedora ships both), and
`brp-compress` gzips the man page to `dsh.1.gz` (hence the `%{_mandir}/man1/dsh.1*`
glob in `%files`).

`rpmbuild` writes only inside `--define "_topdir ..."`, and the build scripts
keep `TMPDIR` inside the checkout, so the build works in a sandbox or container
with no writable `$HOME`.

## 10. Reproducing the investigation

```console
$ scripts/fetch-runtime.sh linux-x64                    # download + verify
$ python3 -c "import zipfile,sys; \
    print('\n'.join(n for n in zipfile.ZipFile(sys.argv[1]).namelist() \
    if 'runtime/' in n))" .cache/downloads/*.whl        # payload inventory
$ scripts/smoke-test.sh --probe-overlay                 # boot + overlay probe
```
