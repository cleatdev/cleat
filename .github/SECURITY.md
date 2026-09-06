# Security policy

Cleat is a container sandbox for AI coding agents, so a hole in the
boundary is the bug that matters most here. Please report it privately.

## How to report

Use GitHub's private vulnerability reporting on this repo: the Security
tab, then "Report a vulnerability". That opens a thread only you and the
maintainer can read. Please do not open a public issue for anything that
weakens the boundary.

## What to expect

Cleat is maintained by one person. You should get a first reply within a
few days. If a week passes with no answer, ping again on the same thread.
There is no bounty programme. Fixes ship in a normal tagged release.
Credit goes in the release notes unless you ask to stay anonymous.

## Supported versions

Only the latest tag. `curl -fsSL https://cleat.sh/install | bash` resolves
the newest release at install time and `cleat update` moves an existing
install forward, so upgrading is the fix path for every report.

## Scope

In scope, anything that breaks the boundary Cleat claims:

- Escaping the container from a default box with no extra capabilities on
- Reading a host path a box never mounts, such as `~/.aws`, or `~/.ssh`
  with the `ssh` capability off
- The installer or the update path fetching or running code from
  somewhere it should not
- Gaining write access to the host through the clipboard bridge or a
  mounted path outside the project

Out of scope, because it is documented behaviour rather than a defect:

- Escapes that need a capability you turned on yourself. The `docker`
  capability mounts the host Docker socket, which is root-equivalent by
  design. The README says so and the CLI warns at startup.
- The agent modifying files in the project directory you mounted. That is
  the point of the tool. Reviewing the diff stays your job.
- Kernel or hypervisor bugs in Docker itself. Report those upstream.

The threat model this project actually defends is at
https://cleat.sh/compare#threat-model. Reading it first saves a round trip.
