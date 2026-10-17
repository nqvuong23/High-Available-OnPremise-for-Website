---
paths:
  - "Vagrantfile"
  - "ansible/**"
  - "scripts/**"
  - "docs/**"
  - "chaos/**"
---

# Detailed architecture

## Overall diagram

```
CLIENT / ADMIN ZONE  vmnet4  172.16.10.0/24
  mgmt01 172.16.10.11  Ansible + k6 + scripts, keeps its NAT NIC
  Windows host adapter 172.16.10.1
  shop.lab.internal -> 192.168.10.100 (from bind9 on fw01)
                                |
                                | default route via 172.16.10.254
                                v
  +-------------------------------------------------------------------+
  | fw01   Ubuntu 24.04, kernel forwarding and masquerade only        |
  |   172.16.10.254   192.168.10.254   192.168.20.254  192.168.30.254 |
  |   plus a permanent NAT NIC on vmnet8, masquerades for every zone  |
  |   also serves chrony NTP and bind9 DNS to all four zones          |
  +----+---------------------+------------------------+---------------+
       |                     |                        |
DMZ ZONE vmnet1        APP ZONE vmnet2           DB ZONE vmnet3
192.168.10.0/24        192.168.20.0/24           192.168.30.0/24
       |                     |                        |
  VIP .100 (VRRP, VRID 51)   |                        |
  +----v-----+  +---------+  |  +--------+ +--------+ |  +--------+ +--------+
  | lb01 .11 |<>| lb02 .12|  |  |web01.11| |web02.12| |  |db01 .11| |db02 .12|
  | HAProxy  |  | HAProxy |  |  |Nginx   | |Nginx   | |  |PRIMARY | |REPLICA |
  | Keepalvd |  | Keepalvd|  |  |PHP-FPM | |PHP-FPM | |  |writable| |ro      |
  | prio 110 |  | prio 100|  |  +---+----+ +----+---+ |  +---+----+ +----+---+
  +----------+  +---------+  |      |  NFSv4.2  |     |      | GTID+semisync |
   VRRP 224.0.0.18 proto 112 |      +-----+-----+     |      +-------+-------+
   stays inside vmnet1       |      | nfs01 .21 |     |  mysqlchk :9200 on both
                             |      +-----------+     |  200 = writable, 503 = ro
```

- Every arrow that crosses a zone boundary passes through `fw01`. Only VRRP, web to NFS and db01 to db02 stay inside one zone.
- `fw01` forwards and masquerades but filters nothing, so an arrow not drawn here is merely undesigned, not blocked. See ADR-25.
- Every lab VM also carries a temporary NAT NIC during provisioning, removed at the end of M1. `fw01` and `mgmt01` keep theirs.
- 9 VMs in total. `mgmt01` is the only node in the client zone. `mon01` used to sit beside it; monitoring and logging moved to a separate project, see ADR-26.

## Data flows

- F1 — user request: client -> VIP:443 on the MASTER node -> HAProxy terminates TLS -> `be_web` roundrobin with a sticky cookie -> Nginx:80 -> PHP-FPM over a unix socket. Crosses dmz to app through `fw01`.
- F2 — file upload: Nginx or PHP-FPM reads `/var/www/wordpress/wp-content/uploads`, mounted from nfs01:2049 inside the app zone.
- F3 — database query: PHP-FPM -> VIP:3306 -> the HAProxy `listen mysql` section in TCP mode -> the writable MySQL node. Crosses app to dmz and then dmz to db, two router hops.
- F4 — replication: db01:3306 -> db02 inside the db zone, the IO thread pulls the binlog, semi-sync waits for the replica to acknowledge receipt.
- F5 — VRRP: lb01 and lb02 over multicast 224.0.0.18, IP protocol 112, advertising every second. Link-local, so it never reaches the router.
- F6 — health checks: HAProxy calls `/healthz.php` on web:80 and `mysqlchk` on db:9200, both across zones.
- F7 — administration: mgmt01 -> port 22 on every node, -> port 8404 on the LBs for stats, -> port 3306 on the DBs for the measurement scripts. All routed from the client zone.
- F8 — internet egress: a lab node -> its zone gateway `.254` -> `fw01` masquerade -> vmnet8 NAT -> internet. This is the only path left after the NAT NICs are removed.
- F9 — time and name: every node -> its own zone `.254`, UDP 123 to chrony and port 53 to bind9. Addressed to the router itself, so it terminates there rather than being forwarded.

