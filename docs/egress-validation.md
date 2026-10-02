# Egress control: validation per Docker engine

Cleat enforces an egress policy only on a Docker engine in its validated set.
Every other engine refuses a box with a policy rather than claim a cage nobody
has tested. This file is where the hand validation of each engine is recorded.
A leg enters `_EGRESS_VALIDATED_ENGINES` in `bin/cleat` only when all fifteen
steps below pass and its dated row is in the results table. The one exception
is the first: Docker Desktop for macOS ships in the set ahead of its row, and
the row must land before the release.

No automated leg can run the whole list. Steps 11, 14 and 15 need a host sleep
or a daemon restart. An agent working inside a Cleat box would restart the
daemon it runs on. CI asserts the refusal on every engine that is not
validated (`test/integration/egress.bats`).

## What to record for each run

The date, the engine kind, the Docker API version, the host uid, the box uid,
the exact CLI version, the image spec version and the three normalization
strings of step 4.

The engine kind is the token `_egress_engine_kind` measures, such as
`desktop-macos`. No screen prints the token itself. Read it at any step from a
checkout of the candidate with `bash -c '. bin/cleat; _egress_engine_kind; echo'`
(sourcing runs no command). Step 2 needs it before any caged box can exist.
Each caged box also carries it as the label its launch compares with the
engine answering now. Once step 4 has started a box, record it with
`docker inspect -f '{{index .Config.Labels "sh.cleat.egress-engine"}}' <box>`.
On a leg not yet validated `cleat egress status` names the engine in words
(step 1). On a validated leg nothing names it: the editor's amber engine line
and the status refusal appear only on an engine that refuses.

## The fifteen steps

Each step asserts a connection outcome or an inspect field, never the presence
of a rule or a config file.

1. On a leg not yet validated, `cleat egress status` under a policy names the
   engine: `Egress control is not available on <engine>`.
2. Add the leg's kind to `_EGRESS_VALIDATED_ENGINES` in a local copy of
   `bin/cleat`, never committed. `cleat egress status` no longer names the
   engine. With no caged box yet it prints `No box yet. Its gateway is created
   with it on the next launch.` The gateway rows appear once step 4 has started
   one.
3. The `host.docker.internal` probe on the leg's real host:
   `docker run --rm --network none --add-host host.docker.internal:host-gateway alpine cat /etc/hosts`,
   then a five second `curl -sS http://host.docker.internal/` from a box.
   Record whether the create succeeded, whether the name resolved and how long
   the connect took.
4. Start a box with a one-host policy. `docker inspect` shows
   `NetworkMode=none`, `CAP_NET_RAW` (or the literal `ALL`) in
   `HostConfig.CapDrop` and the socket volume in `Mounts`, mounted read-only.
   Also record `.HostConfig.CapDrop` after `--cap-drop NET_RAW` and after
   `--cap-drop ALL`, then `.HostConfig.SecurityOpt` after
   `--security-opt seccomp=unconfined`, on three throwaway containers. A leg
   whose strings differ cannot be validated until the difference is written
   down.
5. From inside the box, an allowed host over 443 succeeds.
6. From inside the box, a denied host over 443 fails with a 403 whose body
   names the policy (`cleat egress: <host> is not on the allowlist.`). Read the
   body, not only the status code.
7. The socket permission test. `docker top <box> -o pid,uid,comm` shows every
   `socat` process at the box's `HOST_UID`.
   `docker exec <box> stat -c '%u %a' /run/cleat-egress/proxy.sock` prints that
   uid and `600`. Where the box uid is not 1000, prove the check can fail:
   chown the socket to `0:0` from a throwaway container that mounts the volume
   by name, confirm steps 5 and 6 fail and that `cleat egress status` shows the
   shim not listening, then `cleat egress restart`.
8. `getent hosts example.com` exits 2 and a raw `AF_PACKET` socket from box root
   fails with EPERM. `cat /proc/net/route` prints only its header line (the
   image has no `ip`). `/etc/resolv.conf` is still there and `lo` is still up,
   which is expected. Then, on a host that holds a public IPv4 with a listener
   on 443, run `cleat egress open` for the box and request
   `https://a-b-c-d.sslip.io/` from inside it, with the labels spelling that
   address. Record reached or refused, or that the host holds no public IPv4.
9. `cleat stop`, then `cleat resume`. Between the two, `cleat egress status`
   shows the gateway stopped. The restart starts the gateway before the box.
   Repeat 5 to 7.
10. Kill the gateway container. The box's next request fails as a gateway
    outage, never as a success and never as a policy denial.
