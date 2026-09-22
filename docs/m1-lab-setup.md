# M1 — Dựng môi trường lab từ đầu tới khi Ansible quản được 7 VM

> Phạm vi: chỉ dựng và chuẩn hoá môi trường. **Chưa** cấu hình HAProxy, Nginx, MySQL — những phần đó thuộc M2 trở đi.
> Ký hiệu nơi chạy: **[W]** PowerShell trên Windows · **[M]** shell trên mgmt01 · **[VM]** trên máy lab.

## Điểm xuất phát

Bạn đã có:

- VMware Workstation, VMnet8 NAT `192.168.97.0/24`, VMnet1 host-only `10.10.10.0/24`.
- VM Debian 13 cài từ ISO, hiện **chỉ gắn VMnet8**.
- Vagrant, plugin `vagrant-vmware-desktop`, Vagrant VMware Utility, 2 box `bento/ubuntu-24.04` và `bento/rockylinux-9`.

Còn thiếu để chạy được:

- `mgmt01` chưa có NIC thứ hai nên **chưa vào được mạng lab** `10.10.10.0/24`.
- Chưa có khoá SSH dùng chung; mà khoá này phải tồn tại **trước** khi `vagrant up`.
- Chưa có Ansible trên `mgmt01`, chưa có 7 VM lab.

## Thứ tự thực hiện và lý do

```
B0  [W]  Khởi tạo repo Git trên Windows
         |
B1  [M]  mgmt01: thêm NIC lab + IP tĩnh 10.10.10.5, cài Ansible, SINH KHOÁ SSH
         |        (phải sinh khoá trước, vì Vagrant cần public key lúc provision)
B2  [W]  Copy public key từ mgmt01 về repo trên Windows
         |
B3 [W+M] Trỏ shop.lab.internal về VIP 10.10.10.100
         |
B4  [W]  Kiểm tra VMnet1 và box trước khi dựng
         |
B5  [W]  vagrant up — dựng 7 VM lab
         |
B6  [M]  Đưa repo lên mgmt01
         |
B7  [M]  Cài collections, kiểm tra Ansible chạm được 7 node
         |
B8  [M]  ansible-playbook site.yml — chuẩn hoá OS, cài package
         |
B9  [W]  Snapshot `base`
```

Điểm dễ sai nhất là **B1 phải xong trước B5**. Nếu `vagrant up` khi chưa có `provision/lab_ansible.pub`, Vagrantfile sẽ dừng ngay và in hướng dẫn.

---

## B0 — Khởi tạo repo Git [W]

Các file cấu hình đã có sẵn trong repo. Việc còn lại là khởi tạo Git và tạo nốt thư mục rỗng.

```powershell
cd E:\on_prem_project

# Thư mục sẽ dùng ở các mốc sau
mkdir scripts, loadtest\k6, chaos, postmortems, docs\runbooks -Force

git symbolic-ref HEAD refs/heads/main      # repo chưa có commit nào
git add -A
git commit -m "chore: khung dự án, Vagrantfile và role common cho M1"
```

**Tại sao commit ngay**: từ B5 trở đi mọi thứ đều có thể hỏng và phải dựng lại. Có commit thì luôn quay về được điểm sạch.

---

## B1 — Chuẩn bị mgmt01 [M]

### B1.1 Thêm NIC thứ hai vào mạng lab

Tắt VM Debian, rồi trong VMware: **VM → Settings → Add → Network Adapter → Custom → VMnet1**. Bật VM lên lại.

**Tại sao cần**: `mgmt01` phải nằm cùng mạng `10.10.10.0/24` với 7 VM lab thì Ansible mới SSH vào được. NIC VMnet8 giữ nguyên để `mgmt01` còn ra Internet cài gói.

### B1.2 Đặt IP tĩnh 10.10.10.5

Xác định tên NIC mới và cách máy đang quản lý mạng:

```bash
ip -br a                                # NIC mới là cái chưa có IPv4, thường là ens37/ens192
systemctl is-active NetworkManager      # active => dùng nmcli, còn lại => dùng ifupdown
```

