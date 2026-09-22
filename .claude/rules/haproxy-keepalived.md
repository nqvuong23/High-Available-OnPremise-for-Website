---
paths:
  - "ansible/roles/haproxy/**"
  - "ansible/roles/keepalived/**"
  - "ansible/roles/pki/**"
---

# HAProxy, Keepalived và PKI nội bộ

> Hai LB chạy Ubuntu 24.04 với **cấu hình giống hệt nhau**; khác biệt duy nhất là priority của Keepalived.

## PKI nội bộ

- Tạo CA tự ký bằng `community.crypto`, khoá riêng của CA để ngoài repo.
- Chứng chỉ server phải có SAN gồm `DNS:shop.lab.internal` và `IP:10.10.10.100`.
- HAProxy cần file PEM gộp cả chứng chỉ lẫn khoá riêng, đặt quyền 600.
- Import CA vào Trusted Root của Windows thì trình duyệt mới không cảnh báo.

## HAProxy

- Cài bản 2.8.16 từ apt của Ubuntu 24.04; validate cấu hình bằng `haproxy -c -f %s` trước khi reload.
- Frontend cổng 80: chuyển hướng 301 sang HTTPS, đồng thời phục vụ `monitor-uri` cho Keepalived kiểm tra.
- Frontend cổng 443: bind chứng chỉ, ép TLS tối thiểu 1.2, thêm `X-Forwarded-For` và `X-Forwarded-Proto: https`.
- Backend web: `balance roundrobin`, cookie sticky `SRV`, health check `GET /healthz.php`.
- Tham số health check web: `check inter 2s fall 3 rise 2`, cộng với `option redispatch` và `retries 3`.
- Con số `inter 2s fall 3` chính là lý do node hỏng bị loại trong khoảng 6 giây, khớp với SLO.
- `listen mysql` ở chế độ TCP cổng 3306, health check qua cổng 9200 của `mysqlchk`.
- Ở trạng thái bình thường db01 để `check` còn db02 để `disabled`, tương ứng trạng thái MAINT.
- Trang stats cổng 8404 có xác thực và chỉ cho phép nguồn quản trị.
- Bật admin socket để dùng Runtime API bật tắt server mà không cần reload.

## Log và xoay vòng log

- Cấu hình rsyslog nhận log của HAProxy và ghi ra file riêng.
- Xác nhận logrotate thực sự chạy, vì sự cố gốc trong ticket chính là đầy ổ cứng.
- Kiểm chứng bằng `logrotate -d` rồi ép xoay thử và xem dịch vụ còn ghi log được không.

## Keepalived

- Cài bản 2.2.8 từ apt; một instance VRRP với `virtual_router_id 51`.
- lb01 đặt priority 110 và lb02 đặt priority 100, giữ preempt mặc định.
- `advert_int 1` nên thời gian phát hiện rơi vào khoảng 3 giây, đủ cho SLO dưới 6 giây.
- Interface khai bằng biến `lab_iface` vì tên NIC khác nhau giữa các máy.
- Mật khẩu xác thực lấy từ Vault và không vượt quá 8 ký tự theo giới hạn của VRRP.

## track_script

- Script kiểm tra phải xác nhận HAProxy **thực sự phản hồi**, không chỉ kiểm tra tiến trình còn sống.
- Cách làm: gọi `curl` vào `monitor-uri` trên localhost với timeout 1 giây.
- Khai báo `interval 2 fall 2 rise 2` và `weight -20` để priority của MASTER tụt xuống dưới BACKUP khi HAProxy hỏng.
- Bật `enable_script_security` và đảm bảo script không thuộc thư mục ai cũng ghi được.

## Yêu cầu hệ thống

- Đặt `net.ipv4.ip_nonlocal_bind=1` vì HAProxy trên node BACKUP phải bind vào VIP mà nó chưa sở hữu.
- Mở IP protocol 112 giữa hai LB; `ufw` không có `proto vrrp` nên phải thêm luật vào `/etc/ufw/before.rules`.
- Nếu mạng host-only chặn multicast thì chuyển sang `unicast_src_ip` và `unicast_peer`.

## Nghiệm thu

- `curl -I http://shop.lab.internal` trả 301, `curl -I https://shop.lab.internal` hợp lệ với CA nội bộ.
- Từ mgmt01 nối `mysql -h 10.10.10.100` và xác nhận đang nói chuyện với đúng node primary.
- Chạy probe hoặc k6 liên tục rồi dừng HAProxy trên lb01, đo thời gian VIP chuyển và đếm request lỗi.
- Bật lại HAProxy trên lb01 và quan sát nó giành lại VIP do preempt, ghi nhận lần gián đoạn ngắn thứ hai.
