## v0.4.0

**Clean, quiet output that matches the landing page tone.**

No Docker noise — just concise status lines with color and spinners.

### Features

- **Terminal design system** — unified symbols (`✔ ▸ ! ✖`), 8-color ANSI palette, and formatting rules shared across CLI, installer, and landing page
- **Braille spinner** — 10-frame braille animation (80ms/frame) for slow operations (image build, container start), with ASCII fallback for non-Unicode terminals
- **Clean startup sequence** — step-by-step `✔ Image ready` / `✔ Container started` / `✔ Auth shared` / `✔ Claude launched` output
- **Summary block** — post-launch block showing container name, project path, active capabilities, and env var counts
- **Docker output suppression** — build logs captured and hidden on success, shown (last 20 lines) on failure; container IDs and promo text suppressed
- **Clean exit** — session end shows `✔ Session ended — resume with: cleat resume`; Ctrl-C exits silently; Docker promo text and `Terminated` messages suppressed via `disown`
- **TTY detection** — spinners degrade to static `▸` info lines when stdout is not a terminal (piped, CI, redirected)

### Fixes

- **Clipboard watcher cleanup** — added `trap` on TERM/INT/HUP and `disown` to prevent `Terminated` messages and ensure clean process cleanup
- **Exit cursor restoration** — spinner cleanup restores cursor visibility (`tput cnorm`) on unexpected exit via EXIT trap

### Changes

- 269 behavioral tests (12 new for terminal UX, output suppression, and canonical message hardening)
- Terminal design system documented in `concept/12-terminal-design-system.md`
- Site CSS mapping documented for HTML terminal mockups matching CLI output

---

## v0.3.0

**Opt-in capabilities that extend container access to host resources.**

All disabled by default — the baseline sandbox is unchanged from v0.1.0.

### Features

- **Capability system** — `cleat config` interactive wizard and direct mode (`--enable`, `--disable`, `--list`) to toggle host access per capability
- **`git` capability** — mount `~/.gitconfig` (read-only) so commits use your host identity
- **`ssh` capability** — mount `~/.ssh` (read-only) with SSH agent forwarding for private repos
- **`env` capability** — auto-load environment variables from `~/.config/cleat/env` (global) and `.cleat.env` (project)
- **CLI flags** — `--cap`, `--env KEY=VALUE`, `--env-file PATH` for session-scoped overrides
- **Configuration drift detection** — config fingerprint stored as Docker label; warns on mismatch instead of silently using stale settings
- **Image version detection** — CLI version stored on image; suggests `cleat rebuild` when mismatched
- **Project-level config** — `cleat config --project` saves to `<project>/.cleat`, merged with global

### Fixes

- **Bash 3.2 compatibility** — removed all associative arrays (`local -A`), which require bash 4.0+ (macOS ships 3.2)
- **Empty array expansion** — protected against `set -u` failures on empty arrays in bash < 4.4
- **Env resolution** — replaced grep/sed pipeline that silently exited under `set -euo pipefail` with indexed array approach

### Changes

- 216 behavioral tests (95 new for capabilities, config, hardening, bash compat)
- 21 mutation tests covering security-critical behaviors — all mutations caught
- Source-level scans for forbidden bash 4+ patterns
- Strict-mode regression tests that run the actual binary

---

## v0.2.0

**Run anything. Break nothing.**

### Features

- **Test suite** — 121 behavioral tests covering every CLI command, the clipboard shim, container naming, update logic, and the Docker entrypoint. Mutation-tested: 12/12 code mutations caught.
- **Test runner** — `./test.sh` with per-file pass/fail summary, skip counts, timing, and failure details. Auto-initializes BATS submodules if missing.
- **Sourceable CLI** — `bin/cleat` can now be sourced without executing `main`, enabling direct function testing via a `BASH_SOURCE` guard.

### Changes

- Added BATS framework (bats-core, bats-assert, bats-support) as git submodules
- Added Docker stub with file-based mock responses and function-override mocks
- Added 14 test files covering: argument parsing, clipboard (shim + bridge + detection), container naming, all docker commands, exec_claude, helpers, version resolution, nuke, resolve_project, start/resume lifecycle, update, and version/update-check

---

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
