# DeepSeek Harness — portable bundle

This directory is a self-contained DeepSeek Harness runtime. There is nothing to
install: it carries its own Node.js and the complete plugin closure.

## Run it

**Linux / macOS**

```console
$ ./dsh web                      # boot the browser UI and open it
$ ./dsh --profile headless "summarize this repository"
$ ./dsh --help
```

On macOS you can also double-click `DeepSeek Harness.command`.

**Windows**

```bat
> dsh.cmd web
> dsh.cmd --profile headless "summarize this repository"
> dsh.cmd --help
```

## Where your data goes

* Sessions, profiles, settings, and credentials live in `DSH_HOME`
  (`~/.dsh`, or `%USERPROFILE%\.dsh` on Windows). Set `DSH_HOME` to keep them
  elsewhere.
* On first run the runtime unpacks native addons into the user cache
  (`~/.cache/pkg`, `%LOCALAPPDATA%` on Windows). That location must be writable.

## The browser UI asks for authentication

That is expected. The web UI is protected by a browser-trust fence: a bare visit
to the port returns `401 Unauthorized`, and only the tokenized URL printed by
`dsh web` works. Plain `dsh web` opens that URL for you — start it that way
rather than navigating to the port yourself.

## The `patches/` directory

`patches/00-packaged-workarounds.yml` disables one plugin row that cannot load on
upstream 0.1.5rc1 (the runtime closure is missing the peer package
`@deepseek-ai/dsh-session-title-llm`, which
`@deepseek-ai/dsh-session-title-first-prompt-llm` imports). Without it, every
profile fails to boot with `ERR_MODULE_NOT_FOUND`; with it, session titles fall
back to the first prompt instead of a model-written title.

The launchers apply it automatically. To boot without it, set
`DSH_PACKAGED_PATCH=0`. Once a fixed runtime is published, this file and the
launchers' injection logic go away.

## Verify what you downloaded

Each bundle is assembled from a checksum-pinned upstream wheel; see
`scripts/versions.env` in the packaging repository for the URL and SHA256 of the
wheel this bundle came from.
