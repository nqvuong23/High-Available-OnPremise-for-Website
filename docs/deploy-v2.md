# deploy-v2 — manual build of the full stack

> Manual installation guide, run by hand once before writing any Ansible role.
> Continues `deploy-v1.md`, which already covers chrony, bind9 and the NFS **server**.
> Goal: a complete working system — client reaches the site through the VIP, orders
> land in MySQL, uploads are shared between both web nodes — **before** any chaos
> scenario runs. Every command is run as root or under `sudo`.
> `mon01` is out of scope here; monitoring is M8 and starts after M7.

## Starting point assumed

- 10 VMs up, static IPs, routes and `ip_forward` on `fw01` done, every node pings every node.
- Already installed by hand: chrony + bind9 on `fw01`, keepalived + haproxy on the LBs,
  nginx on the web nodes, a MySQL server package on the DB nodes.

## Order of work

Bottom-up, because each layer needs the one below it. The per-machine sections below
are written to be read in this order, not top to bottom.

| Step | Node | Why it comes here |
|---|---|---|
| 1 | `fw01` | nothing crosses a zone until the forward policy is right |
| 2 | `nfs01` | app zone storage, independent of everything else |
| 3 | `db01`, `db02` | the write path has to exist before the LB can health check it |
| 4 | `lb01`, `lb02` | WordPress reaches MySQL only through `VIP:3306` |
| 5 | `web01`, `web02` | needs the VIP for the DB and NFS for uploads |
| 6 | `mgmt01` | trust the CA, then run the acceptance tests over the routed path |

Snapshot before starting: `vagrant snapshot save pre-deploy-v2`.

## Secrets in this document

Every `<...>` placeholder is a secret that will move to Ansible Vault later. Pick the
values once, keep them in a scratch file outside the repo, and never commit them.

| Placeholder | Used by |
|---|---|
| `<mysql-root-pass>` | both DB nodes |
| `<repl-pass>` | replication user |
| `<wp-pass>` | WordPress application user |
| `<chk-pass>` | `mysqlchk` user |
| `<ops-pass>` | operator user used from `mgmt01` |
| `<vrrp-pass>` | Keepalived, **8 characters or fewer** |
| `<stats-pass>` | HAProxy stats page |
| `<wp-admin-pass>` | WordPress admin account |

---

# Install the missing tools

## Step 0 — check the versions you already have

The project pins three packages to an upstream repository, not to what Ubuntu 24.04
ships. Config syntax differs between them, so check before configuring anything.

```bash
haproxy -v | head -1        # want 3.3.x, Ubuntu ships 2.8
nginx -v                    # want 1.30.5, Ubuntu ships 1.24.0
mysqld --version            # want 8.4.x, Ubuntu ships 8.0
keepalived -v | head -1     # 2.2.8 from Ubuntu apt is correct
```

If a version is the Ubuntu one, replace it with the steps below. This is not cosmetic:
MySQL 8.0 uses `rpl_semi_sync_master_*` variables and `CHANGE MASTER TO`, both of which
are **removed** in 8.4, so a config written here will not load on 8.0.

## HAProxy 3.3 on lb01 and lb02

```bash
apt-get install -y --no-install-recommends software-properties-common
add-apt-repository -y ppa:vbernat/haproxy-3.3
apt-get update
apt-get install -y haproxy socat
haproxy -v | head -1
```

`socat` is for the Runtime API, used to enable and disable servers without a reload.

## Nginx 1.30.5 on web01 and web02

```bash
curl -fsSL https://nginx.org/keys/nginx_signing.key \
  | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg

cat > /etc/apt/sources.list.d/nginx.list <<'EOF'
deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/ubuntu noble nginx
EOF

apt-get update
apt-get remove -y nginx nginx-common nginx-core
apt-get install -y nginx
nginx -v
```

The upstream package runs as user `nginx` and uses `/etc/nginx/conf.d/`, not
`sites-available/`. Both differences are handled in the web01 section.

## MySQL 8.4 LTS on db01 and db02

```bash
curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 \
  | gpg --dearmor -o /usr/share/keyrings/mysql.gpg

cat > /etc/apt/sources.list.d/mysql.list <<'EOF'
deb [signed-by=/usr/share/keyrings/mysql.gpg] http://repo.mysql.com/apt/ubuntu noble mysql-8.4-lts
EOF

apt-get update
```

If Ubuntu's 8.0 is installed and holds no data yet, remove it first. Check the datadir
is empty of real schemas before running this; it destroys everything in it.

```bash
systemctl stop mysql
apt-get purge -y mysql-server mysql-server-8.0 mysql-client-core-8.0
rm -rf /var/lib/mysql /var/log/mysql
```

Then install 8.4 and pin Ubuntu's package out of the way:

```bash
apt-get install -y mysql-community-server mysql-community-client python3-pymysql

cat > /etc/apt/preferences.d/mysql <<'EOF'
Package: mysql-server mysql-server-8.0 mysql-client
Pin: release o=Ubuntu
Pin-Priority: -1
EOF

mysqld --version
```

The installer asks for a root password. Use `<mysql-root-pass>`, and keep
`caching_sha2_password` as the default authentication plugin.

## nfs-kernel-server on nfs01

```bash
apt-get install -y nfs-kernel-server
```

Configuration is in `deploy-v1.md` sections 23 to 28.

## PHP-FPM and client tools on web01 and web02

```bash
apt-get install -y php8.3-fpm php8.3-mysql php8.3-gd php8.3-mbstring \
  php8.3-xml php8.3-intl php8.3-opcache php8.3-zip php8.3-curl \
  nfs-common curl unzip

curl -fsSL -o /usr/local/bin/wp \
  https://github.com/wp-cli/wp-cli/releases/download/v2.12.0/wp-cli-2.12.0.phar
chmod 755 /usr/local/bin/wp
wp --info --allow-root
```

`php8.3-mysql` is what provides `mysqlnd`, `mysqli` and `pdo_mysql`.

## Tooling on mgmt01

```bash
apt-get install -y git python3-venv python3-pip python3-pymysql \
  mysql-client curl nmap traceroute mtr-tiny jq

python3 -m venv ~/ansible-venv
~/ansible-venv/bin/pip install --upgrade pip
~/ansible-venv/bin/pip install 'ansible-core>=2.20,<2.21' ansible-lint

gpg -k
curl -fsSL https://dl.k6.io/key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/k6.gpg
echo "deb [signed-by=/usr/share/keyrings/k6.gpg] https://dl.k6.io/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/k6.list
apt-get update && apt-get install -y k6

~/ansible-venv/bin/ansible --version
k6 version
```

## Diagnostics on every node

```bash
apt-get install -y tcpdump lsof sysstat conntrack auditd
```

---

# Configure each machine

## fw01

Already done: static IPs in all 4 zones, `ip_forward`, chrony and bind9 per `deploy-v1.md`.
Remaining: make `ip_forward` survive a reboot and add the masquerade rule. There is no zone
policy and no host firewall; see ADR-25.

### 1. Persist kernel forwarding

```bash
cat > /etc/sysctl.d/99-router.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl --system
sysctl net.ipv4.ip_forward
```

### 2. Take ufw off every node

```bash
ufw disable
apt-get purge -y ufw
```

