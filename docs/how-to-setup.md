# How to set up the lab from nothing

## Initial VM

### Step 1: Install the host software

Order matters. The plugin will not install before the Utility is running.

1. VMware Workstation Pro 25H2 
2. Vagrant 2.4.9.
3. Vagrant VMware Utility 1.0.24
4. Install plugin: 

```powershell
vagrant plugin install vagrant-vmware-desktop --plugin-version 3.0.5
vagrant plugin list
Get-Service -Name "VMware Vagrant*"
```

### Step 2: Create the virtual networks

In Virtual Network Editor, with administrator rights:

| VMnet | Subnet | Type | DHCP | Host adapter |
|---|---|---|---|---|
| `vmnet1` | `192.168.10.0/24` | host-only | **off** | on |
| `vmnet2` | `192.168.20.0/24` | host-only | **off** | on |
| `vmnet3` | `192.168.30.0/24` | host-only | **off** | on |
| `vmnet4` | `172.16.10.0/24` | host-only | **off** | on |
| `vmnet8` | `10.10.10.0/24` | NAT | **on** | on |

### Step 3: Build the lab

```powershell
vagrant box add bento/ubuntu-24.04 --box-version 202510.26.0 --provider vmware_desktop --architecture amd64
vagrant up --provider vmware_desktop
vagrant status
```

### Step 4: Verify, then snapshot

```powershell
vagrant snapshot save base
```

---

## Config VM

### fw01

#### 1. Install packages

```shell
sudo apt install chrony bind9 bind9-utils bind9-dnsutils
```

#### 2. Config NTP server

- Write to `/etc/chrony/conf.d/server.conf`:

```shell
# serve time to the four lab zones
allow 192.168.10.0/24
allow 192.168.20.0/24
allow 192.168.30.0/24
allow 172.16.10.0/24

# keep serving a consistent clock when upstream is unreachable
local stratum 10
```

- Restart and check chrony: 

```shell
sudo systemctl restart chrony
sudo chronyc tracking
sudo chronyc sources -v
sudo chronyc clients
timedatectl status
```

#### 3. Config internal DNS server by BIND9

- Replace file `/etc/bind/named.conf.options`:

```shell
acl lab {
    192.168.10.0/24;
    192.168.20.0/24;
    192.168.30.0/24;
    172.16.10.0/24;
    localhost;
};

options {
    directory "/var/cache/bind";

    # bind only the zone addresses and loopback, never the NAT NIC
    listen-on port 53 {
        127.0.0.1;
        192.168.10.254;
        192.168.20.254;
        192.168.30.254;
        172.16.10.254;
    };
    listen-on-v6 { none; };

    allow-query     { lab; };
    allow-recursion { lab; };
    allow-transfer  { none; };

    recursion yes;
    forwarders { 1.1.1.1; 8.8.8.8; };
    forward only;

    dnssec-validation auto;
    version none;
};
```

- Replace `/etc/bind/named.conf.local`:

```shell
# forward zone
zone "lab.internal" {
    type master;
    file "/etc/bind/zones/db.lab.internal";
};

# reverse zones, one per lab subnet
zone "10.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/db.192.168.10";
};

zone "20.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/db.192.168.20";
};

zone "30.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/db.192.168.30";
};

zone "10.16.172.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/db.172.16.10";
};
```

- Write to `/etc/bind/zones/db.lab.internal` (**Forward zone file**): 

```bash
mkdir -p /etc/bind/zones
```

```shell
$TTL 3600
@       IN  SOA ns1.lab.internal. admin.lab.internal. (
            2026101201  ; serial, YYYYMMDDnn
            3600        ; refresh
            600         ; retry
            604800      ; expire
            3600 )      ; negative cache TTL

@       IN  NS      ns1.lab.internal.

; name server, fw01 in the dmz zone
ns1     IN  A       192.168.10.254

; fw01, one record per zone interface
fw01        IN  A   192.168.10.254
fw01-dmz    IN  A   192.168.10.254
fw01-app    IN  A   192.168.20.254
fw01-db     IN  A   192.168.30.254
fw01-client IN  A   172.16.10.254

; the only entry point a client should ever use
shop    IN  A       192.168.10.100
vip     IN  A       192.168.10.100

; dmz zone
lb01    IN  A       192.168.10.11
lb02    IN  A       192.168.10.12

; app zone
web01   IN  A       192.168.20.11
web02   IN  A       192.168.20.12
nfs01   IN  A       192.168.20.21

; db zone
db01    IN  A       192.168.30.11
db02    IN  A       192.168.30.12

; client zone
mgmt01  IN  A       172.16.10.11
mon01   IN  A       172.16.10.21
```

