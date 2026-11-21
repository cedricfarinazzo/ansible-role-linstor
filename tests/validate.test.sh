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
# ctrl.example.com: an inventory host a satellite may copy the controller's certificate from; never contacted
run() { ANSIBLE_ROLES_PATH=$WORK/roles ansible-playbook -i localhost,ctrl.example.com, -c local -e "$1" "$WORK/play.yml" > "$WORK/out" 2>&1; }
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
C='"linstor_tls_controller_certs": ["/etc/ssl/ctrl.crt"]'
good "the controller's certificate copied from another host" "{$T, $C, \"linstor_tls_controller_cert_from\": \"ctrl.example.com\", \"linstor_tls_controller_cert_copy\": \"/etc/ssl/ctrl.crt\"}"
good "the host named copies nothing: its own pins need not list the copy" "{$T, \"linstor_tls_controller_certs\": [\"/etc/ssl/node.crt\"], \"linstor_tls_controller_cert_from\": \"localhost\", \"linstor_tls_controller_cert_copy\": \"/etc/ssl/ctrl.crt\"}"
bad "a copy from a host not in the inventory" "{$T, $C, \"linstor_tls_controller_cert_from\": \"other.example.com\", \"linstor_tls_controller_cert_copy\": \"/etc/ssl/ctrl.crt\"}"
bad "a copy not in the pinned certificates" "{$T, $C, \"linstor_tls_controller_cert_from\": \"ctrl.example.com\", \"linstor_tls_controller_cert_copy\": \"/etc/ssl/other.crt\"}"
bad "a copy host without a copy path" "{$T, $C, \"linstor_tls_controller_cert_from\": \"ctrl.example.com\"}"
bad "a copy path without a host" "{$T, $C, \"linstor_tls_controller_cert_copy\": \"/etc/ssl/ctrl.crt\"}"
bad "a copy host as a list" "{$T, $C, \"linstor_tls_controller_cert_from\": [\"ctrl.example.com\"], \"linstor_tls_controller_cert_copy\": \"/etc/ssl/ctrl.crt\"}"
bad "a relative copy path" "{$T, \"linstor_tls_controller_certs\": [\"ctrl.crt\"], \"linstor_tls_controller_cert_from\": \"localhost\", \"linstor_tls_controller_cert_copy\": \"ctrl.crt\"}"
bad "a copy path ending in a newline" "{$T, $C, \"linstor_tls_controller_cert_from\": \"localhost\", \"linstor_tls_controller_cert_copy\": \"/etc/ssl/ctrl.crt\\n\"}"
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
# Embedded (not only trailing) newline and carriage return in every free-text input
bad "a database password with an embedded CR" '{"linstor_controller_db_password": "abc\rdef"}'
bad "a database user with an embedded newline" '{"linstor_controller_db_user": "lin\nstor"}'
bad "a database URL with an embedded newline" '{"linstor_controller_db_connection_url": "jdbc:postgresql://db/x\ny"}'
bad "a database URL with an embedded CR" '{"linstor_controller_db_connection_url": "jdbc:postgresql://db/x\ry"}'
bad "a store password with an embedded newline" '{"linstor_tls_store_password": "abcdef\nghijkl"}'
bad "a bind address with an embedded CR" '{"linstor_satellite_bind_address": "10.0.\r0.1"}'
bad "a client config path with an embedded newline" '{"linstor_client_config": "/etc/linstor\n/c.conf"}'
bad "client controllers with an embedded newline" '{"linstor_client": true, "linstor_client_controllers": "linstor://a\n,linstor://b"}'
bad "an API URL with an embedded CR" '{"linstor_api_url": "https://10.0.0.1\r:3371"}'
bad "an extra package with an embedded newline" '{"linstor_packages_extra": ["drbd\nreactor"]}'
bad "a TLS file path with an embedded CR" "{$T, \"linstor_tls_key\": \"/etc/ssl\\r/node.key\"}"
bad "a controller certificate with an embedded newline" "{$T, \"linstor_tls_controller_certs\": [\"/etc/ssl\\n/c.crt\"]}"
bad "a node name with an embedded newline" '{"linstor_nodes": [{"name": "a\nb", "address": "10.0.0.1"}]}'
bad "a node address with an embedded CR" '{"linstor_nodes": [{"name": "a", "address": "10.0\r.0.1"}]}'
bad "a pool name with an embedded newline" '{"linstor_storage_pools": [{"name": "p\nq", "node": "a", "provider": "lvm", "pool": "vg"}]}'
bad "a driver pool with an embedded CR" '{"linstor_storage_pools": [{"name": "p", "node": "a", "provider": "lvm", "pool": "vg\r/thin"}]}'
bad "a pool property key with an embedded newline" '{"linstor_storage_pools": [{"name": "p", "node": "a", "provider": "lvm", "pool": "vg", "properties": {"Pref\nNic": "x"}}]}'
bad "a pool property value with an embedded newline" '{"linstor_storage_pools": [{"name": "p", "node": "a", "provider": "lvm", "pool": "vg", "properties": {"PrefNic": "data\nAux/x"}}]}'
bad "a pool property value with an embedded CR" '{"linstor_storage_pools": [{"name": "p", "node": "a", "provider": "lvm", "pool": "vg", "properties": {"PrefNic": "data\rx"}}]}'
bad "a group pool list item with an embedded newline" '{"linstor_resource_groups": [{"name": "rg", "storage_pools": ["pool\nother"]}]}'
bad "a DRBD option key with an embedded newline" '{"linstor_resource_groups": [{"name": "rg", "drbd_options": {"Net/\ntls": "yes"}}]}'
bad "a DRBD option value with an embedded newline" '{"linstor_resource_groups": [{"name": "rg", "drbd_options": {"Net/tls": "no\nNet/verify-alg=x"}}]}'
bad "a DRBD option value with an embedded CR" '{"linstor_resource_groups": [{"name": "rg", "drbd_options": {"Net/tls": "no\ryes"}}]}'
bad "a group property value with an embedded newline" '{"linstor_resource_groups": [{"name": "rg", "properties": {"Aux/team": "a\nb"}}]}'
bad "a group description with an embedded newline" '{"linstor_resource_groups": [{"name": "rg", "description": "VM\ndisks"}]}'
# Trailing newline and other control characters in free-text values (\Z, not $; [^\x00-\x1f\x7f])
bad "a database password with a trailing newline" '{"linstor_controller_db_password": "abc\n"}'
bad "a database password with a tab" '{"linstor_controller_db_password": "ab\tc"}'
bad "a database password with a DEL character" '{"linstor_controller_db_password": "ab\u007fc"}'
bad "a database password with a control character" '{"linstor_controller_db_password": "ab\u0001c"}'
bad "an extra package with a trailing newline" '{"linstor_packages_extra": ["drbd-reactor\n"]}'
bad "an API URL with a trailing newline" '{"linstor_api_url": "https://10.0.0.1:3371\n"}'
bad "client controllers with a trailing newline" '{"linstor_client": true, "linstor_client_controllers": "linstor://a\n"}'
bad "a pool property value with a trailing newline" '{"linstor_storage_pools": [{"name": "p", "node": "a", "provider": "lvm", "pool": "vg", "properties": {"PrefNic": "data\n"}}]}'
bad "a pool property value with a tab" '{"linstor_storage_pools": [{"name": "p", "node": "a", "provider": "lvm", "pool": "vg", "properties": {"PrefNic": "da\tta"}}]}'
bad "a pool property key with a trailing newline" '{"linstor_storage_pools": [{"name": "p", "node": "a", "provider": "lvm", "pool": "vg", "properties": {"PrefNic\n": "x"}}]}'
bad "a group pool list item with a trailing newline" '{"linstor_resource_groups": [{"name": "rg", "storage_pools": ["pool\n"]}]}'
bad "a DRBD option key with a trailing newline" '{"linstor_resource_groups": [{"name": "rg", "drbd_options": {"Net/tls\n": "yes"}}]}'
bad "a DRBD option value with a trailing newline" '{"linstor_resource_groups": [{"name": "rg", "drbd_options": {"Net/tls": "no\n"}}]}'
bad "a group property value with a trailing newline" '{"linstor_resource_groups": [{"name": "rg", "properties": {"Aux/team": "a\n"}}]}'
bad "a group description with a trailing newline" '{"linstor_resource_groups": [{"name": "rg", "description": "VM disks\n"}]}'
bad "a group description with a DEL character" '{"linstor_resource_groups": [{"name": "rg", "description": "VM\u007fdisks"}]}'
bad "a group description with a tab" '{"linstor_resource_groups": [{"name": "rg", "description": "VM\tdisks"}]}'
bad "a group description with a control character" '{"linstor_resource_groups": [{"name": "rg", "description": "VM\u0001disks"}]}'
good "a non-ASCII description" '{"linstor_resource_groups": [{"name": "rg", "description": "disques VM é"}]}'
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