Run this on all 10 nodes, `fw01` included. ADR-25 removed the firewall layer entirely, and
the package is purged rather than left disabled so "is a rule blocking this?" is never a
hypothesis during a drill. Purging also removes `/etc/default/ufw`, which is what used to
make `ufw` filter the FORWARD chain on a routing node and silently contradict the routing.

### 3. Masquerade only

The one netfilter rule the lab keeps. Without it a node loses internet access the moment
its own NAT NIC is removed, because the VMware NAT gateway has no route back into the
host-only zones.

Find the NAT interface name first; never copy an interface name from this document.

```bash
ip -brief address
```

Write `/etc/nftables.conf`, replacing `<nat-nic>`:

```
#!/usr/sbin/nft -f

table ip router_nat
delete table ip router_nat

define NAT_IF = "<nat-nic>"

# NAT, not a firewall: policy accept, nothing is ever dropped
table ip router_nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname $NAT_IF masquerade
    }
}
```

```bash
nft -c -f /etc/nftables.conf
systemctl enable --now nftables
nft list ruleset
```

`nft -c` validates without loading. Never load an unchecked ruleset on the one node every
cross-zone flow depends on.

The output must show this table and nothing else. No `filter` chain, no `drop`, on `fw01`
or anywhere. On the other nine nodes `nftables.service` stays stopped, so their ruleset is
empty; the `nft` binary stays installed because three chaos scenarios inject a rule with it
and delete it again on rollback.

What this costs is worth stating plainly: the app zone can now reach
`192.168.30.11:3306` directly, so the zone split is a design and routing boundary rather
than an enforced one, and every service's own access control is the only layer left. That
is the trade in ADR-25.

### 4. Add the missing DNS records

`deploy-v1.md` wrote the zone files before `mon01` existed. Add it, and bump the SOA
serial — a changed zone with an unchanged serial is silently ignored.

In `/etc/bind/zones/db.lab.internal`:

```
mon01   IN  A       172.16.10.21
```

In `/etc/bind/zones/db.172.16.10`:

```
21  IN  PTR mon01.lab.internal.
```

Bump the serial in both files, then:

```bash
named-checkzone lab.internal /etc/bind/zones/db.lab.internal
named-checkzone 10.16.172.in-addr.arpa /etc/bind/zones/db.172.16.10
systemctl reload named
dig +short mon01.lab.internal
```

### 5. Verify

```bash
# from web01, exactly one hop and it must be the app gateway
traceroute -n 192.168.30.11

# from web01, the denied direct path
nc -zv -w 3 192.168.30.11 3306        # must fail

# on fw01, the drop counter for that attempt
journalctl -k | grep '\[DROP\] app to db direct'
```

---

## nfs01

Follow `deploy-v1.md` sections 23 to 28 in order. The summary, because the order is
what matters:

1. Pin `www-data` to 33:33 **before** installing the package, on `nfs01`, `web01` and `web02`.
2. Install `nfs-kernel-server`.
3. Disable NFSv3 in `/etc/nfs.conf`, mask `rpcbind` and `rpc-statd`.
4. Create `/srv/nfs/uploads`, owner `www-data:www-data`, mode `2775`.
5. Export it to `192.168.20.11` and `192.168.20.12` only, `rw,sync,no_subtree_check`.
6. Nothing to open: there is no firewall, so `/etc/exports` is the only access control.

```bash
id www-data                      # expect 33:33 on all three nodes
cat /proc/fs/nfsd/versions       # expect -3 +4 -4.0 -4.1 +4.2
exportfs -v
ss -tlnp | grep 2049
```

A UID mismatch between the three nodes produces permission errors that a plain `ls -l`
cannot show. Check `id www-data` on all three before moving on.

---

## db01

db01 is the initial primary. It still boots read-only; write access is opened by hand.

### 1. Server configuration

Write `/etc/mysql/mysql.conf.d/zz-lab.cnf`:

```
[mysqld]
server_id = 1
report_host = db01
bind_address = 192.168.30.11,127.0.0.1

# binlog and GTID
log_bin = /var/log/mysql/binlog
binlog_format = ROW
binlog_expire_logs_seconds = 604800
gtid_mode = ON
enforce_gtid_consistency = ON
log_replica_updates = ON

# relay log, needed because this node becomes a replica after a failback
relay_log = /var/log/mysql/relaylog
relay_log_recovery = ON

# durability, never lowered for performance
sync_binlog = 1
innodb_flush_log_at_trx_commit = 1

# fencing: any restart comes back read-only
read_only = ON
super_read_only = ON

skip_name_resolve = ON
event_scheduler = ON
innodb_buffer_pool_size = 768M

# both semi-sync roles on both nodes, so a role swap needs no plugin install
plugin_load_add = semisync_source.so
plugin_load_add = semisync_replica.so
rpl_semi_sync_source_enabled = ON
rpl_semi_sync_replica_enabled = ON
rpl_semi_sync_source_wait_point = AFTER_SYNC
rpl_semi_sync_source_timeout = 3000
```

```bash
chown root:root /etc/mysql/mysql.conf.d/zz-lab.cnf
chmod 644 /etc/mysql/mysql.conf.d/zz-lab.cnf
systemctl restart mysql
systemctl status mysql --no-pager
```

Keep `log_bin` and `relay_log` under `/var/log/mysql`. Moving them outside the default
paths needs an AppArmor rule, and the failure looks nothing like a permission problem.

### 2. Root client file

```bash
cat > /root/.my.cnf <<'EOF'
[client]
user = root
password = <mysql-root-pass>
EOF
chmod 600 /root/.my.cnf
mysql -e 'SELECT @@version, @@gtid_mode, @@super_read_only'
```

### 3. Open write access

The config file sets the **boot** state. `SET GLOBAL` sets the **runtime** state and is
never persisted. The two are not in conflict; that split *is* the fencing mechanism from
ADR-09.

Reason: if db01 dies, db02 is promoted, and db01 later reboots writable, the lab has two
nodes accepting orders and the data is corrupt. Booting read-only makes that impossible
without an operator. Cost: write access must be reopened by hand after **every** restart,
planned or not, which is what runbook RB-04 exists for.

```sql
SET GLOBAL super_read_only = OFF;
SET GLOBAL read_only = OFF;
```

Turning `read_only` off implicitly turns `super_read_only` off too, so the second
statement alone would be enough. Both are written out so the intent is explicit.

### 4. Replication user

Replication stays inside the db zone, so this user is granted there only.

```sql
CREATE USER 'repl'@'192.168.30.%' IDENTIFIED BY '<repl-pass>';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'192.168.30.%';
FLUSH PRIVILEGES;
SHOW BINARY LOG STATUS;
```

Create this **before** configuring db02, or db02's IO thread has nothing to connect as.

### 5. Application and operator accounts

Connections arrive through HAProxy, so MySQL sees the **LB address** as the source, not
the web node and not the VIP. Grant on exactly those two addresses.

```sql
CREATE DATABASE wordpress CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER 'wp'@'192.168.10.11' IDENTIFIED BY '<wp-pass>';
CREATE USER 'wp'@'192.168.10.12' IDENTIFIED BY '<wp-pass>';
GRANT ALL PRIVILEGES ON wordpress.* TO 'wp'@'192.168.10.11';
GRANT ALL PRIVILEGES ON wordpress.* TO 'wp'@'192.168.10.12';

-- operator, used by the RPO and failover scripts straight from mgmt01
CREATE USER 'ops'@'172.16.10.11' IDENTIFIED BY '<ops-pass>';
GRANT ALL PRIVILEGES ON *.* TO 'ops'@'172.16.10.11' WITH GRANT OPTION;

-- health check, socket only, no privilege beyond reading its own status
CREATE USER 'mysqlchk'@'localhost' IDENTIFIED BY '<chk-pass>';
FLUSH PRIVILEGES;
```

