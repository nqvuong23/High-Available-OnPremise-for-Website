# Website bán hàng HA on-premise — Ticket #P1-0001

> Tổng quan và ràng buộc bắt buộc. Chi tiết từng tầng nằm trong `.claude/rules/`, xem mục 11.
> Trao đổi và viết tài liệu bằng tiếng Việt; tên file, biến, lệnh bằng tiếng Anh.

## 1. Project này là gì

- Lab hạ tầng on-premise chạy WordPress + WooCommerce ở chế độ HA, loại bỏ SPOF ở mọi tầng xử lý request.
- Mục đích thật: sản phẩm đưa vào CV ứng tuyển thực tập System Engineer / SysAdmin / IT Infrastructure.
- Vai trò nhập vai: System Engineer Intern xử lý ticket #P1-0001, từ phân tích yêu cầu tới bàn giao tài liệu vận hành.
- Yêu cầu khách hàng: uptime 99.9%/tháng, tuyệt đối không mất đơn hàng, HTTPS tại `shop.lab.internal`, kèm tài liệu cho đội trực.
- Bối cảnh: VPS đơn lẻ từng sập 3 tiếng vì đầy ổ cứng, mùa sale sắp tới lượng truy cập tăng mạnh.

## 2. Chỉ số phải đạt

- Uptime 99.9%/tháng, tương đương tối đa khoảng 43,8 phút gián đoạn.
- VIP chuyển sang LB còn lại trong dưới 6 giây khi HAProxy chủ chết.
- HAProxy loại web node hỏng khỏi backend trong khoảng 6 giây, người dùng không thấy lỗi.
- Failover DB thủ công theo runbook, RTO trung bình dưới 5 phút qua tối thiểu 3 lần diễn tập.
- RPO = 0 cho đơn đã xác nhận, chứng minh bằng thực nghiệm chứ không chỉ bằng cấu hình.
- TLS tối thiểu 1.2, chứng chỉ có SAN đúng `shop.lab.internal`.
- `ansible-playbook site.yml` chạy lần thứ hai phải báo `changed=0`.
- Tối thiểu 12 kịch bản sự cố có script gây lỗi, script khôi phục và postmortem.

## 3. Kiến trúc tóm tắt

- Điểm truy cập duy nhất là VIP `10.10.10.100` do Keepalived quản lý bằng VRRP.
- Hai HAProxy chạy active-passive, terminate TLS, cân bằng HTTP cho web và TCP cho MySQL.
- Hai web node Nginx + PHP-FPM chạy code giống hệt nhau, chỉ deploy bằng Ansible.
- Thư mục upload của WordPress nằm trên NFS dùng chung để hai node thấy cùng dữ liệu.
- Hai node MySQL 8.4 chạy GTID replication kèm semi-sync, HAProxy định tuyến tới node đang writable.
- Mọi node MySQL luôn khởi động ở chế độ chỉ đọc; chỉ người vận hành mới mở quyền ghi.
- Nguyên tắc xuyên suốt: tự động hoá ở tầng ít rủi ro, giữ quyết định cho con người ở tầng database.

## 4. Máy trong lab

- `mgmt01` — 10.10.10.5 — Debian 13 — máy admin, chạy Ansible, k6, script — 1024 MB.
- `lb01` — 10.10.10.11 — Ubuntu 24.04 — HAProxy + Keepalived MASTER, priority 110 — 512 MB.
- `lb02` — 10.10.10.12 — Ubuntu 24.04 — HAProxy + Keepalived BACKUP, priority 100 — 512 MB.
- `web01` — 10.10.10.21 — Rocky 9 — Nginx + PHP-FPM, nơi chạy `wp core install` một lần — 1024 MB.
- `web02` — 10.10.10.22 — Rocky 9 — Nginx + PHP-FPM — 1024 MB.
- `db01` — 10.10.10.31 — Rocky 9 — MySQL primary ban đầu — 1536 MB.
- `db02` — 10.10.10.32 — Rocky 9 — MySQL replica ban đầu — 1536 MB.
- `nfs01` — 10.10.10.41 — Ubuntu 24.04 — NFS server, là SPOF đã biết và chấp nhận — 512 MB.
- Tổng 8 VM và 7680 MB RAM, nằm dưới trần 10 GB mà máy host cấp được.