- Write to file `/etc/bind/zones/db.192.168.10` (**Reverse zone files**)

```shell
$TTL 3600
@   IN  SOA ns1.lab.internal. admin.lab.internal. (
        2026101201 3600 600 604800 3600 )
@   IN  NS  ns1.lab.internal.

11  IN  PTR lb01.lab.internal.
12  IN  PTR lb02.lab.internal.
100 IN  PTR shop.lab.internal.
254 IN  PTR fw01-dmz.lab.internal.
```

- Write to file `/etc/bind/zones/db.192.168.20` (**Reverse zone file**):

```shell
$TTL 3600
@   IN  SOA ns1.lab.internal. admin.lab.internal. (
        2026101201 3600 600 604800 3600 )
@   IN  NS  ns1.lab.internal.

11  IN  PTR web01.lab.internal.
12  IN  PTR web02.lab.internal.
21  IN  PTR nfs01.lab.internal.
254 IN  PTR fw01-app.lab.internal.
```

- Write to file `/etc/bind/zones/db.192.168.30` (**Reverse zone file**):

```shell
$TTL 3600
@   IN  SOA ns1.lab.internal. admin.lab.internal. (
        2026101201 3600 600 604800 3600 )
@   IN  NS  ns1.lab.internal.

11  IN  PTR db01.lab.internal.
12  IN  PTR db02.lab.internal.
254 IN  PTR fw01-db.lab.internal.
```

- Write to file `/etc/bind/zones/db.172.16.10` (**Reverse zone file**):

```shell
$TTL 3600
@   IN  SOA ns1.lab.internal. admin.lab.internal. (
        2026101201 3600 600 604800 3600 )
@   IN  NS  ns1.lab.internal.

11  IN  PTR mgmt01.lab.internal.
21  IN  PTR mon01.lab.internal.
254 IN  PTR fw01-client.lab.internal.
```

- Config file ownership:

```shell
sudo chown -R root:bind /etc/bind/zones
sudo chmod 755 /etc/bind/zones
sudo chmod 644 /etc/bind/zones/*
```

- Validate:

```shell
sudo named-checkconf

sudo named-checkzone lab.internal                /etc/bind/zones/db.lab.internal

sudo named-checkzone 10.168.192.in-addr.arpa     /etc/bind/zones/db.192.168.10

sudo named-checkzone 20.168.192.in-addr.arpa     /etc/bind/zones/db.192.168.20

sudo named-checkzone 30.168.192.in-addr.arpa     /etc/bind/zones/db.192.168.30

sudo named-checkzone 10.16.172.in-addr.arpa      /etc/bind/zones/db.172.16.10
```

- Restart:

```shell
sudo systemctl restart named
sudo systemctl status named
sudo ss -tulpn | grep :53
```

- Confirm resolver configuration on fw01 itself:

```shell
dig @127.0.0.1 web01.lab.internal +short      # expect 192.168.20.11
dig @127.0.0.1 deb.debian.org +short          # expect public addresses
```

- Disable `systemd-resolved` and write a static resolver file:

```shell
sudo systemctl disable --now systemd-resolved

sudo rm -f /etc/resolv.conf

cat > /etc/resolv.conf <<'EOF'
nameserver 127.0.0.1
search lab.internal
options timeout:2 attempts:2
EOF

sudo systemctl restart named
sudo ss -tulpn | grep :53
```

---

### nfs01

#### 1. Install packages

- Do this first before installing any package

```shell
id www-data        # expect uid=33(www-data) gid=33(www-data)
```

- If any node disagrees, fix it before continuing, with no `www-data` process running:

```shell
sudo groupmod -g 33 www-data
sudo usermod -u 33 -g 33 www-data
```

- After that, install packages:

```shell
sudo apt install chrony nfs-kernel-server
```

#### 2. Config NTP client

- Edit file `/etc/chrony/chrony.conf`:

```
# Comment the lines of pool server
# replace that lines by NTP server (fw01)
server 192.168.20.254 iburst
```

- Restart and check chrony: 

```shell
sudo systemctl restart chrony
sudo chronyc tracking
sudo chronyc sources -v
timedatectl status
```

#### 3. Config NFS server

- Disable NFSv3, keep v4.2 only:

Edit `/etc/nfs.conf`:

```shell
[nfsd]
vers3 = n
vers4 = y
vers4.0 = n
vers4.1 = n
vers4.2 = y
```