Nếu **NetworkManager** đang chạy:

```bash
sudo nmcli con add type ethernet ifname ens37 con-name lab \
     ipv4.method manual ipv4.addresses 10.10.10.5/24
sudo nmcli con up lab
```

Nếu dùng **ifupdown** (cài Debian không kèm desktop thường rơi vào đây):

```bash
sudo tee /etc/network/interfaces.d/lab >/dev/null <<'EOF'
auto ens37
iface ens37 inet static
    address 10.10.10.5/24
EOF
sudo ifup ens37
```

Thay `ens37` bằng tên thật của bạn. **Không khai gateway** trên NIC này: đường ra Internet đã đi qua NIC NAT, khai thêm default route thứ hai sẽ gây định tuyến lộn xộn.

Kiểm tra:

```bash
ip -4 -o addr show | grep 10.10.10.5    # phải thấy IP
ping -c 3 10.10.10.1                    # card host-only phía Windows
ping -c 3 8.8.8.8                       # Internet vẫn đi qua NIC NAT
```

### B1.3 Cài công cụ và Ansible

```bash
sudo apt update
sudo apt install -y openssh-server git python3-venv python3-pip curl rsync

python3 -m venv ~/venvs/ansible
source ~/venvs/ansible/bin/activate
pip install --upgrade pip
pip install "ansible-core>=2.20,<2.21" ansible-lint yamllint

echo 'source ~/venvs/ansible/bin/activate' >> ~/.bashrc
ansible --version
```

**Tại sao dùng venv**: Debian 13 chặn `pip` cài vào Python hệ thống theo PEP 668. Kiểm tra dòng `python version` trong kết quả phải là **3.12 trở lên** — đây chính là lý do chọn Debian 13 thay vì Debian 12 (chỉ có Python 3.11, không chạy được ansible-core 2.20).

### B1.4 Sinh khoá SSH dùng chung

```bash
ssh-keygen -t ed25519 -f ~/.ssh/lab_ansible -C "ansible@lab" -N ""
cat ~/.ssh/lab_ansible.pub
```

**Tại sao một cặp khoá cho cả 7 máy**: Vagrant mặc định sinh khoá riêng cho từng VM ở đường dẫn khác nhau, rất phiền cho inventory Ansible. Một cặp khoá dùng chung làm cấu hình gọn hơn nhiều. Khoá riêng nằm trong home của `mgmt01` và không bao giờ vào repo.

---

## B2 — Đưa public key về repo trên Windows [W]

Trước hết cho Windows SSH vào `mgmt01` bằng tên ngắn:

```powershell
# Tạo hoặc bổ sung C:\Users\<ban>\.ssh\config
@"
Host mgmt01
  HostName 10.10.10.5
  User <ten_user_debian>
"@ | Add-Content "$env:UserProfile\.ssh\config" -Encoding ascii

ssh mgmt01 hostname        # phải trả về tên máy Debian
```

Rồi copy public key vào repo:

```powershell
cd E:\on_prem_project
scp mgmt01:~/.ssh/lab_ansible.pub provision\lab_ansible.pub
type provision\lab_ansible.pub      # phải bắt đầu bằng ssh-ed25519
```

**Tại sao đi đường vòng qua Windows**: Vagrant chạy trên Windows nên file public key phải nằm trong repo trên Windows thì provision mới nhúng được vào 7 VM.

---

## B3 — Trỏ tên miền về VIP [W] + [M]

Trên Windows, PowerShell **Administrator**:

