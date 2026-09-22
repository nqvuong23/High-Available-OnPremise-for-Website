---
paths:
  - "Vagrantfile"
  - "ansible/**"
  - "scripts/**"
  - "docs/**"
  - "chaos/**"
---

# Kiến trúc chi tiết

## Sơ đồ tổng thể

```
        Người dùng / Windows host (10.10.10.1) · mgmt01 (10.10.10.5, Debian 13)
                       shop.lab.internal -> 10.10.10.100
                                     |
                       HTTPS :443  (HTTP :80 -> 301 HTTPS)
                                     |
              +--------- VIP 10.10.10.100 (VRRP, VRID 51) ----------+
              |                                                     |
   +----------v-----------+    VRRP 224.0.0.18     +----------------v-----+
   | lb01  10.10.10.11    | <====================> | lb02  10.10.10.12    |
   | Ubuntu 24.04         |   IP protocol 112      | Ubuntu 24.04         |
   | HAProxy + Keepalived |   advert mỗi 1 giây    | HAProxy + Keepalived |
   | priority 110 MASTER  |                        | priority 100 BACKUP  |
   +----+------------+----+                        +----+------------+----+
        | be_web :80 | listen mysql :3306               |            |
        |            | (tới node writable, check :9200) |            |
  +-----v-----+  +---v-------+                          |            |
  | web01 .21 |  | web02 .22 | <------------------------+            |
  | Rocky 9   |  | Rocky 9   |                                       |
  | Nginx     |  | Nginx     |                                       |
  | PHP-FPM   |  | PHP-FPM   |                                       |
  +--+-----+--+  +--+-----+--+                                       |
     |     |        |     |  PHP nối DB qua VIP:3306 ----------------+
     |     +---+----+     |
     |   NFS v4.2 :2049   |
     |   +------v------+  |
     |   | nfs01 .41   |  |
     |   | Ubuntu 24.04|  |
     |   | /srv/nfs/   |  |
     |   |   uploads   |  |
     |   +-------------+  |
     |                    |
  +--v--------------------v-----------------------------------------+
  | db01 10.10.10.31 (Rocky 9, PRIMARY, writable)                   |
  |    |  GTID + semi-sync replication :3306                        |
  |    v                                                            |
  | db02 10.10.10.32 (Rocky 9, REPLICA, super_read_only)            |
  | mysqlchk :9200 trên mỗi node: 200 = writable, 503 = chỉ đọc     |
  +-----------------------------------------------------------------+
```

## Luồng dữ liệu

- F1 — request người dùng: client → VIP:443 trên node MASTER → HAProxy giải mã TLS → `be_web` roundrobin kèm cookie sticky → Nginx:80 → PHP-FPM qua unix socket.
- F2 — file upload: Nginx hoặc PHP-FPM đọc `/var/www/wordpress/wp-content/uploads` đang mount NFS từ nfs01:2049.
- F3 — truy vấn database: PHP-FPM → VIP:3306 → `listen mysql` của HAProxy ở chế độ TCP → node MySQL đang writable.
- F4 — replication: db01:3306 → db02, IO thread kéo binlog, semi-sync chờ replica xác nhận đã nhận.
- F5 — VRRP: lb01 ↔ lb02 qua multicast 224.0.0.18, IP protocol 112, quảng bá mỗi 1 giây.
- F6 — health check: HAProxy gọi `/healthz.php` trên web:80 và `mysqlchk` trên db:9200.
- F7 — quản trị: mgmt01 và Windows host → mọi node cổng 22, → LB cổng 8404 xem stats, → DB cổng 3306 để monitor.

## Luồng đọc một trang sản phẩm

- Trình duyệt phân giải `shop.lab.internal` thành `10.10.10.100` qua file hosts.
- Node đang giữ VIP nhận kết nối TLS tại HAProxy và giải mã.
- HAProxy chọn web node đang UP, thêm header `X-Forwarded-For` và `X-Forwarded-Proto: https`.
- Nginx phục vụ file tĩnh từ NFS, đẩy file `.php` qua socket tới PHP-FPM.
- PHP truy vấn MySQL qua `10.10.10.100:3306`, HAProxy chuyển tới primary.

## Luồng đặt hàng

- Bốn bước đầu giống luồng đọc nhưng là request POST.
- PHP ghi đơn hàng vào primary thông qua HAProxy.
- Primary ghi binlog rồi gửi sự kiện sang replica.
- Với semi-sync, primary **chờ replica xác nhận đã nhận** rồi mới trả kết quả commit về ứng dụng.
- Người dùng chỉ thấy "đặt hàng thành công" sau khi dữ liệu đã nằm trên ít nhất hai máy.

## Trạng thái trước và sau failover database

```
TRƯỚC SỰ CỐ                              SAU FAILOVER (theo runbook RB-02)

HAProxy listen mysql                     HAProxy listen mysql
  db01  UP     <- nhận ghi                 db01  MAINT (disabled)
  db02  MAINT  (disabled)                  db02  UP     <- nhận ghi

db01  PRIMARY  read_only=OFF             db01  CHẾT; khi bật lại: super_read_only=ON
  |  binlog GTID                               (kiểm tra errant GTID rồi mới làm replica)
  v
db02  REPLICA  super_read_only=ON        db02  PRIMARY  read_only=OFF, không còn replication
```

## Vì sao một VPS đơn lẻ không đáp ứng được

- Nginx hoặc PHP-FPM chết là toàn bộ website ngừng hoạt động.
- Reboot vì cập nhật kernel gây downtime vài phút mỗi lần bảo trì.
- Disk hỏng hoặc đầy vừa làm mất dữ liệu đơn hàng vừa làm website ngừng.
- MySQL crash giữa lúc ghi có thể mất giao dịch chưa flush xuống disk.

## Điểm dễ hiểu sai: IP nguồn khi kết nối database

- Kết nối DB đi qua HAProxy nên MySQL thấy IP nguồn là **IP thật của LB** (`10.10.10.11` hoặc `.12`).
- IP nguồn **không phải** IP của web node và cũng **không phải** VIP.
- Vì vậy user MySQL của ứng dụng phải được GRANT theo dải `10.10.10.%` hoặc đúng hai IP của LB.
- Đây là nguyên nhân gốc của một kịch bản chaos, cần giữ nguyên để luyện chẩn đoán.
