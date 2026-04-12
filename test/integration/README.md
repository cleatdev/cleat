# Integration tests

Tests in this directory use **real Docker**. They:

1. Build the `cleat` image
2. Run actual `cleat` commands against a real daemon
3. Assert on the real container state and command output

## When to use

Integration tests are the only layer that catches platform-specific bugs like
v0.6.5 (macOS Docker Desktop virtiofs behavior) or v0.6.4 (OAuth callback proxy
IPv6 vs IPv4). Unit tests with the mock docker stub cannot reach these layers.

Because they're slow (seconds per test) and require a Docker daemon, they run:

- In CI (`test-integration` job) on every PR
- Locally when you run `test/integration/run.sh` manually

They **do not** run as part of `./test.sh` (which must remain fast and
daemon-free so developers can iterate).

## Skipping

Every test starts with a `skip_if_no_docker` check. On machines without Docker
(or with it unavailable), the tests skip cleanly rather than failing.

## Layout

```
test/integration/
  run.sh           — runner script (invokes bats on *.bats files)
  lifecycle.bats   — full container lifecycle: build → start → shell → stop → rm
  env.bats         — env passthrough: .cleat.env vars visible in cleat shell
```

## Running locally

```bash
./test/integration/run.sh              # all integration tests
./test/integration/run.sh env.bats     # one file
```