```shell
sudo systemctl mask rpcbind.service rpcbind.socket rpc-statd.service
sudo systemctl restart nfs-server
```

Confirm:

```shell
sudo cat /proc/fs/nfsd/versions  # expect -3 +4 -4.0 -4.1 +4.2
ss -tlnp | grep 2049
id www-data                 # expect 33:33 on all three nodes (web01, web02, nfs01)
ss -tlnp | grep ':111'      # expect no output
systemctl is-enabled rpcbind.socket     # expect: masked
```

- Create the export directory:

```shell
sudo mkdir -p /srv/nfs/uploads
sudo chown www-data:www-data /srv/nfs/uploads
sudo chmod 2775 /srv/nfs/uploads
```

- Define the export:

Write `/etc/exports`:

```shell
# WordPress uploads, exported to the two web nodes only
/srv/nfs/uploads 192.168.20.11(rw,sync,no_subtree_check) 192.168.20.12(rw,sync,no_subtree_check)
```

Apply and verify:

```shell
sudo exportfs -ra
sudo exportfs -v
```

---

### db01 and db02

#### 1. Install packages

```shell
sudo apt install chrony mysql-server
```

#### 2. Config NTP client

- Edit file `/etc/chrony/chrony.conf`:

```
# Comment the lines of pool server
# replace that lines by NTP server (fw01)
server 192.168.30.254 iburst
```

- Restart and check chrony: 

```shell
sudo systemctl restart chrony
sudo chronyc tracking
sudo chronyc sources -v
timedatectl status
```

#### 3. On `db01`:

- Write `/etc/mysql/mysql.conf.d/zz-lab.cnf`:

```shell
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

- Run command:

```shell
sudo chown root:root /etc/mysql/mysql.conf.d/zz-lab.cnf
sudo chmod 644 /etc/mysql/mysql.conf.d/zz-lab.cnf
sudo systemctl restart mysql
systemctl status mysql --no-pager
```

- Edit Root client file: enter root password of mysql before run command

```shell
sudo tee /root/.my.cnf <<'EOF'
[client]
user = root
password = <mysql-root-pass>
EOF

sudo chmod 600 /root/.my.cnf
sudo mysql -e 'SELECT @@version, @@gtid_mode, @@super_read_only'
```

- Open write access in MySQL:

Login mysql with root permission:

```shell
mysql -u root -p  
# Enter mysql root password
```

Run command in order:

```mysql
SET GLOBAL super_read_only = OFF;
SET GLOBAL read_only = OFF;
```

Verification: expected result: Both value of `read_only` and `super_read_only` is OFF.

```mysql
SHOW VARIABLES LIKE '%read_only%';
```

Create Replication user: enter password by replacing `<repl-pass>`

```mysql
CREATE USER 'repl'@'192.168.30.%' IDENTIFIED BY '<repl-pass>';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'192.168.30.%';
FLUSH PRIVILEGES;
SHOW BINARY LOG STATUS;
```

Application and operator accounts: enter password by replacing `<wp-pass>`, `<ops-pass>`, `<chk-pass>`

```mysql
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

Replication heartbeat:

```mysql
CREATE DATABASE lab;
CREATE TABLE lab.heartbeat (id TINYINT PRIMARY KEY, ts DATETIME(3) NOT NULL);
INSERT INTO lab.heartbeat VALUES (1, NOW(3));

CREATE EVENT lab.heartbeat_tick ON SCHEDULE EVERY 1 SECOND DO UPDATE lab.heartbeat SET ts = NOW(3) WHERE id = 1;
```

- mysqlchk on port 9200:

```mysql
exit
```

Open file `/etc/mysql/mysqlchk.cnf`:

```shell
[client]
user = mysqlchk
password = <chk-pass>
```

Run command:

```shell
sudo chmod 600 /etc/mysql/mysqlchk.cnf
```

Open file `/usr/local/bin/mysqlchk`:

```shell
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

Run command:

```shell
sudo chmod 755 /usr/local/bin/mysqlchk
```

Open file `/etc/systemd/system/mysqlchk.socket`:

```shell
[Unit]
Description=mysqlchk listener for HAProxy

[Socket]
ListenStream=192.168.30.11:9200
ListenStream=127.0.0.1:9200
Accept=yes

[Install]
WantedBy=sockets.target
```

Open file `/etc/systemd/system/mysqlchk@.service`:

```shell
[Unit]
Description=mysqlchk per-connection responder

[Service]
Type=simple
ExecStart=/usr/local/bin/mysqlchk
StandardInput=socket
StandardOutput=socket
StandardError=journal
```

Run command: 

```shell
sudo systemctl daemon-reload
sudo systemctl enable --now mysqlchk.socket

