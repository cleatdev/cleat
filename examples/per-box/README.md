# Per-box config: one project, three boxes

A box is a named container on a project. `cleat start`, `cleat start az` and
`cleat start review` are three separate boxes on the same repo. This example
shapes three of them differently from a single `.cleat` file.

Before per-box sections, a per-box override meant a separate dotfile per box
(`.cleat.az`, `.cleat.heavy`, `.cleat.review`, ...). A week of forks left a pile
of committed dotfiles in the repo. Now it is one file: scope any section to one
box with a `[box.<name>.<kind>]` header, where `<kind>` is `caps`, `resources`,
`setup` or `fork`.

## The three boxes

| Box | Caps | Memory | Setup |
|---|---|---|---|
| `az` | `git env` | 2g | Azure CLI (inline) |
| `heavy` | `git ssh docker` | 8g | none |
| `review` | none (lockdown) | inherits 4g | none |
| _project default_ | `git ssh` | 4g | none |

The project default sets `git ssh` caps and a 4g memory ceiling. It sets no
`cpus`, so every box falls back to Cleat's computed default there. Each box below
writes only the lines that differ.

## One rule, three outcomes

A `[box.<name>.<kind>]` section overrides the project default for that one box.
The three boxes show the whole rule:

- **DECLARED replaces.** `[box.heavy.caps]` lists `git ssh docker`. It does not
  merge with the project `git ssh`. It replaces the section wholesale, so heavy
  has to re-list `git` and `ssh` to keep them while adding `docker`. Replace
  never merges, so a box can only ever ask for FEWER caps than the project, never
  more. That is what keeps least privilege.
- **ABSENT inherits.** `review` has no `[box.review.resources]`, so it inherits
  the project 4g. `az` declares only `memory`, so it keeps its own 2g and
  inherits everything else. Resources fall back per key, not per section.
- **EMPTY is a value.** `[box.review.caps]` is declared with nothing under it.
  That is zero capabilities, a hard lockdown, not "inherit the project
  `git ssh`". Present-but-empty is the one thing the old per-box dotfiles could
  not express.

## Trust is per box

`[setup]` runs shell commands, so it needs your consent. Trust is tracked per
box. Launching `az` for the first time previews its Azure CLI payload and asks
once. Approving it does not silently approve any other box. `heavy` and `review`
ship no `[setup]`, so they never prompt.

## Resources and the 8g clamp

`.cleat` ships with the repo, so a project value is untrusted input. Memory is
clamped to 8g and cpus to the host core count: a cloned repo cannot oversize a
box on your machine. `heavy` asks for the full 8g ceiling. Ask for more (say 16g)
and Cleat clamps it straight back to 8g. Your own global config
(`~/.config/cleat/config`) is not capped, since it is yours. A limit is a
ceiling, not a reservation: a box only holds what it touches.

## `docker` is root-equivalent

The `docker` cap on `heavy` mounts the host Docker socket into the box. That is
control of the host Docker daemon, an escape from the sandbox Cleat exists to
give you. Grant it only to a box you would trust with your whole machine. Never
grant it to a box running an untrusted agent. `az` and `review` never get it.

## A fork is a box

A fork is a box created from a copy of your working tree, so every rule above
applies to a fork unchanged. `cleat fork start az` (the same as
`cleat start az --fork`) copies the repo into a fork named `az`, gives it the
`git env` caps and 2g, then runs `[box.az.setup]` on the copy. So the fork
installs the Azure CLI too, behind the same one-time approval.

`[box.<name>.fork]` prunes paths from that copy. `review` sets
`exclude = node_modules` and `exclude = dist`, so `cleat fork start review`
leaves both out of the fork. Excludes are project-relative, one per line. No
absolute paths, no `..`, no naming the workspace root.

Run several forks of one project side by side, each in its own copy with its own
caps and limits. To relocate where fork copies live, set `dir = <abspath>` under
`[fork]` in your global config. That key is global-only and is never read from a
project `.cleat`.

## Try it

```sh
# from your project root, copy just the .cleat
cp /path/to/cleat/examples/per-box/.cleat .

cleat start az            # low-memory cloud box: previews and runs the Azure CLI setup once
cleat start heavy         # docker cap, 8g ceiling
cleat start review        # zero-cap read-only box, no host identity

cleat fork start az       # a fork of az: own workspace copy, runs the Azure CLI setup on it
cleat fork start review   # a fork of review: prunes node_modules and dist from the copy

cleat config az --list    # caps and limits resolved for the az box
cleat config review --list
```

`cleat config <box> --list` prints the caps and the memory/cpu limits a box
resolves to, after the declared/inherited rules and the clamp. Run it to confirm
`review` is locked down and `heavy` sits at 8g.