## 5. Môi trường triển khai

- Máy host Windows 11 cài VMware Workstation Pro, Vagrant và toàn bộ box; host là nơi duy nhất điều khiển hypervisor.
- **Không dùng WSL2.** Máy điều khiển là VM `mgmt01` chạy Debian 13.
- Cách làm việc hằng ngày: từ Windows mở SSH vào `mgmt01`, mọi lệnh Ansible và script chạy tại đó.
- Lệnh `vagrant` chỉ chạy trên Windows PowerShell tại thư mục repo, không chạy trên `mgmt01`.
- Mạng lab là host-only `10.10.10.0/24`, tắt DHCP, card phía Windows mang địa chỉ `10.10.10.1`.
- Mỗi VM có 2 NIC: NIC NAT dành cho Vagrant và Internet, NIC lab dành cho traffic hệ thống.
- Repo gốc nằm trên Windows; `mgmt01` lấy code bằng `git clone`, không dùng thư mục chia sẻ của hypervisor.
- Debian 13 được chọn vì có Python 3.13, đủ điều kiện chạy ansible-core 2.20; Debian 12 chỉ có Python 3.11 nên không dùng được.

## 6. Tech stack

- Ảo hoá: VMware Workstation Pro 26H1, Vagrant 2.4.9, plugin `vagrant-vmware-desktop` 3.0.5, Vagrant VMware Utility 1.0.24.
- Box: `bento/debian-13`, `bento/ubuntu-24.04`, `bento/rockylinux-9`, tất cả ghim version `202510.26.0`.
- Hệ điều hành: Debian 13 cho mgmt, Rocky Linux 9 cho web và db, Ubuntu 24.04 cho lb và nfs.
- Load balancer: HAProxy 2.8.16 từ apt Ubuntu; VIP bằng Keepalived 2.2.8 với VRID 51.
- Web: Nginx 1.26 và PHP-FPM 8.3, bật qua `dnf module enable` trên Rocky 9.
- Ứng dụng: WordPress 7.0.x và WooCommerce 11.1.x, cài cùng quản lý bằng WP-CLI 2.12.0.
- Database: MySQL Community 8.4 LTS từ repo chính thức của Oracle, không dùng module AppStream.
- Lưu trữ dùng chung: NFS v4.2, mount chế độ `hard` vào thư mục uploads của WordPress.
- Automation: ansible-core 2.20.x trong virtualenv, secret trong Ansible Vault, kiểm tra bằng ansible-lint.
- Kiểm thử và vận hành: k6 2.1.x, Bash và Python 3 với PyMySQL, cảnh báo qua Telegram Bot API.
- Bảo mật nền: SELinux Enforcing trên Rocky, firewalld trên Rocky và ufw trên Ubuntu/Debian.
- Chẩn đoán: tcpdump, ss, lsof, sysstat, conntrack-tools, audit, setroubleshoot.

## 7. Cấu trúc repo

- `Vagrantfile` và `provision/` — khai báo 8 VM và provision tối thiểu để Ansible vào được.
- `ansible/` — `ansible.cfg`, `requirements.yml`, `inventory/`, `site.yml`, `diagnose.yml`, `roles/`.
- `ansible/roles/` — common, nfs_server, nfs_client, mysql, mysqlchk, nginx_php, wordpress, haproxy, keepalived, pki.
- `scripts/` — probe.sh, healthcheck.py, triage.py, auto_remediate.sh, db_failover.py, order_writer.py, rpo_check.py.
- `loadtest/k6/` — kịch bản load test và báo cáo hiệu năng trước/sau tuning.
- `chaos/` — mỗi kịch bản một thư mục gồm `inject.sh`, `rollback.sh` và `README.md`.
- `postmortems/` — một file cho mỗi lần diễn tập sự cố.
- `docs/` — README, sơ đồ, ADR, runbook RB-01 đến RB-04, SOP thay đổi, tài liệu bàn giao, danh sách hạn chế.