curl -sS -i http://127.0.0.1:9200/ | head -5 # expected HTTP/1.1 200 OK and Content-Length: 16

curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9200/    # expect 200

# On lb01
curl -sS -m 3 -o /dev/null -w '%{http_code}\n' http://192.168.30.11:9200/   # expect 200
```

#### 4. On `db02`:

- Open file `/etc/mysql/mysql.conf.d/zz-lab.cnf`

```shell
[mysqld]
server_id = 2
report_host = db02
bind_address = 192.168.30.12,127.0.0.1

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

- Run command:

```shell
sudo chown root:root /etc/mysql/mysql.conf.d/zz-lab.cnf
sudo chmod 644 /etc/mysql/mysql.conf.d/zz-lab.cnf
sudo systemctl restart mysql
systemctl status mysql --no-pager
```

- Edit Root client file: enter root password of mysql before run command

```shell
sudo tee /root/.my.cnf <<'EOF'
[client]
user = root
password = <mysql-root-pass>
EOF

sudo chmod 600 /root/.my.cnf
sudo mysql -e 'SELECT @@version, @@server_id, @@super_read_only'
```

- Start replication:

Login mysql with root permission:

```shell
mysql -u root -p  
# Enter mysql root password
```

Run command: enter password by replacing `<repl-pass>`

```mysql
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

- mysqlchk:

```mysql
exit
```

Open file `/etc/mysql/mysqlchk.cnf`:

```shell
[client]
user = mysqlchk
password = <chk-pass>
```

Run command:

```shell
sudo chmod 600 /etc/mysql/mysqlchk.cnf
```

Open file `/usr/local/bin/mysqlchk`:

```shell
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

Run command:

```shell
sudo chmod 755 /usr/local/bin/mysqlchk
```

Open file `/etc/systemd/system/mysqlchk.socket`:

```shell
[Unit]
Description=mysqlchk listener for HAProxy

[Socket]
ListenStream=192.168.30.12:9200
ListenStream=127.0.0.1:9200
Accept=yes

[Install]
WantedBy=sockets.target
```

Open file `/etc/systemd/system/mysqlchk@.service`:

```shell
[Unit]
Description=mysqlchk per-connection responder

[Service]
Type=simple
ExecStart=/usr/local/bin/mysqlchk
StandardInput=socket
StandardOutput=socket
StandardError=journal
```

Run command: 

```shell
sudo systemctl daemon-reload
sudo systemctl enable --now mysqlchk.socket
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9200/    # expect 503
```

#### 5. Verify the database layer

```shell
mysql -u root -p
```

- On `db01`:

```mysql
SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source_status';     -- ON
SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source_clients';    -- 1
CREATE TABLE wordpress.probe (id INT PRIMARY KEY);
INSERT INTO wordpress.probe VALUES (1);
```

- On `db02`:

```mysql
SELECT * FROM wordpress.probe;           -- the row must be there
INSERT INTO wordpress.probe VALUES (2);  -- must fail with error 1290
SELECT TIMESTAMPDIFF(MICROSECOND, ts, NOW(3))/1000 AS lag_ms FROM lab.heartbeat;
```

- Then reboot **both nodes** (`sudo reboot`) and confirm each comes back read-only:

```shell
sudo mysql -e 'SELECT @@read_only, @@super_read_only'     # expect 1, 1
```

- Clean up and reopen write on `db01` after the reboot:

```mysql
-- db01 only, never db02
SET GLOBAL super_read_only = OFF;
SET GLOBAL read_only = OFF;

DROP TABLE wordpress.probe;
```

- Confirm the heartbeat resumed, since the event only runs while the node is writable:

```mysql
SELECT ts, NOW(3) FROM lab.heartbeat;
```

---

### lb01 and lb02

#### 1. Install packages

```shell
sudo apt install chrony haproxy keepalived
```

#### 2. Config NTP client

- Edit file `/etc/chrony/chrony.conf`:

```shell
# Comment the lines of pool server
# replace that lines by NTP server (fw01)
server 192.168.10.254 iburst
```

- Restart and check chrony: 

```shell
sudo systemctl restart chrony
sudo chronyc tracking
sudo chronyc sources -v
timedatectl status
```

#### 3. On `lb01`

- Allow binding a VIP it does not own:

```shell
sudo tee /etc/sysctl.d/99-haproxy.conf <<'EOF'
# ip_nonlocal_bind: BACKUP must bind the VIP it does not own yet
net.ipv4.ip_nonlocal_bind = 1
EOF

sudo sysctl --system
sudo sysctl net.ipv4.ip_nonlocal_bind # expected = 1
```

- Internal PKI: Generate the CA and the server certificate here, then copy them out. Keep the CA key off the repo.

```shell
sudo mkdir -p /root/ca /etc/haproxy/certs
sudo -i
cd /root/ca

openssl genrsa -out lab-ca.key 4096

openssl req -x509 -new -nodes -key lab-ca.key -sha256 -days 3650 -subj "/C=VN/O=Lab/CN=lab.internal Root CA" -out lab-ca.crt

openssl genrsa -out shop.key 2048
```

Open file `/root/ca/shop.cnf`:

```shell
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

```shell
# in sudo mode
openssl req -new -key shop.key -out shop.csr -config shop.cnf

openssl x509 -req -in shop.csr -CA lab-ca.crt -CAkey lab-ca.key -CAcreateserial \
  -out shop.crt -days 825 -sha256 -extfile shop.cnf -extensions v3_req

cat shop.crt lab-ca.crt shop.key > /etc/haproxy/certs/shop.pem

chmod 600 /etc/haproxy/certs/shop.pem
chown root:root /etc/haproxy/certs/shop.pem

openssl x509 -in shop.crt -noout -text | grep -A1 'Subject Alternative Name'
```

Copy to `lb02` and to `mgmt01`: The CA private key `/root/ca/lab-ca.key` never leaves lb01. lb02 needs the server PEM only, because nothing on it signs a certificate.

```shell
# on mgmt01
ssh vagrant@192.168.10.11 'sudo cat /etc/haproxy/certs/shop.pem' \
  | ssh vagrant@192.168.10.12 'sudo mkdir -p /etc/haproxy/certs \
      && sudo tee /etc/haproxy/certs/shop.pem >/dev/null \
      && sudo chmod 600 /etc/haproxy/certs/shop.pem'

ssh vagrant@192.168.10.11 'sudo cat /root/ca/lab-ca.crt' > /tmp/lab-ca.crt
```

- HAProxy:

Write to file `/etc/haproxy/haproxy.cfg`: enter password `<stats-pass>`

```shell
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

Validate:

```shell
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo systemctl restart haproxy
systemctl status haproxy --no-pager
ss -tlnp | grep haproxy
```

- HAProxy logging and rotation:

Write to file `/etc/rsyslog.d/49-haproxy.conf` if not exists the following content:

```shell
:programname, startswith, "haproxy" /var/log/haproxy.log
& stop
```

Run command:

```shell
systemctl restart rsyslog
logrotate -d /etc/logrotate.d/haproxy
logrotate -f /etc/logrotate.d/haproxy
ls -l /var/log/haproxy.log*
```

- Keepalived check script:

Write to file `/usr/local/bin/chk_haproxy.sh`:

```shell
#!/bin/bash
# a live process that stopped answering is still a failure
curl -sf -m 1 -o /dev/null http://127.0.0.1/haproxy-alive
```

Run command:

```shell
sudo chmod 755 /usr/local/bin/chk_haproxy.sh
sudo chown root:root /usr/local/bin/chk_haproxy.sh
```

- Keepalived:

Find the dmz interface name 

```shell
ip -brief address | grep 192.168.10.11
```

then write to file `/etc/keepalived/keepalived.conf`: enter `<dmz-nic>` and `<vrrp-pass>`

```shell
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

Run command:

```shell
sudo systemctl restart keepalived
ip -4 addr show | grep 192.168.10.100
journalctl -u keepalived -n 20 --no-pager
ss -tlnp | grep 192.168.10.100 
```

#### 4. On `lb02`

- Allow binding a VIP it does not own:

```shell
sudo tee /etc/sysctl.d/99-haproxy.conf <<'EOF'
# ip_nonlocal_bind: BACKUP must bind the VIP it does not own yet
net.ipv4.ip_nonlocal_bind = 1
EOF

sudo sysctl --system
sudo sysctl net.ipv4.ip_nonlocal_bind # expected = 1
```

- HAProxy:

Write to file `/etc/haproxy/haproxy.cfg`: enter password `<stats-pass>`

```shell
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
    bind 192.168.10.12:8404
    bind 127.0.0.1:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 5s
    stats auth admin:<stats-pass>
    stats admin if TRUE
