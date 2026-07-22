# Cleat examples

Copy-paste starting points for real Cleat configs. Each folder is a tiny
project you can drop into your own repo.

## `setup/`: box provisioning with `[setup]`

A `[setup]` section in your project's `.cleat` file installs a toolchain the
base box does not ship. The commands run once per container, as the `coder`
user, in `/workspace`, right after the box is created. Cleat shows you the
exact commands and asks once before running them. See
[docs/cli.md](../../docs/cli.md#provisioning-setup-section) for the full
reference.

| Example | Shows |
|---|---|
| [`setup/dotnet`](setup/dotnet/) | Inline commands (install the .NET SDK from Microsoft's apt feed) |
| [`setup/python`](setup/python/) | A single `script <path>` directive (install `uv`, sync deps) |
| [`setup/rust`](setup/rust/) | **Two** `script` directives (toolchain, then extra tools) |

### Using one

```sh
# from your project root
cp -r /path/to/cleat/examples/setup/dotnet/. .
cleat run          # Cleat previews the [setup] payload and asks once
```

On approval the commands run inside the fresh box. A later `cleat rm` +
`cleat run` re-provisions automatically without re-asking, as long as the
commands have not changed. Preview or re-run anytime with:

```sh
cleat setup --show   # payload, hash, trust and marker state (no run)
cleat setup          # re-run provisioning now (box must be running)
```

### The base box

The default box is `node:24-bookworm-slim` (Debian 12 "bookworm"), amd64 and
arm64. It ships Node.js, git, `gh`, curl and the Docker CLI. The `coder` user
has passwordless `sudo`, so `sudo apt-get install ...` works. Everything else
you add is exactly what these examples are for.