## 8. Lệnh thường dùng

```powershell
# Windows PowerShell, tại thư mục repo
vagrant up --provider vmware_desktop
vagrant status
vagrant snapshot save <ten>            # snapshot toàn bộ VM
vagrant halt --force db01              # tắt cứng, dùng khi diễn tập failover DB
ssh mgmt01                             # vào máy admin để làm việc
```

```bash
# Trên mgmt01, trong thư mục ansible/
ansible all -m ping
ansible-playbook site.yml
ansible-playbook site.yml --check --diff     # phát hiện cấu hình bị sửa tay
ansible-playbook site.yml --limit db --tags mysql
ansible-vault edit inventory/group_vars/all/vault.yml
ansible-lint
```

## 9. Quy tắc tuyệt đối không vi phạm

- Không bao giờ tự động failover database; mọi thao tác promote phải có người xác nhận.
- Không bao giờ để hai node MySQL cùng writable; xác nhận primary cũ đã chết hoặc bị fence trước khi promote.
- Luôn kiểm tra errant GTID trước khi cho primary cũ quay lại làm replica.
- Health check của web không được gọi DB hay NFS, vì lỗi dùng chung sẽ loại cả hai node cùng lúc.
- Mọi thay đổi hạ tầng đi qua Ansible; sửa tay để thử nghiệm thì phải đưa về code hoặc rollback ngay.
- Secret nằm trong Ansible Vault; không commit vault password, khoá riêng, chứng chỉ hay `.vagrant/`.
- Snapshot trước khi gây lỗi có chủ đích; khôi phục `db01` và `db02` cùng lúc để GTID không lệch.
- Khi tối ưu hiệu năng chỉ đổi một biến mỗi lần và lưu lại kết quả đo của từng lần.

## 10. Cách làm việc

- Làm tay một lần để hiểu cơ chế, sau đó mới viết thành Ansible role.
- Triển khai từ dưới lên theo thứ tự phụ thuộc: OS → Database → LB/VIP → Storage → Web/App.
- Mỗi mốc có kiểm thử nghiệm thu riêng; đạt rồi mới snapshot và đi tiếp.
- Mọi số liệu RTO, RPO, tỷ lệ lỗi phải đo được và ghi lại, không ước lượng.
- Viết tài liệu song song trong lúc làm, không dồn đến cuối.
- Luôn giải thích "tại sao" chứ không chỉ "làm thế nào", vì người phỏng vấn hỏi lý do nhiều hơn thao tác.
- Trung thực về giới hạn thiết kế; phần ngoài phạm vi phải ghi rõ thay vì giấu đi.

## 11. Chi tiết nằm ở đâu

- `milestones.md` — mốc M1 đến M7 và tiêu chí nghiệm thu; nạp mọi phiên vì đây là lộ trình.
- `architecture.md` — sơ đồ đầy đủ, luồng dữ liệu, trạng thái trước và sau failover DB.
- `decisions.md` — 15 quyết định thiết kế kèm lý do và đánh đổi.
- `lab-vagrant.md` — quy ước Vagrantfile, tài nguyên, mạng hai NIC, quy tắc snapshot.
- `network-firewall.md` — ma trận cổng và nguyên tắc firewall cho từng node.
- `ansible-conventions.md` — chuẩn viết role, idempotency, Vault, lint.
- `mysql.md` — GTID, semi-sync, cú pháp MySQL 8.4, quy tắc an toàn khi failover.
- `haproxy-keepalived.md` — cấu hình LB, health check, VRRP, PKI nội bộ.
- `web-stack.md` — Nginx, PHP-FPM, WordPress, NFS và SELinux trên Rocky 9.
- `chaos-ops.md` — quy trình gây lỗi, runbook, postmortem, cảnh báo.
- Các rule trừ `milestones.md` đều có `paths` frontmatter nên chỉ nạp khi đụng file liên quan; lúc file chưa tồn tại thì đọc thẳng rule đó trước khi bắt đầu.
