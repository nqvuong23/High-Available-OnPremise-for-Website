---
paths:
  - "chaos/**"
  - "postmortems/**"
  - "docs/runbooks/**"
  - "scripts/**"
  - "loadtest/**"
---

# Mô phỏng sự cố, runbook và vận hành

> Đây là phần tạo khác biệt lớn nhất khi phỏng vấn: bằng chứng đã tự xử lý sự cố thật và rút ra bài học.

## Quy trình cho mỗi kịch bản

- Khôi phục về snapshot `baseline` hoặc xác nhận hệ thống đang khoẻ.
- Chạy `probe.sh` ở nền trước khi gây lỗi, để đo tác động thật lên người dùng.
- Gây lỗi bằng `inject.sh`; tốt nhất nhờ người khác chọn hộ kịch bản mà mình không biết trước.
- Xử lý như người trực ca, **không đọc nguyên nhân gốc trước khi tự chẩn đoán xong**.
- Khôi phục dịch vụ, xác định nguyên nhân gốc, rồi rollback bằng Ansible chứ không sửa tay.
- Viết postmortem ngay sau khi xong, lúc còn nhớ chi tiết.

## Cấu trúc thư mục chaos

- Mỗi kịch bản một thư mục `chaos/Sxx-<ten>/`.
- Bên trong gồm `inject.sh` gây lỗi, `rollback.sh` khôi phục, và `README.md` ghi mục tiêu học cùng kỳ vọng quan sát.
- Kế hoạch 19 kịch bản, bắt buộc tối thiểu 10, hoàn thành đầy đủ tối thiểu 12.

## Các kịch bản đã xác định

- Lệch code giữa hai web node, mô phỏng việc cài plugin qua wp-admin trên một máy.
- NFS chết khiến tiến trình PHP treo ở trạng thái D, không phải lỗi của PHP.
- Lỗi database chỉ xảy ra trên một web node, mà health check nông cố ý không phát hiện được.
- GRANT sai vì quên rằng MySQL thấy IP nguồn là IP của LB chứ không phải IP web node.
- Primary chết đột ngột, dùng để đo RTO và RPO.

## Ứng viên bổ sung cho đủ danh mục

- Dừng HAProxy hoặc Keepalived trên node đang giữ VIP.
- Dừng Nginx hoặc PHP-FPM trên một web node.
- Tắt boolean SELinux `httpd_use_nfs` khiến Nginx không đọc được thư mục upload.
- Làm đầy disk, và một kịch bản riêng làm đầy inode.
- Chặn nhầm cổng trong firewall: 3306, 2049, 9200 hoặc VRRP.
- Replication lag tăng vọt, hoặc IO thread lỗi.
- Replica chết khiến semi-sync âm thầm hạ xuống async.
- Primary khởi động lại nhưng người trực quên mở quyền ghi.
- Lệch giờ giữa các node do chrony hỏng.
- Chứng chỉ TLS hết hạn hoặc sai SAN.
- Cấu hình bị sửa tay trên node, phát hiện bằng `--check --diff`.

## Runbook

- RB-01 — failover load balancer và VIP khi HAProxy chủ chết, kèm cách đo thời gian gián đoạn.
- RB-02 — failover database khi primary chết: xác nhận đã fence, chọn replica, mở quyền ghi, chuyển HAProxy, kiểm tra lại.
- RB-03 — đưa primary cũ quay lại làm replica, bắt buộc kiểm tra errant GTID trước.
- RB-04 — mở quyền ghi sau khi restart primary có kế hoạch, vì MySQL luôn boot ở chế độ chỉ đọc.
- Mỗi runbook viết theo khung: triệu chứng, cách kiểm tra, các bước xử lý, cách xác minh, cách rollback.
- Tiêu chí đạt: người khác đọc và làm theo được mà không cần hỏi lại.

## Mẫu postmortem

- Tóm tắt sự cố trong vài dòng.
- Tác động thật, lấy số liệu từ `probe.sh` chứ không ước lượng.
- Dòng thời gian: lúc phát hiện, lúc bắt đầu xử lý, lúc dịch vụ hồi phục.
- Nguyên nhân gốc, phân biệt rõ với triệu chứng bề mặt.
- Điều đã làm đúng và điều làm chưa tốt.
- RTO và RPO đo được.
- Hành động khắc phục để lần sau không lặp lại.
- Luật mới rút ra để thêm vào `triage.py`.

## Script vận hành

- `probe.sh` — gọi liên tục qua VIP, ghi timestamp, mã HTTP và thời gian, tính tổng thời gian gián đoạn.
- `healthcheck.py` — chạy mỗi phút, kiểm VIP, stats HAProxy, health của từng web, replication, semi-sync, trạng thái chỉ đọc, NFS, disk và inode.
- Cảnh báo Telegram phải chống spam: gom lỗi lặp, đặt thời gian chờ giữa hai lần báo, và báo khi đã hồi phục.
- `diagnose.yml` — một lệnh thu thập toàn bộ bằng chứng về máy admin: `ss`, journal, `df -h`, `df -i`, trạng thái dịch vụ, log AVC.
- `triage.py` — áp các luật rút từ postmortem lên dữ liệu chẩn đoán, in ra nghi vấn kèm lệnh kiểm tra tiếp theo.
- `auto_remediate.sh` — chỉ xử lý lỗi an toàn như restart Nginx hoặc PHP-FPM, có giới hạn số lần mỗi giờ, có chế độ `--dry-run`, và **không bao giờ đụng vào MySQL**.
- `db_failover.py` — hỗ trợ failover: kiểm tra điều kiện an toàn, bắt người vận hành xác nhận, rồi mới thao tác.
- `order_writer.py` và `rpo_check.py` — tạo đơn liên tục và đối chiếu đơn đã xác nhận để đo RPO.

## Phân định tự động và thủ công

- Tự động vì rủi ro thấp: chuyển VIP, loại web node lỗi, xoay vòng log, phát hiện disk và inode, gửi cảnh báo.
- Con người quyết định vì rủi ro cao: promote database, mở quyền ghi, đưa primary cũ về làm replica, xử lý errant GTID, rollback cấu hình lớn, mọi thao tác động tới dữ liệu đơn hàng.

## Load test

- Kịch bản k6 mô phỏng xem trang chủ, xem sản phẩm và thêm vào giỏ hàng.
- Đặt ngưỡng pass/fail cho p95 và tỷ lệ lỗi ngay trong kịch bản.
- Chạy baseline với cấu hình mặc định trước, lưu kết quả lại.
- Tuning **một biến mỗi lần** rồi chạy lại cùng kịch bản, để biết thay đổi nào thực sự có tác dụng.
- Cuối cùng lập bảng so sánh trước và sau gồm p95, RPS và tỷ lệ lỗi kèm giải thích.