Do **not** grant `wp` on `192.168.20.%`. If that grant makes the site work, traffic is
bypassing the LB and the design is broken.

The same rule decides which account can reach which path, and the two here are deliberately
different:

| Account | Granted on | Usable path |
|---|---|---|
| `wp` | the two LB addresses | through `VIP:3306` only |
| `ops` | `172.16.10.11` | direct to `192.168.30.11` or `.12` only |

So `ops` through the VIP fails with error 1045, by design: failover and RPO work has to
address one **named** node, never whichever node a load balancer happens to pick. If a
script later needs to write through the VIP the way the application does, it should use
`wp`, not a broader grant on `ops`.

These statements replicate to db02 once step db02/3 is done, so run them on db01 only.

### 6. Replication heartbeat

Lag is not measurable without a row that changes on a known schedule.

```sql
CREATE DATABASE lab;
CREATE TABLE lab.heartbeat (id TINYINT PRIMARY KEY, ts DATETIME(3) NOT NULL);
INSERT INTO lab.heartbeat VALUES (1, NOW(3));

CREATE EVENT lab.heartbeat_tick
  ON SCHEDULE EVERY 1 SECOND
  DO UPDATE lab.heartbeat SET ts = NOW(3) WHERE id = 1;
```

The event only runs while this node is writable, which is correct: on a read-only node
the heartbeat stopping is itself the signal.

### 7. mysqlchk on port 9200

A systemd socket unit, so there is no web server to run or patch.

`/etc/mysql/mysqlchk.cnf` — no `host` line on purpose, so the check connects over the
unix socket and matches the `'mysqlchk'@'localhost'` account under `skip_name_resolve`:

```
[client]
user = mysqlchk
password = <chk-pass>
```

```bash
chmod 600 /etc/mysql/mysqlchk.cnf
```

`/usr/local/bin/mysqlchk`:

```bash
#!/bin/bash
# 200 = writable, 503 = read-only
set -u

# read the request away first: closing a socket that still holds unread data makes the
# kernel send RST instead of FIN, and HAProxy reports that as a check socket error
while IFS= read -r -t 1 line; do
    [ -z "${line%$'\r'}" ] && break
done

ro=$(mysql --defaults-file=/etc/mysql/mysqlchk.cnf -N -B \
     -e 'SELECT @@read_only + @@super_read_only' 2>/dev/null)

if [ "${ro:-}" = "0" ]; then
    status='200 OK'
    body='[OK] db writable'
else
    status='503 Service Unavailable'
    body='[WARN] db read-only'
fi

# Content-Length is mandatory: without it HAProxy must read to connection close to know
# the body ended, so any abrupt close turns a healthy node into a failed check
printf 'HTTP/1.1 %s\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
    "$status" "${#body}" "$body"
```

```bash
chmod 755 /usr/local/bin/mysqlchk
```

`/etc/systemd/system/mysqlchk.socket`:

```
[Unit]
Description=mysqlchk listener for HAProxy

[Socket]
ListenStream=192.168.30.11:9200
ListenStream=127.0.0.1:9200
Accept=yes

[Install]
WantedBy=sockets.target
```

`/etc/systemd/system/mysqlchk@.service`:

```
[Unit]
Description=mysqlchk per-connection responder

[Service]
Type=simple
ExecStart=/usr/local/bin/mysqlchk
StandardInput=socket
StandardOutput=socket
StandardError=journal
```

```bash
systemctl daemon-reload
systemctl enable --now mysqlchk.socket

# -S so a reset is reported instead of swallowed, -i to confirm Content-Length is there
curl -sS -i http://127.0.0.1:9200/ | head -5
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9200/    # expect 200
```

A `Recv failure: Connection reset by peer` here, or a reply with no `Content-Length`,
means the responder will fail HAProxy's check even though this node is healthy.

`ListenStream` names the zone address explicitly, so 9200 never appears on the NAT NIC.

Then prove it over the real path, from `lb01`, because that is the client that matters:

```bash
curl -sS -m 3 -o /dev/null -w '%{http_code}\n' http://192.168.30.11:9200/   # expect 200
```

### 8. No firewall, so check what is listening instead

ADR-25 means 3306 and 9200 are reachable from every zone that can route here. Confirm the
sockets are at least bound where they should be:

```bash
ss -tlnp | grep -E ':(3306|9200)'
```

Expect `192.168.30.11` and `127.0.0.1`, never `0.0.0.0` and never the NAT address. That
`bind_address` line in `zz-lab.cnf` is now the only thing keeping MySQL off the NAT
segment, so read it as load-bearing rather than tidy.

The access control that remains is the GRANT host pattern: the application user exists only
for `192.168.10.%`, which is why a web node connecting directly to this port fails at
authentication rather than at the network. That is a weaker boundary than a dropped packet
and belongs in the known limitations.

---

## db02

Identical to db01 except for three values and the replication statement.

### 1. Server configuration

Same `/etc/mysql/mysql.conf.d/zz-lab.cnf` as db01, with:

```
server_id = 2
report_host = db02
bind_address = 192.168.30.12,127.0.0.1
```

```bash
systemctl restart mysql
```

### 2. Root client file

db02 needs this exactly as db01 did. Without it, `mysql` falls back to the shell user
with no password and every statement fails with error 1045 before MySQL even looks at
read-only.

```bash
cat > /root/.my.cnf <<'EOF'
[client]
user = root
password = <mysql-root-pass>
EOF
chmod 600 /root/.my.cnf
mysql -e 'SELECT @@version, @@server_id, @@super_read_only'
```

### 3. Start replication

`CHANGE MASTER TO` and `START SLAVE` are removed in 8.4 and raise a syntax error.

```sql
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST = '192.168.30.11',
  SOURCE_PORT = 3306,
  SOURCE_USER = 'repl',
  SOURCE_PASSWORD = '<repl-pass>',
  SOURCE_AUTO_POSITION = 1,
  GET_SOURCE_PUBLIC_KEY = 1;

START REPLICA;
SHOW REPLICA STATUS\G
```

`GET_SOURCE_PUBLIC_KEY = 1` is required because `caching_sha2_password` is the default
in 8.4; without it, and without TLS, the IO thread cannot authenticate.

`Replica_IO_Running` and `Replica_SQL_Running` must both be `Yes`.

### 4. mysqlchk

Same three files as db01 step 7, with the socket bound to this node's address:

```
ListenStream=192.168.30.12:9200
ListenStream=127.0.0.1:9200
```

The `mysqlchk` account arrives by replication, so do not create it here.

```bash
systemctl enable --now mysqlchk.socket
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9200/    # expect 503
```

503 is the correct answer on a replica. That difference is the whole mechanism HAProxy
uses to find the writable node.

### 5. No firewall here either

Same as db01: check the bind addresses, not a rule set. Replication reaches this node on
`192.168.30.12:3306` from `192.168.30.11`, inside the db zone, so it never crosses the
router at all.

### 6. Verify the database layer

On db01:

```sql
SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source_status';     -- ON
SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source_clients';    -- 1
CREATE TABLE wordpress.probe (id INT PRIMARY KEY);
INSERT INTO wordpress.probe VALUES (1);
```

On db02:

```sql
SELECT * FROM wordpress.probe;                   -- the row must be there
INSERT INTO wordpress.probe VALUES (2);          -- must fail with error 1290
SELECT TIMESTAMPDIFF(MICROSECOND, ts, NOW(3))/1000 AS lag_ms FROM lab.heartbeat;
```

Then reboot both nodes and confirm each comes back read-only. Run it as root on **both**
nodes, because `/root/.my.cnf` is what holds the credentials:

```bash
sudo mysql -e 'SELECT @@hostname, @@read_only, @@super_read_only'     # expect 1, 1
```

Both returning `1, 1` is the acceptance criterion for this step: the reboot undid the
runtime `SET GLOBAL` and the file put fencing back. That is the whole point of ADR-09.

Now reopen write on **db01 only**, then clean up. The order matters: the node is
read-only again after the reboot, so `DROP TABLE` fails with error 1290 until write is
reopened.

```sql
-- db01 only, never db02
SET GLOBAL super_read_only = OFF;
SET GLOBAL read_only = OFF;

DROP TABLE wordpress.probe;
```

Leave db02 read-only. Opening write there is the one action that breaks the single-writer
invariant, and nothing in the normal flow ever needs it.

Confirm the heartbeat resumed, since the event only runs while the node is writable:

```sql
SELECT ts, NOW(3) FROM lab.heartbeat;
```

---

## lb01

lb01 owns the PKI and is Keepalived MASTER at priority 110.

### 1. Allow binding a VIP it does not own

```bash
cat > /etc/sysctl.d/99-haproxy.conf <<'EOF'
# ip_nonlocal_bind: BACKUP must bind the VIP it does not own yet
net.ipv4.ip_nonlocal_bind = 1
EOF
sysctl --system
```

### 2. Internal PKI

Generate the CA and the server certificate here, then copy them out. Keep the CA key
off the repo.

```bash
mkdir -p /root/ca /etc/haproxy/certs
cd /root/ca

openssl genrsa -out lab-ca.key 4096
openssl req -x509 -new -nodes -key lab-ca.key -sha256 -days 3650 \
  -subj "/C=VN/O=Lab/CN=lab.internal Root CA" -out lab-ca.crt

openssl genrsa -out shop.key 2048
```

`shop.cnf` — the SAN is what the certificate is actually validated against; the CN is
ignored by modern clients:

```
[req]
distinguished_name = dn
req_extensions     = v3_req
prompt             = no

[dn]
C  = VN
O  = Lab
CN = shop.lab.internal

[v3_req]
subjectAltName   = DNS:shop.lab.internal, IP:192.168.10.100
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
```

```bash
openssl req -new -key shop.key -out shop.csr -config shop.cnf
openssl x509 -req -in shop.csr -CA lab-ca.crt -CAkey lab-ca.key -CAcreateserial \
  -out shop.crt -days 825 -sha256 -extfile shop.cnf -extensions v3_req

cat shop.crt lab-ca.crt shop.key > /etc/haproxy/certs/shop.pem
chmod 600 /etc/haproxy/certs/shop.pem
chown root:root /etc/haproxy/certs/shop.pem

openssl x509 -in shop.crt -noout -text | grep -A1 'Subject Alternative Name'
```

HAProxy needs the certificate, the chain and the key in one PEM. Order matters: leaf
first.

Copy out. The shared key is installed for the `vagrant` user only and `mgmt01` is the
single node holding its private half, so both transfers are driven from there rather
than node to node:

```bash
# on mgmt01
ssh vagrant@192.168.10.11 'sudo cat /etc/haproxy/certs/shop.pem' \
  | ssh vagrant@192.168.10.12 'sudo mkdir -p /etc/haproxy/certs \
      && sudo tee /etc/haproxy/certs/shop.pem >/dev/null \
      && sudo chmod 600 /etc/haproxy/certs/shop.pem'

ssh vagrant@192.168.10.11 'sudo cat /root/ca/lab-ca.crt' > /tmp/lab-ca.crt
```

The CA private key `/root/ca/lab-ca.key` never leaves lb01. lb02 needs the server PEM
only, because nothing on it signs a certificate.

### 3. HAProxy

Write `/etc/haproxy/haproxy.cfg`:

```
global
    log /dev/log local0
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    retries 3
    option  redispatch
    # timeouts allow for two routed hops; too tight reads a router hop as a failure
    timeout connect 5s
    timeout client  30s
    timeout server  30s
    timeout http-request 10s

frontend fe_http
    bind 192.168.10.100:80
    bind 127.0.0.1:80
    monitor-uri /haproxy-alive
    http-request redirect scheme https code 301 unless { path /haproxy-alive }

frontend fe_https
    bind 192.168.10.100:443 ssl crt /etc/haproxy/certs/shop.pem
    option forwardfor
    http-request set-header X-Forwarded-Proto https
    default_backend be_web

backend be_web
    balance roundrobin
    cookie SRV insert indirect nocache
    option httpchk
    http-check send meth GET uri /healthz.php
    http-check expect status 200
    # inter 2s fall 3 is why a broken node leaves the backend in about 6 seconds
    default-server check inter 2s fall 3 rise 2
    server web01 192.168.20.11:80 cookie w1
    server web02 192.168.20.12:80 cookie w2

listen mysql
    bind 192.168.10.100:3306
    mode tcp
    option tcplog
    balance first
    option httpchk
    http-check send meth GET uri /
    http-check expect status 200
    default-server check port 9200 inter 2s fall 3 rise 2 on-marked-down shutdown-sessions
    server db01 192.168.30.11:3306
    server db02 192.168.30.12:3306 disabled

frontend fe_stats
    bind 192.168.10.11:8404
    bind 127.0.0.1:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 5s
    stats auth admin:<stats-pass>
    stats admin if TRUE
```

Three things worth understanding:

- `listen mysql` is TCP on 3306 but health checked over HTTP on 9200. That split is
  what lets HAProxy ask "are you writable" instead of "is the port open".
- db02 is `disabled`, which is MAINT. Only one node ever receives writes, enforced here
  as well as by `super_read_only`.
- `bind 127.0.0.1:80` exists for the Keepalived check script. Nothing binds the NAT NIC.

Validate before reloading, always:

```bash
haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl restart haproxy
systemctl status haproxy --no-pager
ss -tlnp | grep haproxy
```

### 4. HAProxy logging and rotation

A full disk is the failure that started this ticket, so verify rotation rather than
assuming the package got it right.

`/etc/rsyslog.d/49-haproxy.conf`:

```
:programname, startswith, "haproxy" /var/log/haproxy.log
& stop
```

```bash
systemctl restart rsyslog
logrotate -d /etc/logrotate.d/haproxy
logrotate -f /etc/logrotate.d/haproxy
ls -l /var/log/haproxy.log*
```

### 5. Keepalived check script

The script must prove HAProxy **answers**, not that the process exists.

`/usr/local/bin/chk_haproxy.sh`:

```bash
#!/bin/bash
# a live process that stopped answering is still a failure
curl -sf -m 1 -o /dev/null http://127.0.0.1/haproxy-alive
```

```bash
chmod 755 /usr/local/bin/chk_haproxy.sh
chown root:root /usr/local/bin/chk_haproxy.sh
```

