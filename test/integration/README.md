# Integration tests

Tests in this directory use **real Docker**. They:

1. Build the `cleat` image
2. Run actual `cleat` commands against a real daemon
3. Assert on the real container state and command output

## When to use

Integration tests are the only layer that catches platform-specific bugs like
v0.6.5 (macOS Docker Desktop virtiofs behavior). Unit tests with the mock
docker stub cannot reach that layer. The OAuth callback proxy (v0.6.4, IPv6
before IPv4) is NOT covered here: it is pinned in the unit suite by driving a
real loopback request through the real host socat with a stub container.

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
  run.sh           is the runner script (invokes bats on *.bats files)
  accounts.bats    covers named Claude logins against a real box
  egress.bats      covers egress control: the refusal on an engine that is not validated,
                   and the ten cases of EGRESS-SPEC.md 11.7 on one that is
  handoff.bats     covers the live account handoff
  image.bats       covers the built image itself
  lifecycle.bats   covers the full container lifecycle: build → start → shell → stop → rm
  provision.bats   covers [setup] provisioning
```

`egress.bats` reads the engine kind and the shipped `_EGRESS_ENFORCING` from
`bin/cleat` and never patches it. Every CI leg reads an engine that is not
validated, so there it asserts the refusal. Its full cases run on Docker
Desktop for macOS, from the Mac itself. A CI step pins the kind it expects with
`CLEAT_INT_EXPECT_ENGINE`, and the file fails when the kind it reads differs.

Run from inside a Cleat box against the host's Docker, set `TMPDIR` to the
checkout's gitignored `.egress-scratch/` first, so every path the CLI binds
exists on the Docker host too. These files build the `cleat` image, which
replaces the host's own.

## Running locally

```bash
./test/integration/run.sh              # all integration tests
./test/integration/run.sh env.bats     # one file
```
