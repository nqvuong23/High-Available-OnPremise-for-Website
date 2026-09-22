# Lộ trình và tiêu chí nghiệm thu

> Rule này cố ý **không** có `paths` nên luôn được nạp: đây là lộ trình để biết đang ở đâu và bước tiếp theo là gì.
> Thứ tự bắt buộc từ dưới lên: OS → Database → LB/VIP → Storage → Web/App. Web cần DB qua VIP nên LB phải xong trước WordPress.

## M1 — Dựng lab và chuẩn hoá hệ điều hành

- Sản phẩm: `Vagrantfile`, role `common`, ma trận firewall được áp dụng thật.
- Đạt khi: 8 VM chạy, SELinux Enforcing trên node Rocky, chrony đồng bộ, firewall chỉ mở đúng cổng.
- Đạt khi: xoá sạch rồi dựng lại toàn bộ bằng lệnh, không thao tác tay nào, có bấm giờ.
- Snapshot khi xong: `base`.

## M2 — Tầng database bền vững

- Sản phẩm: role `mysql`, role `mysqlchk`, tài liệu bootstrap database.
- Đạt khi: replication `Replica_IO_Running` và `Replica_SQL_Running` đều `Yes`, semi-sync bật.
- Đạt khi: cả hai node boot ở trạng thái chỉ đọc, ghi thẳng vào replica bị từ chối với lỗi 1290.
- Đạt khi: heartbeat đo được replication lag; `mysqlchk` trả 200 trên primary và 503 trên replica.
- Snapshot khi xong: `db-ready`.

## M3 — Tầng load balancer và VIP

- Sản phẩm: role `haproxy`, role `keepalived`, PKI nội bộ tự ký.
- Đạt khi: HTTPS hợp lệ với CA nội bộ, HTTP chuyển 301 sang HTTPS.
- Đạt khi: dừng HAProxy trên lb01 thì VIP sang lb02 trong dưới 6 giây, có số liệu request lỗi kèm theo.
- Phần "dừng Nginx một node, HAProxy đánh DOWN trong khoảng 6 giây" chỉ kiểm được sau khi M4 xong.
- Snapshot khi xong: `lb-ready`.

## M4 — Tầng web, ứng dụng và lưu trữ

- Sản phẩm: role `nfs_server`, `nfs_client`, `nginx_php`, `wordpress`.
- Đạt khi: WooCommerce tạo được đơn hàng thật qua HTTPS.
- Đạt khi: ảnh upload lúc request vào web01 xem được khi request vào web02 và ngược lại.
- Đạt khi: checksum cây code trên hai node giống hệt nhau.
- Snapshot khi xong: `app-ready`.

## M5 — Tài liệu vận hành

- Sản phẩm: runbook RB-01 đến RB-04, SOP thay đổi cấu hình, tài liệu bàn giao, ADR.
- Đạt khi: người khác đọc runbook tự thực hiện được failover mà không cần hỏi lại.

## M6 — Mô phỏng lỗi và troubleshooting thủ công

- Sản phẩm: thư mục `chaos/` và `postmortems/`.
- Đạt khi: tối thiểu 12 kịch bản có script gây lỗi, script khôi phục và postmortem đầy đủ.
- Đạt khi: đo được RTO và RPO của kịch bản primary chết đột ngột.

## M7 — Automation

- Sản phẩm: playbook idempotent, `diagnose.yml`, `healthcheck.py`, `auto_remediate.sh`, `db_failover.py`, kịch bản k6.
- Đạt khi: `site.yml` chạy lần hai báo `changed=0`.
- Đạt khi: healthcheck phát hiện ít nhất 10 kịch bản lỗi trong vòng 2 phút.
- Đạt khi: có báo cáo load test trước và sau tuning kèm giải thích.

## Mục tiêu bổ sung

- G5 — semi-sync: `Rpl_semi_sync_source_status = ON`, có bảng so sánh RPO giữa async và semi-sync.
- G6 — Keepalived: VIP chuyển dưới 5 giây, kèm tỷ lệ lỗi k6 đo trong lúc chuyển.
- G7 — failover DB: diễn tập tối thiểu 3 lần, RTO trung bình dưới 5 phút, có runbook đưa primary cũ về làm replica.
- G8 — Ansible: `changed=0` ở lần chạy thứ hai, mật khẩu trong Vault, template có bước kiểm tra cú pháp.
- G9 — hiệu năng: bảng k6 trước và sau tuning với p95, RPS, tỷ lệ lỗi.
- G10 — chaos: kế hoạch 19 kịch bản, bắt buộc tối thiểu 10, hoàn thành tối thiểu 12.
- G11 — automation hỗ trợ xử lý sự cố: `diagnose.yml`, `triage.py`, `auto_remediate.sh`, `db_failover.py`, `order_writer.py`, `rpo_check.py`.
- G12 — tài liệu: README, sơ đồ, ADR, runbook, danh sách hạn chế.

## Ngoài phạm vi, phải ghi rõ trong README

- NFS server đơn là SPOF đã biết; hướng xử lý sau này là GlusterFS, DRBD kèm Pacemaker hoặc object storage.
- Không làm failover DB tự động; hướng xử lý sau này là Orchestrator hoặc ProxySQL kèm fencing.
- Fencing chỉ mô phỏng bằng tắt VM và trạng thái chỉ đọc khi boot, không có STONITH thật.
- Toàn bộ lab nằm trên một máy vật lý nên không chống được lỗi mức host.
- Backup và restore mới dừng ở mức dựng lại replica, chưa có giải pháp backup thật.
- Giám sát mới ở mức script healthcheck, chưa có Zabbix hay Grafana.
