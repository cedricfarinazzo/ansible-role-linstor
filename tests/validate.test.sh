#!/usr/bin/env bash
# The role's input checks: each bad input fails before anything changes, the good ones pass.
# Runs tasks/validate.yml on localhost; needs ansible-playbook on PATH, no host.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/roles"
ln -s "$REPO" "$WORK/roles/linstor"
cat > "$WORK/play.yml" <<'PLAY'
- name: Validate linstor inputs
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Validate
      ansible.builtin.include_role:
        name: linstor
        tasks_from: validate.yml
PLAY
fails=0
run() { ANSIBLE_ROLES_PATH=$WORK/roles ansible-playbook -i localhost, -c local -e "$1" "$WORK/play.yml" > "$WORK/out" 2>&1; }
good() { if run "$2"; then echo "ok   accepted: $1"; else echo "FAIL rejected a good input: $1" >&2; tail -5 "$WORK/out" >&2; fails=$((fails + 1)); fi; }
# Rejected by an assert, never by a templating crash: that would pass for the wrong reason.
bad() {
  if run "$2"; then echo "FAIL accepted: $1" >&2; fails=$((fails + 1))
  elif grep -qE '"assertion"|Action failed: ' "$WORK/out"; then echo "ok   rejected: $1"
  else echo "FAIL failed without an assertion: $1" >&2; grep -m3 -E 'ERROR|fatal' "$WORK/out" >&2; fails=$((fails + 1)); fi
}

