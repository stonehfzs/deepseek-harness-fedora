# Design: packaging DeepSeek Harness for Fedora

## Goal

Let a Fedora user get DeepSeek Harness the way users on other platforms get it —
download one thing, run it — while keeping the package maintainable, verifiable,
and honest about what it ships.

Concretely:

1. `sudo dnf install deepseek-harness-*.rpm` followed by `dsh` (or the menu entry)
   must work with no further setup.
2. No `nodejs`/`npm`/`pnpm` requirement, no install-time downloads.
3. The packaged bytes must be traceable to an upstream release and verifiable by
   checksum.
4. The same mechanism should extend to Windows and macOS without a second
   packaging story.
5. Everything a future maintainer needs to know must be in the repository, not in
   someone's head.

## What upstream actually publishes

| Artifact | Self-contained? | Notes |
| --- | --- | --- |
| npm package `@deepseek-ai/dsh` (+ ~240 deps) | No | Needs Node ≥ 22.19; ~292 MiB unpacked; `dsh plugin` also wants pnpm |
| PyPI `deepseek-harness-runtime-bin` wheels | **Yes** | One single-file runtime per platform, its own Node, virtual filesystem; Linux x64/arm64, macOS arm64/x64, Windows x64 |
| Source repository | No | Building requires pnpm, a full monorepo build, and a `build-exe-for-python-sdk.ts` deploy step |
| Community Electron wrappers | Varies | Third-party, separate trust and update chain |

The PyPI wheel is the only **official, self-contained, per-platform** artifact.
Its README states the runtime "packages the normal `dsh` CLI and its closed Node
dependency tree into a native executable, so SDK use requires no system Node.js",
which is exactly the property a Linux package wants.

## Options considered

| | A. System Node + npm tree | B. Bundle the PyPI runtime | C. Wrap the Python wheel | D. Build from source | E. Ship an Electron wrapper |
| --- | --- | --- | --- | --- | --- |
| Install-time network | No (if vendored) but ~292 MiB of `node_modules` | No | No | No | No |
| Requires system Node | **Yes** (≥ 22.19) | No | No, but requires Python ≥ 3.10 | No | No |
| Matches upstream release bytes | Only per-package versions | **Yes** (checksum-pinned) | Yes | No (rebuilt) | No |
| Fedora packaging cleanliness | Poor: vendored npm tree, unbundling rules | Blob redistribution, needs a note | Draags in a Python runtime for a CLI | Best on paper, heaviest to maintain | Unrelated trust chain |
| Cross-platform reuse | Per-platform npm installs | **Same wheel mechanism for 5 targets** | Same | Different build per platform | Only what Electron supports |
| Verified working here | Yes (this GUI runs on it) | Yes (after the overlay workaround) | Not attempted | Not attempted | Not attempted |

**Chosen: B**, with A documented as the fallback if a future release stops
shipping a usable runtime.

Rationale: it gives the "one file, just runs" experience that motivated the
request, keeps the shipped bytes bit-identical to upstream's own release, makes
the RPM independent of Fedora's Node.js version, and reuses one pinned-download
mechanism for Windows and macOS bundles.

The cost is that the package redistributes a 262 MiB prebuilt blob. That is
acceptable for a side-load/COPR package; it is the reason this package is **not**
shaped for an official Fedora submission, where vendored binaries of this kind
would be rejected. That trade-off is recorded here deliberately.

## Architecture

```
                 scripts/versions.env   (version + 5 × URL/SHA256)
                          │
        ┌─────────────────┴──────────────────┐
        │                                    │
 scripts/build-rpm.sh                scripts/build-portable.sh
        │                                    │
   wheel → SOURCES/                     wheel → payload/
        │                                    │  rename to dsh-runtime[.exe] + dsh-runtime-rg[.exe]
   rpmbuild -bb                             │  keep other sidecars (macOS -spawn-helper)
        │                                    │  copy launcher + overlay + README
   deepseek-harness-<v>.fc44.x86_64.rpm  dist/deepseek-harness-<v>-<target>.tar.gz|.zip
```

Both paths run the same three steps: **fetch and verify** the pinned wheel,
**extract and normalize** the payload (`dsh-runtime` + `<same>-rg`), and **add the
packaging layer** (launcher, overlay, desktop integration or bundle README).

### Why a launcher script instead of shipping the runtime as `/usr/bin/dsh`

The raw executable would work for `dsh web`, but a wrapper buys three things that
cannot be expressed in an RPM file list:

1. **Defaults.** `DSH_HOME` is pinned to `~/.dsh`, so behaviour does not depend on
   whatever the caller's environment happens to contain.
2. **The overlay.** One upstream defect (missing peer package, see
   [packaging-notes.md](packaging-notes.md#4-upstream-015rc1-is-missing-a-peer-package-so-no-profile-boots))
   makes every profile fail to boot. The fix is a patch overlay, and the only
   place to inject it is the argv, which requires the `web` alias to be rewritten
   to `--profile web` first.
3. **Escape hatches.** `DSH_LIBEXEC`, `DSH_PACKAGED_PATCH`, and
   `DSH_PACKAGED_PATCH=0` make the wrapper testable, relocatable (portable
   bundles reuse it verbatim), and easy to unwind once upstream fixes the defect.

The wrapper stays POSIX `sh`, does no parsing beyond the launcher's own leading
flag prefix, and `exec`s the runtime so signals and exit status pass through.

### Overlay instead of modifying user state

The alternative injection point is `$DSH_HOME/cordis.patch.yml`, which the runtime
applies to every profile. That would avoid argv surgery entirely and work
identically on Windows. It was rejected because it means the package writing into
the user's state directory, where it could collide with user edits; the
`--patch` overlay is read-only, explicit, and visible in `--dump-config`.

### Failure visibility

Three mechanisms keep the packaging honest as upstream moves:

* `scripts/lint.sh` fails if the spec and `versions.env` disagree about the
  version or the wheel URL, and if the anti-strip macros disappear.
* `%check` runs the runtime, asserts the sidecar, and validates the desktop and
  AppStream metadata during every build.
* `scripts/smoke-test.sh --probe-overlay` verifies end-to-end that `dsh web` boots
  **and** that the overlay is still required, so a fixed upstream release
  surfaces as a failing check rather than silent dead weight.

## Non-goals and future work

* **Official Fedora submission.** Requires unbundling Node and the npm closure.
  The realistic path is COPR or a third-party repository.
* **aarch64 RPM.** `versions.env` already pins the arm64 wheel; only the spec's
  `ExclusiveArch`/`Source0` need a per-arch split.
* **Flatpak / AppImage / .deb.** The portable-bundle builder covers the
  no-package-manager case; Flatpak would need a different sandbox story because
  the runtime already sandboxes its own tools.
* **Auto-updating profiles.** `dsh plugin` needs `pnpm`; the RPM only recommends
  it. Shipping pnpm would mean vendoring another dependency tree.
* **Pinning a newer CLI than the bundled runtime.** The runtime carries a fixed
  plugin closure; mixing in npm packages of a different minor version is not
  supported by upstream and was not attempted.
