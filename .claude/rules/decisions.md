---
paths:
  - "ansible/**"
  - "docs/**"
  - "Vagrantfile"
  - "scripts/**"
---

# Quyết định thiết kế và đánh đổi

> Đây là phần người phỏng vấn hỏi nhiều nhất. Mỗi quyết định phải nêu được **lý do** và **cái giá phải trả**.
> Khi cần thay đổi một quyết định ở đây, cập nhật rule này trước rồi mới sửa code.

## Tầng load balancer

- **ADR-01 — Dùng HAProxy thay vì Nginx làm load balancer.** Lý do: health check chủ động linh hoạt, Runtime API bật tắt server không cần reload, trang stats trực quan, cân bằng được cả HTTP lẫn TCP cho MySQL. Đánh đổi: thêm một công nghệ phải học.
- **ADR-02 — Terminate TLS tại HAProxy.** Lý do: quản lý chứng chỉ tập trung một chỗ, web node chỉ nhận HTTP nội bộ nên cấu hình đơn giản. Đánh đổi: traffic từ LB tới web không mã hoá, chấp nhận được trong mạng riêng.
- **ADR-03 — Keepalived bật preempt, lb01 priority 110 và lb02 priority 100.** Lý do: lb01 luôn là MASTER khi khoẻ nên trạng thái dễ đoán. Đánh đổi: lúc lb01 hồi phục có thêm một lần gián đoạn ngắn.
- **ADR-04 — Bật cookie sticky `SRV` trên backend web.** Lý do: người dùng ổn định trên một node nên dễ debug. Đánh đổi: không bắt buộc về chức năng vì WooCommerce đã lưu session trong database.

## Tầng web và ứng dụng

- **ADR-05 — Health check web "nông", `/healthz.php` chỉ kiểm tra Nginx tới PHP-FPM, không chạm DB và NFS.** Lý do: nếu health check phụ thuộc DB thì khi DB chậm HAProxy sẽ đánh DOWN **cả hai** web node và gây sập dây chuyền. Đánh đổi: không phát hiện được lỗi DB, kể cả lỗi chỉ xảy ra trên một node, nên DB và NFS phải giám sát bằng kênh riêng.
- **ADR-12 — Code chỉ deploy bằng Ansible, đặt `DISALLOW_FILE_MODS=true`.** Lý do: tránh lệch code giữa hai node khi ai đó cài plugin qua wp-admin. Đánh đổi: cài plugin phải theo quy trình, không bấm nút trong giao diện quản trị.
- **ADR-10 — Dùng NFS cho thư mục upload thay vì GlusterFS.** Lý do: đơn giản, đủ cho quy mô lab, dễ troubleshooting. Đánh đổi: NFS thành điểm lỗi đơn, phải ghi vào mục hạn chế.
- **ADR-11 — Mount NFS ở chế độ `hard`.** Lý do: không hỏng dữ liệu upload khi mạng chập chờn. Đánh đổi: NFS chết thì tiến trình treo ở trạng thái D, phải biết để không nhầm với lỗi PHP.

## Tầng database

- **ADR-06 — Ứng dụng nối database qua `VIP:3306`, HAProxy chọn node writable bằng `mysqlchk`.** Lý do: web không cần biết primary là máy nào, đổi primary chỉ thao tác trên HAProxy chứ không sửa `wp-config.php` từng node. Đánh đổi: thêm một chặng mạng, MySQL thấy IP nguồn là IP của LB, và LB failover làm rớt kết nối DB đang mở.
- **ADR-07 — Failover database thủ công có kiểm soát, không tự động.** Lý do: tự động failover mà không có fencing dễ gây hai primary cùng nhận ghi và hỏng dữ liệu đơn hàng; với dữ liệu tiền bạc, mất vài phút để người xác nhận vẫn an toàn hơn. Đánh đổi: RTO tính bằng phút và phụ thuộc người trực.
- **ADR-08 — Bật semi-synchronous replication, `AFTER_SYNC`, timeout 3 giây.** Lý do: primary chỉ báo commit thành công khi replica đã nhận sự kiện nên đơn đã xác nhận luôn nằm trên ít nhất hai node. Đánh đổi: tăng độ trễ ghi, và nếu replica không phản hồi quá timeout thì tự quay về async nên **bắt buộc phải giám sát**.
- **ADR-09 — Đặt `super_read_only=ON` trong file cấu hình của cả hai node DB.** Lý do: node nào khởi động lại cũng chỉ đọc, đây là một dạng fencing đơn giản chống hai primary. Đánh đổi: sau khi restart primary có kế hoạch thì phải mở quyền ghi thủ công theo runbook RB-04.

## Hạ tầng và công cụ

- **ADR-13 — Web và DB chạy Rocky Linux 9, LB và NFS chạy Ubuntu 24.04.** Lý do: JD yêu cầu cả họ RHEL lẫn Ubuntu; Rocky bật SELinux Enforcing mặc định nên tạo ra tình huống lỗi rất thực tế ở đúng những tầng nhiều thao tác nhạy cảm. Đánh đổi: Ansible phải xử lý hai họ phân phối khác nhau về gói, firewall, tên dịch vụ và đường dẫn.
- **ADR-14 — Ansible quản toàn bộ cấu hình, Vagrant quản vòng đời VM.** Lý do: tái tạo lab từ đầu bằng lệnh, thể hiện tư duy hạ tầng là code. Đánh đổi: tốn thời gian viết ban đầu.
- **ADR-15 — Máy điều khiển là VM `mgmt01` chạy Debian 13, không dùng WSL2.** Lý do: `mgmt01` nằm cùng mạng lab nên không phụ thuộc vào mirrored networking của WSL2 vốn có lỗi đã biết với card host-only của hypervisor; Debian 13 có Python 3.13 nên đủ điều kiện chạy ansible-core 2.20. Đánh đổi: tốn thêm 1 GB RAM, và phải SSH từ Windows vào mới làm việc được.
