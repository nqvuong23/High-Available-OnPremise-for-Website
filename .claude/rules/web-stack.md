---
paths:
  - "ansible/roles/nginx_php/**"
  - "ansible/roles/wordpress/**"
  - "ansible/roles/nfs_server/**"
  - "ansible/roles/nfs_client/**"
---

# Web, WordPress và NFS trên Rocky 9

> Hai web node phải **giống hệt nhau**. Bất kỳ khác biệt nào giữa web01 và web02 đều là lỗi cần sửa.

## NFS

- Server chạy trên nfs01 (Ubuntu 24.04) với `nfs-kernel-server`, chỉ bật NFSv4, tắt v3.
- Export `/srv/nfs/uploads` cho đúng hai IP của web node, chế độ `rw,sync,no_subtree_check`.
- Client trên Rocky cài `nfs-utils`, mount với `nfsvers=4.2,hard,noatime,_netdev`.
- Mount `hard` là quyết định có chủ đích: bảo toàn dữ liệu, đánh đổi là tiến trình treo ở trạng thái D khi NFS chết.
- Chỉ mount đúng thư mục `wp-content/uploads`, không mount cả cây WordPress.

## UID và GID

- Tạo group và user `nginx` với **số UID/GID cố định giống nhau** trên web01, web02 và nfs01.
- Phải tạo **trước khi** cài package, nếu không package sẽ tự cấp số tuỳ ý và lệch giữa các máy.
- UID lệch nhau trên NFS gây lỗi quyền rất khó nhìn ra vì thư mục vẫn hiện bình thường.

## Nginx và PHP-FPM

- Bật module stream bằng `dnf module enable nginx:1.26` và `php:8.3` trước khi cài.
- Extension PHP cần cho WooCommerce: mysqlnd, gd, mbstring, xml, intl, opcache, zip.
- PHP-FPM chạy dưới user `nginx`, nghe qua unix socket, chế độ `pm=dynamic`.
- `pm.max_children` tính từ RAM đo được thật của mỗi tiến trình, không đặt theo cảm tính.
- Bật `pm.status_path` cho `/fpm-status` nhưng chỉ cho phép nguồn quản trị và LB truy cập.
- Nginx dùng `set_real_ip_from` với hai IP của LB để log ra IP thật của client.
- Đặt `client_max_body_size` cùng `upload_max_filesize` và `post_max_size` đủ lớn cho ảnh sản phẩm.

## Health check

- `/healthz.php` chỉ trả về chuỗi tĩnh, chứng minh Nginx gọi được PHP-FPM.
- **Không** truy vấn database và **không** đọc NFS trong health check.
- Lý do: thành phần dùng chung mà lỗi sẽ khiến HAProxy loại cả hai web node cùng lúc và gây sập dây chuyền.
- Hệ quả chấp nhận: lỗi DB và NFS phải được phát hiện bằng `healthcheck.py` chứ không qua HAProxy.

## SELinux trên Rocky 9

- Giữ Enforcing, không chuyển sang Permissive để né lỗi.
- Bật boolean `httpd_use_nfs` để Nginx đọc được thư mục mount từ NFS.
- Bật boolean `httpd_can_network_connect_db` để PHP nối được MySQL qua VIP.
- Khi một dịch vụ mới lỗi, kiểm tra `ausearch -m avc -ts recent` **trước khi** nghi ngờ cấu hình ứng dụng.
- Sau khi chạy đủ luồng đọc, ghi và upload thì log AVC phải sạch.

## WordPress và WooCommerce

- Tải một artifact duy nhất rồi triển khai lên cả hai node để đảm bảo code giống hệt; có kiểm tra checksum khi tải.
- Ghim phiên bản WordPress, WooCommerce và WP-CLI trong `group_vars`, không dùng "latest".
- `wp-config.php` đặt `DB_HOST` trỏ tới `10.10.10.100:3306`, tức là đi qua HAProxy.
- Đặt `DISALLOW_FILE_MODS=true` để không ai cài plugin qua giao diện quản trị làm lệch code.
- Đặt `WP_HOME` và `WP_SITEURL` là `https://shop.lab.internal`.
- Phải đọc header `X-Forwarded-Proto` và tự đặt `$_SERVER['HTTPS']='on'`, nếu không sẽ lặp redirect hoặc mixed content.
- Salt lấy từ Vault, file `wp-config.php` đặt quyền 640 thuộc `root:nginx`.
- Tắt WP-Cron mặc định và chạy cron hệ thống trên **một node duy nhất**, tránh WooCommerce chạy tác vụ định kỳ trùng lặp.
- Chạy `wp core install` **đúng một lần** trên web01, dùng `run_once` và chỉ chạy khi chưa cài.

## Nghiệm thu

- Đặt một đơn hàng thật qua HTTPS và xác nhận đơn xuất hiện trên cả db01 lẫn db02.
- Upload ảnh khi request vào web01 rồi xem lại khi request vào web02, và làm ngược lại.
- So `sha256sum` toàn bộ cây code giữa hai node, phải khớp hoàn toàn.
- Dừng Nginx trên một node và xác nhận HAProxy đánh DOWN trong khoảng 6 giây mà site vẫn phục vụ.