`enable_script_security` refuses to run a script from a world-writable path, so the
ownership above is load-bearing.

### 6. Keepalived

Find the dmz interface name, then write `/etc/keepalived/keepalived.conf`:

```bash
ip -brief address | grep 192.168.10.11
```

```
global_defs {
    router_id lb01
    enable_script_security
    script_user root
}

vrrp_script chk_haproxy {
    script "/usr/local/bin/chk_haproxy.sh"
    interval 2
    timeout 1
    fall 2
    rise 2
    weight -20
}

vrrp_instance VI_SHOP {
    state MASTER
    interface <dmz-nic>
    virtual_router_id 51
    priority 110
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass <vrrp-pass>
    }

    virtual_ipaddress {
        192.168.10.100/24
    }

    track_script {
        chk_haproxy
    }
}
```

```bash
systemctl restart keepalived
ip -4 addr show dev <dmz-nic> | grep 192.168.10.100
journalctl -u keepalived -n 20 --no-pager
```

The instance must bind the dmz NIC. On the NAT NIC the VIP appears on the wrong
segment and nothing reaches it. `advert_int 1` puts detection near 3 seconds, inside
the under-6-second target.

### 7. No firewall, which removes a classic VRRP trap

Nothing to configure. This step used to be the fiddly one, because `ufw` has no
`proto vrrp` and IP protocol 112 had to go into `/etc/ufw/before.rules` by hand; forget it
and the BACKUP hears nothing, declares the MASTER dead and claims the VIP, which is a
split brain caused entirely by the firewall. ADR-25 deletes that whole failure mode.

Scenario 05 still reproduces it on purpose, by injecting a `inet lab_chaos` table that
drops protocol 112, and `05-rollback.sh` deletes the table again. Confirm the LB is clean
before and after:

```bash
sudo nft list ruleset        # must be empty on an LB
```

Check the stats port instead, since nothing filters it: `fe_stats` must bind
`192.168.10.11:8404` and not `0.0.0.0`, because that bind address is now the only thing
limiting who can reach the stats page.

---

## lb02

The same node as lb01 with four values changed. Any other difference is a bug.

| lb01 step | What lb02 does |
|---|---|
| 1. Allow binding a VIP it does not own | **run it, unchanged** — this is the node that needs it |
| 2. Internal PKI | **do not regenerate** — receive `shop.pem` only, from the copy in lb01 step 2 |
| 3. HAProxy | same file, one line changed: `fe_stats` binds `192.168.10.12:8404` |
| 4. Logging and rotation | same, unchanged |
| 5. Keepalived check script | same, unchanged |
| 6. Keepalived | `router_id lb02`, `state BACKUP`, `priority 100` |
| 7. Firewall | nothing to do on either node |

So the four values are three in `keepalived.conf` and one in `haproxy.cfg`. The sysctl
drop-in, `chk_haproxy.sh` and the rsyslog file are identical.

### Why lb02 needs ip_nonlocal_bind, and lb01 does too

`haproxy.cfg` on both nodes carries `bind 192.168.10.100:443`. Binding an address that
sits on no local interface fails with `EADDRNOTAVAIL` unless the kernel permits it, and
the BACKUP node by definition does not hold the VIP. Without this sysctl HAProxy does
not start on lb02 at all, so the failover being built has nothing to fail over to.

lb01 needs it for the same reason in a narrower window: if lb01 reboots while lb02 holds
the VIP, it comes back as BACKUP until it wins the election, and HAProxy starts before
Keepalived has claimed anything. Identical on both nodes, no exception.

### Verify

```bash
haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl restart haproxy keepalived

sysctl net.ipv4.ip_nonlocal_bind              # expect 1
ss -tlnp | grep 192.168.10.100                # haproxy listening on the VIP
ip -4 addr show | grep 192.168.10.100         # expect no output: lb01 holds the VIP
```

Those last two together are the proof, and the pair looks contradictory until you see
why: HAProxy is listening on an address the node does not own. That is exactly the state
that makes a VIP move instant, because the socket is already open when the address
arrives.

### Verify the VIP layer

From `mgmt01`, so the request takes the routed path:

```bash
ping -c 2 192.168.10.100
curl -I http://shop.lab.internal                             # expect 301
curl -I https://shop.lab.internal --cacert /tmp/lab-ca.crt   # expect 503, see below

# wp, not ops: through the VIP MySQL sees the LB address, and wp is the account granted there
mysql -h 192.168.10.100 -u wp -p -e 'SELECT @@hostname, @@read_only'
```

A 503 on the HTTPS line is the **correct** result here, and it proves more than it looks:
to return a 503 at all, HAProxy had to resolve the name, own the VIP, complete a TLS
handshake the client validated against the internal CA, and find `be_web` empty. Only the
backend is missing.

The MySQL query must answer `db01` and `0`. That proves `mysqlchk` steered HAProxy to the
writable node rather than to whichever node answered first.

Use `wp` and not `ops` on that line. Through `VIP:3306` MySQL sees the source as
`192.168.10.11` or `.12`, and `ops` is granted on `172.16.10.11` only, so it fails with
error 1045. That failure is itself a useful signal: the host named in the 1045 message is
the address MySQL really saw, which is the fastest way to confirm traffic went through the
LB instead of around it.

At this point `be_web` is DOWN and that is expected: `/healthz.php` does not exist until
web01 is configured, so the check gets a 404 from whatever nginx serves by default.

`mysql/db01` must be **UP** though. When it is not, read the reason HAProxy prints rather
than guessing, because each one points at a different layer:

| HAProxy reason | Where to look |
|---|---|
| `Layer4 timeout` | the packet never arrived: routing, or `bind_address` on db01. No firewall can cause this one |
| `Layer4 connection problem, Connection refused` | nothing is listening: `mysqlchk.socket` is not started |
| `Socket error, ECONNRESET` | accepted then reset: the responder is at fault, not the network |
| `Layer7 wrong status, code: 503` | mysqlchk answered honestly — that node really is read-only |

Only the last one is a database state. The other three are infrastructure, and the error
class tells you which without a single guess.

### Prove the VIP actually moves

This is the M3 acceptance criterion and the reason two LBs exist. Probe `monitor-uri`
rather than the site, so the test does not depend on a web backend that is still empty.

On `mgmt01`:

```bash
while :; do
    curl -s -o /dev/null -w '%{http_code} ' -m 1 http://192.168.10.100/haproxy-alive
    sleep 0.2
done
```

On `lb01`, break HAProxy while that runs:

```bash
systemctl stop haproxy
```

`chk_haproxy.sh` starts failing, `weight -20` drops lb01 to 90, lb02 at 100 wins the
election and claims the VIP. Confirm on lb02:

```bash
ip -4 addr show | grep 192.168.10.100
```

Count the non-200 responses in the probe output and record the number with the elapsed
time; the target is the VIP moving in under 6 seconds. Estimating this number is not
acceptable, it has to be counted.

Then bring lb01 back and watch preempt return the VIP, which costs a second short
interruption:

```bash
systemctl start haproxy
```

| Measurement | Value |
|---|---|
| failed requests, lb01 stopped | |
| time for VIP to reach lb02 | |
| failed requests, lb01 restored | |

Stop the probe once both transitions are recorded.

---

## web01

web01 runs `wp core install` once. Everything else is identical on both web nodes.

### 1. Pin www-data and mount NFS

