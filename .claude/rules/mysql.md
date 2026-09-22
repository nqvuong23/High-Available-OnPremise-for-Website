---
paths:
  - "ansible/roles/mysql/**"
  - "ansible/roles/mysqlchk/**"
  - "scripts/**"
  - "docs/runbooks/**"
---

# MySQL 8.4: replication, semi-sync và failover

> Đây là tầng giữ dữ liệu tiền bạc. Mọi thao tác ở đây ưu tiên an toàn hơn tốc độ.

## Quy tắc an toàn bắt buộc

- **Không bao giờ tự động failover.** Mọi thao tác promote phải có người xác nhận tường minh.
- **Không bao giờ để hai node cùng writable.** Trước khi promote phải chắc chắn primary cũ đã chết hoặc đã bị tắt.
- Mọi node luôn khởi động với `super_read_only=ON`; quyền ghi chỉ được mở ở runtime.
- Trước khi cho primary cũ quay lại làm replica, **bắt buộc kiểm tra errant GTID** bằng `GTID_SUBTRACT`.
- Semi-sync có thể tự hạ xuống async khi replica chết quá timeout; phải giám sát `Rpl_semi_sync_source_status`, nếu không thì lời hứa RPO bằng 0 không còn đúng.
- Script `auto_remediate.sh` tuyệt đối không được tự restart hay can thiệp vào MySQL.

## Cài đặt trên Rocky 9

- Chạy `dnf module disable -y mysql` trước, vì module AppStream mặc định xung đột với repo chính thức.
- Thêm repo `mysql84-lts-community` của Oracle rồi cài gói `mysql-community-server`.
- Cài `python3-PyMySQL` để module `community.mysql` hoạt động.
- Bootstrap: đọc mật khẩu tạm trong `/var/log/mysqld.log`, đổi sang mật khẩu lấy từ Vault, ghi `/root/.my.cnf` quyền 600.

## Cấu hình cốt lõi

- Định danh và binlog: `server_id` khác nhau giữa hai node, bật `log_bin`, `binlog_format=ROW`.
- GTID: `gtid_mode=ON` và `enforce_gtid_consistency=ON`.
- Độ bền dữ liệu: `sync_binlog=1` và `innodb_flush_log_at_trx_commit=1`, không được hạ xuống để lấy hiệu năng.
- Chỉ đọc khi boot: `read_only=ON` và `super_read_only=ON` đặt trong file cấu hình của **cả hai** node.
- Khác: `relay_log_recovery=ON`, `skip_name_resolve`, `event_scheduler=ON` cho heartbeat.
- Kích thước buffer pool đặt khoảng một nửa RAM của node, tức khoảng 768 MB với node 1536 MB.

## Semi-sync

- Nạp plugin bằng `plugin_load_add` với `semisync_source.so` và `semisync_replica.so`.
- Bật **cả hai** vai trò trên **cả hai** node để lúc đổi vai không phải cài thêm plugin.
- Đặt `rpl_semi_sync_source_wait_point=AFTER_SYNC` và `rpl_semi_sync_source_timeout=3000`.
- Kiểm chứng: `Rpl_semi_sync_source_status` phải `ON` và `Rpl_semi_sync_source_clients` phải bằng 1.

## Cú pháp MySQL 8.4

- Các lệnh sau **đã bị gỡ** và sẽ báo lỗi cú pháp: `CHANGE MASTER TO`, `START SLAVE`, `STOP SLAVE`, `SHOW SLAVE STATUS`, `RESET MASTER`, `SHOW MASTER STATUS`, các tham số `MASTER_*`, và `IGNORE_SERVER_IDS`.
- Thay bằng: `CHANGE REPLICATION SOURCE TO` với các tham số `SOURCE_*`, `START REPLICA`, `STOP REPLICA`, `SHOW REPLICA STATUS`, `RESET BINARY LOGS AND GTIDS`, `SHOW BINARY LOG STATUS`.
- Xác thực mặc định là `caching_sha2_password`, còn `mysql_native_password` đã tắt mặc định.
- User replication vì thế cần `GET_SOURCE_PUBLIC_KEY=1` hoặc phải bật TLS.

## Tài khoản

- User ứng dụng, user replication và user vận hành đều GRANT theo dải `10.10.10.%` hoặc đúng hai IP của LB.
- Lý do: kết nối đi qua HAProxy nên MySQL thấy IP nguồn là IP của LB, không phải IP web node.
- User của `mysqlchk` chỉ cần quyền đọc biến trạng thái và nên giới hạn ở `localhost`.

## mysqlchk

- Lắng nghe cổng 9200, trả HTTP 200 khi node writable và 503 khi node đang chỉ đọc.
- Điều kiện để trả 200: cả `@@read_only` và `@@super_read_only` đều bằng 0.
- Triển khai bằng systemd socket cho nhẹ; không cần cài thêm web server.
- Trên Rocky phải khai báo nhãn SELinux cho cổng 9200 bằng `semanage port`.

## Nghiệm thu

- Ghi trên primary rồi đọc được trên replica.
- Ghi thẳng vào replica phải bị từ chối với lỗi 1290.
- `SHOW REPLICA STATUS` cho `Replica_IO_Running` và `Replica_SQL_Running` đều `Yes`.
- Reboot từng node DB, cả hai phải quay lại ở trạng thái chỉ đọc.
- `curl localhost:9200` trả 200 trên primary và 503 trên replica.

## Diễn tập failover

- Chạy `order_writer.py` tạo đơn liên tục, chỉ ghi ID vào log **sau khi** commit thành công.
- Tắt cứng VM primary bằng `vagrant halt --force db01` để mô phỏng chết đột ngột.
- Làm theo runbook RB-02, bấm giờ để lấy RTO, rồi chạy `rpo_check.py` để lấy RPO.
- Lặp lại tối thiểu 3 lần với semi-sync, và thêm một lần với async để có bảng so sánh.
