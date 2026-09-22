---
paths:
  - "ansible/**"
---

# Chuẩn viết Ansible

> Chạy trên `mgmt01` (Debian 13, Python 3.13) trong virtualenv. Tiêu chí nghiệm thu gắt nhất: `site.yml` chạy lần hai báo `changed=0`.

## Môi trường

- ansible-core 2.20.x cài trong virtualenv; Debian 13 chặn `pip` vào Python hệ thống theo PEP 668.
- Control node cần Python từ 3.12 trở lên; node Rocky 9 dùng Python 3.9 vẫn hợp lệ ở vai trò máy được quản lý.
- Collections ghim phiên bản trong `requirements.yml`: `community.mysql`, `ansible.posix`, `community.general`, `community.crypto`.
- Đặt `ANSIBLE_CONFIG` tường minh để chắc chắn `ansible.cfg` được đọc.

## Cấu trúc

- Mỗi role có đủ `defaults/`, `tasks/`, `templates/`, `handlers/`.
- Role xử lý nhiều hệ điều hành thì tách `tasks/RedHat.yml` và `tasks/Debian.yml`, chọn theo `ansible_os_family`.
- `site.yml` gọi role đúng thứ tự phụ thuộc: common → nfs → mysql → web → haproxy → keepalived.
- Inventory nhóm hai chiều: theo vai trò (`lb`, `web`, `db`, `nfs`) và theo họ phân phối (`rocky`, `ubuntu`).
- Biến dùng ở nhiều nơi như VIP, domain, UID/GID chỉ được định nghĩa **một lần** trong `group_vars`.

## Idempotency

- Ưu tiên module chuẩn với tên đầy đủ (FQCN) thay cho `shell` và `command`.
- Bắt buộc dùng `command` thì phải khai báo `changed_when` hoặc `creates` để không báo changed giả.
- Nghiệm thu bằng cách chạy `site.yml` lần hai; còn `changed` ở đâu thì sửa task ở đó.
- Dùng `ansible-playbook site.yml --check --diff` để phát hiện cấu hình bị sửa tay trên node.

## An toàn khi áp dụng cấu hình

- Mọi template cấu hình phải có `validate:` hoặc handler kiểm tra cú pháp trước khi reload dịch vụ.
- Ví dụ: `nginx -t` cho Nginx, `haproxy -c -f %s` cho HAProxy, `visudo -cf %s` cho sudoers, `mysqld --validate-config` cho MySQL.
- Không bao giờ reload hay restart một dịch vụ khi file cấu hình chưa qua bước kiểm tra cú pháp.

## Secret

- Mật khẩu database, token Telegram, khoá riêng CA đều nằm trong Ansible Vault.
- Quy ước đặt tên biến bắt đầu bằng `vault_` để nhìn template là biết đâu là secret.
- File vault password để ngoài repo với quyền 600; không bao giờ commit.
- Dùng `no_log: true` cho task có khả năng in secret ra log.
- Mật khẩu VRRP bị giao thức giới hạn tối đa 8 ký tự, cắt sẵn từ lúc sinh cho khỏi lỗi khó hiểu.

## Chất lượng

- Chạy `ansible-lint` ở profile `production` trước khi commit.
- Mọi task phải có `name` mô tả rõ việc nó làm.
- Commit nhỏ, thông điệp nêu rõ role nào thay đổi và vì sao.

## Thư viện cần có trên node đích

- Node DB cần `PyMySQL` thì module `community.mysql` mới chạy được.
- Node Rocky cần `python3-libselinux` cho các module SELinux.
- Cài các phụ thuộc này ngay trong role tương ứng, không giả định box đã có sẵn.