```bash
id www-data                      # expect 33:33, fix before anything else
mkdir -p /var/www/wordpress/wp-content/uploads
```

Make the mount point unwritable **before** mounting anything on it:

```bash
chown root:root /var/www/wordpress/wp-content/uploads
chmod 0555 /var/www/wordpress/wp-content/uploads
```

Reason: an unmounted mount point is still a perfectly good local directory, so a mount
that fails at boot leaves WordPress writing uploads to local disk, the two web nodes
diverge, and nothing complains. A root-owned `0555` directory makes `www-data` fail that
write instead, so a missing mount shows up as a visible upload error on the first attempt.
Cost: the message WordPress shows is unhelpful, so the runbook has to start with
`findmnt`. These permissions only apply while unmounted; once mounted, the directory is
the export's own `www-data`-owned `2775`.

Add to `/etc/fstab`:

```
192.168.20.21:/srv/nfs/uploads  /var/www/wordpress/wp-content/uploads  nfs4  nfsvers=4.2,hard,noatime,_netdev  0  0
```

```bash
mount -a
findmnt /var/www/wordpress/wp-content/uploads     # no output at all means NOT mounted
```

`findmnt` is the only reliable test, and its exit code is what a script must read. `ls` on
an unmounted mount point lists the local directory and looks entirely normal, which is
exactly how this failure hides.

Any write into the mount has to run as `www-data`, never as root. The export keeps the
default `root_squash`, so root maps to `nobody`, and `nobody` has no write bit on a
`2775 www-data` directory. A `sudo cp` into the mount fails with a permission error that
reads like a broken export and is not one.

Mount only `wp-content/uploads`. Sharing the whole tree would make `nfs01` a SPOF for
the application code as well as for uploads.

### 2. Nginx

The upstream package runs as `nginx`; switch it to `www-data` so one UID owns the whole
web path and the NFS mount.

In `/etc/nginx/nginx.conf`:

```
user www-data;
```

```bash
rm -f /etc/nginx/conf.d/default.conf
```

Write `/etc/nginx/conf.d/shop.conf`:

```
server {
    listen 192.168.20.11:80 default_server;
    listen 127.0.0.1:80;
    server_name shop.lab.internal;

    root  /var/www/wordpress;
    index index.php index.html;

    client_max_body_size 32m;

    # log the real client, not the LB
    set_real_ip_from 192.168.10.11;
    set_real_ip_from 192.168.10.12;
    real_ip_header   X-Forwarded-For;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        include      fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    location = /healthz.php {
        include      fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        access_log   off;
    }

    location = /fpm-status {
        allow 172.16.10.11;
        allow 192.168.10.11;
        allow 192.168.10.12;
        deny  all;
        include      fastcgi_params;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    # an uploaded .php must never execute
    location ~* /wp-content/uploads/.*\.php$ {
        deny all;
    }
}
```

`listen` names the zone address, so Nginx never binds the temporary NAT NIC.

```bash
nginx -t
systemctl restart nginx
ss -tlnp | grep nginx
```

### 3. PHP-FPM

Replace `/etc/php/8.3/fpm/pool.d/www.conf` with this **complete** file. The `[www]` header
on line 1 is not decoration: without a section header FPM has no pool to attach the
directives to and refuses to start with `unknown entry 'user'` at line 1.

```
[www]
user  = www-data
group = www-data

listen       = /run/php/php8.3-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode  = 0660

pm = dynamic
pm.max_children      = 12
pm.start_servers     = 3
pm.min_spare_servers = 2
pm.max_spare_servers = 5

pm.status_path = /fpm-status
```

This one has to be a whole-file replacement rather than a drop-in. `php-fpm.conf`
includes every `pool.d/*.conf`, so a second file also declaring `[www]` collides on the
pool name, and giving it a different name would create a second pool instead of changing
this one.

`/etc/php/8.3/fpm/conf.d/99-lab.ini`:

```
memory_limit = 256M
upload_max_filesize = 32M
post_max_size = 32M
max_execution_time = 60
opcache.enable = 1
opcache.memory_consumption = 128
expose_php = Off
```

```bash
php-fpm8.3 -t
systemctl restart php8.3-fpm
```

`pm.max_children = 12` is a starting point, not a measurement. Measure real RSS per
worker under k6 and correct it in M7:

```bash
ps -o rss=,args= -C php-fpm8.3 | awk '/pool www/ {s+=$1; n++} END \
  {if (n) printf "%.0f MB avg over %d workers\n", s/n/1024, n; \
   else print "[WARN] no php-fpm worker running"}'
```

The `pool www` filter keeps the master process out of the average, since only workers
serve requests. The guard on `n` is there because a dead FPM would otherwise fail with an
awk division by zero, which hides the real problem.

### 4. Health check endpoint

`/var/www/wordpress/healthz.php`:

```php
<?php
// shallow on purpose: a db or nfs check here would drop both web nodes at once
header('Content-Type: text/plain');
echo "ok\n";
```

```bash
chown www-data:www-data /var/www/wordpress/healthz.php
curl -s http://127.0.0.1/healthz.php
```

HAProxy should now mark web01 UP. Check the stats page from `mgmt01`.

### 5. WordPress and WooCommerce

Pin the versions; never use "latest". Verify the checksum on download.

```bash
cd /tmp
WP_VERSION=7.0
curl -fsSLO "https://wordpress.org/wordpress-${WP_VERSION}.tar.gz"
curl -fsSLO "https://wordpress.org/wordpress-${WP_VERSION}.tar.gz.sha256"
sha256sum -c "wordpress-${WP_VERSION}.tar.gz.sha256"

tar -xzf "wordpress-${WP_VERSION}.tar.gz" --strip-components=1 -C /var/www/wordpress
chown -R www-data:www-data /var/www/wordpress
```

Install WooCommerce **before** `DISALLOW_FILE_MODS` goes in, because that constant
blocks WP-CLI plugin installs too.

```bash
WC_VERSION=11.1.0
cd /tmp
curl -fsSLO "https://downloads.wordpress.org/plugin/woocommerce.${WC_VERSION}.zip"
unzip -q "woocommerce.${WC_VERSION}.zip" -d /var/www/wordpress/wp-content/plugins/
chown -R www-data:www-data /var/www/wordpress/wp-content/plugins/woocommerce
```

### 6. wp-config.php

Generate the salts first, then paste them in:

```bash
curl -s https://api.wordpress.org/secret-key/1.1/salt/
```

Write `/var/www/wordpress/wp-config.php`:

```php
<?php
define('DB_NAME',     'wordpress');
define('DB_USER',     'wp');
define('DB_PASSWORD', '<wp-pass>');
// through HAProxy in the dmz zone, never a db node address
define('DB_HOST',     '192.168.10.100:3306');
define('DB_CHARSET',  'utf8mb4');
define('DB_COLLATE',  '');

// paste the eight generated salts here
define('AUTH_KEY',         '<salt>');
define('SECURE_AUTH_KEY',  '<salt>');
define('LOGGED_IN_KEY',    '<salt>');
define('NONCE_KEY',        '<salt>');
define('AUTH_SALT',        '<salt>');
define('SECURE_AUTH_SALT', '<salt>');
define('LOGGED_IN_SALT',   '<salt>');
define('NONCE_SALT',       '<salt>');

define('WP_HOME',    'https://shop.lab.internal');
define('WP_SITEURL', 'https://shop.lab.internal');

// no plugin installs through the admin UI, or the two nodes drift
define('DISALLOW_FILE_MODS', true);

// WP-Cron runs from a system cron on web01 only, so nothing runs twice
define('DISABLE_WP_CRON', true);

define('FS_METHOD', 'direct');

// TLS ends at HAProxy; without this WordPress loops on redirects
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO'])
    && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
}

$table_prefix = 'wp_';

if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}
require_once ABSPATH . 'wp-settings.php';
```