```

Validate:

```shell
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo systemctl restart haproxy
systemctl status haproxy --no-pager
ss -tlnp | grep haproxy
```

- HAProxy logging and rotation:

Write to file `/etc/rsyslog.d/49-haproxy.conf` if not exists the following content:

```shell
:programname, startswith, "haproxy" /var/log/haproxy.log
& stop
```

Run command:

```shell
systemctl restart rsyslog
logrotate -d /etc/logrotate.d/haproxy
logrotate -f /etc/logrotate.d/haproxy
ls -l /var/log/haproxy.log*
```

- Keepalived check script:

Write to file `/usr/local/bin/chk_haproxy.sh`:

```shell
#!/bin/bash
# a live process that stopped answering is still a failure
curl -sf -m 1 -o /dev/null http://127.0.0.1/haproxy-alive
```

Run command:

```shell
sudo chmod 755 /usr/local/bin/chk_haproxy.sh
sudo chown root:root /usr/local/bin/chk_haproxy.sh
```

- Keepalived:

Find the dmz interface name 

```shell
ip -brief address | grep 192.168.10.12
```

then write to file `/etc/keepalived/keepalived.conf`: enter `<dmz-nic>` and `<vrrp-pass>`

```shell
global_defs {
    router_id lb02
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
    state BACKUP
    interface <dmz-nic>
    virtual_router_id 51
    priority 100
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

Run command: enter `<dmz-nic>`

```shell
sudo systemctl restart keepalived
ip -4 addr show | grep 192.168.10.100 #
# expect no output: lb01 holds the VIP
journalctl -u keepalived -n 20 --no-pager
ss -tlnp | grep 192.168.10.100  
```

#### 5. Verify the VIP layer

- From `mgmt01`:

```shell
ping -c 2 192.168.10.100
curl -I http://shop.lab.internal  # expect 301
curl -I https://shop.lab.internal --cacert /tmp/lab-ca.crt

mysql -h 192.168.10.100 -u wp -p -e 'SELECT @@hostname, @@read_only'# expected `0`
mysql -h 192.168.30.11 -u ops -p -e 'SELECT @@hostname, @@read_only' # expected 0
```

The MySQL query must answer `db01` and `0`. That proves `mysqlchk` steered HAProxy to the writable node rather than to whichever node answered first.
The web backend is DOWN at this point. That is expected; `/healthz.php` does not exist until web01 is configured.

#### 6. Prove the VIP actually moves

- On `mgmt01`:

```shell
while :; do
    curl -s -o /dev/null -w '%{http_code} ' -m 1 http://192.168.10.100/haproxy-alive
    sleep 0.2
done
```

- On `lb01`: break HAProxy while loop runs:

```shell
sudo systemctl stop haproxy
```

- Confirm on `lb02`:

```shell
ip -4 addr show | grep 192.168.10.100
```

- Then bring `lb01` back and watch preempt return the VIP

```shell
sudo systemctl start haproxy
```

---

### web01 and web02

#### 1. Install packages

- Do this first before installing any package

```shell
id www-data        # expect uid=33(www-data) gid=33(www-data)
```

- If any node disagrees, fix it before continuing, with no `www-data` process running:

```shell
sudo groupmod -g 33 www-data
sudo usermod -u 33 -g 33 www-data
```

- After that, install packages:

```shell
sudo apt install chrony nginx php8.3-fpm php8.3-mysql php8.3-gd php8.3-mbstring php8.3-xml php8.3-intl php8.3-opcache php8.3-zip php8.3-curl nfs-common curl unzip

curl -fsSL -o /usr/local/bin/wp \
  https://github.com/wp-cli/wp-cli/releases/download/v2.12.0/wp-cli-2.12.0.phar

chmod 755 /usr/local/bin/wp

wp --info --allow-root
```

#### 2. Config NTP client

- Edit file `/etc/chrony/chrony.conf`:

```
# Comment the lines of pool server
# replace that lines by NTP server (fw01)
server 192.168.20.254 iburst
```

- Restart and check chrony: 

```shell
sudo systemctl restart chrony
sudo chronyc tracking
sudo chronyc sources -v
timedatectl status
```

#### 3. Config NFS client:

- Mount from the web nodes:

```shell
id www-data  # expect 33:33, fix before anything else
sudo mkdir -p /var/www/wordpress/wp-content/uploads
```

- Make the mount point unwritable **before** mounting anything on it:

```shell
chown root:root /var/www/wordpress/wp-content/uploads
chmod 0555 /var/www/wordpress/wp-content/uploads
```

- Add to file `/etc/fstab`:

```shell
192.168.20.21:/srv/nfs/uploads  /var/www/wordpress/wp-content/uploads  nfs4  nfsvers=4.2,hard,noatime,_netdev  0  0
```

- Run command:

```shell
sudo mount -a
sudo systemctl daemon-reload
findmnt /var/www/wordpress/wp-content/uploads
```

- Verify the NFS layer:

```shell
# On web01
sudo -u www-data touch /var/www/wordpress/wp-content/uploads/from-web01
# On web02
ls -l /var/www/wordpress/wp-content/uploads/from-web01
sudo -u www-data touch /var/www/wordpress/wp-content/uploads/from-web02

# On nfs01
ls -ln /srv/nfs/uploads # The numeric owner must be `33 33` on both files
```

- Clean up:

```shell
sudo -u www-data rm -f /var/www/wordpress/wp-content/uploads/from-web0*
```

- Confirm the denied path as well, from `mgmt01`:

```shell
nc -zv -w 3 192.168.20.21 2049      # must fail
```

#### 4. On `web01`

- Nginx:

In `/etc/nginx/nginx.conf`:

```shell
user www-data;
```

Run command:

```shell
sudo rm -f /etc/nginx/conf.d/default.conf
```

Write `/etc/nginx/conf.d/shop.conf`:

```shell
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

Run command:

```shell
sudo nginx -t
sudo systemctl restart nginx
ss -tlnp | grep nginx
```

- PHP-FPM:

In `/etc/php/8.3/fpm/pool.d/www.conf`:

```shell
[www]
user  = www-data
group = www-data
listen = /run/php/php8.3-fpm.sock
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

In `/etc/php/8.3/fpm/conf.d/99-lab.ini`:

```shell
memory_limit = 256M
upload_max_filesize = 32M
post_max_size = 32M
max_execution_time = 60
opcache.enable = 1
opcache.memory_consumption = 128
expose_php = Off
```

Run command:

```shell
sudo php-fpm8.3 -t
sudo systemctl restart php8.3-fpm
sudo systemctl status php8.3-fpm --no-pager
ls -l /run/php/php8.3-fpm.sock

ps -o rss=,args= -C php-fpm8.3 | awk '/pool www/ {s+=$1; n++} END \
  {if (n) printf "%.0f MB avg over %d workers\n", s/n/1024, n; \
   else print "[WARN] no php-fpm worker running"}'
```

- Health check endpoint

In `/var/www/wordpress/healthz.php`:

```shell
<?php
// shallow on purpose: a db or nfs check here would drop both web nodes at once
header('Content-Type: text/plain');
echo "ok\n";
```

Run command:

```shell
sudo chown www-data:www-data /var/www/wordpress/healthz.php
curl -s http://127.0.0.1/healthz.php # expected ok
```

- WordPress and WooCommerce

Pin the versions; never use "latest", run command:

```shell
cd /tmp
WP_VERSION=7.0
curl -fsSLO "https://wordpress.org/wordpress-${WP_VERSION}.tar.gz"

curl -fsSLO "https://wordpress.org/wordpress-${WP_VERSION}.tar.gz.sha256"
sha256sum -c "wordpress-${WP_VERSION}.tar.gz.sha256"

sudo tar -xzf "wordpress-${WP_VERSION}.tar.gz" --strip-components=1 -C /var/www/wordpress

sudo chown -R www-data:www-data /var/www/wordpress
```

Install WooCommerce **before** `DISALLOW_FILE_MODS` goes in

```shell
WC_VERSION=11.1.0
cd /tmp
curl -fsSLO "https://downloads.wordpress.org/plugin/woocommerce.${WC_VERSION}.zip"

sudo unzip -q "woocommerce.${WC_VERSION}.zip" -d /var/www/wordpress/wp-content/plugins/

sudo chown -R www-data:www-data /var/www/wordpress/wp-content/plugins/woocommerce
```

Generate the salts first, then paste them in:

```shell
curl -s https://api.wordpress.org/secret-key/1.1/salt/
```

Write `/var/www/wordpress/wp-config.php`: remember paste above output into this file, and enter password `<wp-pass>`

```shell
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

Run command:

```shell
sudo chown root:www-data /var/www/wordpress/wp-config.php
sudo chmod 640 /var/www/wordpress/wp-config.php
```

Install the site, once: db01 must be writable for this. If it is not, open it per db01 step 3. Run command: Enter password `<wp-admin-pass>`

```shell
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

Make an order possible

```shell
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

WP-Cron on web01 only, write to `/etc/cron.d/wordpress-cron`:

```shell
*/5 * * * * www-data cd /var/www/wordpress && /usr/local/bin/wp cron event run --due-now >/dev/null 2>&1
```

#### 5. On `web02`

- Nginx:

In `/etc/nginx/nginx.conf`:

```shell
user www-data;
```

Run command:

```shell
sudo rm -f /etc/nginx/conf.d/default.conf
```

Write `/etc/nginx/conf.d/shop.conf`:

```shell
server {
    listen 192.168.20.12:80 default_server;
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

Run command:

```shell
sudo nginx -t
sudo systemctl restart nginx
ss -tlnp | grep nginx
```

- PHP-FPM:

In `/etc/php/8.3/fpm/pool.d/www.conf`:

```shell
[www]
user  = www-data
group = www-data
listen = /run/php/php8.3-fpm.sock
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

In `/etc/php/8.3/fpm/conf.d/99-lab.ini`:

```shell
memory_limit = 256M
upload_max_filesize = 32M
post_max_size = 32M
max_execution_time = 60
opcache.enable = 1
opcache.memory_consumption = 128
expose_php = Off
```

Run command:

```shell
sudo php-fpm8.3 -t
sudo systemctl restart php8.3-fpm
sudo systemctl status php8.3-fpm --no-pager
ls -l /run/php/php8.3-fpm.sock

ps -o rss=,args= -C php-fpm8.3 | awk '/pool www/ {s+=$1; n++} END \
  {if (n) printf "%.0f MB avg over %d workers\n", s/n/1024, n; \
   else print "[WARN] no php-fpm worker running"}'
```

- Health check endpoint

In `/var/www/wordpress/healthz.php`:

```shell
<?php
// shallow on purpose: a db or nfs check here would drop both web nodes at once
header('Content-Type: text/plain');
echo "ok\n";
```

Run command:

```shell
sudo chown www-data:www-data /var/www/wordpress/healthz.php
curl -s http://127.0.0.1/healthz.php # expected ok
```

- Copy the code from `web01`

On `web02`

```shell
sudo umount /var/www/wordpress/wp-content/uploads
```

On `web01`

```shell
sudo tar -C /var/www -cz --exclude="wordpress/wp-content/uploads/*" wordpress \
  | ssh vagrant@192.168.20.12 'sudo tar -C /var/www -xz'
```

On `web02`

```shell
# trên web02
sudo chown -R www-data:www-data /var/www/wordpress

sudo chown root:www-data /var/www/wordpress/wp-config.php
sudo chmod 640 /var/www/wordpress/wp-config.php

sudo mount -a
findmnt /var/www/wordpress/wp-content/uploads
sudo systemctl restart php8.3-fpm nginx
```

---

### mgmt01

#### 1. Install package

```shell
sudo apt install -y git python3-venv python3-pip python3-pymysql \
  mysql-client curl nmap traceroute mtr-tiny jq

python3 -m venv ~/ansible-venv
~/ansible-venv/bin/pip install --upgrade pip
~/ansible-venv/bin/pip install 'ansible-core>=2.20,<2.21' ansible-lint

gpg -k

curl -fsSL https://dl.k6.io/key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/k6.gpg

echo "deb [signed-by=/usr/share/keyrings/k6.gpg] https://dl.k6.io/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/k6.list

sudo apt update 
sudo apt install -y k6

~/ansible-venv/bin/ansible --version
k6 version
```

#### 2. Config NTP client

- Edit file `/etc/chrony/chrony.conf`:

```
# Comment the lines of pool server
# replace that lines by NTP server (fw01)
server 172.16.10.254 iburst
```

- Restart and check chrony: 

```shell
sudo systemctl restart chrony
sudo chronyc tracking
sudo chronyc sources -v
timedatectl status
```

#### 3. Trust the internal CA

```shell
sudo cp /tmp/lab-ca.crt /usr/local/share/ca-certificates/lab-ca.crt
sudo update-ca-certificates
curl -I https://shop.lab.internal        # must validate with no --cacert
```

#### 4. Confirm DNS and routing

```shell
ip route | grep 192.168
dig +short shop.lab.internal             # expect 192.168.10.100
resolvectl status | head -20
```

#### 5. Ansible reachability

```shell
source ~/ansible-venv/bin/activate
cd ~/linux_project/ansible
ansible all -m ping
```

---

### mon01

2. Config NTP client

- Edit file `/etc/chrony/chrony.conf`:

```
# Comment the lines of pool server
# replace that lines by NTP server (fw01)
server 172.16.10.254 iburst
```

- Restart and check chrony: 

```shell
sudo systemctl restart chrony
sudo chronyc tracking
sudo chronyc sources -v
timedatectl status
```