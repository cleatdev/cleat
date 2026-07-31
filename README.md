# Cleat

[![Tests](https://github.com/cleatdev/cleat/actions/workflows/test.yml/badge.svg)](https://github.com/cleatdev/cleat/actions/workflows/test.yml)
[![Image](https://github.com/cleatdev/cleat/actions/workflows/publish-image.yml/badge.svg)](https://github.com/cleatdev/cleat/actions/workflows/publish-image.yml)
[![Release](https://img.shields.io/github/v/release/cleatdev/cleat?label=release)](https://github.com/cleatdev/cleat/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Give the agent a cage, not your keys.**

*Unattended, not unguarded.*

Run AI coding agents with full autonomous permissions, safely sandboxed in Docker.

One command. Per-project isolation. Your host stays untouched.

<p align="center">
  <img src="assets/cleat-demo.gif" alt="A real Claude Code session inside a Cleat box: credential probes come up empty, the agent deletes the box's own OS on purpose and the host machine (SSH keys, files) is untouched" width="800">
</p>
<p align="center">
  <sub>A real session, not a mockup: Claude Code hunts for keys, finds nothing, then <code>rm -rf</code>'s the box's own OS. The host doesn't notice.</sub>
</p>

```bash
curl -fsSL https://cleat.sh/install | bash
```

```bash
cd ~/your-project && cleat
```

That's it. First run pulls the prebuilt image from GHCR (~30s), starts an isolated container for your project and drops you into Claude Code with full permissions, all sandboxed. If the prebuilt image is unavailable for your CLI version, it falls back to a local build (~2 min) automatically.

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

**Stay updated:** Watch → Custom → Releases on this repo and upgrade any time with `cleat update`.

---

## Requirements

- **[Docker](https://docs.docker.com/get-docker/)** -- must be installed and running
- **macOS or Linux** (Windows support via WSL2)
- **An [Anthropic](https://www.anthropic.com/) account** -- Pro, Max, Team, or Enterprise plan, or an API key
- **git** -- used by the installer

---

## Why Cleat?

### The problem

Claude Code with `--dangerously-skip-permissions` is the fastest way to build software with AI. No confirmation dialogs, no permission prompts. Claude just does what you ask. But on your actual machine, that means:

- System files and configs can be modified or deleted
- Packages can be installed, upgraded, or removed system-wide
- Dotfiles, SSH keys, or credentials can be read or overwritten
- Other projects on your machine can be accessed or changed
- A single bad command can irreversibly delete your work -- on a Mac's internal SSD, TRIM means there is no undo and no undelete, only your last backup -- or leak a live credential to the internet, where it is abused in minutes

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

- **One command** -- `cleat` pulls (or builds) the image, starts a container and launches Claude Code
- **Per-project isolation** -- each project gets its own container, run multiple projects in parallel
- **Session persistence** -- stop and resume sessions without losing context, each project's history is isolated
- **Safe for unattended use** -- let Claude work overnight without risking your system
- **Zero file permission issues** -- container user matches your host UID/GID automatically
- **Shared auth** -- log in once, all containers use the same credentials
- **Clipboard support** -- `pbcopy`, `xclip` and `xsel` shims route to your host clipboard via a file bridge -- no X11 or special terminal features needed
- **Lightweight** -- Node.js-based image with Python, Git, GitHub CLI, jq and socat
- **Capabilities** -- opt-in access to host git identity (`--cap git`), SSH keys (`--cap ssh`), env var passthrough (`--cap env`), host hook execution (`--cap hooks`), GitHub CLI auth (`--cap gh`) and host Docker daemon for testing dockerized apps (`--cap docker`). All disabled by default
- **Pre-built image** -- `cleat start` pulls from `ghcr.io/cleatdev/cleat` (~30s) instead of building locally (~2-5 min), with automatic local-build fallback
- **Forked workspaces** -- `--fork` gives a box its own copy of the project, so several agents can work in parallel without touching your tree
- **Contained Claude home** -- a box sees only its own project's Claude history. The instruction surfaces your host `claude` obeys are read-only inside the cage
- **Hook execution on host** -- your Claude Code hooks (global and project-level) run on the host, not in the container
- **Browser bridge** -- `open` and `xdg-open` inside the container forward URLs to your host browser (auth, OAuth, docs)
- **Host connectivity** -- `host.docker.internal` always available, user-defined hooks and MCP servers work out of the box
- **Configuration drift detection** -- notifies when config has changed since container creation
- **Clean terminal output** -- braille spinners for slow operations, suppressed Docker noise, canonical startup/exit sequences
- **Auto-upgrade notifications** -- checks for updates every 10 minutes and notifies you before launching Claude
- **Release highlights** -- a one-time, non-blocking note on the first run after an update tells you the new version's headline feature

---

## The story behind this

I was deep into vibe coding, letting Claude Code run with `--dangerously-skip-permissions` so it could ship without interrupting my flow. Kick off a task, step away, come back to working code. Multiple projects on my Mac, sometimes left running overnight through a big refactor.

The campfire version of the story is that one night it went rogue and bricked my Mac. The honest version is scarier, because it actually happens. The hardware was never in danger -- Apple sealed the OS so thoroughly that not even root can modify `/System` in place. Any Mac you can boot into Internet Recovery or DFU you can bring back. What an agent running with no gates can actually destroy is everything that *isn't* the OS. It runs as *you*.

So it installs packages system-wide and litters configs across your home directory until the machine you keep clean is quietly rotting. It reads `~/.ssh`, `~/.aws`, your `.npmrc` tokens and your `.env` files -- and it can commit or deploy those secrets straight to the internet. That one isn't hypothetical for us: one night an agent wired up a deploy and an API key rode along into a public static deployment. Nothing was "hacked" -- it was running as us, it had the key, it shipped it. Public keys get scraped and abused in minutes, not days. Providers rarely refund fraud on technically-valid requests. By the time we rotated it, roughly $10,000 was already gone.

And one bad glob ends the rest: developers have wiped entire home folders with a trailing `~/` on an `rm -rf`, where the shell expands the tilde to your whole home directory *after* the agent's own check passes. On a Mac's internal SSD, TRIM is on by default, so the freed blocks are discarded and the per-file encryption key is destroyed within seconds. No undo. No undelete. Only your last backup, if you had one. Gemini CLI destroyed a user's project files the same way. Replit's agent dropped a production database. These are not hypotheticals -- they are documented and all within the last year. Data and credentials die. The hardware survives them.

You can defend the host by hand: never run `--dangerously-skip-permissions` on your machine, never give the agent passwordless sudo, never pre-approve broad globs like `Bash(sudo *)` or `Bash(*)` and keep real backups. That is a lot of discipline to maintain on every project, forever, at 2am.

So I built Cleat. Same unrestricted power, but inside a per-project Docker sandbox where, by default, the blast radius stops at the container. Your host system stays untouched. Capabilities -- ssh, git, env, gh, docker -- are all off until you opt in. Claude can `rm -rf /` inside the container and the rest of your Mac won't even notice. Give the agent a cage, not your keys.

We haven't leaked a key, lost a home folder, or restored from a backup since.

---

## Install

### Quick install (recommended)

```bash
curl -fsSL https://cleat.sh/install | bash
```

This clones the repo to `~/.cleat`, checks out the latest stable release tag and symlinks `cleat` into your PATH. The short URL resolves to the same `install.sh` served from the latest tagged release on GitHub.

### Dev install (from local clone)

```bash
git clone https://github.com/cleatdev/cleat.git
cd cleat
./install.sh --local
```

This symlinks your working copy into PATH. Edits to `bin/cleat` take effect immediately, no reinstall needed. Switch back to the official release at any time with `./install.sh` (without `--local`).

### Update

Releases are published as git tags (e.g. `v0.1.0`). The updater fetches tags and checks out the latest one:

```bash
cleat update
```

To update just the Claude Code build bundled in the image (without a full rebuild):

```bash
cleat upgrade-claude            # latest (default)
cleat upgrade-claude stable     # stable channel
cleat upgrade-claude 2.1.156    # pin a version
```

This re-runs the official installer in the image and commits it back, then offers to recreate the current project's container so the new version takes effect immediately. The change is local-only. `cleat rebuild`/`update`/`nuke` reset the image to a fresh release build (which already bundles a current Claude Code).

You don't have to remember to run it: when you start `cleat` interactively, it checks (at most once every 10 minutes) whether a newer Claude Code is out and offers to upgrade before starting. The check is skipped for non-interactive runs, never blocks on a slow network, defaults to the `latest` channel (`CLEAT_CLAUDE_CHANNEL=stable` to change it) and can be turned off with `CLEAT_NO_CLAUDE_UPDATE_CHECK=1`.

To rebuild the whole image from scratch instead:

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

Credentials are saved to `~/.claude` on your host and shared across all containers automatically. Log in once, every container picks it up: whether you signed in on the host or inside any box, the next box you start or create carries the login. On macOS, where Claude keeps its login in the **Keychain** rather than a file, Cleat bridges that token into the box for you on launch.

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

# Remove the container when you want a fresh environment.
# Session history lives on the host at ~/.claude/projects/<key>/
# and is NOT touched by cleat rm. `cleat resume` after rm
# auto-creates a fresh container and picks up where you left off.
cleat rm
cleat resume
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

### Boxes: multiple sandboxes per project

A **box** is a named, isolated container scoped to the current directory. By
default every box mounts the **same** live files (a fork box is the exception,
see below), but each has its own capabilities, writable
layer and Claude session, so a locked-down `dev` box can run beside a
cloud-capable `az` box over the same repo. The agent in `dev` can't reach the
Docker socket or cloud token that `az` holds.

```bash
cleat start                       # the default box (main)
cleat start az --desc "cloud box" # a separate az sandbox
cleat config az --enable docker   # give just the az box the docker cap
cleat resume dev                  # resume the dev box's last session
cleat status                      # list this project's boxes
```

The token after a verb is a box name (lowercase letters, digits, `-`, `_`),
never a path. `cleat` always operates on the current directory. The default box
is byte-identical to the pre-boxes container, so existing projects keep working
unchanged. Per-box caps come from `.cleat.<box>` (replace, not merge: a box can
have *fewer* caps than `.cleat`). One caveat: `~/.claude` (your Anthropic auth)
is shared across boxes. A box isolates host capabilities and the writable layer,
not your Claude login.

### Kits: curated Claude pre-configurations, per box

### Forked workspaces

A box normally shares your live project directory. `--fork` gives it its own
copy, so an agent can work without touching your tree.

```bash
cleat start feat-a --fork    # its own copy of the project
cleat start feat-b --fork    # another one, independent
```

Run it a few times and you have several agents on the same project, each in its
own container working on its own files. They still share what every box shares:
your Claude login and the host `~/.claude/plugins`.

A box's workspace is fixed when the container is created, so the flag only does
something at create time. Passing `--fork` to a box that already exists as a
plain box is refused rather than silently ignored, with `cleat rm <box>` as the
remedy. Forking a fork, or pointing the fork root inside the project so the copy
would contain itself, is refused too.

It is a copy rather than a git clone, so submodules, untracked sibling repos,
uncommitted work and `node_modules` all come along. A project with no git
works the same way. Symlinks are copied as symlinks and never followed, so a
project holding `sub/keys -> ~/.ssh` does not put real key bytes in the cage. On
macOS the copy is copy-on-write, so it is close to instant and costs almost no
disk until something changes. Exclude what you do not want with
`[fork] exclude = node_modules` in `.cleat`. An exclude that is an absolute
path, contains `..`, names the workspace root, or resolves outside the copy
through a symlink is refused with a warning instead of being deleted.

The launch summary names the copy and how old it is, so a stale fork is never
silent:

```
  Fork:       ~/.config/cleat/forks/cleat-myproj-2f96c884-feat-a  (copied 3h ago)
```

Move the fork root with `[fork] dir` in your **global** config
(`~/.config/cleat/config`) if your projects live on another volume: copy-on-write
only works within a volume. It is read from the global config only and must be
an absolute path. A `[fork] dir` in a project's `.cleat` is ignored on purpose,
because `.cleat` arrives with a cloned repo and this value is a path Cleat
creates and deletes under.

`cleat rm <box>` frees the container and keeps the copy, since it may hold the
only version of the work. Because it is kept, starting the box again with
`--fork` **reuses** that copy rather than taking a fresh one, so a change to
`[fork] exclude` does not apply until you refresh it.

Worth knowing before you rely on it:

- The copy is a **point-in-time snapshot**. A fork taken an hour ago does not
  have work you did in the live tree since.
- Without copy-on-write (Linux without reflink support, or a fork root on a
  different volume) the copy is real duplicated disk.
- `cleat storage` does not see fork copies. It measures the Docker store, while
  the copies live on your filesystem.
- Landing the work is yours. Cleat copies out, it does not merge back.

The copies outlive their boxes on purpose, so they get their own verb. `fork` is
a verb here while `--fork` stays a flag on `start` and `run`.

```bash
cleat fork start feat-a      # create a fork box and launch Claude (= start feat-a --fork)
cleat fork run feat-a        # create it without launching Claude
cleat fork                   # every copy: apparent size, age, is its box still there
cleat fork path feat-a       # bare path, so cd "$(cleat fork path feat-a)" works
cleat fork rm feat-a         # delete one copy and drop the box's fork marker
cleat fork prune             # delete copies whose container is gone, plus any stale marker
cleat fork refresh feat-a    # replace a copy with a fresh one from the project
```

```
  Fork workspaces in ~/.config/cleat/forks

    cleat-demo-ab8ed4e5-feat-a                     412 MB  3h ago     box exists
    cleat-demo-ab8ed4e5-feat-b                      12 MB  2d ago     no box

    2 copies, 424 MB apparent.
```

Size is **apparent, not reclaimable**: `du` is not copy-on-write aware, so a
fresh copy reports its full size while sharing nearly every block with the
project. `rm` and `refresh` refuse while the box exists, because its container
has the copy mounted at `/workspace`. Both confirm, defaulting to no. Both say
plainly that uncommitted agent work in the copy will be lost.

A **kit** is a curated Claude Code setup (a CLAUDE.md policy plus custom
subagents) that you enable for one box with one command. The flagship kit,
`plan-big-execute-small`, adapts the coordinator pattern from
[Anthropic's cookbook](https://github.com/anthropics/claude-cookbooks/blob/main/managed_agents/CMA_plan_big_execute_small.ipynb)
(big models for planning, small models for execution):
run your session on Fable 5 (set once with `/model` inside the session) and
it plans and reviews while `worker` and `scout` subagents (Sonnet 5 by
default) execute and explore, each in its own context window so the main
session stays lean. Flagship judgment on the plan
and every review, the mechanical bulk billed at the worker model's rate, so
heavy work burns your rate limit far slower. Prefer different economics? Pin or swap the agent
models under a `[kits]` section in `~/.config/cleat/config`
(`worker_model = haiku`). The planner is always your session's model.

```bash
cleat kit                              # interactive picker: kit, then models
cleat kit list                         # plain library + this project's selections
cleat kit plan-big-execute-small       # or enable directly, for the main box
cleat kit off                          # back to your own config next session
cleat kit show plan-big-execute-small  # read every line it injects, first
```

A kit merges on top of your own config inside the box, so your global
CLAUDE.md and agents keep working: the kit section is appended and clearly
marked, after a `Cleat box notes` section every box carries with the
clipboard-bridge rules. Its content stays off the host: kits live in generated
mask files mounted into the box, nothing kit-related lands in your `~/.claude`
and native `claude` never sees them. (Creating a box does seed inert placeholders there
when missing, an empty `CLAUDE.md` and empty `agents`/`commands`/`skills`/`plugins`
dirs: mount targets, not content.) Different boxes can run different kits on the
same repo. Kits contain instructions and subagents only, no hooks and no settings.
Whatever they steer the agent to do happens inside the cage. As a
hardening side effect, your five user-level instruction surfaces
(`~/.claude/CLAUDE.md`, `agents`, `commands`, `skills` and `plugins`) are
mounted read-only in every box: the agent reads them but can't plant a
host-user-level command, agent or skill that your host `claude` would later
obey. `skills` matters most, because Claude Code loads whatever it finds there
on its own and can invoke it without you typing anything. Author those at
project level (`.claude/agents/`, `.claude/commands/`, `.claude/skills/`)
instead. Plugins you already have stay readable and usable in a box, but installing a
new one from inside a box fails, because that directory is read-only. Install
plugins on the host and every box sees them. Other projects stay invisible: `~/.claude/projects` holds a full transcript of
every project you have ever run Claude Code on, so a box gets a generated
directory containing only its own project's sessions. Its own session stays
writable, so `--continue` and `--resume` work normally. `file-history`,
`paste-cache`, `uploads`, `backups`, `shell-snapshots`, `sessions`, `tasks`,
`jobs` and `hooks` each become an empty per-box directory. `hooks` is the one
that matters most. It is also why these are generated empties rather than
read-only views. The `hooks` capability runs your hook commands on the **host**
and the usual way to write one names a script under `~/.claude/hooks/`, so a box
able to write there could rewrite what your host runs. What a box can still
reach is the project you mounted plus your Claude login, which it needs to
authenticate.
The read-only copies
dereference symlinks (a dotfile-repo `commands` dir shows up as real files in
the box) while a symlink nested inside a skill is kept as a link, so a skill
pointing at `~/.ssh` cannot pull real key bytes into the box. A broken
symlink at one of the mask paths stops box create with a
clear fix-or-remove error (your symlink is never deleted) and a box created
before these masks existed prints a recreate note on every start until you
run `cleat rm && cleat`.

### Command reference

#### Quick start
| Command | Description |
|---|---|
| `cleat` | Build + run + launch Claude Code (all-in-one) |
| `cleat resume` | Resume the most recent session (recreates the container if `cleat rm` was run since: sessions persist on the host) |

#### Lifecycle
| Command | Description |
|---|---|
| `cleat stop [box]` | Stop this project's container (keeps it for resume) |
| `cleat rm [box]` | Stop and remove container permanently (session history on the host is preserved) |
| `cleat stop-all` | Stop all Cleat containers |
| `cleat build` | Build the Docker image |
| `cleat rebuild` | Force rebuild the image from scratch |
| `cleat upgrade-claude [stable\|latest\|VERSION]` | Update the bundled Claude Code in place (default `latest`). Offers to recreate the current container |
| `cleat clean` | Stop everything and remove the image |
| `cleat prune` | Remove stale cleat images (boxes and other projects untouched) |
| `cleat prune --cache` | Also clear the shared Docker build cache (regenerable, all projects). Typed flag + default-No confirm |
| `cleat storage` | Read-only Docker disk breakdown: fill bar, cleat vs shared vs other projects |
| `cleat nuke` | Remove **all** Cleat containers and images, plus the shared build cache |

#### Capabilities
| Command | Description |
|---|---|
| `cleat config` | Open the `.cleat` editor: a keyboard TUI for capabilities + resources |
| `cleat config --list` | List capabilities and resources (memory, cpus) and their status |
| `cleat config --enable <cap>` | Enable a capability (e.g. `git`, `ssh`, `env`) |
| `cleat config --disable <cap>` | Disable a capability |
| `cleat config --memory <val>` | Set the box memory ceiling (`default` clears it) |
| `cleat config --cpus <val>` | Set the box CPU limit (`all` clears it) |
| `cleat config --project --enable <cap>` | Project-level config (saved to `.cleat`) |
| `cleat config <box> --enable <cap>` | Per-box config (saved to `.cleat.<box>`, replaces `.cleat` for that box) |

The editor also has a **generate** row (global scope): it stamps your current caps + resources into `./.cleat` so a per-project config never has to be hand-written. It preserves an existing `[setup]` section and does not auto-trust (the file goes through the normal trust prompt on the next run).

#### Workspace trust
| Command | Description |
|---|---|
| `cleat trust [path] [box]` | Record approval for a project's (or a box's) `.cleat` capabilities and `[setup]` |
| `cleat trust [box]` | Trust a box of the current project (a lone valid box name) |
| `cleat trust --list` | List trusted projects and boxes (yellow = config changed since approval) |
| `cleat untrust [path] [box]` | Remove a project's (or a box's) trust entry |

#### Kits
| Command | Description |
|---|---|
| `cleat kit` | Interactive picker: pick a kit, then its agent models (TUI, like `cleat config`) |
| `cleat kit list` | Plain kit library and this project's selections |
| `cleat kit <name> [box]` | Enable a kit for a box (merges on top of your config, next session) |
| `cleat kit off [box]` | Disable the box's kit (back to your own config) |
| `cleat kit show <name>` | Print everything a kit injects |

#### Setup
| Command | Description |
|---|---|
| `cleat setup [box]` | Run this project's `[setup]` provisioning now (the box must already be running) |
| `cleat setup [box] --show` | Preview the payload, trust state and marker state without running anything |

#### Flags (apply to `start`, `run`, `resume`, `claude`, `shell`, `login`)
| Flag | Description |
|---|---|
| `--cap <name>` | Enable a capability for this session only |
| `--env KEY=VALUE` | Pass environment variable to container |
| `--env KEY` | Inherit from host environment |
| `--env-file PATH` | Load env vars from file |
| `--trust-project` | Auto-approve the current project's `.cleat` caps without prompting |
| `--trust-setup` | Auto-approve the current project's `[setup]` provisioning without prompting |
| `--desc <text>` | Set the box's description at start (host-side, never recreates) |
| `--fork` | Give the box its own copy of the project instead of the live tree (create time only) |
| `fork [sub]` | Fork a box (`start`, `run`) or manage the copies (`list`, `path`, `rm`, `prune`, `refresh`) |

#### Interact
| Command | Description |
|---|---|
| `cleat claude [box]` | Attach Claude Code to a running container |
| `cleat shell [box]` | Open bash inside the container |
| `cleat login [box]` | Authenticate with Anthropic (OAuth) |
| `cleat logs [box]` | Tail container logs |

#### Info
| Command | Description |
|---|---|
| `cleat status` | Show this project's boxes, image and auth status |
| `cleat describe [box] [text]` | Show or set a box's description (host-side, never recreates) |
| `cleat ps` | List all Cleat containers (running and stopped, with a box column) |
| `cleat update` | Check for updates and install the latest version |
| `cleat version` | Show current version |

All commands operate on the current working directory. The optional `[box]` is a
named sandbox for the project (default: `main`). See **Boxes** above.

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

1. **Pulls or builds the Docker image** (first run only) -- pulls pre-built image from registry (~30s), falls back to local build if unavailable. Image includes Node.js, Python, Git, GitHub CLI, jq, socat and Claude Code CLI
2. **Starts a container** named `cleat-<dirname>-<hash>` (hash derived from the full project path) with your project mounted at `/workspace`
3. **Maps your UID/GID** into the container so files created by Claude are owned by you on the host
4. **Mounts `~/.claude`** for shared authentication across all containers
5. **Starts the clipboard bridge** -- a host-side watcher and a shared file mount so `pbcopy`/`xclip`/`xsel` relay to your host clipboard
6. **Launches Claude Code** with `--dangerously-skip-permissions` inside the sandbox

### Security hardening

Containers run with these protections by default:

- `--pids-limit 4096` -- prevents fork bombs from affecting the host
- A per-box memory ceiling (a quarter of your Docker VM's memory, clamped to 4-8 GB) with swap disabled -- a runaway process OOMs inside its own box instead of swap-thrashing every session at once. Set it with `cleat config` (the arrow-key editor has a Resources group) or `cleat config --memory 4g --cpus 2`, or hand-write a `[resources]` section in `~/.config/cleat/config` or `<project>/.cleat`. The editor's choices are built from your actual machine. Cpus come from the core count Docker reports. On a VM bigger than 8 GB the memory ring climbs in real stops to the VM's size, so a 24 GB VM can be asked for all 24 GB. Past 8 GB it annotates instead of blocking, with a note that gets blunter as the number climbs and the full reason at the whole-VM value (a box that grows into everything starves the daemon and the VM's own OOM killer starts firing). Repo-supplied values are capped (8g memory, your core count for cpus). CPU is unlimited unless you set it -- an idle core costs nothing. If a session is ever OOM-killed (often a test runner spawning one worker per host core), Cleat says so and how to fix it: raise `memory`, cap workers (`jest --maxWorkers=2`), or set `cpus`
- `--init` -- a real PID 1 reaps orphaned processes, so long sessions can't wedge on zombie buildup and `cleat stop` is instant
- Numeric UID/GID validation in the entrypoint to prevent injection attacks
- Node.js bookworm-slim base image with minimal attack surface

Images are published multi-arch (amd64 + arm64): Apple Silicon runs natively, never under emulation. `cleat prune` clears cleat's own stale images (cleat also offers this automatically when they pile up). Boxes and other projects' images are never touched.

Closing a terminal ends the session but leaves the box running, still reserving its memory ceiling. On every interactive start, Cleat stops other idle boxes that are safe to stop (detached, no agent running, idle past a 30-minute grace) and tells you what it freed. A box working unattended (terminal left open, agent still running) is never touched. Disable with `CLEAT_NO_IDLE_SWEEP=1`. Tune the grace with `CLEAT_IDLE_GRACE_MINS`.

If your Docker VM memory is set too low, or swap is left at the default, Cleat **holds the launch** on a prominent amber banner and waits for you to press Enter, instead of letting the warning scroll past unread into Claude's TUI. It fires only on a genuine config problem (never the transient overload notice) and only on a real interactive terminal, so cron, pipes and CI never block. Press Enter to launch anyway, Ctrl-C to go fix Docker, or set `CLEAT_NO_DOCKER_GATE=1` to keep the advisory but skip the hold.

Disk is watched the same way. Every box shares one Docker store, so a box that reads 100% full is really the whole store filling up. When it crosses about 85% full with little free space Cleat drops a one-line advisory naming what you can reclaim (`cleat storage` shows the full breakdown, `cleat prune --cache` clears the shared build cache). When it crosses 95% with under 10 GB free it **holds the launch** like the memory gate, with `CLEAT_NO_DISK_GATE=1` to skip the hold. The trigger is the fill percentage, so a 60 GB disk and a 1.8 TB one trip at the same fullness. The fix guidance is written for your engine (Docker Desktop, OrbStack, Colima, native Linux or WSL). If a store is too full for a box to start at all, Cleat catches the out-of-space error and prints the same guidance.

---

## Capabilities

Capabilities are opt-in features that extend what the container can access from the host. They are **disabled by default**: the baseline container is locked down and each capability explicitly widens the boundary.

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

| Capability | Category | What it does |
|---|---|---|
| `git` | mount | Mounts `~/.gitconfig` (read-only). Commits inside the container use your host identity. |
| `ssh` | mount | Mounts `~/.ssh` (read-only). SSH agent forwarding if `SSH_AUTH_SOCK` is set. |
| `env` | mount | Auto-loads env vars from `~/.config/cleat/env` (global) and `.cleat.env` (project). |
| `hooks` | mount | Runs your Claude Code hooks on the host (global and project-level). |
| `gh` | mount | Mounts `~/.config/gh` (read-write). `gh auth login` inside container writes tokens to host. |
| `docker` | sandbox | Mounts `/var/run/docker.sock`. `docker`, `docker compose` and anything that talks to the daemon run against your host: sibling containers, zero overhead. **Sandbox-escaping. See security note below.** |

> Cloud CLI caps (`az`, `aws`, `gcloud`) and the lazy-install framework that backed them shipped in v0.11.0 / v0.12.0 and were removed after v0.12.3. They bloated first-run time without earning their weight. Install the CLI on the host and pass credentials via the `env` cap.

### Display categories

The post-launch summary and `cleat status` group active caps by behavior:

- **mount** (green): `git`, `ssh`, `env`, `hooks`, `gh`. Bind-mount auth/identity, no install.
- **sandbox** (amber): `docker`. Mounts the host socket, breaks isolation.

When only one category is active the line collapses to a single coloured row. With caps in both categories, the renderer prints a labeled block: same UI on the landing page mockups so the CLI and the marketing copy stay in lockstep.

### Workspace trust: project `.cleat` approval

A project's `.cleat` file lives in the repo. Whoever controls the repo controls that file. Cleat won't silently apply a `.cleat`'s capabilities on first run. Instead, on first launch inside a project with a `.cleat`, you'll see:

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │  This project's .cleat file requests capabilities                   │
  │  that extend what the sandbox can access on your host.              │
  │                                                                     │
  │  Requested:                                                         │
  │                                                                     │
  │    docker  Host Docker socket (breaks sandbox) to test Docker apps  │
  │    env     Load env vars from ~/.config/cleat/env and .cleat.env    │
  │                                                                     │
  │  Project: /Users/you/proj                                           │
  └─────────────────────────────────────────────────────────────────────┘

  Trust this project's .cleat? [y/N]:
```

Say yes and the approval is stored at `~/.config/cleat/trust`. Next launch, nothing to see. Cleat silently applies the caps.

Approval is keyed on the **canonical list of capabilities** declared in `.cleat`, not the raw file. Comment edits and cap reordering don't invalidate trust. Adding, removing, or changing a cap triggers a re-prompt with an "…has changed since you trusted it" framing.

#### Scripting & CI

Non-interactive contexts (pipes, CI, `cleat … | tee log`) can't answer a prompt, so they default-deny: project `.cleat` caps are silently dropped, global config and `--cap` flags still apply. To opt in explicitly:

`CLEAT_TRUST_SETUP=1` (or `--trust-setup`) approves a project's `[setup]` commands only. `CLEAT_TRUST_PROJECT=1` never covers it: caps and setup are separate consent classes.

```bash
cleat --trust-project                 # one-off session flag, caps only
CLEAT_TRUST_PROJECT=1 cleat           # env var (same effect)
cleat --trust-setup                   # one-off session flag, [setup] commands only
CLEAT_TRUST_SETUP=1 cleat             # env var (same effect)
cleat trust                           # persist for this project, once (caps and setup)
```

#### Subcommands

```bash
cleat trust                  # trust the current dir's .cleat
cleat trust ~/proj           # trust a specific project
cleat trust web              # trust the current project's "web" box (.cleat.web)
cleat trust --list           # show all trusted projects and boxes
cleat untrust web            # untrust just the "web" box
cleat untrust ~/proj         # remove a project's trust entry
```

#### What trust covers

| Source | Trusted? |
|---|---|
| `~/.config/cleat/config` (global) | ✔ always: user's own file |
| `--cap <name>` CLI flag | ✔ always: affirmative typed action |
| `<project>/.cleat` | requires approval per-project, per-cap-set |
| `[setup]` in `<project>/.cleat` | requires approval per-project, a separate consent class from caps |

`cleat status` never prompts: it's read-only and silently omits untrusted project caps when displaying.

### Provision the box: the `[setup]` section

Some stacks need a tool the base image doesn't ship: a runtime, an SDK, a
database client. A `[setup]` section in `.cleat` lists the shell commands that
install it, run once per container as the `coder` user right after it's
created. You approve the exact commands once, the same way you approve
capabilities.

```ini
[setup]
curl -fsSL https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -o /tmp/msprod.deb
sudo dpkg -i /tmp/msprod.deb
sudo apt-get update
sudo apt-get install -y dotnet-sdk-8.0
```

That snippet shows the syntax on amd64. Microsoft's Debian feed ships .NET 8
for amd64 only, so the runnable [`examples/setup/dotnet`](examples/setup/dotnet)
example uses the official `dotnet-install.sh` on arm64 (Apple Silicon).

A `script <path>` line inlines a project-relative script file at that position
instead of writing commands inline. List as many `script` directives as you
like, mixed with inline commands, in any order. Copy-paste examples live in
[`examples/setup/`](examples/setup): `dotnet` (inline commands), `python` (one
script file) and `rust` (two script files).

Setup trust is separate from capability trust. `CLEAT_TRUST_SETUP=1` (or
`--trust-setup`) approves it non-interactively, `cleat trust` approves both
caps and setup together and editing `[setup]` re-prompts without ever
recreating the container. Trust is per (project, box): `cleat trust <box>`
approves that box's `.cleat.<box>`.

A failed command prints its exit code and the box still opens. Fix `.cleat`
or the box, then retry with `cleat setup`.

### Docker capability: testing dockerized apps

When `docker` is enabled, the container mounts the host Docker socket and can build, run and manage containers against the **host** daemon. Containers you launch from inside Cleat run as **siblings** on the host (not nested), so there's zero virtualization overhead:

```bash
cleat config --enable docker        # persistent
cleat --cap docker                  # one-off session

# Then, inside the sandbox:
docker compose up -d
docker compose exec app npm run test:ci
docker build -t myapp .
docker run -v $(pwd):/app node:24 npm install
```

Cleat also bind-mounts your project at its **host path** inside the container (in addition to `/workspace`) and sets `workdir` there, so `$(pwd)` returns a host-valid path. This makes `docker run -v $(pwd):/app …` and relative paths like `-v ./data:/data` in `docker-compose.yml` resolve correctly on the host daemon.

The `CLEAT_HOST_PROJECT` environment variable is exported with your project's host path for scripts that want it explicitly.

> **Security note.** The Docker socket grants root-equivalent access to your host. Any process inside the container that can reach `/var/run/docker.sock` can create a container that mounts `/` from the host and escape the sandbox (this is a property of Docker, not Cleat). When the capability is active, Cleat prints an amber warning on startup:
>
> ```
>   ! Docker socket mounted. Container can create host-level processes
> ```
>
> Enable this capability only in projects you trust and disable it when you don't need it. It's off by default and every activation is explicit (`cleat config --enable docker` or `--cap docker`).

Known limitations in v0.10.0:
- Literal `/workspace/…` paths in `-v` aren't translated. Docker errors cleanly that the source doesn't exist. Use `$(pwd)` or the host path instead.
- Paths created inside Cleat at locations that don't exist on the host (e.g. `/tmp/scratch` after `mkdir -p /tmp/scratch` inside Cleat) will be created on the host as empty directories. Keep bind-mount sources under your project path.

### Docker autopilot

Daemon down after a reboot? Run `cleat` and it starts Docker for you, waits
with a spinner, then continues your command. On macOS that means Docker
Desktop, OrbStack, or Colima (named Colima profiles included), on Linux Docker
Desktop or a rootless engine via `systemctl --user`, from WSL2 the
Windows-side Docker Desktop when interop is enabled. Where it can't start Docker safely it prints the
exact fix instead: a root-owned Linux engine (or an in-distro engine inside
WSL2, which wins over the Windows Desktop) gets `sudo systemctl start docker`,
a socket you can't write means Docker is up and you're not in the `docker`
group (the message hands you `sudo usermod -aG docker <user>`) and a remote
endpoint (`tcp://`, `ssh://`, `npipe://`, `fd://`) is refused with "start it
where it runs". Fires only on session verbs and only in an interactive
terminal, so scripts and CI are untouched. The wait is bounded
(`CLEAT_AUTOSTART_TIMEOUT_SECS`, default 90s) and `CLEAT_NO_AUTOSTART=1`
turns it off.

No Docker installed at all? Cleat offers to install it, consent-first: on
macOS a menu of Docker Desktop / OrbStack / Colima via Homebrew's official
packages (casks for Desktop/OrbStack, formulae for Colima, with the licensing
difference stated), on Linux Docker's official install script downloaded to a
private temp dir and run under sudo only after you say yes, on WSL2 the
Windows-side Desktop via winget. The exact command is always shown, the
default is No and scripts are never prompted.

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

When you change **capabilities or env keys** after a container was created, Cleat detects the mismatch the next time you run `cleat`, `cleat resume`, or `cleat claude`. On a TTY it prompts you to recreate (a plain-text line, no box):

```
  ▸ Config changed since cleat-<project> was created: caps or env keys differ from the running setup
    Recreate cleat-<project> now? [Y/n]
```

Accepting removes the container and rebuilds it with the new caps/env. Sessions persist on the host (`~/.claude/projects/<key>/`) and are never touched. Declining keeps the existing container.

A Cleat version bump on its own does **not** trigger this: the drift check looks only at caps and env keys. Image freshness is handled separately and is also content-aware: the on-start image-refresh prompt fires only when the image's actual contents change (the entrypoint, the clipboard or browser bridge, the Dockerfile, or the pinned base), not on every version bump. The base image is pinned by digest, so a routine release leaves your container and everything you installed in it untouched. A base or security update ships through the same refresh prompt.

Non-TTY runs (CI, scripts) print the notice and continue with the existing container. They never auto-destroy.

### Config files

```
~/.config/cleat/config    ← global capabilities, [resources], [kits], [fork] dir
~/.config/cleat/env       ← global env vars
~/.config/cleat/forks/    ← fork workspace copies (default root, moved by [fork] dir)
<project>/.cleat          ← project-level capabilities (extends global), [setup], [fork] exclude
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
  ✔ Session ended. Resume with: cleat resume
```

Docker's "What's next?" promo text and clipboard watcher cleanup messages are suppressed.

---

## Hooks

When the `hooks` capability is enabled, your Claude Code hooks run on the host, exactly as if you weren't using a container. Hooks from all three settings locations are supported:

- `~/.claude/settings.json` (global)
- `.claude/settings.json` (project, committed)
- `.claude/settings.local.json` (project, local)

**This capability is the one place where the box's activity deliberately runs a command outside the cage.** That is the feature and it is your call, but enable it knowing the shape. The command runs on your host, as you, uncontained. The agent is what generates the events that trigger it. Two consequences worth reading twice. A hook command that names a path in the repo (`$CLAUDE_PROJECT_DIR/.claude/hooks/format.sh`, `npm run hook`, `make lint`) resolves inside `/workspace`, which the agent edits as ordinary work. The two project settings files above are read from your working tree, so hooks the agent writes there are hooks your host will run. Point a hook you care about at a script outside the project. Treat the set of hooks you have enabled as the set of things the box can ask your host to do, at a time of its choosing.

```bash
cleat config --enable hooks    # enable persistently
cleat --cap hooks start        # enable for one session
```

### How it works

1. Cleat creates a settings overlay that replaces hook commands with an event forwarder inside the container
2. Project-level hook settings are also overlaid to prevent double-execution
3. A host-side bridge reads forwarded events and executes the original hook commands on the host
4. Event JSON is piped to stdin, matchers are respected, 30s timeout per command
5. Commands like `osascript`, local scripts and anything host-specific work transparently

---

## Browser bridge

When Claude Code or any tool inside the container calls `open` or `xdg-open` with a URL, it opens in your host browser. OAuth callbacks are automatically proxied back to the container. `cleat login` and any auth flow work seamlessly without manual URL copy-paste. No capability needed.

**One click, one tab.** Your terminal already opens a clicked link itself, so on an interactive terminal the bridge defers plain links to it and opens via the bridge only what the terminal won't: auth/OAuth-callback URLs and non-interactive runs. Clicking a link opens a single tab, on any terminal. Override with `CLEAT_BROWSER_BRIDGE=always` (open every URL through the bridge) or `off` (never auto-open, the login callback proxy still runs).

---

## Host connectivity

Containers can always reach services on the host via `host.docker.internal`. No capability needed. User-defined hooks, MCP servers and HTTP endpoints on the host work out of the box.

```bash
# In .cleat.env (with env capability enabled)
CLAUDE_VISUAL_URL=http://host.docker.internal:3200
```

On Linux (Docker Engine), Cleat adds `--add-host host.docker.internal:host-gateway` automatically. Docker Desktop (macOS/Windows) provides this natively.

---

## Auto-upgrade notifications

Cleat checks for new release tags at most once every 10 minutes via `git ls-remote --tags` (a lightweight network call that fetches no objects). When a newer version is available, you'll see a notice before Claude Code launches:

```
  ┌──────────────────────────────────────────────────────┐
  │  Update available  v0.4.0 → v0.5.0                   │
  │  Run cleat update to install the latest version.      │
  └──────────────────────────────────────────────────────┘
```

- The check runs at most **once every 10 minutes**. It will not slow down subsequent launches.
- The result is cached in `.update_check` inside the installation directory (`~/.cleat`).
- The notification is informational only. It will never interrupt or block your workflow.
- To upgrade, run `cleat update`. To also update Claude Code inside containers, follow up with `cleat rebuild`.

---

## Clipboard support

Clipboard works out of the box. When Claude Code (or any tool) calls `pbcopy`, `xclip`, or `xsel` inside the container, the text is copied to your **host machine's clipboard** -- no X11, display server, or special terminal features required.

### How it works

A host-side clipboard watcher starts automatically alongside every Claude Code session. The container writes clipboard data to a shared file via a bind mount. The watcher claims the file and copies the content to your real clipboard using `pbcopy` (macOS), `xclip`, `xsel`, or `wl-copy` (Linux). Each copy is picked up once and never replayed: the watcher consumes the payload as it delivers it and discards anything left over from an earlier session instead of replaying it onto your clipboard.

```
┌─────────────────────────────┐      ┌─────────────────────────────────┐
│  Docker container           │      │  Host                           │
│                             │      │                                 │
│  Claude Code                │      │                                 │
│    └─ echo "text" | pbcopy  │      │                                 │
│         └─ writes to ──────────────>  ~/.config/cleat/run/<box>/clip/│
│           /tmp/cleat-clip/  │      │    └─ watcher claims the file   │
│                             │      │         └─ pbcopy / xclip       │
│                             │      │              └─ ✔ clipboard!    │
└─────────────────────────────┘      └─────────────────────────────────┘
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

An interactive `cleat` starts Docker for you (see **Docker autopilot** above), so
you rarely see a raw daemon error now. If Cleat prints `Docker isn't running`, run
the exact start command it shows. This happens by design when the auto-launch can't
help: a script or CI run (no TTY), `CLEAT_NO_AUTOSTART=1`, a root-owned Linux engine
or an in-distro WSL2 engine (the message hands you `sudo systemctl start docker`), a
WSL2 distro with interop disabled (start Docker Desktop on Windows and enable WSL
integration for the distro), or a remote `tcp://`/`ssh://`/`npipe://`/`fd://`
endpoint (start it where it runs). `Docker is running, but you can't reach its
socket` is permission, not a down daemon: add yourself to the docker group with the
printed `sudo usermod -aG docker <user>`, then log out and back in. `Docker isn't
installed` instead? Take the install offer, or run the printed install command.

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

<sub>Cleat. Give the agent a cage, not your keys. | Docker sandbox for AI coding agents | cleat.sh</sub>