```powershell
Add-Content "$env:SystemRoot\System32\drivers\etc\hosts" "10.10.10.100`tshop.lab.internal" -Encoding ascii
ping shop.lab.internal      # chỉ cần phân giải đúng 10.10.10.100; chưa có VIP nên timeout là bình thường
```

Trên `mgmt01`:

```bash
echo -e "10.10.10.100\tshop.lab.internal" | sudo tee -a /etc/hosts
getent hosts shop.lab.internal
```

**Tại sao trỏ về VIP chứ không về IP node**: chứng chỉ TLS ở M3 cấp cho đúng tên này, và mọi bài kiểm tra phải đi qua đúng đường của người dùng thật thì mới chứng minh được HA. Trên 7 VM lab thì role `common` tự ghi dòng này vào `/etc/hosts`, không cần làm tay.

---

## B4 — Kiểm tra trước khi dựng VM [W]

```powershell
vagrant box list
```

Phải thấy cả hai box kèm `(vmware_desktop, <version>)`. Nếu version khác `202510.26.0`, sửa hằng `BOX_VERSION` ở đầu `Vagrantfile` cho khớp. Nếu thiếu provider `vmware_desktop`, tải lại:

```powershell
vagrant box add bento/ubuntu-24.04  --provider vmware_desktop --architecture amd64
vagrant box add bento/rockylinux-9  --provider vmware_desktop --architecture amd64
```

Mở **Virtual Network Editor** (Administrator) và xác nhận VMnet1:

- Subnet IP `10.10.10.0`, mask `255.255.255.0`.
- **"Use local DHCP service" phải TẮT.** Nếu còn bật, DHCP sẽ cấp địa chỉ trùng dải IP tĩnh và gây xung đột rất khó đoán.
- "Connect a host virtual adapter" phải bật, đó là thứ tạo ra `10.10.10.1` trên Windows.

---

## B5 — Dựng 7 VM [W]

```powershell
cd E:\on_prem_project
Measure-Command { vagrant up --provider vmware_desktop } | Select-Object TotalMinutes
vagrant status
```

**Ghi lại số phút** — đây là mốc so sánh cho lần dựng lại ở M7 và là một số liệu đẹp để đưa vào CV.

Mỗi máy khi provision xong sẽ in một dòng dạng:

```
[bootstrap] OK  host=web01  lab_ip=10.10.10.21  lab_iface=ens37  Python 3.9.x
```

Nếu `lab_ip=CHUA-CO` thì provider chưa gán được IP tĩnh cho NIC thứ hai. Xem mục Xử lý sự cố ở cuối.

Kiểm tra nhanh từ Windows:

```powershell
11,12,21,22,31,32,41 | ForEach-Object { "10.10.10.$_ -> $(Test-Connection "10.10.10.$_" -Count 1 -Quiet)" }
```

---

## B6 — Đưa repo lên mgmt01 [M]

Cách gọn nhất, đẩy thẳng từ Windows sang:

```powershell
# [W]
ssh mgmt01 "mkdir -p ~/on_prem_project"
scp -r E:\on_prem_project\ansible mgmt01:~/on_prem_project/
```

Hoặc nếu đã push lên GitHub thì clone cho đúng quy trình lâu dài:

```bash
# [M]
git clone git@github.com:<ban>/<repo>.git ~/on_prem_project
```

**Tại sao không dùng thư mục chia sẻ của hypervisor**: thư mục chia sẻ từ NTFS mang quyền 777, và Ansible sẽ **âm thầm bỏ qua** `ansible.cfg` nằm trong thư mục ai cũng ghi được. Triệu chứng là cấu hình không có hiệu lực mà không báo lỗi gì.

---

## B7 — Kiểm tra Ansible chạm được 7 node [M]

```bash
cd ~/on_prem_project/ansible
source ~/venvs/ansible/bin/activate

ansible-galaxy collection install -r requirements.yml
ansible-galaxy collection list | head -20