T='"linstor_tls": true, "linstor_tls_cert": "/etc/ssl/node.crt", "linstor_tls_key": "/etc/ssl/node.key", "linstor_tls_ca": "/etc/ssl/ca.crt"'
good "defaults (a plain satellite)" '{}'
good "state absent, nothing selected" '{"linstor_state": "absent", "linstor_satellite": false}'
good "a pinned controller certificate" "{$T, \"linstor_tls_controller_certs\": [\"/etc/ssl/ctrl.crt\"]}"
good "a combined node over TLS" "{$T, \"linstor_controller\": true}"
good "a client only" '{"linstor_satellite": false, "linstor_client": true, "linstor_client_controllers": "linstor+ssl://ctrl.example.com:3371,linstor+ssl://ctrl2.example.com"}'
good "every option set" "{$T, \"linstor_controller\": true, \"linstor_packages_extra\": [\"drbd-reactor\"], \"linstor_controller_db_connection_url\": \"jdbc:postgresql://db.example.com/linstor\", \"linstor_controller_db_user\": \"linstor\", \"linstor_controller_db_password\": \"s3cret pass\", \"linstor_tls_protocol\": \"TLSv1.2\", \"linstor_tls_store_password\": \"abcdefghijkl\", \"linstor_satellite_bind_address\": \"10.0.0.1\", \"linstor_controller_http_listen\": \"::1\", \"linstor_api_url\": \"https://10.0.0.1:3371\", \"linstor_wait_retries\": 10, \"linstor_remove_data\": true}"
good "an etcd database" '{"linstor_controller": true, "linstor_controller_db_connection_url": "etcd://etcd1.example.com:2379"}'
good "a cluster" '{"linstor_controller": true, "linstor_nodes": [{"name": "node-a", "address": "10.0.0.1", "type": "combined"}, {"name": "node-b", "address": "10.0.0.2", "encryption": "plain", "port": 3366}], "linstor_storage_pools": [{"name": "pool", "node": "node-a", "provider": "lvm_thin", "pool": "vg/thin"}, {"name": "pool", "node": "node-b", "provider": "zfs", "pool": "tank", "properties": {"PrefNic": "data"}}, {"name": "nodisk", "node": "node-b", "provider": "diskless"}], "linstor_resource_groups": [{"name": "rg", "place_count": 2, "storage_pools": ["pool"], "drbd_options": {"PeerDevice/c-max-rate": 71680, "Net/tls": "yes"}, "properties": {"Aux/team": "a"}, "description": "VM disks"}]}'
bad "a database password with a newline" '{"linstor_controller_db_password": "abc\ndef"}'
bad "a database password with a backslash" '{"linstor_controller_db_password": "abc\\ndef"}'
bad "a database user with a trailing newline" '{"linstor_controller_db_user": "linstor\n"}'
bad "a database URL with a trailing newline" '{"linstor_controller_db_connection_url": "jdbc:postgresql://db/x\n"}'
bad "a store password with a trailing newline" '{"linstor_tls_store_password": "abcdefghijkl\n"}'
bad "a listen address with a trailing newline" '{"linstor_controller_http_listen": "127.0.0.1\n"}'
bad "a port with a trailing newline" '{"linstor_satellite_port": "3367\n"}'
bad "a client config path with a trailing newline" '{"linstor_client_config": "/etc/linstor/c.conf\n"}'
bad "a node name with a trailing newline" '{"linstor_nodes": [{"name": "a\n", "address": "10.0.0.1"}]}'
bad "a node address with a trailing newline" '{"linstor_nodes": [{"name": "a", "address": "10.0.0.1\n"}]}'
bad "a pool with a trailing newline" '{"linstor_storage_pools": [{"name": "p", "node": "a", "provider": "lvm", "pool": "vg\n"}]}'
bad "a group name with a trailing newline" '{"linstor_resource_groups": [{"name": "rg\n"}]}'
bad "a TLS file path with a trailing newline" "{$T, \"linstor_tls_cert\": \"/etc/ssl/node.crt\\n\"}"
bad "controller certificates as a string" "{$T, \"linstor_tls_controller_certs\": \"/etc/ssl/c.crt\"}"
bad "controller certificates as a mapping" "{$T, \"linstor_tls_controller_certs\": {\"a\": \"/etc/ssl/c.crt\"}}"
bad "a relative controller certificate" "{$T, \"linstor_tls_controller_certs\": [\"c.crt\"]}"
bad "a controller certificate with a trailing newline" "{$T, \"linstor_tls_controller_certs\": [\"/etc/ssl/c.crt\\n\"]}"
bad "controller certificates without TLS" '{"linstor_tls_controller_certs": ["/etc/ssl/c.crt"]}'
bad "an unknown state" '{"linstor_state": "latest"}'
bad "satellite as a string" '{"linstor_satellite": "yes"}'
bad "nothing selected" '{"linstor_satellite": false}'
bad "a package name with a space" '{"linstor_packages_extra": ["drbd reactor"]}'
bad "a database URL of another kind" '{"linstor_controller_db_connection_url": "mysql://db"}'
bad "a database user with a quote" '{"linstor_controller_db_user": "a\"b"}'
bad "tls as a string" '{"linstor_tls": "true"}'
bad "tls without its files" '{"linstor_tls": true}'
bad "a relative certificate" "{$T, \"linstor_tls_cert\": \"node.crt\"}"
bad "an old TLS protocol" '{"linstor_tls_protocol": "TLSv1.1"}'
bad "a short store password" '{"linstor_tls_store_password": "short"}'
bad "a store password with a quote" '{"linstor_tls_store_password": "abcdefghijkl\""}'
bad "a listen address that is a name" '{"linstor_controller_http_listen": "localhost"}'
bad "a port out of range" '{"linstor_satellite_port": 70000}'
bad "HTTP and HTTPS on one port" '{"linstor_controller_https_port": 3370}'
bad "plain connector as a string" '{"linstor_controller_plain_connector": "no"}'
bad "a relative client config" '{"linstor_client_config": "linstor-client.conf"}'
bad "a client URL of another scheme" '{"linstor_client_controllers": "https://ctrl:3371"}'
bad "a cluster on a satellite" '{"linstor_cluster": true}'
bad "an API URL with a path" '{"linstor_controller": true, "linstor_api_url": "https://ctrl:3371/v1"}'
bad "zero retries" '{"linstor_wait_retries": 0}'
bad "remove data as a string" '{"linstor_remove_data": "yes"}'
bad "nodes as a mapping" '{"linstor_nodes": {"name": "a"}}'
bad "a node with an unknown key" '{"linstor_nodes": [{"name": "a", "address": "10.0.0.1", "role": "x"}]}'
bad "a node without an address" '{"linstor_nodes": [{"name": "a"}]}'
bad "a node address that is a name" '{"linstor_nodes": [{"name": "a", "address": "node-a.example.com"}]}'
bad "a node of an unknown type" '{"linstor_nodes": [{"name": "a", "address": "10.0.0.1", "type": "master"}]}'
bad "a node name twice" '{"linstor_nodes": [{"name": "a", "address": "10.0.0.1"}, {"name": "a", "address": "10.0.0.2"}]}'
bad "a plain node without the plain connector" "{$T, \"linstor_nodes\": [{\"name\": \"a\", \"address\": \"10.0.0.1\", \"encryption\": \"plain\"}]}"
bad "a pool of an unknown provider" '{"linstor_storage_pools": [{"name": "p", "node": "a", "provider": "btrfs", "pool": "x"}]}'
bad "a pool without its driver pool" '{"linstor_storage_pools": [{"name": "p", "node": "a", "provider": "lvm_thin"}]}'
bad "a diskless pool with a driver pool" '{"linstor_storage_pools": [{"name": "p", "node": "a", "provider": "diskless", "pool": "x"}]}'
bad "a pool with a space" '{"linstor_storage_pools": [{"name": "p", "node": "a", "provider": "lvm", "pool": "vg 1"}]}'
bad "a pool twice on one node" '{"linstor_storage_pools": [{"name": "p", "node": "a", "provider": "lvm", "pool": "vg"}, {"name": "p", "node": "a", "provider": "lvm", "pool": "vg2"}]}'
bad "a group with place count 0" '{"linstor_resource_groups": [{"name": "rg", "place_count": 0}]}'
bad "a group with pools as a string" '{"linstor_resource_groups": [{"name": "rg", "storage_pools": "pool"}]}'
bad "a DRBD option with its prefix" '{"linstor_resource_groups": [{"name": "rg", "drbd_options": {"DrbdOptions/Net/tls": "yes"}}]}'
bad "DRBD options as a list" '{"linstor_resource_groups": [{"name": "rg", "drbd_options": ["Net/tls"]}]}'
bad "a group with an unknown key" '{"linstor_resource_groups": [{"name": "rg", "replicas": 2}]}'

if [[ $fails -gt 0 ]]; then echo "$fails failed" >&2; exit 1; fi
echo "all passed"
