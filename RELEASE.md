## v0.1.0

**Run anything. Break nothing.**

A Docker sandbox for running AI coding agents with full autonomous permissions — safely isolated from your host machine.

### Features

- **One command** — `cleat` builds the Docker image, starts a per-project container, and launches Claude Code with `--dangerously-skip-permissions`
- **Per-project isolation** — each project gets its own container (`cleat-<dirname>-<hash>`), run as many as you need in parallel
- **Session persistence** — `cleat stop` and `cleat resume` pick up right where you left off
- **Zero file permission issues** — host UID/GID is mapped into the container automatically
- **Clipboard bridge** — `pbcopy`, `xclip`, and `xsel` shims copy to your host clipboard via a file-based bridge with inotifywait/fswatch support and OSC 52 fallback
- **Shared auth** — `~/.claude` is mounted into all containers, log in once
- **Auto-upgrade notifications** — daily lightweight tag check, never blocks your workflow
- **Security hardening** — `--pids-limit 1024`, `--memory 8g`, numeric UID/GID validation, Debian slim base

### Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/cleatdev/cleat/main/install.sh | bash
cd ~/your-project && cleat
```

### Requirements

- [Docker](https://docs.docker.com/get-docker/)
- macOS or Linux (Windows via WSL2)
- An [Anthropic](https://www.anthropic.com/) account (team or Pro plan)