ansible-inventory --graph        # xem đúng nhóm lb/web/db/nfs và rocky/ubuntu
ansible all -m ping              # phải 7/7 "pong"
ansible all -a "id" --become     # phải trả uid=0(root)
```

**Ba lệnh kiểm tra này tách bạch ba thứ khác nhau**: `ping` chứng minh SSH và Python đã thông, `--become` chứng minh leo quyền sudo chạy được, `inventory --graph` chứng minh inventory được đọc đúng. Thiếu bất kỳ cái nào thì `site.yml` sẽ hỏng giữa chừng.

---

## B8 — Chuẩn hoá OS và cài package [M]

Xem trước những gì sẽ thay đổi mà chưa đụng vào hệ thống:

```bash
ansible-playbook site.yml --check --diff
```

Rồi áp dụng thật:

```bash
ansible-playbook site.yml
```

Role `common` làm các việc sau, và đây là lý do của từng việc:

- **Cài bộ công cụ chẩn đoán** (tcpdump, lsof, sysstat, conntrack, audit…) — để khi sự cố xảy ra ở M6 không phải vừa xử lý vừa đi cài công cụ.
- **Đặt múi giờ và bật chrony** — lệch giờ giữa các node làm log không khớp, rất khó dựng lại dòng thời gian khi điều tra sự cố.
- **Sinh `/etc/hosts` từ inventory** — mọi node gọi nhau bằng tên, gồm cả `shop.lab.internal` trỏ về VIP.
- **Tạo user `nginx` với UID/GID cố định 2001** trên web01, web02 và nfs01 — phải làm **trước** khi cài package ở M4, vì nếu để package tự cấp số thì UID lệch giữa các máy và quyền file trên NFS sẽ sai một cách rất khó nhìn ra.
- **Rocky: bật firewalld, mở SSH ở cả zone `public` lẫn `internal`, rồi mới gán NIC lab vào `internal`** — đúng thứ tự này để không tự khoá mình ra ngoài.
- **Rocky: đặt SELinux Enforcing**, tự reboot nếu cần gán nhãn lại filesystem, rồi kiểm tra `getenforce`.
- **Ubuntu: mở cổng 22 trước, sau đó mới bật ufw** với chính sách chặn mặc định chiều vào.

Chạy lại lần hai để chứng minh playbook idempotent:

```bash
ansible-playbook site.yml
```

Dòng `PLAY RECAP` phải cho `changed=0` ở cả 7 máy. Còn `changed` ở đâu nghĩa là task đó chưa idempotent và cần sửa.

---

## B9 — Snapshot `base` [W]

```powershell
vagrant snapshot save base
vagrant snapshot list
```

**Tại sao snapshot ngay**: từ M2 trở đi bạn sẽ đụng vào MySQL, firewall và SELinux — những thứ rất dễ làm hỏng máy. Quay về `base` mất vài giây, còn dựng lại từ đầu mất cả giờ.

---

# Kiểm tra tổng kết

Chạy hết bảng này. Chỉ khi tất cả đều đạt mới coi là xong M1 và chuyển sang M2.

| # | Kiểm tra | Lệnh | Kết quả mong đợi |
|---|---|---|---|
| 1 | mgmt01 có 2 NIC | [M] `ip -br a` | Có cả IP `192.168.97.x` và `10.10.10.5` |
| 2 | mgmt01 ra được Internet | [M] `ping -c3 8.8.8.8` | 0% packet loss |
| 3 | Windows SSH vào mgmt01 | [W] `ssh mgmt01 hostname` | Trả về tên máy Debian |
| 4 | Box đúng provider | [W] `vagrant box list` | 2 box kèm `vmware_desktop` |
| 5 | 7 VM chạy | [W] `vagrant status` | 7 dòng `running` |
| 6 | IP lab đúng | [W] ping 7 địa chỉ `.11 .12 .21 .22 .31 .32 .41` | Tất cả trả lời |
| 7 | VM ra được Internet | [W] `vagrant ssh web01 -c "ping -c2 8.8.8.8"` | 0% packet loss |
| 8 | Ansible chạm được | [M] `ansible all -m ping` | 7/7 `pong` |
| 9 | Leo quyền sudo | [M] `ansible all -a id --become` | `uid=0(root)` cả 7 |
| 10 | Playbook idempotent | [M] `ansible-playbook site.yml` lần 2 | `changed=0` cả 7 |
| 11 | SELinux Enforcing | [M] `ansible rocky -a getenforce` | `Enforcing` trên 4 node |
| 12 | Đồng hồ đồng bộ | [M] `ansible all -a "chronyc tracking" \| grep -i "leap\|system time"` | Có nguồn, lệch dưới 100 ms |
| 13 | Firewall đang bật | [M] `ansible rocky -a "firewall-cmd --state" --become` | `running` |
| 14 | ufw đang bật | [M] `ansible ubuntu -a "ufw status" --become` | `Status: active` |
| 15 | Chỉ mở cổng 22 | [M] `nmap -sS -p- 10.10.10.21` | Chỉ thấy `22/tcp open` |
| 16 | Tên miền có trên node | [M] `ansible all -a "getent hosts shop.lab.internal"` | Trả về `10.10.10.100` |
| 17 | UID/GID nginx đúng | [M] `ansible web,nfs -a "id nginx"` | `uid=2001 gid=2001` cả 3 máy |
| 18 | Không có AVC denial | [M] `ansible rocky -a "ausearch -m avc -ts recent" --become` | Không có bản ghi nào |
| 19 | Snapshot đã lưu | [W] `vagrant snapshot list` | `base` trên cả 7 máy |
| 20 | Repo sạch secret | [W] `git status --ignored \| Select-String vagrant` | `.vagrant/` đang bị bỏ qua |

Mục **10** và **15** là hai mục quan trọng nhất: một chứng minh hạ tầng thật sự là code, một chứng minh nguyên tắc firewall tối thiểu được thực thi chứ không chỉ nằm trên giấy.

---

# Xử lý sự cố thường gặp

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `vagrant up` dừng ngay, báo thiếu `provision/lab_ansible.pub` | Chưa làm B1.4 và B2 | Sinh khoá trên mgmt01 rồi `scp` public key về repo |
| Provision in `lab_ip=CHUA-CO` | Provider chưa gán được IP tĩnh cho NIC thứ hai | Đặt IP trong guest: netplan cho Ubuntu, `nmcli` cho Rocky; hoặc kiểm tra lại subnet VMnet1 |
| Vagrant tạo ra một VMnet mới thay vì dùng VMnet1 | Subnet VMnet1 không khớp `10.10.10.0/24` | Sửa lại trong Virtual Network Editor rồi `vagrant reload` |
| `vagrant up` treo ở "Waiting for machine to boot" | Service Vagrant VMware Utility đã dừng | `Get-Service *vagrant*` rồi khởi động lại service |
| Lỗi xác minh vmnet | Provider không xác minh được vmnet thủ công | Thêm `v.verify_vmnet = false` vào khối provider trong Vagrantfile |
| `ansible all -m ping` báo `Permission denied (publickey)` | Public key chưa vào máy hoặc sai khoá | `vagrant provision <node>`; kiểm tra bằng `ssh -i ~/.ssh/lab_ansible -v vagrant@10.10.10.21` |
| Ansible không đọc `ansible.cfg` | Thư mục có quyền 777 (thường do dùng thư mục chia sẻ) | Đưa repo vào home của mgmt01, hoặc đặt `export ANSIBLE_CONFIG=~/on_prem_project/ansible/ansible.cfg` |
| Script báo `bad interpreter: /bin/bash^M` | File dính CRLF khi sửa từ Windows | Kiểm tra `.gitattributes`; sửa nhanh bằng `sed -i 's/\r$//' <file>` |
| Playbook đứng ở bước bật ufw | Cổng 22 chưa được mở trước | Role đã xử lý đúng thứ tự; nếu vẫn kẹt thì vào bằng `vagrant ssh` và chạy `ufw allow 22` |
| Task SELinux lỗi "libselinux-python missing" | Thiếu `python3-libselinux` | `bootstrap.sh` đã cài; chạy `vagrant provision <node>` nếu node bị sót |
| Mất SSH vào node Rocky sau khi đổi firewall | Zone của NIC lab chưa mở ssh | Vào bằng `vagrant ssh <node>` qua đường NAT rồi `firewall-cmd --zone=internal --add-service=ssh --permanent` |

---

# Sau khi xong

Commit lại kết quả và chuyển sang M2 (tầng database):

```powershell
cd E:\on_prem_project
git add -A
git commit -m "feat(m1): dựng lab 7 VM và chuẩn hoá OS bằng role common"
```

M2 sẽ cần đọc `.claude/rules/mysql.md` trước khi bắt đầu.
