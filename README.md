# Cleat

[![Tests](https://github.com/cleatdev/cleat/actions/workflows/test.yml/badge.svg)](https://github.com/cleatdev/cleat/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-supported-brightgreen)](https://github.com/cleatdev/cleat)
[![Linux](https://img.shields.io/badge/Linux-supported-brightgreen)](https://github.com/cleatdev/cleat)

**Run anything. Break nothing.**

Run AI coding agents with full autonomous permissions — safely sandboxed in Docker.

One command. Per-project isolation. Zero risk to your host.

```bash
curl -fsSL https://raw.githubusercontent.com/cleatdev/cleat/main/install.sh | bash
```

```bash
cd ~/your-project && cleat
```

That's it. First run builds the Docker image (~2 min), starts an isolated container for your project, and drops you into Claude Code with full permissions, all sandboxed.

```
┌─────────────────────┐      ┌─────────────────────────────────┐
│  Your machine        │      │  Docker container                │
│                      │      │                                  │
│  ~/my-project ───────────>  │  /workspace                      │
│  ~/.claude ──────────────>  │  /home/coder/.claude             │
│                      │      │                                  │
│  Everything else     │      │  Claude Code runs free here:     │
│  is untouched.       │      │  install, build, delete, run     │
│                      │      │  anything. Fully sandboxed.      │
└─────────────────────┘      └─────────────────────────────────┘
```

---

## Requirements

- **[Docker](https://docs.docker.com/get-docker/)** -- must be installed and running
- **macOS or Linux** (Windows support via WSL2)
- **An [Anthropic](https://www.anthropic.com/) account** -- team or Pro plan
- **git** -- used by the installer

---

## Why Cleat?

### The problem

Claude Code with `--dangerously-skip-permissions` is the fastest way to build software with AI. No confirmation dialogs, no permission prompts. Claude just does what you ask. But on your actual machine, that means:

- System files and configs can be modified or deleted
- Packages can be installed, upgraded, or removed system-wide
- Dotfiles, SSH keys, or credentials can be read or overwritten
- Other projects on your machine can be accessed or changed
- A single bad command can render your OS unbootable

### The solution

Cleat gives you the best of both worlds:

| | Without isolation | With Cleat |
|---|---|---|
| Claude can edit project files | Yes | Yes |
| Claude can install packages | Yes (on your system) | Yes (in container) |
| Claude can run any command | Yes (on your system) | Yes (in container) |
| Claude can access other projects | Yes | **No** |
| Claude can modify your system | Yes | **No** |
| Claude can read ~/.ssh, credentials | Yes | **Opt-in** (via `cleat config`) |
| Safe to leave running overnight | No | **Yes** |
| File ownership issues | N/A | **None** (UID/GID mapped) |
| Copy to host clipboard | Yes | **Yes** (via clipboard bridge) |

### Key features

- **One command** -- `cleat` builds, starts, and launches everything
- **Per-project isolation** -- each project gets its own container, run multiple projects in parallel
- **Session persistence** -- stop and resume sessions without losing context, each project's history is isolated
- **Safe for unattended use** -- let Claude work overnight without risking your system
- **Zero file permission issues** -- container user matches your host UID/GID automatically
- **Shared auth** -- log in once, all containers use the same credentials
- **Clipboard support** -- `pbcopy`, `xclip`, and `xsel` shims route to your host clipboard via a file bridge -- no X11 or special terminal features needed
- **Lightweight** -- Node.js-based image with Python, Git, GitHub CLI, jq, and socat
- **Capabilities** -- opt-in access to host git identity (`--cap git`), SSH keys (`--cap ssh`), env var passthrough (`--cap env`), host hook execution (`--cap hooks`), GitHub CLI auth (`--cap gh`), all disabled by default
- **Pre-built image** -- `cleat start` pulls from `ghcr.io/cleatdev/cleat` (~30s) instead of building locally (~2-5 min), with automatic local-build fallback
- **Hook execution on host** -- your Claude Code hooks (global and project-level) run on the host, not in the container
- **Browser bridge** -- `open` and `xdg-open` inside the container forward URLs to your host browser (auth, OAuth, docs)
- **Host connectivity** -- `host.docker.internal` always available, user-defined hooks and MCP servers work out of the box
- **Configuration drift detection** -- notifies when config has changed since container creation
- **Clean terminal output** -- braille spinners for slow operations, suppressed Docker noise, canonical startup/exit sequences
- **Auto-upgrade notifications** -- checks for updates once per day and notifies you before launching Claude

---

## The story behind this

I was deep into vibe coding. Shipping features fast, letting Claude Code run with `--dangerously-skip-permissions` so it could execute anything without interrupting my flow. It was incredible. I'd kick off tasks, step away, come back to working code. I was running multiple projects on my Mac, sometimes leaving Claude running overnight while it worked through larger refactors.

Then one morning I opened my laptop and nothing worked. The system was completely broken. Apps wouldn't launch, the terminal was unusable, core system files had been modified. Claude had been working autonomously through the night, and somewhere along the way it had started making changes outside the project directory. It tried to fix a dependency issue by modifying system-level configs, which cascaded into more "fixes" across the filesystem. By the time it was done, macOS was unrecoverable.

I had to restore my entire machine from a Time Machine backup. Hours of setup, re-authenticating everything, recreating local state that wasn't backed up. All because I gave an AI unrestricted access to my actual system.

The thing is, I didn't want to stop using `--dangerously-skip-permissions`. The productivity gain is real. Claude Code without permission gates is a different experience entirely: it moves fast, installs what it needs, runs builds and tests, iterates on errors, all without waiting for you to click "allow" fifty times. Going back to the default permission mode felt like putting the brakes back on.

So I built Cleat. Same unrestricted power, but inside a Docker container where the blast radius is zero. Claude can `rm -rf /` inside the sandbox and my Mac won't even notice. Each project gets its own container, my host system is completely untouched, and I never have to worry about what Claude does when I'm not looking.

I haven't restored from a backup since.

---

## Install

### Quick install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/cleatdev/cleat/main/install.sh | bash
```

This clones the repo to `~/.cleat`, checks out the latest stable release tag, and symlinks `cleat` into your PATH.

### Dev install (from local clone)

```bash
git clone https://github.com/cleatdev/cleat.git
cd cleat
./install.sh --local
```

This symlinks your working copy into PATH. Edits to `bin/cleat` take effect immediately — no reinstall needed. Switch back to the official release at any time with `./install.sh` (without `--local`).

### Update

Releases are published as git tags (e.g. `v0.1.0`). The updater fetches tags and checks out the latest one:

```bash
cleat update
```

To also update Claude Code inside the container:

```bash
cleat rebuild
```

---

## Getting started

### 1. Authenticate (first time only)

```bash
cd ~/your-project
cleat                # starts the container + launches Claude
# Claude will prompt you to log in on first run
```

Or authenticate separately:

```bash
cleat start          # start the container
cleat login          # opens a browser URL to sign in
```

Credentials are saved to `~/.claude` on your host and shared across all containers automatically. Log in once, every container picks it up.

### 2. Use it

```bash
cd ~/your-project
cleat
```

That's it. You're inside Claude Code with full autonomous permissions, sandboxed in Docker.

---

## Usage

### Daily workflow

```bash
# Start a new session
cd ~/my-project
cleat

# Resume your last session
cleat resume

# Check what's running
cleat ps

# Stop when done (keeps container for resume)
cleat stop
```

### Multiple projects at once

Each project gets its own isolated container:

```bash
# Terminal 1
cd ~/backend && cleat

# Terminal 2
cd ~/frontend && cleat

# See all running containers
cleat ps
```

```
  Cleat containers:

    ● cleat-backend-1a2b3c4d
      Up 12 minutes
      /Users/you/backend

    ● cleat-frontend-5e6f7a8b
      Up 3 minutes
      /Users/you/frontend
```

### Command reference

#### Quick start
| Command | Description |
|---|---|
| `cleat` | Build + run + launch Claude Code (all-in-one) |
| `cleat resume` | Resume the most recent session |

#### Lifecycle
| Command | Description |
|---|---|
| `cleat stop [path]` | Stop this project's container (keeps it for resume) |
| `cleat rm [path]` | Stop and remove container permanently |
| `cleat stop-all` | Stop all Cleat containers |
| `cleat build` | Build the Docker image |
| `cleat rebuild` | Force rebuild the image from scratch |
| `cleat clean` | Stop everything and remove the image |
| `cleat nuke` | Remove **all** containers, images, and build cache |

#### Capabilities
| Command | Description |
|---|---|
| `cleat config` | Interactive capability picker (keyboard TUI) |
| `cleat config --list` | List capabilities and their status |
| `cleat config --enable <cap>` | Enable a capability (e.g. `git`, `ssh`, `env`) |
| `cleat config --disable <cap>` | Disable a capability |
| `cleat config --project --enable <cap>` | Project-level config (saved to `.cleat`) |

#### Flags (apply to `start`, `run`, `resume`, `claude`, `shell`, `login`)
| Flag | Description |
|---|---|
| `--cap <name>` | Enable a capability for this session only |
| `--env KEY=VALUE` | Pass environment variable to container |
| `--env KEY` | Inherit from host environment |
| `--env-file PATH` | Load env vars from file |

#### Interact
| Command | Description |
|---|---|
| `cleat claude [path]` | Attach Claude Code to a running container |
| `cleat shell [path]` | Open bash inside the container |
| `cleat login [path]` | Authenticate with Anthropic (OAuth) |
| `cleat logs [path]` | Tail container logs |

#### Info
| Command | Description |
|---|---|
| `cleat status [path]` | Show container, image, and auth status |
| `cleat ps` | List all Cleat containers (running and stopped) |
| `cleat update` | Check for updates and install the latest version |
| `cleat version` | Show current version |

All commands default to the current working directory if `[path]` is omitted.

---

## How it works

### Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Your machine                                                │
│                                                              │
│   ~/.claude ──────────────┐  (auth, sessions, settings)      │
│   ~/.claude.json ─────────┼── (config)                       │
│   ~/my-project ───────────┼──────────────────────┐           │
│                           │                      │           │
│  ┌────────────────────────┼──────────────────────┼───────┐   │
│  │  Docker container      │                      │       │   │
│  │                        v                      v       │   │
│  │  /home/coder/.claude        /workspace                │   │
│  │  /home/coder/.claude.json                             │   │
│  │                                                       │   │
│  │  Claude Code (--dangerously-skip-permissions)         │   │
│  │                                                       │   │
│  │  Can: read/write project, install packages, run cmds  │   │
│  │  Cannot: touch host system, access other projects     │   │
│  └───────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
```

### Components

| File | Purpose |
|---|---|
| `bin/cleat` | CLI script (symlinked as `cleat`) |
| `docker/Dockerfile` | Node.js bookworm-slim image with Claude Code (native installer) |
| `docker/entrypoint.sh` | Maps host UID/GID into the container so files are owned by you |
| `docker/clip` | Clipboard shim -- writes to file bridge (primary) or OSC 52 daemon (fallback). Symlinked as `pbcopy`, `xclip`, `xsel` |
| `docker/clip-daemon` | Background daemon -- relays clipboard data to the host terminal via OSC 52 (fallback for terminals that support it) |
| `docker/CLAUDE.md` | User-level instructions for Claude Code (clipboard usage, paste limitations) |
| `install.sh` | One-line installer (`curl \| bash`) |

### What happens when you run `cleat`

1. **Pulls or builds the Docker image** (first run only) -- pulls pre-built image from registry (~30s), falls back to local build if unavailable. Image includes Node.js, Python, Git, GitHub CLI, jq, socat, and Claude Code CLI
2. **Starts a container** named `cleat-<dirname>-<hash>` (hash derived from the full project path) with your project mounted at `/workspace`
3. **Maps your UID/GID** into the container so files created by Claude are owned by you on the host
4. **Mounts `~/.claude`** for shared authentication across all containers
5. **Starts the clipboard bridge** -- a host-side watcher and a shared file mount so `pbcopy`/`xclip`/`xsel` relay to your host clipboard
6. **Launches Claude Code** with `--dangerously-skip-permissions` inside the sandbox

### Security hardening

Containers run with these protections by default:

- `--pids-limit 1024` -- prevents fork bombs from affecting the host
- `--memory 8g` -- prevents runaway processes from exhausting host memory
- Numeric UID/GID validation in the entrypoint to prevent injection attacks
- Node.js bookworm-slim base image with minimal attack surface

---

## Capabilities

Capabilities are opt-in features that extend what the container can access from the host. They are **disabled by default** — the baseline container is locked down, and each capability explicitly widens the boundary.

### Enable capabilities

```bash
# Interactive wizard
cleat config

# Direct mode
cleat config --enable git
cleat config --enable ssh
cleat config --enable env

# One-off (session only, no config change)
cleat --cap ssh start
```

### Available capabilities

| Capability | What it does |
|---|---|
| `git` | Mounts `~/.gitconfig` (read-only). Commits inside the container use your host identity. |
| `ssh` | Mounts `~/.ssh` (read-only). SSH agent forwarding if `SSH_AUTH_SOCK` is set. |
| `env` | Auto-loads env vars from `~/.config/cleat/env` (global) and `.cleat.env` (project). |
| `hooks` | Runs your Claude Code hooks on the host (global and project-level). |
| `gh` | Mounts `~/.config/gh` (read-write). `gh auth login` inside container writes tokens to host. |

### Environment variables

The `env` capability controls automatic loading of env files. The `--env` and `--env-file` flags always work, regardless of whether the capability is enabled:

```bash
# These always work (bypass capability gate)
cleat --env GH_TOKEN=abc123 start
cleat --env GH_TOKEN start              # inherit from host
cleat --env-file .env.local start

# These require the env capability
# ~/.config/cleat/env     ← global
# .cleat.env              ← project-specific
```

### Configuration drift detection

When you change capabilities after a container was created, Cleat detects the mismatch and shows a notice:

```
  ┌──────────────────────────────────────────────────────┐
  │  Configuration changed since this container was       │
  │  created. Recreate to apply the new settings.         │
  │                                                       │
  │  Run: cleat rm && cleat                               │
  └──────────────────────────────────────────────────────┘
```

Drift detection is informational only — Cleat never auto-destroys containers.

### Config files

```
~/.config/cleat/config    ← global capabilities
~/.config/cleat/env       ← global env vars
<project>/.cleat          ← project-level capabilities (extends global)
<project>/.cleat.env      ← project-level env vars
```

---

## Terminal output

Cleat uses a clean, consistent output format with no Docker noise.

### Startup

```
  ✔ Image ready (cached)
  ✔ Container started
  ✔ Auth shared
  ✔ Claude launched

  Container:  cleat-backend-a1b2c3d4
  Project:    ~/backend → /workspace
  Caps:       git, ssh
```

Slow operations (image build, container start) show animated braille spinners that resolve to checkmarks. When stdout is not a TTY (piped, CI), spinners degrade to static lines.

### Exit

```
  ✔ Session ended — resume with: cleat resume
```

Docker's "What's next?" promo text and clipboard watcher cleanup messages are suppressed.

---

## Hooks

When the `hooks` capability is enabled, your Claude Code hooks run on the host — exactly as if you weren't using a container. Hooks from all three settings locations are supported:

- `~/.claude/settings.json` (global)
- `.claude/settings.json` (project, committed)
- `.claude/settings.local.json` (project, local)

```bash
cleat config --enable hooks    # enable persistently
cleat --cap hooks start        # enable for one session
```

### How it works

1. Cleat creates a settings overlay that replaces hook commands with an event forwarder inside the container
2. Project-level hook settings are also overlaid to prevent double-execution
3. A host-side bridge reads forwarded events and executes the original hook commands on the host
4. Event JSON is piped to stdin, matchers are respected, 30s timeout per command
5. Commands like `osascript`, local scripts, and anything host-specific work transparently

---

## Browser bridge

When Claude Code or any tool inside the container calls `open` or `xdg-open` with a URL, it opens in your host browser. OAuth callbacks are automatically proxied back to the container — `cleat login` and any auth flow work seamlessly without manual URL copy-paste. No capability needed.

---

## Host connectivity

Containers can always reach services on the host via `host.docker.internal` — no capability needed. User-defined hooks, MCP servers, and HTTP endpoints on the host work out of the box.

```bash
# In .cleat.env (with env capability enabled)
CLAUDE_VISUAL_URL=http://host.docker.internal:3200
```

On Linux (Docker Engine), Cleat adds `--add-host host.docker.internal:host-gateway` automatically. Docker Desktop (macOS/Windows) provides this natively.

---

## Auto-upgrade notifications

Cleat checks for new release tags once every 24 hours via `git ls-remote --tags` (a lightweight network call that fetches no objects). When a newer version is available, you'll see a notice before Claude Code launches:

```
  ┌──────────────────────────────────────────────────────┐
  │  Update available  v0.4.0 → v0.5.0                   │
  │  Run cleat update to install the latest version.      │
  └──────────────────────────────────────────────────────┘
```

- The check runs at most **once per day** — it will not slow down subsequent launches.
- The result is cached in `.update_check` inside the installation directory (`~/.cleat`).
- The notification is informational only — it will never interrupt or block your workflow.
- To upgrade, run `cleat update`. To also update Claude Code inside containers, follow up with `cleat rebuild`.

---

## Clipboard support

Clipboard works out of the box. When Claude Code (or any tool) calls `pbcopy`, `xclip`, or `xsel` inside the container, the text is copied to your **host machine's clipboard** -- no X11, display server, or special terminal features required.

### How it works

A host-side clipboard watcher starts automatically alongside every Claude Code session. The container writes clipboard data to a shared file via a bind mount, and the watcher detects changes and copies the content to your real clipboard using `pbcopy` (macOS), `xclip`, `xsel`, or `wl-copy` (Linux).

```
┌─────────────────────────────┐      ┌──────────────────────────────┐
│  Docker container            │      │  Host                         │
│                              │      │                               │
│  Claude Code                 │      │                               │
│    └─ echo "text" | pbcopy   │      │                               │
│         └─ writes to ────────────>  │  /tmp/cleat-clip-*/clipboard  │
│           /tmp/cleat-clip/   │      │    └─ watcher detects change  │
│                              │      │         └─ pbcopy / xclip     │
│                              │      │              └─ ✔ clipboard!  │
└─────────────────────────────┘      └──────────────────────────────┘
```

An [OSC 52](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Operating-System-Commands) fallback is available for terminals that support it, used automatically when the file bridge is not active.

```bash
# These all work inside the container -- including from Claude Code:
echo "hello" | clip              # dedicated helper
echo "hello" | pbcopy            # macOS-style
echo "hello" | xclip -selection clipboard  # Linux-style
echo "hello" | xsel --clipboard  # Linux-style (alternative)
git log -1 --format=%B | clip    # copy last commit message
```

**Limits:** Payloads are capped at 100KB. Paste (`xclip -o`, `xsel --output`, `pbpaste`) is not supported -- clipboard is copy-only.

---

## Troubleshooting

### Clipboard not working

If `pbcopy`/`xclip`/`xsel` inside the container doesn't copy to your host clipboard:

1. **Check the bridge is active** -- inside the container, run `ls /tmp/cleat-clip/.host-ready`. If the file exists, the host watcher is running.
2. **Check clipboard commands on the host** -- the watcher needs `pbcopy` (macOS), `xclip`, `xsel`, or `wl-copy` (Linux) available on your PATH.
3. **Rebuild the container** -- if you upgraded from an older version, run `cleat rm && cleat start` so the new clipboard mount is created.
4. **Large payloads** -- clipboard is capped at 100KB. For larger content, write it to a file in `/workspace` and copy from the host.

### Docker not running

```
Cannot connect to the Docker daemon
```

Start Docker Desktop or the Docker daemon, then retry.

### Permission denied on install

```bash
# If /usr/local/bin is not writable, the installer uses sudo automatically.
# You can also install to a custom location:
ln -sf "$(pwd)/bin/cleat" ~/.local/bin/cleat
```

### Container naming

Each container is named `cleat-<dirname>-<hash>` where the hash is derived from the full absolute path of the project directory. This means two projects with the same directory name (e.g. `~/code/client-a/api` and `~/code/client-b/api`) get separate containers automatically. The container name is printed before every session so you always know which sandbox you're in.

### Rebuilding after Claude Code updates

The Claude Code CLI is baked into the Docker image. To get the latest version:

```bash
cleat rebuild
```

### Files created as root

This shouldn't happen. The entrypoint maps your host UID/GID. If it does, check that Docker is passing through `HOST_UID` and `HOST_GID` correctly:

```bash
cleat shell
id    # should show your UID/GID
```

---

## Uninstall

```bash
cleat clean       # remove all containers + image
cleat uninstall   # remove CLI symlinks
rm -rf ~/.cleat   # remove the repo clone
```

Your project files and `~/.claude` credentials are never touched.

---

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

```bash
git clone https://github.com/cleatdev/cleat.git
cd cleat
# Make your changes on main, test locally
./bin/cleat start ~/some-test-project
```

### Releasing

Releases are cut by tagging a commit on `main`:

```bash
git tag v0.3.0
git push --tags
```

The installer and updater both resolve the latest semver tag automatically. No release branch is needed.

---

## License

[MIT](LICENSE)

---

<sub>Cleat — Run anything. Break nothing. | Docker sandbox for AI coding agents | cleat.sh</sub>