11. Suspend the host for at least an hour, resume, repeat 5 and 6.
12. Run `[setup]` over https through the shipped runner: `sudo apt-get update`,
    then one package from a repository a ticked pack covers. It exits 0. Untick
    that pack, change the install line to a second package from the same
    repository that the box does not hold and run `cleat setup`: the install
    exits 100, the runner prints `Setup failed with exit code 100` and
    `cleat egress why <package>` names the pack. A 1 would mean `sudo` refused
    to run.
13. `cleat rm` the box. The gateway, the socket volume, the rendered policy and
    the box's own egress files under `~/.config/cleat` (`egress-boxes`,
    `egress-pins`, `egress-notices`) are all gone. `docker volume ls` shows no
    orphan.
14. Restart the Docker daemon with a box and its gateway running. Record which
    containers returned, whether `proxy.sock` survived, the socket volume's
    `CreatedAt` and labels before and after, whether the shim needed
    respawning and the `.State.ExitCode` of both containers. Read the volume
    with `docker volume inspect -f '{{.CreatedAt}} {{json .Labels}}' <volume>`,
    where `<volume>` is the name on the `Socket:` row of `cleat egress status`.
    Neither may change. The socket's inode is no evidence about the volume.
    Every gateway start unlinks `proxy.sock` and binds a new socket, which may
    get a new inode number or the old one back. Expected, not yet confirmed:
    after a clean quit and reopen both stay stopped and the next `cleat start`
    brings the gateway back before the box. After a daemon killed uncleanly the
    gateway returns without its box and `cleat egress status` shows it
    orphaned. Read both containers before any cleat command. A gateway the
    daemon started again reads exit code 0, because a start clears the code.
    Its return shows as `.State.Running` true with a `.State.StartedAt` later
    than the reopen. The box tells the two cases apart: 255 means the daemon
    found it still marked running, which is the unclean case.
15. The overnight run, below.

## Step 15, the overnight run

One real unattended session of at least eight hours, with any keep-awake
utility off. It includes a lid sleep of at least thirty minutes and a Docker
Desktop quit and reopen. At the end, record:

- the gateway's health and `RestartCount`
- `gw-admin path_ok`
- the socket volume's `CreatedAt` and labels before and after, read as in
  step 14 (a change means the volume was made again during the run). Not the
  `proxy.sock` inode, which a gateway start replaces
- `last_shim_seen` and how many times the shim was respawned
- whether the box returned after the daemon restart (expected: no)
- whether the gateway returned
- the `.State.ExitCode` of both containers (a gateway that returned reads 0,
  see step 14)
- the first request after wake
- the tunnel count in the gateway log across the sleep boundary
- whether the VM clock jump disturbed the health check interval

Thirty minutes is the floor because a shorter sleep may not cross the VM
suspend threshold. The keep-awake utility being off is the point: a daily setup
that keeps the machine awake hides this failure.

It exists because the worst failure in this design is silent. One failed
`fork()` kills socat. Its supervisor starts it again about a second later and
logs `relay exited` in `/tmp/cleat-egress-shim.log` inside the box, so count
those lines. A box out of pids for longer than about fifteen seconds makes bash
give up on a fork, which ends the supervisor or its heartbeat loop. Each starts
itself again in place. Its command line still starts
`bash /usr/local/bin/cleat-egress-shim`. A supervisor that started itself again
goes on with `--again`. A heartbeat loop goes on with `--beats` and its relay's
pid from its first start, so `--again` is only ever a supervisor. The last word
of either counts that shell's quick ends in a row. The supervisor logs
`supervisor started again in place` each time, so count those lines too.

An end can also come within seconds. bash never retries a fork that fails for
want of memory. A child that exits while bash waits to retry a fork also cuts
the retry short. The fourth such quick end in a row is the last, so that shell
stays down. Each shell counts its own, so a heartbeat loop started by a
supervisor that had quick ends still gets its own three restarts. If the
supervisor stays down, or is killed, every later request from that box fails
and the gateway stays healthy throughout. Overnight that is
a total loss of egress that nothing on the host reports on its own.
`cleat egress status` shows the relay's last heartbeat.
`cleat egress restart --shim` brings it back. If only the heartbeat loop stays
down, requests keep working, but status reads `Shim not listening` until its
relay or the box restarts. Its supervisor is alive and keeps the lock, so
`cleat egress restart --shim` sends one heartbeat and the row goes stale again.

## Results

One row per step per leg. A step is passed only once its row is here.

| Date | Engine kind | Step | Result | Notes |
|---|---|---|---|---|
| | desktop-macos | 1 to 15 | not yet run | |

## Earlier evidence, not a validation

On 2026-09-26 the builder drove the shipped helpers by hand against Docker
Desktop for macOS on arm64, from inside a Cleat box: a gateway created with the
exact run line, a caged box, the relay, an allowed and a denied request, the
socket permission path and the heartbeat. Every check passed. That was not the
product path and it covers none of steps 11, 14 or 15, so it validates nothing
on its own.