## Reading a product page

- The browser resolves `shop.lab.internal` to `192.168.10.100` from the hosts file.
- The request leaves the client zone, `fw01` forwards it into the dmz zone.
- The node holding the VIP accepts the TLS connection at HAProxy and decrypts it.
- HAProxy picks a web node that is UP and adds `X-Forwarded-For` and `X-Forwarded-Proto: https`.
- Nginx serves static files from NFS and passes `.php` over the socket to PHP-FPM.
- PHP queries MySQL through `192.168.10.100:3306`, which sends it back out through the router to HAProxy, which forwards it to the primary.

## Placing an order

- The first steps match the read flow, but the request is a POST.
- PHP writes the order into the primary through HAProxy.
- The primary writes the binlog and then ships the event to the replica.
- With semi-sync the primary **waits for the replica to acknowledge receipt** before returning the commit to the application.
- The user only sees "order placed" once the data exists on at least two machines.

## State before and after database failover

```
BEFORE THE INCIDENT                      AFTER FAILOVER (runbook RB-02)

HAProxy listen mysql                     HAProxy listen mysql
  db01  UP     <- takes writes             db01  MAINT (disabled)
  db02  MAINT  (disabled)                  db02  UP     <- takes writes

db01  PRIMARY  read_only=OFF             db01  DEAD; on restart: super_read_only=ON
  |  GTID binlog                               (check errant GTID before rejoining)
  v
db02  REPLICA  super_read_only=ON        db02  PRIMARY  read_only=OFF, no replication
```

## Why a single VPS does not meet the requirement

- Nginx or PHP-FPM dying takes the whole website down.
- A reboot for a kernel update costs minutes of downtime on every maintenance.
- A full or failing disk loses order data and takes the site down at the same time.
- A MySQL crash mid-write can lose transactions that were not yet flushed to disk.

## Easy to get wrong: source IP on database connections

- DB connections pass through HAProxy, so MySQL sees the **real LB IP** as the source: `192.168.10.11` or `192.168.10.12`.
- The source is **not** the web node IP and **not** the VIP.
- The application MySQL user must therefore be granted on `192.168.10.%` or on exactly those two LB addresses.
- This is the root cause of one chaos scenario; keep it as a diagnosis exercise.

## Easy to get wrong: the router is in the write path

- Because the VIP lives in the dmz zone, a web-to-DB query crosses `fw01` twice.
- That means `fw01` is a SPOF for order writes, not just for administration.
- It also means DB latency includes two routed hops, which must be visible in the k6 baseline.
- Both facts belong in the known limitations list, not hidden.

## Easy to get wrong: a dead router looks like every node dying at once

- Every check run from `mgmt01` crosses `fw01`, because the client zone is on the far side of it.
- So a `fw01` outage makes every target unreachable at the same moment. Read that pattern as a routing failure, not as eight simultaneous host failures. Scenario 01 exists to train exactly that reflex.
- `fw01` also serves DNS and NTP, so its death takes name resolution and clock sync with it. Those are separate failure domains in a real deployment and are deliberately collapsed here.
- The second vantage point is `healthcheck.py` running locally on each node, which keeps working when the router does not.
- All of this belongs in the known limitations list, not hidden.

## Easy to get wrong: default route versus zone routes

- While the NAT NIC exists, the default route points at the NAT gateway and cross-zone traffic needs explicit static routes via `.254`.
- After the NAT NIC is removed, the default route points at `.254` and no static routes are needed.
- A node stuck between those two states can ping its own zone but nothing else, which looks exactly like a firewall problem and is not. The lab runs no firewall at all (ADR-25), so `nft list ruleset` rules that out in one command and routing is the only remaining answer.
