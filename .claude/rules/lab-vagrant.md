---
paths:
  - "Vagrantfile"
  - "provision/**"
---

# Dựng lab bằng Vagrant và VMware

> `vagrant` **chỉ chạy trên Windows PowerShell** tại thư mục repo. `mgmt01` không điều khiển hypervisor.

## Phần mềm trên máy host Windows

- VMware Workstation Pro 26H1, miễn phí cho cá nhân, cần tài khoản Broadcom để tải.
- Vagrant 2.4.9, Vagrant VMware Utility 1.0.24 chạy như một Windows service, plugin `vagrant-vmware-desktop` 3.0.5.
- Thứ tự cài bắt buộc: Workstation, rồi Utility, rồi mới `vagrant plugin install`.
- Khi WSL2 hoặc Virtual Machine Platform đang bật, Workstation chạy ở chế độ Host VBS nên chậm hơn; chấp nhận được.

## Box

- `bento/debian-13`, `bento/ubuntu-24.04`, `bento/rockylinux-9`, tất cả ghim `202510.26.0`.
- Luôn thêm box kèm `--provider vmware_desktop --architecture amd64`; thiếu cờ sẽ báo box không hỗ trợ provider.
- Tải box trước khi `vagrant up` để tách bạch lỗi mạng với lỗi dựng máy.

## Mạng

- VMnet8 giữ nguyên mặc định làm NAT; đây là NIC thứ nhất và là đường `vagrant ssh` cùng đường ra Internet.
- Tạo thêm một VMnet host-only `10.10.10.0/24`, **tắt DHCP**, bật host virtual adapter để Windows có `10.10.10.1`.
- NIC thứ hai của mỗi VM gắn vào mạng lab với IP tĩnh khai trong `Vagrantfile`.
- Tên NIC lab trong guest do hệ điều hành đặt (ví dụ `ens33`, `ens192`); ghi lại và đưa vào biến `lab_iface` của inventory.
- Nếu provider không gán được IP tĩnh cho NIC thứ hai thì cấu hình trong guest: netplan cho Debian/Ubuntu, nmcli cho Rocky.

## Quy ước Vagrantfile

- Khai báo toàn bộ máy trong một mảng gồm tên, box, octet cuối của IP và dung lượng RAM để sửa quy hoạch chỉ ở một chỗ.
- Đặt RAM và CPU qua `v.vmx["memsize"]` và `v.vmx["numvcpus"]`.
- Bật `v.linked_clone = true` để các VM dùng chung đĩa nền của box, tiết kiệm nhiều GB.
- Đặt `v.gui = false` vì toàn bộ thao tác đi qua SSH.
- Tắt synced folder bằng `config.vm.synced_folder ".", "/vagrant", disabled: true`; HGFS từ NTFS gây rối quyền file và không cần thiết.
- Ghim `box_version` cho từng máy để lần dựng lại sau ra đúng hệ điều hành cũ.

## Provision tối thiểu

- Mục tiêu duy nhất: đưa máy tới trạng thái Ansible vào được. Mọi cấu hình dịch vụ để Ansible làm.
- Cài `python3`; riêng Rocky cài thêm `python3-libselinux` cho các module SELinux của Ansible.
- Chép public key dùng chung vào `authorized_keys` của user `vagrant`, viết sao cho chạy lại không nhân đôi dòng.
- Xác nhận sudo không cần mật khẩu, và luôn kiểm tra file sudoers bằng `visudo -cf` trước khi để nó có hiệu lực.
- Đặt hostname qua `node.vm.hostname` chứ không viết tay trong script.

## Snapshot

- Tên chuẩn theo mốc: `fresh` khi OS còn trắng, rồi `base`, `db-ready`, `lb-ready`, `app-ready`, `stable`, `baseline`.
- `vagrant snapshot save <ten>` áp dụng cho toàn bộ máy trong Vagrantfile.
- **Luôn khôi phục `db01` và `db02` cùng lúc về cùng một snapshot**, nếu lệch thì GTID không khớp và replication gãy rất khó gỡ.
- Tạo `baseline` sau khi hệ thống đã tuning và khoẻ, dùng làm mốc quay về cho mọi kịch bản chaos.

## Lỗi hay gặp

- `vagrant up` treo ở "Waiting for machine to boot": kiểm tra service Vagrant VMware Utility còn chạy không.
- Lỗi xác minh vmnet: đặt `v.verify_vmnet = false` trong khối provider.
- `vagrant plugin install` timeout tới `gems.hashicorp.com`: máy có IPv6 hỏng ngầm, cho Windows ưu tiên IPv4 bằng `netsh interface ipv6 set prefixpolicy ::ffff:0:0/96 45 4 store=persistent` rồi chạy `show prefixpolicies` xác nhận đã thành 45.
- Script dính CRLF báo `bad interpreter: /bin/bash^M`: đảm bảo `.gitattributes` ép `eol=lf`.
