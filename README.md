# 🗄️ Ansible Role: linstor

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Ansible Galaxy](https://img.shields.io/badge/Ansible%20Galaxy-cedricfarinazzo.linstor-blue)](https://galaxy.ansible.com/cedricfarinazzo/linstor)

> **[LINSTOR](https://linbit.com/linstor/) satellite, controller and client, with mutual TLS from your own certificates, and the cluster's nodes, storage pools and resource groups set through the controller's REST API.**

LINSTOR's satellite port and REST API have no authentication of their own. This role installs the components you pick, builds LINSTOR's Java key and trust stores from PEM files your PKI put on the host, and turns on SSL for the satellites and HTTPS with required client certificates for the API, with the plain listeners off or on loopback. On the controller it then registers the nodes, creates the storage pools and creates or updates the resource groups, DRBD options included.

## 🚀 Quick Start

```yaml
# DRBD 9 and LINBIT's source first (cedricfarinazzo.drbd), then LINSTOR
- hosts: storage
  become: true
  roles:
    - role: cedricfarinazzo.drbd
    - role: cedricfarinazzo.linstor
      vars:
        linstor_controller: "{{ inventory_hostname == 'node-a' }}"
```

The role will:
- ✅ Check every input, then (with `linstor_tls`) that the certificate, its key and the CA are readable, match, chain and are not expired, before any package or LINSTOR file changes
- ✅ Install `linstor-satellite`, `linstor-controller` and `linstor-client` as chosen, by name, from the APT sources already configured; it stops with a clear message when none provides them
- ✅ Build `/etc/linstor/ssl/keystore.jks` (key and certificate chain) and `certificates.jks` (the CA) with a password generated on the host and kept root-only; rebuild them when the certificate, key or CA changes
- ✅ Write `linstor_satellite.toml` (SSL on 3367, TLS 1.3), `linstor.toml` (HTTPS on 3371, client certificates required; plain HTTP on 127.0.0.1, which only redirects to HTTPS) and the `linstor` CLI configuration
- ✅ With `linstor_tls_controller_certs`: build a satellite trust store holding only the controller certificates, so a second node of the same CA cannot take the satellite over
- ✅ Point the controller's connector to satellites at the same stores, SSL only (the plain and debug connectors off)
- ✅ Register the nodes, create the storage pools, create or update the resource groups, DRBD options and properties included; never delete anything

## 📋 Requirements

| Component | Requirement |
|-----------|-------------|
| **Operating System** | Debian, Ubuntu (see below), systemd |
| **Ansible** | ansible-core 2.15+ (CI tests the version pinned in `requirements-dev.txt`) |
| **Collections** | none (`ansible.builtin` only) |
| **Privileges** | Root or sudo access on the target hosts |
| **Packages** | An APT source with LINSTOR: LINBIT's (the [`cedricfarinazzo.drbd`](https://github.com/cedricfarinazzo/ansible-role-drbd) role adds it with a fingerprint-pinned key), a mirror, or Proxmox VE's |
| **Certificates** | With `linstor_tls`: per host a PEM certificate (server and client use), its unencrypted PEM key and the CA certificate, on the host |

### Supported Distributions

Each is tested in CI with Molecule: a combined node over mutual TLS, a rerun for idempotence, a certificate renewal, then `linstor_state: absent`.

| Distribution | Versions | LINSTOR source tested |
|--------------|----------|-----------------------|
| **Debian** | 13 | LINBIT's `proxmox-9` suite, as `cedricfarinazzo.drbd` adds it |
| **Ubuntu** | 24.04, 26.04 | LINBIT's PPA `linbit/linbit-drbd9-stack`, as `cedricfarinazzo.drbd` adds it |

#### Platform notes

- **Debian 12:** not supported. LINBIT's `proxmox-8` suite ships LINSTOR 1.33, whose controller leaves its SSL connector off when it is set as this role sets it: SSL nodes never come online.

#### Why no source of its own

LINSTOR ships in the same LINBIT suites as DRBD 9. A second APT source for the same repository with another `Signed-By` keyring makes APT refuse both ("Conflicting values set for option Signed-By"), and two copies of one trust are two places to rotate. So this role trusts nothing itself: run `cedricfarinazzo.drbd` (or any role that sets up your LINSTOR source) first.

## ⚙️ Configuration

Every input is checked before anything changes: a wrong type or value fails the play.

### Components

```yaml
linstor_state: present          # absent: stop, purge, remove the files the role wrote
linstor_satellite: true
linstor_controller: false       # both true = a combined node
linstor_client: "{{ linstor_controller }}"
linstor_packages_extra: []      # e.g. [drbd-reactor]

# Controller database: "" = LINSTOR's embedded H2 under /var/lib/linstor; or jdbc:... / etcd://...
linstor_controller_db_connection_url: ""
linstor_controller_db_user: ""
linstor_controller_db_password: ""
```

### Mutual TLS

```yaml
linstor_tls: false
linstor_tls_cert: ""            # PEM, server and client use; the same certificate serves satellite, API and CLI
linstor_tls_key: ""             # PEM, no passphrase; stays where you put it
linstor_tls_ca: ""              # PEM, the CA every node and client certificate chains to
linstor_tls_protocol: TLSv1.3
linstor_tls_controller_certs: []   # satellite: PEM certificates of the controller(s) it accepts; [] = the whole CA
linstor_tls_store_password: ""  # "" = generated on the host into /etc/linstor/ssl/store.password (0600)
```

The PEM files are yours: the role reads them and never moves or rewrites them, so other services (DRBD's kernel TLS handshake daemon, for example) can use the same files. Renew a certificate in place and rerun the role: it rebuilds the stores and restarts LINSTOR.

`linstor_tls_controller_certs` closes the satellite's weak spot (see [Security notes](#️-security-notes)): the satellite then trusts exactly the listed certificates (a combined node lists its own), kept in `/etc/linstor/ssl/satellite-trust.jks`, so no other certificate of your CA can connect to it. List the certificate files of the controller(s) on every satellite host (a public certificate, copied by your PKI or by Ansible); renew the controller's certificate, copy it, and rerun the role on the satellites.

### Listeners

```yaml
linstor_satellite_bind_address: "::0"
linstor_satellite_port: "{{ 3367 if linstor_tls else 3366 }}"
linstor_controller_http_listen: "{{ '127.0.0.1' if linstor_tls else '::' }}"
linstor_controller_http_port: 3370
linstor_controller_https_listen: "::"
linstor_controller_https_port: 3371
linstor_controller_plain_connector: "{{ not linstor_tls }}"
```

LINSTOR's `[http] enabled = false` also stops the HTTPS server, so the plain listener cannot be turned off: under TLS it is bound to loopback, where it only answers a redirect to HTTPS.

### Client

```yaml
linstor_client_config: /etc/linstor/linstor-client.conf   # or ~/.config/linstor/linstor-client.conf of a user
linstor_client_controllers: ""   # "" = this host's controller; or linstor+ssl://ctrl1.example.com:3371,...
```

### Cluster objects

Set from the controller (`linstor_cluster`, on by default there) through `linstor_api_url` (`""` = `https://localhost:3371` with the TLS files, or `http://127.0.0.1:3370`). The role adds and updates; an object you remove from a list stays in LINSTOR.

```yaml
linstor_nodes:
  - name: node-a                # the node's host name (uname -n)
    address: 10.0.0.1
    type: combined              # satellite (default), combined, controller, auxiliary
    # encryption: ssl           # ssl under linstor_tls, else plain; port 3367 / 3366
  - name: node-b
    address: 10.0.0.2
linstor_storage_pools:
  - name: pool-vm
    node: node-a
    provider: lvm_thin          # lvm, lvm_thin, zfs, zfs_thin, file, file_thin, diskless
    pool: vg0/thin0             # vg, vg/thinpool, zpool, directory; none for diskless
    properties: {}
linstor_resource_groups:
  - name: rg-vm
    place_count: 2
    storage_pools:
      - pool-vm
    drbd_options:               # set as DrbdOptions/<key>, in DRBD's base units
      PeerDevice/c-max-rate: 71680   # KiB/s: 70M
      Net/tls: "yes"                 # DRBD's kernel TLS, once tlshd runs on every node
    properties: {}
    description: VM disks
linstor_wait_retries: 36        # 5 s apart: API up, nodes with pools online
```

A storage pool's provider and driver pool are fixed at creation: a different value fails the role, asking you to recreate the pool yourself.

## 🎯 Usage Examples

### Three satellites, a controller on the first, client certificates from your PKI

```yaml
linstor_tls: true
linstor_tls_cert: /etc/ssl/linstor/node.crt
linstor_tls_key: /etc/ssl/linstor/node.key
linstor_tls_ca: /etc/ssl/linstor/ca.crt
linstor_controller: "{{ inventory_hostname == 'node-a' }}"
linstor_nodes:
  - {name: node-a, address: 10.0.0.1, type: combined}
  - {name: node-b, address: 10.0.0.2}
  - {name: node-c, address: 10.0.0.3}
```

### Without TLS, on a trusted storage network

```yaml
linstor_controller: true
linstor_nodes:
  - {name: node-a, address: 10.0.0.1, type: combined}
```

### Cluster objects in a later play, once every satellite runs

```yaml
- hosts: storage
  roles:
    - role: cedricfarinazzo.linstor
      vars:
        linstor_cluster: false
- hosts: node-a
  tasks:
    - ansible.builtin.include_role:
        name: cedricfarinazzo.linstor
        tasks_from: cluster.yml
```

## ⚠️ Security notes

- **A satellite trusts what its trust store holds.** By default that is your CA: LINSTOR's satellite port 3367 keeps one controller session, and a TLS peer with any valid certificate of the CA that connects takes it from the real controller (the node stays offline until the satellite restarts). Any node, or anything holding a certificate of the CA, can do it. Set `linstor_tls_controller_certs` on every satellite to pin the controller's certificate, and open 3367 in your firewall to the controller's address only (nftables: `ip saddr <controller> tcp dport 3367 accept`), or bind the satellite to the storage network with `linstor_satellite_bind_address`.
- **Residual risk with the pin:** whoever holds the controller's private key (or can sit between the controller and a satellite at the network level with it) still is the controller; a pin is renewed by copying the new controller certificate to the satellites. The controller side still trusts the whole CA to authenticate satellites and API clients: issue client certificates only to who may administer the cluster, and keep 3371 and 3367 off untrusted networks.
- **Passwords:** the key and trust store password and the database password sit in the TOML files, `root`-owned and readable by the controller's group only (`0640`); the tasks that read or write them are `no_log`, and the templates are kept out of `--diff` output.

## 🔍 Check

```bash
linstor node list                        # every node Online, addresses with (SSL)
linstor storage-pool list
linstor resource-group list
ss -tlnp | grep java                     # 3367, 3371 on every address; 3370 on 127.0.0.1; nothing on 3366
curl -s --cacert ca.crt https://node-a:3371/v1/controller/version   # refused: no client certificate
```

## ↩️ Rollback

`linstor_state: absent` stops and purges the LINSTOR packages (and `linstor_packages_extra`) and removes the role's files: `/etc/linstor/ssl`, the TOML files, the client configuration. The database and satellite state under `/var/lib/linstor` stay unless `linstor_remove_data: true`. Your PEM files are never touched.

## 🧪 Testing

Molecule runs in Docker containers, which share the CI host's kernel: no DRBD resource is ever brought up, LINSTOR itself runs. A test CA made in `prepare` signs throwaway certificates. `default` (every supported distribution) runs check mode on a fresh container, converges a combined node over mutual TLS with a file-backed thin pool and a resource group, checks the files, stores, listeners (3366 closed, 3370 on loopback only), that HTTPS 3371 and the satellite 3367 refuse a client without a certificate or with another CA's, the node online over SSL; reruns for idempotence, then runs a pass under `--diff` (the store password must not appear), a pass without the controller pin (a valid certificate of the CA must then take the satellite from its controller, proving the pin is what stops it), renews the certificate and runs `linstor_state: absent`. The satellite refuses a second node's valid certificate. `cluster` (Debian 13) runs a combined node and a satellite in two containers and checks the same across the network, the other node's valid certificate included. `failure` (Debian 13) runs a missing file, a key of another pair, a certificate of another CA, an expired certificate, a wrong controller certificate (missing, of another CA, expired) and no package source: each must stop before any LINSTOR package or file. `tests/validate.test.sh` feeds good and bad inputs to the role's checks.

```bash
./run-tests.sh debian13
make molecule-test-all
./run-tests.sh -s cluster debian13
./run-tests.sh -s failure debian13
source .venv/bin/activate && yamllint . && ansible-lint && shellcheck run-tests.sh tests/*.sh && tests/validate.test.sh
```

## 🚢 Releases

Once CI passes on `main`, [semantic-release](https://github.com/semantic-release/semantic-release) cuts the version from [Conventional Commits](https://www.conventionalcommits.org/): `fix:` releases a patch, `feat:` a minor, a `!` or `BREAKING CHANGE:` footer a major. A squash merge lands the pull request title (checked in CI). Each release gets a bare semver tag (`1.2.3`) and GitHub release notes; Ansible Galaxy imports the new tag from the repository. [Renovate](https://docs.renovatebot.com/) keeps the tooling and the pinned GitHub Actions up to date.

## 📦 Dependencies

- ✅ **Ansible Core Modules** (built-in)
- ✅ **OS packages** `openssl` (with TLS), the LINSTOR packages (they pull a Java runtime, whose `keytool` builds the stores)

## 👥 Authors & Contributors

**Cédric Farinazzo** ([@cedricfarinazzo](https://github.com/cedricfarinazzo)) - *Author and Maintainer*
