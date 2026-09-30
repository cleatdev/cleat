# The egress catalogue

> If you think a row here is wrong, or you want a host added or removed, open an issue at
> https://github.com/cleatdev/cleat/issues.

Every host Cleat's egress editor can offer, grouped into the packs it offers them in. This file is
the published copy of the table built into `bin/cleat` (`_egress_pack_catalogue`), and a test
fails when the two differ.

Egress control is not enforced yet. A saved policy is configuration only. See
[concept/46](https://cleat.sh/docs) for what that means today.

## How to read a row

- **class** is how the host's edge answered a request for a name that is not its own, measured on
  HTTP/1.1 and HTTP/2 on the date in **measured**. **single origin**: nothing else sits behind the
  name. **contained**: other names sit behind the same edge and it refuses to serve them.
  **shared**: the edge serves a different site when asked, so allowing the host allows more than
  its name. **open tenancy**: whatever the edge does, anyone can place content there, so the host is
  an upload or download channel for strangers. **unaudited**: no measurement exists.
- The editor (`cleat egress`) says a class in plain words on the pack's row and in its pane:
  nothing for single origin and contained, `! reaches other sites` for shared, `! anyone can
  upload` for open tenancy and `! not checked` for unaudited. A pack takes the word of its weakest
  default host. The class words above stay in `cleat egress packs`, `--list` and this file.
- A class is a dated measurement, not a guarantee. An edge can move with no signal between one
  measurement and the next.
- **flags** name how the editor treats the row: `core` and `locked` rows are always on,
  `default` packs sit on the `[setup]` provisioning path, a `sub-tick` host is added on its own
  from the pack's hosts, a `parameterised` host needs a value you type (the part in braces), `no-security` means an
  apt source without a security suite and `requires-cap` means the pack needs a capability that
  egress control refuses.
- Nothing marked shared, open tenancy, unaudited or parameterised is ever ticked for you, with two
  named exceptions, `apt-debian` and `apt-image-extras`, which sit on the `[setup]` path. Debian
  publishes no single-origin security archive, and the image configures the Docker and GitHub CLI
  apt sources itself.

## The catalogue

| pack | host | class | flags | measured |
|---|---|---|---|---|
| `claude` | `api.anthropic.com` | contained | `core` `locked` | h1+h2, 2026-09-21 |
| `claude` | `claude.ai` | contained | `core` `locked` | h1+h2, 2026-09-21 |
| `claude` | `claude.com` | contained | `core` `locked` | h1+h2, 2026-09-21 |
| `claude` | `platform.claude.com` | contained | `core` `locked` | h1+h2, 2026-09-21 |
| `claude` | `code.claude.com` | contained | `core` `locked` | h1+h2, 2026-09-21 |
| `github` | `github.com` | contained |  | h1+h2, 2026-09-21 |
| `github` | `api.github.com` | contained |  | h1+h2, 2026-09-21 |
| `github` | `codeload.github.com` | contained |  | h1+h2, 2026-09-21 |
| `github` | `uploads.github.com` | contained |  | h1+h2, 2026-09-21 |
| `github-objects` | `objects.githubusercontent.com` | open tenancy | `sub-tick` `open-tenancy` | h1+h2, 2026-09-21 |
| `github-objects` | `release-assets.githubusercontent.com` | open tenancy | `sub-tick` `open-tenancy` | h1+h2, 2026-09-21 |
| `github-objects` | `github-releases.githubusercontent.com` | open tenancy | `sub-tick` `open-tenancy` | h1+h2, 2026-09-21 |
| `github-raw` | `raw.githubusercontent.com` | open tenancy | `open-tenancy` | h1+h2, 2026-09-21 |
| `gitlab` | `gitlab.com` | contained |  | h1+h2, 2026-09-21 |
| `gitlab` | `registry.gitlab.com` | contained | `sub-tick` | h1+h2, 2026-09-21 |
| `atlassian` | `id.atlassian.com` | contained |  | h1+h2, 2026-09-21 |
| `atlassian` | `api.atlassian.com` | contained |  | h1+h2, 2026-09-21 |
| `atlassian` | `{site}.atlassian.net` | unaudited | `parameterised` | unaudited |
| `atlassian` | `bitbucket.org` | contained |  | h1+h2, 2026-09-21 |
| `atlassian` | `api.bitbucket.org` | contained |  | h1+h2, 2026-09-21 |
| `azure-devops` | `dev.azure.com` | contained | `parameterised` | h1+h2, 2026-09-21 |
| `azure-devops` | `login.microsoftonline.com` | contained |  | h1 only, no h2 offered, 2026-09-21 |
| `azure-devops` | `vssps.dev.azure.com` | contained |  | h1+h2, 2026-09-21 |
| `azure-devops` | `pkgs.dev.azure.com` | contained |  | h1+h2, 2026-09-21 |
| `aws` | `sts.amazonaws.com` | contained |  | h1 only, no h2 offered, 2026-09-21 |
| `aws` | `sts.{region}.amazonaws.com` | unaudited | `parameterised` | unaudited |
| `aws` | `s3.{region}.amazonaws.com` | open tenancy | `open-tenancy` `parameterised` | unaudited |
| `aws` | `s3.amazonaws.com` | open tenancy | `open-tenancy` | h1 only, no h2 offered, 2026-09-21 |
| `gcp` | `accounts.google.com` | shared |  | h1+h2, 2026-09-21 |
| `gcp` | `oauth2.googleapis.com` | shared |  | h1+h2, 2026-09-21 |
| `gcp` | `www.googleapis.com` | shared |  | h1+h2, 2026-09-21 |
| `gcp` | `storage.googleapis.com` | open tenancy | `sub-tick` `open-tenancy` | h1+h2, 2026-09-21 |
| `npm` | `registry.npmjs.org` | contained |  | h1+h2, 2026-09-21 |
| `npm` | `registry.yarnpkg.com` | contained | `sub-tick` | h1+h2, 2026-09-21 |
| `npm` | `nodejs.org` | contained | `sub-tick` | h1+h2, 2026-09-21 |
| `pypi` | `pypi.org` | shared |  | h1+h2, 2026-09-21 |
| `pypi` | `files.pythonhosted.org` | shared |  | h1+h2, 2026-09-21 |
| `apt-debian` | `deb.debian.org` | shared | `default` | h1+h2, 2026-09-21 |
| `apt-image-extras` | `download.docker.com` | contained | `default` | h1+h2, 2026-09-21 |
| `apt-image-extras` | `cli.github.com` | open tenancy | `default` `sub-tick` `open-tenancy` | h1+h2, 2026-09-21 |
| `apt-ubuntu` | `archive.ubuntu.com` | single origin |  | h1 only, no h2 offered, 2026-09-21 |
| `apt-ubuntu` | `security.ubuntu.com` | single origin |  | h1 only, no h2 offered, 2026-09-21 |
| `apt-ubuntu` | `ports.ubuntu.com` | single origin |  | h1 only, no h2 offered, 2026-09-21 |
| `debian-mirror` | `debian.osuosl.org` | single origin | `no-security` | h1 only, no h2 offered, 2026-09-21 |
| `dotnet` | `packages.microsoft.com` | contained |  | h1+h2, 2026-09-21 |
| `dotnet` | `dot.net` | contained |  | h1+h2, 2026-09-21 |
| `astral` | `astral.sh` | contained |  | h1+h2, 2026-09-21 |
| `azure-cli` | `packages.microsoft.com` | contained |  | h1+h2, 2026-09-21 |
| `go` | `proxy.golang.org` | contained |  | h1+h2, 2026-09-21 |
| `go` | `sum.golang.org` | contained |  | h1+h2, 2026-09-21 |
| `go` | `index.golang.org` | contained |  | h1+h2, 2026-09-21 |
| `rust` | `static.crates.io` | shared |  | h1+h2, 2026-09-21 |
| `rust` | `index.crates.io` | shared |  | h1+h2, 2026-09-21 |
| `rust` | `crates.io` | shared |  | h1+h2, 2026-09-21 |
| `rust` | `sh.rustup.rs` | contained | `sub-tick` | h1+h2, 2026-09-21 |
| `rust` | `static.rust-lang.org` | shared |  | h1+h2, 2026-09-21 |
| `ruby` | `rubygems.org` | shared |  | h1+h2, 2026-09-21 |
| `ruby` | `index.rubygems.org` | shared |  | h1+h2, 2026-09-21 |
| `maven` | `repo1.maven.org` | contained |  | h1+h2, 2026-09-21 |
| `maven` | `plugins.gradle.org` | contained |  | h1 only, no h2 offered, 2026-09-21 |
| `maven` | `services.gradle.org` | contained |  | h1 only, no h2 offered, 2026-09-21 |
| `containers` | `registry-1.docker.io` | contained | `requires-cap` | h1+h2, 2026-09-21 |
| `containers` | `auth.docker.io` | contained | `requires-cap` | h1+h2, 2026-09-21 |
| `containers` | `production.cloudflare.docker.com` | contained | `requires-cap` | h1+h2, 2026-09-21 |
| `containers` | `index.docker.io` | contained | `requires-cap` | h1+h2, 2026-09-21 |
| `containers` | `ghcr.io` | contained | `requires-cap` | h1+h2, 2026-09-21 |
| `containers` | `pkg-containers.githubusercontent.com` | open tenancy | `open-tenancy` `requires-cap` | h1+h2, 2026-09-21 |
| `homebrew` | `formulae.brew.sh` | open tenancy | `open-tenancy` | h1+h2, 2026-09-21 |
| `homebrew` | `ghcr.io` | contained |  | h1+h2, 2026-09-21 |
| `homebrew` | `pkg-containers.githubusercontent.com` | open tenancy | `open-tenancy` | h1+h2, 2026-09-21 |
| `huggingface` | `huggingface.co` | open tenancy | `open-tenancy` | h1+h2, 2026-09-21 |
| `huggingface` | `cas-server.xethub.hf.co` | open tenancy | `open-tenancy` | h1 only, no h2 offered, 2026-09-21 |
| `huggingface` | `transfer.xethub.hf.co` | open tenancy | `open-tenancy` | h1 only, no h2 offered, 2026-09-21 |
| `huggingface` | `us.aws.cdn.hf.co` | open tenancy | `open-tenancy` | h1+h2, 2026-09-21 |
| `playwright` | `cdn.playwright.dev` | single origin |  | h1+h2, 2026-09-21 |
| `playwright` | `playwright.download.prss.microsoft.com` | single origin |  | h1 only, no h2 offered, 2026-09-21 |
| `docs` | `developer.mozilla.org` | shared |  | h1+h2, 2026-09-21 |
| `docs` | `devdocs.io` | contained |  | h1+h2, 2026-09-21 |
| `docs` | `stackoverflow.com` | open tenancy | `open-tenancy` | h1+h2, 2026-09-21 |
| `docs` | `api.stackexchange.com` | contained |  | h1+h2, 2026-09-21 |
| `docs` | `docs.python.org` | shared |  | h1+h2, 2026-09-21 |
| `docs` | `pkg.go.dev` | contained |  | h1+h2, 2026-09-21 |

The measured column's forms: `h1+h2, <date>` means both protocol legs ran. `h1 only, no h2
offered, <date>` means the edge declined HTTP/2, which is a complete result for that date.
`unaudited` means no leg has run, which is true of every parameterised host.
