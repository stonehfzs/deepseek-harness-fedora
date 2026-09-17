# Contributing

This repository packages an upstream artifact; it does not modify DeepSeek
Harness. Almost every change is therefore either "point at a new release" or
"fix the packaging layer", and both have a short checklist.

## Quick start

```console
$ make lint            # static invariants + spec/versions consistency
$ make rpm             # build the RPM
$ make smoke           # unpack and prove it runs (no root)
$ make portable TARGET=windows-x64
```

Requirements to build: Fedora with `rpm-build`, `unzip`, `desktop-file-utils`,
`appstream`; ~1 GiB free in `build/`.

## Repository conventions

* **`scripts/versions.env` is the single source of truth** for the upstream
  version and the per-target wheel URL/SHA256. Nothing else may hardcode them.
* **The spec must work standalone.** `packaging/rpm/deepseek-harness.spec` is
  written so COPR or a plain `rpmbuild` invocation can use it without the
  scripts; `build-rpm.sh` only stages files under the names `SourceN` declares.
* **Shell scripts are POSIX `sh`** (`packaging/rpm/dsh-wrapper.sh`, portable
  launchers) or `bash` (`scripts/*.sh`, because they use arrays). The wrapper is
  `sh` deliberately: it runs on minimal systems and inside RPM scriptlets.
* **No new runtime dependencies without justification.** The point of this
  package is that installing it needs nothing but glibc; every added `Requires:`
  should be argued in the spec comment and in `docs/`.
* **Never strip the runtime.** See
  [docs/packaging-notes.md](docs/packaging-notes.md#1-the-runtime-must-never-be-stripped).
  If you touch anything about the build, `scripts/lint.sh` and `%check` exist to
  stop you.
* **Document the why, not the what.** Non-obvious constraints belong in
  `docs/packaging-notes.md` with the symptom, the evidence, and the rule.

## Adding support for a new upstream release

1. Find the new `deepseek-harness-runtime-bin` release on PyPI. For each target
   you intend to ship, note the wheel filename and its SHA256.
2. Update `scripts/versions.env`:
   * `DSH_RUNTIME_VERSION` (PyPI form, e.g. `0.1.6rc1`)
   * `DSH_CLI_VERSION` (what `dsh --version` prints, e.g. `0.1.6-rc.1`)
   * `DSH_RPM_VERSION` (tilde form, e.g. `0.1.6~rc1`) and `DSH_RPM_RELEASE`
   * the five `DSH_TARGET_*` rows (name, SHA256, URL)
3. Mirror the versions in the spec: `Version:`, `%global pypi_ver`,
   `%global pypi_tag`, `%global cli_version`. `Source0` is built from those
   macros, so it updates itself — verify with
   `rpmspec -P packaging/rpm/deepseek-harness.spec | grep Source0`.
4. Add a `%changelog` entry (correct weekday; rpmbuild warns otherwise).
5. Run the full gate:

   ```console
   $ make lint
   $ make rpm
   $ scripts/smoke-test.sh --probe-overlay
   ```

6. If the overlay probe now **passes** (boot succeeds without the overlay),
   upstream fixed the missing-package defect. Retire the workaround:
   remove `packaging/rpm/00-packaged-workarounds.yml`, its `Source5` line and
   install step in the spec, and delete the injection block in the launchers.
   `.gitignore` and the docs should follow.

## Adding a target

`versions.env` already pins all five published targets. To add a Linux aarch64
RPM, for example: teach `build-rpm.sh` to select the `linux-arm64` wheel, add
`ExclusiveArch`/`Source0` conditionals to the spec (or a second spec), and update
the file list if the payload names differ. `docs/cross-platform.md` records the
verification status per target — keep that table honest when you add one.

## Testing expectations for a pull request

* `make lint` and `make rpm` must pass on Fedora.
* `make smoke` must pass; paste the summary in the PR description, together with
  the `dsh --version` output the build produced.
* Changes to the launcher must also exercise the argv rewrite: boot `dsh web`
  (covered by the smoke test) and confirm `dsh plugin --profile web ...` is *not*
  given the overlay.
* Changes to the packaging layer must update `docs/packaging-notes.md` when they
  encode a new constraint.

## Commit and PR style

Conventional-commit subjects are welcome (`packaging:`, `spec:`, `scripts:`,
`docs:`). Keep the subject under ~72 characters and explain the reasoning — the
symptom, the evidence, the decision — in the body. One logical change per commit;
version bumps should be a single commit touching `versions.env`, the spec, and
the changelog together, so the lint check can never see a half-updated pair.