# Controller HA, N nodes, resource definitions
HA="{$T, \"linstor_controller_ha\": true, \"linstor_tls_store_password\": \"abcdefghijkl\", \"linstor_controller\": true, \"linstor_client_controllers\": \"linstor+ssl://10.0.0.1:3371,linstor+ssl://10.0.0.2:3371\"}"
good "an HA controller-capable node" "$HA"
good "an HA tiebreaker satellite" '{"linstor_controller_ha": true}'
good "HA with every option" "{$T, \"linstor_controller_ha\": true, \"linstor_tls_store_password\": \"abcdefghijkl\", \"linstor_controller\": true, \"linstor_client_controllers\": \"linstor+ssl://10.0.0.1:3371,linstor+ssl://10.0.0.2:3371\", \"linstor_controller_ha_resource\": \"ctrl_db\", \"linstor_controller_ha_fstype\": \"xfs\", \"linstor_controller_ha_mount_options\": \"noatime,nodev\", \"linstor_controller_ha_on_stop_failure\": \"echo b > /proc/sysrq-trigger\", \"linstor_controller_ha_stop_services_on_exit\": false, \"linstor_satellite_keep_resources\": [\"ctrl_db\", \"other\"]}"
good "a group placing diskless on the remaining nodes" '{"linstor_resource_groups": [{"name": "db", "place_count": 2, "diskless_on_remaining": true, "drbd_options": {"Resource/quorum": "majority", "auto-add-quorum-tiebreaker": "true"}}]}'
good "a resource definition" '{"linstor_resource_definitions": [{"name": "linstor_db", "resource_group": "db", "size_mib": 200, "place": false, "drbd_options": {"Resource/auto-promote": "no"}, "properties": {"Aux/x": "y"}}]}'
bad "HA as a string" '{"linstor_controller_ha": "yes"}'
bad "an HA controller with an external database" "{$T, \"linstor_controller_ha\": true, \"linstor_tls_store_password\": \"abcdefghijkl\", \"linstor_controller\": true, \"linstor_client_controllers\": \"linstor+ssl://10.0.0.1:3371,linstor+ssl://10.0.0.2:3371\", \"linstor_controller_db_connection_url\": \"jdbc:postgresql://db/x\"}"
bad "an HA TLS controller with a generated store password" "{$T, \"linstor_controller_ha\": true, \"linstor_controller\": true, \"linstor_client_controllers\": \"linstor+ssl://10.0.0.1:3371,linstor+ssl://10.0.0.2:3371\"}"
bad "an HA client without the controller list" "{$T, \"linstor_controller_ha\": true, \"linstor_tls_store_password\": \"abcdefghijkl\", \"linstor_controller\": true}"
bad "an HA resource with a trailing newline" '{"linstor_controller_ha_resource": "linstor_db\n"}'
bad "an HA resource with an embedded newline" '{"linstor_controller_ha_resource": "linstor\n_db"}'
bad "an HA resource with a slash" '{"linstor_controller_ha_resource": "../db"}'
bad "an unknown HA filesystem" '{"linstor_controller_ha_fstype": "btrfs"}'
bad "HA mount options with a trailing newline" '{"linstor_controller_ha_mount_options": "defaults\n"}'
bad "HA mount options with an embedded CR" '{"linstor_controller_ha_mount_options": "noatime\rWhat=/dev/sda"}'
bad "an on-stop-failure with a trailing newline" '{"linstor_controller_ha_on_stop_failure": "reboot\n"}'
bad "an on-stop-failure with an embedded newline" '{"linstor_controller_ha_on_stop_failure": "reboot\nstart = []"}'
bad "an on-stop-failure with a quote" '{"linstor_controller_ha_on_stop_failure": "echo \"b\""}'
bad "stop-services-on-exit as a string" '{"linstor_controller_ha_stop_services_on_exit": "yes"}'
bad "keep resources as a string" '{"linstor_satellite_keep_resources": "linstor_db"}'
bad "a kept resource with a trailing newline" '{"linstor_satellite_keep_resources": ["linstor_db\n"]}'
bad "a kept resource with an embedded newline" '{"linstor_satellite_keep_resources": ["a\nLS_X=b"]}'
bad "diskless on remaining as a string" '{"linstor_resource_groups": [{"name": "rg", "diskless_on_remaining": "yes"}]}'
bad "resource definitions as a mapping" '{"linstor_resource_definitions": {"name": "r"}}'
bad "a resource definition without a group" '{"linstor_resource_definitions": [{"name": "r", "size_mib": 1}]}'
bad "a resource definition without a size" '{"linstor_resource_definitions": [{"name": "r", "resource_group": "g"}]}'
bad "a resource definition of size 0" '{"linstor_resource_definitions": [{"name": "r", "resource_group": "g", "size_mib": 0}]}'
bad "a resource definition with a size in units" '{"linstor_resource_definitions": [{"name": "r", "resource_group": "g", "size_mib": "200M"}]}'
bad "a resource definition name with a trailing newline" '{"linstor_resource_definitions": [{"name": "r\n", "resource_group": "g", "size_mib": 1}]}'
bad "a resource definition group with an embedded newline" '{"linstor_resource_definitions": [{"name": "r", "resource_group": "g\nh", "size_mib": 1}]}'
bad "a resource definition place as a string" '{"linstor_resource_definitions": [{"name": "r", "resource_group": "g", "size_mib": 1, "place": "no"}]}'
bad "a resource definition DRBD option with its prefix" '{"linstor_resource_definitions": [{"name": "r", "resource_group": "g", "size_mib": 1, "drbd_options": {"DrbdOptions/Net/tls": "yes"}}]}'
bad "a resource definition DRBD option value with an embedded newline" '{"linstor_resource_definitions": [{"name": "r", "resource_group": "g", "size_mib": 1, "drbd_options": {"Resource/quorum": "majority\nx"}}]}'
bad "a resource definition property key with a trailing newline" '{"linstor_resource_definitions": [{"name": "r", "resource_group": "g", "size_mib": 1, "properties": {"Aux/x\n": "y"}}]}'
bad "a resource definition twice" '{"linstor_resource_definitions": [{"name": "r", "resource_group": "g", "size_mib": 1}, {"name": "r", "resource_group": "g", "size_mib": 2}]}'
bad "a resource definition with an unknown key" '{"linstor_resource_definitions": [{"name": "r", "resource_group": "g", "size_mib": 1, "replicas": 3}]}'