```bash
chown root:www-data /var/www/wordpress/wp-config.php
chmod 640 /var/www/wordpress/wp-config.php
```

### 7. Install the site, once

db01 must be writable for this. If it is not, open it per db01 step 3.

```bash
cd /var/www/wordpress

sudo -u www-data wp core install \
  --url=https://shop.lab.internal \
  --title="Lab Shop" \
  --admin_user=admin \
  --admin_password='<wp-admin-pass>' \
  --admin_email=admin@lab.internal \
  --skip-email

sudo -u www-data wp plugin activate woocommerce
sudo -u www-data wp wc tool run install_pages --user=admin
```

### 8. Make an order possible

Cash on delivery needs no gateway, which is what keeps the order path testable offline.

```bash
cd /var/www/wordpress

sudo -u www-data wp option update woocommerce_cod_settings \
  --format=json '{"enabled":"yes","title":"Cash on delivery"}'

sudo -u www-data wp option update woocommerce_default_country 'VN:SG'
sudo -u www-data wp option update woocommerce_currency 'VND'
sudo -u www-data wp option update woocommerce_calc_taxes 'no'

PID=$(sudo -u www-data wp post create --post_type=product \
  --post_title='Lab Widget' --post_status=publish --porcelain)
sudo -u www-data wp post meta update "$PID" _price 100000
sudo -u www-data wp post meta update "$PID" _regular_price 100000
sudo -u www-data wp post meta update "$PID" _stock_status instock
sudo -u www-data wp post term set "$PID" product_type simple
```

### 9. WP-Cron on web01 only

`/etc/cron.d/wordpress-cron` — **this file exists on web01 and nowhere else**, or
WooCommerce scheduled tasks run twice:

```
*/5 * * * * www-data cd /var/www/wordpress && /usr/local/bin/wp cron event run --due-now >/dev/null 2>&1
```

### 10. No firewall, so check the nginx allow lists instead

Port 80 is reachable from every zone. What limits the sensitive paths is nginx itself:

```bash
grep -A6 'location = /fpm-status' /etc/nginx/conf.d/shop.conf
```

`/fpm-status` must list the admin and LB addresses and end with `deny all`. That `deny all`
is now the only thing in front of it, so treat it as load-bearing and test it from a node
that is not on the list.

---

## web02

Same as web01 except: the code tree is **copied**, not installed, and there is no cron
file. The two nodes must be byte-identical.

### 1. Everything except the application

Repeat web01 steps 1 to 4 and step 10, changing only the addresses:

| File | Change |
|---|---|
| `/etc/nginx/conf.d/shop.conf` | `listen 192.168.20.12:80 default_server;` |

The PHP-FPM files, `healthz.php` and the `fstab` line are identical.

### 2. Copy the code from web01

Exclude the uploads directory: it is an NFS mount, shared rather than copied.

Unmount it on web02 first. The archive still carries the `uploads/` directory entry even
with its contents excluded, so extracting over a live `hard` NFS mount would write
metadata across the network and can hang instead of failing.

```bash
# on web02
sudo umount /var/www/wordpress/wp-content/uploads
```

Then stream the tree straight from one node to the other. No staging file is written on
either side, which is both faster and avoids the two traps described below:

```bash
# on mgmt01, the only node holding the shared private key
ssh vagrant@192.168.20.11 \
  'sudo tar -C /var/www -cz --exclude="wordpress/wp-content/uploads/*" wordpress' \
  | ssh vagrant@192.168.20.12 'sudo tar -C /var/www -xz'
```

Finish on web02:

```bash
sudo chown -R www-data:www-data /var/www/wordpress
sudo chown root:www-data /var/www/wordpress/wp-config.php
sudo chmod 640 /var/www/wordpress/wp-config.php
sudo mount -a
sudo systemctl restart php8.3-fpm nginx
```

Two reasons this is a stream and not a `tar` to `/tmp` plus an `scp`:

- **`scp root@<node>` does not work here.** `bootstrap.sh` installs the shared key for the
  `vagrant` user only, so node-to-node transfers go through `mgmt01`, which holds the
  private half.
- **Staging in `/tmp` can fail even as root.** Ubuntu sets `fs.protected_regular = 1`, so
  `O_CREAT` on an existing file you do not own inside a world-writable sticky directory
  returns `EACCES`, and that check has no `CAP_FOWNER` bypass. A leftover
  `/tmp/wordpress.tar.gz` owned by `vagrant` therefore blocks `sudo tar -f` with a
  permission error that `sudo` cannot solve. Stage under `/root` if a file is ever needed.

### 3. Prove the trees match

Run on both nodes and compare the single hash:

```bash
find /var/www/wordpress -path /var/www/wordpress/wp-content/uploads -prune -o -type f -print0 \
  | sort -z | xargs -0 sha256sum | sha256sum
```

A mismatch is a bug to fix, not a difference to accept.

### 4. Verify the shared uploads

On web01:

```bash
sudo -u www-data touch /var/www/wordpress/wp-content/uploads/from-web01
```

On web02:

```bash
ls -l /var/www/wordpress/wp-content/uploads/from-web01
sudo -u www-data touch /var/www/wordpress/wp-content/uploads/from-web02
```

On nfs01, the numeric owner must be `33 33` for both files:

```bash
ls -ln /srv/nfs/uploads
```

```bash
rm -f /var/www/wordpress/wp-content/uploads/from-web0*
```

---

## mgmt01

The control node and the test client. Every acceptance test runs from here, because it
is the only admin source that takes the routed path a real user would.

### 1. Trust the internal CA

Without this, `curl` fails and the error looks like an HAProxy fault.

```bash
cp /tmp/lab-ca.crt /usr/local/share/ca-certificates/lab-ca.crt
update-ca-certificates
curl -I https://shop.lab.internal        # must validate with no --cacert
```

### 2. Confirm DNS and routing

Static routes to the other three zones already exist from M1, because `mgmt01` keeps
its NAT NIC and so keeps its default route there.

```bash
ip route | grep 192.168
dig +short shop.lab.internal             # expect 192.168.10.100
resolvectl status | head -20
```

### 3. Ansible reachability

```bash
source ~/ansible-venv/bin/activate
cd ~/linux_project/ansible
ansible all -m ping
```

### 4. Windows host, for browser testing

In PowerShell as administrator, add to `C:\Windows\System32\drivers\etc\hosts`:

```
192.168.10.100 shop.lab.internal
```

Then import `lab-ca.crt` into the Trusted Root Certification Authorities store, or the
browser keeps warning. The host uses a hosts file rather than `fw01` as its resolver,
because DNS order across multiple adapters is unreliable and the host also needs normal
internet DNS.

---

# End-to-end verification

Run all of this from `mgmt01` before writing a single chaos scenario. A failure here is
a build problem, not a drill result.

## The request path

