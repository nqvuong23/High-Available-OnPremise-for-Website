---
paths:
  - "ansible/roles/common/**"
  - "ansible/inventory/**"
  - "Vagrantfile"
  - "scripts/**"
---

# Mạng và ma trận firewall

> Nguyên tắc: mở tối thiểu, không để database lộ ra ngoài dải lab, và **kiểm chứng bằng quét cổng thật** chứ không chỉ đọc cấu hình.

## Công cụ firewall theo hệ điều hành

- Rocky 9 (web01, web02, db01, db02): dùng `firewalld`, gán NIC lab vào zone riêng.
- Ubuntu 24.04 (lb01, lb02, nfs01) và Debian 13 (mgmt01): dùng `ufw`, mặc định `deny incoming`.
- Role `common` phải phân nhánh theo `ansible_os_family`; mỗi role dịch vụ tự mở cổng của riêng nó.

## Nguồn được phép

- "Host" trong ma trận gồm Windows host `10.10.10.1` và máy admin `mgmt01` `10.10.10.5`.
- Cả hai đều được phép SSH vào mọi máy và truy cập trang stats của HAProxy.

## Ma trận cổng

- Host → VIP: TCP 80 và 443, để truy cập website như người dùng thật.
- Host → lb01, lb02: TCP 8404, xem trang stats của HAProxy.
- Host → mọi VM: TCP 22, phục vụ SSH và Ansible.
- Host → web01, web02: TCP 80, để kiểm tra trực tiếp từng node khi so sánh upload chéo.
- Host → VIP, db01, db02: TCP 3306, dành cho script đo RPO và thao tác failover.
- lb01 ↔ lb02: IP protocol 112 tới 224.0.0.18, để Keepalived trao đổi quảng bá VRRP.
- lb01, lb02 → web01, web02: TCP 80, chuyển request và chạy health check.
- lb01, lb02 → db01, db02: TCP 3306 để chuyển kết nối MySQL, và TCP 9200 để gọi `mysqlchk`.
- web01, web02 → VIP: TCP 3306, WordPress đọc ghi database qua HAProxy.
- web01, web02 → nfs01: TCP 2049, mount NFSv4.
- db01 ↔ db02: TCP 3306, replication hai chiều để còn đổi vai trò khi failover.

## Ràng buộc quan trọng

- SSH phải mở trên **cả NIC NAT lẫn NIC lab**; chặn nhầm NIC NAT là mất luôn đường `vagrant ssh`.
- Không mở cổng 3306 hay 9200 ra NIC NAT trong bất kỳ trường hợp nào.
- `ufw` không hiểu `proto vrrp`; phải thêm luật cho IP protocol 112 vào `/etc/ufw/before.rules` rồi `ufw reload`.
- Trên Rocky, cổng 9200 của `mysqlchk` cần được khai báo nhãn SELinux bằng `semanage port` ngoài việc mở firewall.

## Cách kiểm chứng

- Quét từ `mgmt01`: `sudo nmap -sS -p- 10.10.10.11,12,21,22,31,32,41` rồi đối chiếu với ma trận trên.
- Thử từ một nguồn **không** được phép, ví dụ web01 gọi db01:3306, và xác nhận bị chặn.
- Kiểm tra trang stats và `/fpm-status` từ chối nguồn lạ.
- Dùng `firewall-cmd --list-all` trên Rocky và `ufw status verbose` trên Ubuntu/Debian để đọc lại trạng thái thật.

## Tên miền

- `shop.lab.internal` trỏ tới VIP `10.10.10.100`, khai trong file hosts của Windows và `/etc/hosts` của mgmt01.
- Trỏ về VIP chứ không về IP node cụ thể, để mọi bài kiểm tra đều đi đúng đường của người dùng.
- CA nội bộ phải được import vào Trusted Root của Windows thì trình duyệt mới tin chứng chỉ.
