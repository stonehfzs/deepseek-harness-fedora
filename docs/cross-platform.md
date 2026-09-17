# Cross-platform bundles

Upstream publishes a self-contained runtime for five targets inside the PyPI
wheel `deepseek-harness-runtime-bin`. This repository pins all five in
`scripts/versions.env`, so the same fetch → extract → normalize → wrap pipeline
that feeds the Fedora RPM also produces portable bundles.

```console
$ make portable TARGET=linux-x64      # dist/deepseek-harness-<v>-linux-x64.tar.gz
$ make portable TARGET=macos-arm64    # dist/deepseek-harness-<v>-macos-arm64.tar.gz
$ make portable TARGET=windows-x64    # dist/deepseek-harness-<v>-windows-x64.zip
$ make dist                           # RPM + every non-x64 portable target
```

## What each bundle contains

```
deepseek-harness-<version>-<target>/
├── dsh-runtime(.exe)        upstream executable, renamed (its own Node.js inside)
├── dsh-runtime-rg(.exe)     ripgrep sidecar; the name MUST be "<runtime>-rg"
├── dsh                      launcher (Linux/macOS; same script the RPM installs)
├── dsh.cmd                  launcher (Windows)
├── DeepSeek Harness.command double-click launcher (macOS only)
├── patches/00-packaged-workarounds.yml
└── README.md                end-user instructions, generated from packaging/portable/
```

The rename to `dsh-runtime` is safe because the runtime resolves its sidecar
relative to its own path (`<execPath>-rg`) and does not check its own filename.
Sidecars that are neither the main executable nor ripgrep keep their upstream
names — on macOS that is node-pty's `-spawn-helper`, which must stay next to the
executable.

## Verification status

Being explicit about what has actually been exercised, on this machine
(Fedora 44, x86_64, glibc 2.41):

| Target | Wheel payload names | Wheel SHA256 | Runtime executed | Launcher exercised |
| --- | --- | --- | --- | --- |
| `linux-x64` | Verified | Verified (download + hash) | **Verified** (`--version`, `web` boot) | **Verified** (RPM smoke test) |
| `linux-arm64` | Not inspected | Pinned from the PyPI release page | No | No |
| `macos-arm64` | Verified | Verified (download + hash) | No (wrong OS) | No |
| `macos-x64` | Not inspected | Pinned from the PyPI release page | No | No |
| `windows-x64` | Download pending during authoring | Pinned from the PyPI release page | No (wrong OS) | No |

Payload names confirmed by listing the wheel's zip index:

```console
$ python3 -c "import zipfile,sys; print('\n'.join(n for n in \
    zipfile.ZipFile(sys.argv[1]).namelist() if 'runtime/' in n))" mac-arm.whl
deepseek_harness_runtime/runtime/deepseek-harness-sdk-runtime-macos-arm64
deepseek_harness_runtime/runtime/deepseek-harness-sdk-runtime-macos-arm64-rg
deepseek_harness_runtime/runtime/deepseek-harness-sdk-runtime-macos-arm64-spawn-helper
```

The scripts never hardcode these names: `dsh_extract_payload` flattens the
runtime directory and classifies files by size and suffix, so an unexpected
layout fails loudly instead of producing a broken bundle.

## Windows notes

* `dsh.cmd` mirrors the POSIX launcher: defaults `DSH_HOME` to
  `%USERPROFILE%\.dsh`, rewrites the `web` alias to `--profile web` (commander
  rejects `--patch` in front of the `web` subcommand), and applies the same
  overlay. `DSH_PACKAGED_PATCH=0` disables it.
* The batch launcher re-quotes the arguments it forwards, so unusual quoting in
  arguments containing `"` may not survive. The POSIX launcher has no such
  limitation.
* No installer is produced: unpack the zip and run `dsh.cmd` or `dsh web`. A
  Start Menu shortcut is left to the user; upstream's community Electron builds
  cover the fully integrated desktop case.

## macOS notes

* Unpack, then `./dsh web`, or double-click `DeepSeek Harness.command`.
* Binaries downloaded outside a signed installer are quarantined by Gatekeeper.
  If macOS refuses to run the runtime, clear the attribute once:
  `xattr -dr com.apple.quarantine <bundle-dir>`. No code signing or notarization
  is performed here, and a `.app` wrapper around `dsh web` is not built.
* The macOS wheel additionally ships node-pty's `-spawn-helper`; `build-portable.sh`
  copies it next to the executable automatically.

## Why not AppImage, .deb, Flatpak, or .dmg?

They are out of scope rather than rejected on principle. The RPM is the primary
target; the portable bundles exist so that "just run it" works on the other two
platforms this project was asked about. Flatpak in particular would need a
different sandbox design, because the runtime already sandboxes the tools it
runs. Adding a `.deb` would mostly mean reusing the spec's file layout with a
different packager; the launcher, overlay, and detection logic are already
platform-neutral.