```bash
curl -I http://shop.lab.internal                 # 301 to https
curl -sI https://shop.lab.internal | head -1     # 200
curl -s https://shop.lab.internal/healthz.php    # ok
curl -s -u admin:'<stats-pass>' http://192.168.10.11:8404/stats | grep -c web0
```

Both web nodes must be UP on the stats page, db01 UP and db02 MAINT.

## The write path

Place a real order in the browser from the Windows host. WooCommerce 11.x stores orders
in `wp_wc_orders` when HPOS is on and in `wp_posts` when it is not, so check the layout
before trusting a count:

```bash
mysql -h 192.168.30.11 -u ops -p -e "SHOW TABLES IN wordpress LIKE 'wp_wc_orders'"
```

With HPOS on, compare the two nodes:

```bash
for h in 192.168.30.11 192.168.30.12; do
    echo -n "$h "
    mysql -h "$h" -u ops -p -N -B -e 'SELECT COUNT(*) FROM wordpress.wp_wc_orders'
done
```

Without HPOS, use `wp_posts` with `post_type='shop_order'` instead.

Equal counts on both nodes is the RPO=0 claim in its simplest form. The real proof
comes from `rpo_check.py` during the M6 drills.

## The shared storage path

Upload an image in wp-admin through web01, then fetch it through web02 directly:

```bash
curl -sI http://192.168.20.12/wp-content/uploads/<year>/<month>/<file> | head -1
```

## Isolation that must fail

```bash
# web nodes must not reach the db zone directly
ssh web01 'nc -zv -w 3 192.168.30.11 3306'       # must fail

# nfs is not an administrative interface
nc -zv -w 3 192.168.20.21 2049                   # must fail

# ntp and dns must be closed on the NAT segment
sntp -t 3 <fw01-nat-ip>                          # must time out
dig @<fw01-nat-ip> shop.lab.internal             # must time out or be refused
```

## Full port scan against the matrix

```bash
sudo nmap -sS -p- 192.168.10.11,12 192.168.20.11,12,21 192.168.30.11,12
```

Nothing filters, so every listening socket shows as open. The finding is therefore a
service bound wider than it should be, not a missing rule: compare the result against the
listen addresses in `network-firewall.md`, and expect to see ports that used to be
filtered. `bind_address`, `listen-on` and nginx `allow` are the only boundaries left.

## Acceptance checklist

- [ ] `nft list ruleset` on `fw01` shows the masquerade table and nothing else; empty on all nine other nodes, and `ufw` is not installed anywhere.
- [ ] `traceroute` from web01 to db01 shows exactly one hop at `192.168.20.254`.
- [ ] Replication: `Replica_IO_Running` and `Replica_SQL_Running` both `Yes`.
- [ ] `Rpl_semi_sync_source_status` is `ON` and `Rpl_semi_sync_source_clients` is 1.
- [ ] A direct write to db02 is refused with error 1290.
- [ ] Both DB nodes come back read-only after a reboot.
- [ ] `curl localhost:9200` returns 200 on db01 and 503 on db02.
- [ ] VIP `192.168.10.100` answers from `mgmt01` and lives on lb01.
- [ ] HTTP returns 301, HTTPS validates against the internal CA with no `--cacert`.
- [ ] The certificate SAN contains `DNS:shop.lab.internal` and `IP:192.168.10.100`, TLS 1.2 minimum.
- [ ] `mysql -h 192.168.10.100` from `mgmt01` reports `db01` and `read_only = 0`.
- [ ] Both web nodes UP on the stats page, db01 UP and db02 MAINT.
- [ ] A WooCommerce order placed over HTTPS appears on both db01 and db02.
- [ ] An image uploaded through web01 is served by web02, and the reverse.
- [ ] After rebooting both web nodes, `findmnt` still reports the uploads mount on each.
      An unmounted mount point looks normal to `ls` and silently takes local writes.
- [ ] The code tree hash is identical on web01 and web02.
- [ ] `/etc/cron.d/wordpress-cron` exists on web01 only.
- [ ] Every denied path in the isolation section actually fails.
- [ ] `nmap` output matches the port matrix with no extra open port.

Then snapshot: `vagrant snapshot save app-ready`.

---

# Turn this into Ansible

Nothing above is finished until it is code. A hand edit made to experiment must be
coded or rolled back immediately.

| Role | Tasks from this document |
|---|---|
| `common` | purge `ufw`, keep `nftables.service` stopped outside the router |
| `router` | sysctl forwarding, template `nftables.conf` with the masquerade rule only, `nft -c` validation before reload |
| `mysql` | Oracle repo and apt pin, `zz-lab.cnf` with `server_id` from inventory, root `.my.cnf`, users from Vault, heartbeat table and event, replication wired with `SOURCE_*` |
| `mysqlchk` | `mysqlchk.cnf`, the responder script, the socket and template units with the zone address from a variable |
| `pki` | CA and server certificate with `community.crypto`, SAN from a variable, `shop.pem` mode 600, CA pushed to `mgmt01` |
| `haproxy` | PPA and key, `haproxy.cfg` template validated with `haproxy -c -f %s`, rsyslog file, logrotate check |
| `keepalived` | `keepalived.conf` with `priority` and `state` from inventory, `lab_iface` variable, check script |
| `nginx_php` | nginx.org repo and key, `user www-data`, `shop.conf` with the zone address from a variable, pool and ini drop-ins, `healthz.php` |
| `wordpress` | pinned tarball with checksum, WooCommerce zip, `wp-config.php` from a template with Vault salts, `wp core install` with `run_once` and a guard, cron file on one node only |
| `nfs_client` | pin `www-data` 33:33, `nfs-common`, mount point, `fstab`, mount |

Idempotency traps that would break the `changed=0` requirement:

- WordPress salts must come from Vault, never be regenerated per run.
- `wp core install` must be guarded by `wp core is-installed`, not run blindly.
- The WooCommerce product and option values must be checked before being set, or every
  run reports changed.
- Validate `haproxy -c -f` and `nft -c -f` in a handler **before** the reload, so a bad
  template cannot take down the entry point or the router.
- `/root/.my.cnf` and `shop.pem` must be written with `no_log: true`.

# Known limitations recorded by this document

- No firewall on any node and no zone policy on the router; see ADR-25. The four zones are
  still routed and still separate broadcast domains, but nothing enforces which pairs may
  talk, so `web01` can open `192.168.30.11:3306` directly and the only thing that stops it
  succeeding is the GRANT host pattern. "Denied on purpose" flows in
  `network-firewall.md` are now design intent, not enforcement, and the port scan proves
  reachability rather than policy.
- `DB_HOST` points at the VIP, so every query crosses `fw01` twice and the router sits
  in the write path. Already listed as a limitation of ADR-18; this document makes it
  concrete.
- The MySQL application user is granted on the two LB addresses only. With no firewall that
  GRANT is the only thing stopping a web node writing straight to the db zone, so a grant
  change that makes `192.168.20.%` work means traffic stopped going through the LB and
  nothing else will say so.
- `pm.max_children = 12` is a guess until M7 measures it. Note it as unmeasured rather
  than presenting it as tuned.
- Cash on delivery is the only payment method, so the order path never exercises an
  external gateway. Accepted: the test target is the write path, not the payment.
- The WP-Cron file on web01 only means scheduled WooCommerce tasks stop when web01 is
  down, even though the site keeps serving. That is a deliberate trade against running
  them twice, and belongs in the chaos scenario list.
