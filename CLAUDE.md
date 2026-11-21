# CLAUDE.md — ansible-role-linstor

Orientation for Claude Code sessions in this repository. `AGENTS.md` is a symlink to this file.

## Purpose

Public Ansible role `cedricfarinazzo.linstor` (Ansible Galaxy): LINSTOR satellite, controller and client, mutual TLS from PEM files the user's PKI puts on the host, the cluster's nodes, storage pools, resource groups and resource definitions through the controller's REST API, and LINBIT's controller HA by drbd-reactor on any number of nodes. Generic by design: no reference to any downstream project, host, user or network in code, defaults, docs or commit messages.

## Layout

- `defaults/main.yml` — every user-facing variable (`linstor_*`), with its generic default.
- `vars/main.yml` — file paths (stores, password, stamp, TOML files), package and service lists, the API and client URLs, the controller's connector properties, node types and providers, the per-item REST bodies (`linstor_node_netif`, `linstor_rg_filter`, `linstor_rg_props`).
- `tasks/main.yml` — `validate.yml` (every input asserted before any change), then for `present`: `certs.yml` (with TLS: the PEM files readable, key matching, not expired, chaining to the CA; then, with `linstor_tls_controller_cert_from`, the controller's certificate read by delegation and copied to `linstor_tls_controller_cert_copy`; then the pinned certificates checked, a copy check mode did not write left out; before any package), `install.yml` (each package has a candidate in the configured sources; a LINSTOR service not yet installed is masked for the boot (`--runtime`), then installs by name), `stores.yml` (password generated once, key and trust stores rebuilt when the PEM files or password change), `config.yml` (TOML files, client configuration, the install-time masks lifted, `ha.yml` (HA mount unit and drbd-reactor promoter on controller-capable nodes, the controller disabled; the satellite's `LS_KEEP_RES` drop-in), services, then, on a node where the controller runs, `connectors.yml` (the controller's connector properties set and the controller restarted when they differ) and `cluster.yml` (nodes, storage pools, resource groups, resource definitions spawned definitions-only then auto-placed; read, then create or update; also run alone by `tasks_from`)); for `absent`: `absent.yml`.
- `templates/` — `linstor_satellite.toml.j2`, `linstor.toml.j2`, `linstor-client.conf.j2`, `var-lib-linstor.mount.j2`, `drbd-reactor-promoter.toml.j2`, `linstor-satellite-dropin.conf.j2`.
- `handlers/main.yml` — systemd reload, restart of the selected LINSTOR services (under HA a `try-restart` of the controller, so a standby never starts one), drbd-reactor reload, satellite restart on its drop-in.
- `meta/main.yml` — Galaxy metadata; `platforms` lists exactly what CI tests.
- `molecule/default/` — one combined node per distribution: check mode on a fresh container, converge over mutual TLS with a file-thin pool and a resource group, verify (packages, root-only files, TOML, stores, listeners, mTLS refusals on 3371 and 3367 including a valid second certificate of the CA, node online over SSL, connectors), idempotence, `side_effect/` (a `--diff` run that must not print the store password, a run without the pin where the second certificate takes the satellite over, certificate renewal, then `absent` and nothing left).
- `molecule/cluster/` — Debian 13, two containers on one network: a combined node and a satellite, certificates signed by a test CA on the controller from CSRs made on each node, the controller's certificate pinned on both satellites (the other node copies it by `linstor_tls_controller_cert_from`, verify checks the copy); verify across the network, the other node's valid certificate refused; check mode and idempotence.
- `molecule/ha/` — Debian 13, three containers (two controller-capable combined nodes, a diskless satellite): converge with one controller (three nodes online over SSL, `place_count: 2` with quorum and the auto-tiebreaker, LINBIT's database group, `linstor_db` defined not placed, pins of both controller-capable nodes, the third node's certificate refused by every satellite, the standby's accepted), idempotence; `side_effect/` turns HA on from the control node (`ha-vars.yml`): check mode, run, rerun with no change, promoter, mount unit, controller disabled everywhere, drbd-reactor running, its promotion attempt failing and no controller left running, `LS_KEEP_RES`, then absent. No DRBD module: promotion, mount and failover are not tested.
- `molecule/plain/` — Debian 13, a combined node without TLS: no `/etc/linstor/ssl`, plain satellite 3366 and REST 3370, SSL ports closed, node online as PLAIN, plain connector on.
- `molecule/failure/` — Debian 13, no LINSTOR source: a missing file, a key of another pair, a certificate of another CA, an expired certificate, a missing, foreign or expired pinned controller certificate, then no package source; `converge/case.yml` records each failure, `verify/` checks it and that nothing of LINSTOR is on the host.
- Satellite pin: `linstor_tls_controller_certs` builds `satellite-trust.jks` (only those certificates) for the satellite's `trusted_certificates`; the CA stays in `certificates.jks` for the controller. Java trusts a certificate in the store as an anchor, so another certificate of the CA chains to nothing the satellite trusts. The store also holds, per certificate, a throwaway self-signed anchor named like its issuer; its key is generated in tmpfs (`/dev/shm`), deleted right after the export, never in the store or on disk: the controller picks its client certificate by the issuer names the server lists, and without it sends none ("Empty client certificate chain"). Renewal: pin old and new together, then drop the old (README); `side_effect/` runs that overlap and `verify/` probes forged certificates under the CA's name.
- Molecule's test-only role (`molecule/*/requirements.yml`): `cedricfarinazzo.drbd`, its `repo.yml` only, for LINBIT's source; installed into the scenario's ephemeral directory by the `shell` dependency.
- `tests/validate.test.sh` — good and bad inputs against `tasks/validate.yml` on localhost.
- `run-tests.sh` / `Makefile` — local Molecule entry points: `run-tests.sh [-s SCENARIO] <distro>`; several distros or `all` run in parallel, one log each in `.molecule-logs/` (git-ignored).
- `requirements.yml` — collections the role needs at runtime: none.
- `requirements-dev.txt` — controller tooling, exact pins.
- `package.json`, `bun.lock`, `.releaserc.json` — semantic-release tooling only.
- `.github/workflows/` — `ci.yml` (lint, Galaxy description length, shellcheck, input tests, the default scenario on every distribution, the cluster, plain, failure and ha scenarios), `pr-title.yml` (Conventional Commit title check), `release.yml` (semantic-release after `ci.yml` passes on `main`).
- `renovate.json` — dependency updates.

## Conventions

- **Conventional Commits** (`conventionalcommits` preset, so a `!` after the type is breaking). `feat:` → minor, `fix:` / `perf:` → patch, `!` or a `BREAKING CHANGE:` footer → major; `docs:` / `ci:` / `chore:` / `test:` / `refactor:` / `build:` release nothing. A squash merge lands the **PR title** (`pr-title.yml` checks it).
- **Breaking = a consumer must act.** Dropping a platform, renaming or removing a variable, changing a default port, listener, protocol or store path, or a default that turns TLS or a component on or off.
- **Tags are bare semver** (`1.2.3`, no `v`, `tagFormat` in `.releaserc.json`). Release notes live in GitHub Releases; no `CHANGELOG.md`, no release commit.
- **No ruleset or branch protection on `main`:** a ruleset blocks semantic-release. Changes still go through a PR with green CI, by discipline.
- **Variables:** every user-facing variable starts with `linstor_`, is defined in `defaults/main.yml`, asserted in `tasks/validate.yml` (with a case in `tests/validate.test.sh`) and documented in `README.md` in the same PR. Internal values start with `linstor_` too (ansible-lint `var-naming[no-role-prefix]`).
- **No package source of its own:** LINSTOR comes from the sources already configured; a second source for LINBIT's repository with another `Signed-By` conflicts in APT.
- **No PKI in the role:** it reads the user's PEM files and never moves, rewrites or copies a private key off the host.
- **Bad certificates stop the role before any package or LINSTOR file**; every input is asserted before any change.
- **A secret never reaches the output:** tasks that read or send the store password are `no_log`; the password reaches shell tasks by environment, never in the command line; the templates holding it are `diff: false` and `no_log` (`side_effect/` greps a `--diff` run for the password).
- **Satellite pin:** `linstor_tls_controller_certs` stops any other certificate of the CA taking a satellite from its controller (default `[]` keeps the CA trust; documented in README Security notes). Every input regex ends in `\Z`, never `$`, which lets a trailing newline through.
- **Cluster objects are added and updated, never deleted.**
- **Under `linstor_controller_ha` the role never enables or starts `linstor-controller`:** drbd-reactor owns it; API work runs only where it is active (`ha` side_effect checks the standby never starts one).
- **Examples never copy a real deployment:** README and Molecule values use `example.com` names, made-up hosts and documentation addresses.
- **GitHub Actions pinned by full commit SHA**, tag in a trailing comment.
- **Exact pins for tooling** (`requirements-dev.txt`, `package.json`, `molecule/*/collections.yml`, `molecule/*/requirements.yml`); ranges only in `requirements.yml`. `renovate.json` is identical in the sibling roles: change them together.
- **License:** MIT.

## Supported platforms

`meta/main.yml` `platforms`, the CI matrix, the `README.md` table, `run-tests.sh --help` and the `Makefile` list the same set. End-of-life releases are dropped (a `feat!:` change).

### Adding a platform — checklist

1. Check a `geerlingguy/docker-<distro>-ansible:latest` image exists.
2. Check a LINBIT source (as `cedricfarinazzo.drbd` adds it) ships `linstor-satellite`, `linstor-controller`, `linstor-client` and `drbd-reactor` for it.
3. Add it to the CI matrix, `meta/main.yml`, `README.md`, `run-tests.sh` usage and the `Makefile`.
4. `./run-tests.sh <distro>` green locally.

## How releases work

1. A PR is squash-merged into `main` with a Conventional Commit title.
2. When `ci.yml` passes on the push to `main`, `release.yml` (`workflow_run`) runs `bunx semantic-release`: tag, GitHub Release with notes, comments on the released PRs.
3. Ansible Galaxy imports each new tag by itself; nothing in CI pushes to Galaxy.

## Commands

- Lint: `source .venv/bin/activate && yamllint . && ansible-lint && shellcheck run-tests.sh tests/*.sh`
- Input tests: `tests/validate.test.sh`
- Molecule: `./run-tests.sh debian13`, `./run-tests.sh -s cluster debian13`, `./run-tests.sh -s plain debian13`, `./run-tests.sh -s failure debian13`, `./run-tests.sh -s ha debian13`, all distros in parallel: `./run-tests.sh all`

## Gotchas

- A host's postinst starts a new LINSTOR service at once: the controller's writes `linstor.toml` with H2 user and password `linstor` (`linstor-config create-db-file`), creates the database with them and serves plain HTTP on `[::]:3370`; the role's `linstor.toml` (no `[db]`, so no user) then fails `Wrong user name or password` at the next start. `install.yml` masks the units for the boot before the install, `config.yml` lifts the mask before `ha.yml` (which cannot disable a masked unit). Docker images' `policy-rc.d` (exit 101) hid it: the scenarios' prepare removes it and records each start's configuration in `/run/molecule-<unit>-starts`.
- `[http] enabled = false` stops LINSTOR's whole REST server, HTTPS included: the plain listener is bound to loopback instead, and with HTTPS on it only answers 302 to HTTPS.
- The controller's connector to satellites is not in `linstor.toml`: it is controller properties (`NetCom/SslConnector/*`), read at start, defaulting to password `linstor`. The role sets them over the API and restarts the controller; until then an SSL node stays OFFLINE ("The ServiceName of the default TCP connector is not valid").
- The satellite asks for a client certificate and drops the connection right after the TLS 1.3 handshake when there is none, or one of another CA: `openssl s_client` shows `CONNECTED`, then `unexpected eof`. A refused probe leaves the controller's session alone.
- A second TLS peer with a valid certificate on a satellite that trusts the CA (an `openssl s_client`) takes it from its controller: the node stays OFFLINE until the satellite restarts. `linstor_tls_controller_certs` pins the controller's certificate; `side_effect/` runs unpinned to prove the takeover is real. A tested peer is accepted when `s_client` does not end in `unexpected eof`.
- `destroy` empties the scenario's ephemeral directory: `test_sequence` runs `dependency` after it, or the test-only role is gone (a developer's `~/.ansible/roles` hides this; CI starts clean).
- DRBD options are stored in DRBD's base units: `c-max-rate` in KiB/s (`70M` = `71680`); LINSTOR rejects `70M` in a property.
- A storage pool's driver pool is `StorDriver/StorPoolName` for every provider (LINSTOR shows `/srv/pool` for a file pool).
- Minimal container images drop `/usr/share/man`: the JRE's postinst fails on its man page alternative (Ubuntu). The scenarios' prepare makes `/usr/share/man/man1`.
- A container has no LVM, ZFS or DRBD module: the scenarios use file-thin pools and never place a resource (`ha` defines `linstor_db` with `place: false`).
- Molecule interpolates `$` in `molecule.yml`, even inside a Jinja regex: `'^(.*)$'` fails with "Invalid placeholder"; avoid `$` there.
- Ansible's `sequence` test is true for a mapping: list inputs are also asserted `is not mapping`.
- Molecule's `galaxy` dependency installs roles into `~/.ansible/roles` and fails on the second run: the scenarios use a `shell` dependency into the ephemeral directory.
- drbd-reactor fails to start in a container (`drbdadm --version` reports no kernel module, `drbdsetup events2` exits): `ha` side_effect puts stubs first on drbd-reactor's PATH only. It then tries to promote at start, fails, and stops any running `linstor-controller`: under HA no controller runs in CI.
- `openssl verify` also fails on an expired certificate: expiry is checked first, so the message names the right cause.

## Self Improvement Loop

Keep `CLAUDE.md` and `README.md` accurate, in the same PR as the change. Update when:

- **A variable is added, renamed or removed:** `defaults/main.yml`, `tasks/validate.yml`, `tests/validate.test.sh` and the `README.md` blocks.
- **A platform is added or dropped:** the checklist above.
- **A file or task file is added, removed or changes role:** Layout above.
- **A tool or Action is added:** pinned in its own file; never copy versions into prose.
- **A trap costs a debugging round:** one Gotchas line: the symptom, the cause, the fix.
- **A convention is established:** Conventions above.

New fact replaces the old clause; never append a changelog. Prefer small targeted edits over rewrites.