J='-Xmx768m -XX:+UseSerialGC -Xlog:gc*:file=/var/log/linstor-controller/gc.log:time,uptime:filecount=3,filesize=5M'
good "JVM options and environment of both services" "{\"linstor_controller\": true, \"linstor_controller_java_opts\": \"$J\", \"linstor_controller_environment\": {\"MALLOC_ARENA_MAX\": 2}, \"linstor_satellite_java_opts\": \"-Xmx384m\", \"linstor_satellite_environment\": {\"MALLOC_ARENA_MAX\": \"2\", \"TZ\": \"UTC\"}}"
bad "JVM options with a newline" '{"linstor_controller_java_opts": "-Xmx1g\nExecStart=/bin/false"}'
bad "JVM options with a trailing newline" '{"linstor_satellite_java_opts": "-Xmx1g\n"}'
bad "JVM options with a quote" '{"linstor_controller_java_opts": "-Xmx1g\" -Dx=\"y"}'
bad "JVM options with a single quote" "{\"linstor_satellite_java_opts\": \"-Dx='a b'\"}"
bad "JVM options with a backslash" '{"linstor_controller_java_opts": "-Dx=a\\\\b"}'
bad "JVM options with a systemd specifier" '{"linstor_satellite_java_opts": "-Dhost=%H"}'
bad "JVM options as a list" '{"linstor_controller_java_opts": ["-Xmx1g"]}'
bad "an environment as a list" '{"linstor_satellite_environment": ["MALLOC_ARENA_MAX=2"]}'
bad "an environment name with a space" '{"linstor_controller_environment": {"MALLOC ARENA": "2"}}'
bad "an environment name with a trailing newline" '{"linstor_satellite_environment": {"MALLOC_ARENA_MAX\n": "2"}}'
bad "an environment value with a newline" '{"linstor_controller_environment": {"MALLOC_ARENA_MAX": "2\nExecStart=/bin/false"}}'
bad "an environment value as a list" '{"linstor_satellite_environment": {"X": ["a"]}}'
bad "JAVA_OPTS in an environment" '{"linstor_controller_environment": {"JAVA_OPTS": "-Xmx1g"}}'
bad "LS_KEEP_RES in the satellite environment" '{"linstor_satellite_environment": {"LS_KEEP_RES": "r"}}'
good "a restart policy for both services" '{"linstor_controller": true, "linstor_controller_restart": "on-failure", "linstor_satellite_restart": "always", "linstor_restart_sec": 30}'
good "a restart policy alone, no JVM option" '{"linstor_satellite_restart": "on-abnormal"}'
bad "an unknown restart policy" '{"linstor_satellite_restart": "sometimes"}'
bad "a restart policy with a trailing newline" '{"linstor_controller_restart": "on-failure\n"}'
bad "a restart policy with an embedded newline" '{"linstor_satellite_restart": "on-failure\nExecStart=/bin/false"}'
bad "a restart policy as a boolean" '{"linstor_controller_restart": true}'
bad "a restart delay of 0" '{"linstor_restart_sec": 0}'
bad "a restart delay with a unit" '{"linstor_restart_sec": "10s"}'
bad "a restart delay with a trailing newline" '{"linstor_restart_sec": "10\n"}'

if [[ $fails -gt 0 ]]; then echo "$fails failed" >&2; exit 1; fi
echo "all passed"
