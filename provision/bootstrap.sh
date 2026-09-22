#!/usr/bin/env bash
# Provision tối thiểu: chỉ đưa máy tới trạng thái Ansible vào được.
# Mọi cấu hình dịch vụ do Ansible làm, không làm ở đây.
set -euo pipefail

log() { echo "[bootstrap] $*"; }

# ---------------------------------------------------------------------------
# 1. Khoá SSH dùng chung cho Ansible (chạy lại nhiều lần không nhân đôi dòng)
# ---------------------------------------------------------------------------
install -d -m 700 -o vagrant -g vagrant /home/vagrant/.ssh
touch /home/vagrant/.ssh/authorized_keys
if ! grep -qF -f /tmp/lab_ansible.pub /home/vagrant/.ssh/authorized_keys; then
  cat /tmp/lab_ansible.pub >> /home/vagrant/.ssh/authorized_keys
  log "da them public key cua Ansible"
else
  log "public key da co san, bo qua"
fi
chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys
chmod 600 /home/vagrant/.ssh/authorized_keys
rm -f /tmp/lab_ansible.pub

# ---------------------------------------------------------------------------
# 2. Python cho Ansible; Rocky cần thêm binding SELinux cho module của Ansible
# ---------------------------------------------------------------------------
if command -v dnf >/dev/null 2>&1; then
  dnf install -y -q python3 python3-libselinux
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq python3
fi

# ---------------------------------------------------------------------------
# 3. sudo không mật khẩu (box bento đã có, khẳng định lại cho chắc)
# ---------------------------------------------------------------------------
echo 'vagrant ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-vagrant
chmod 440 /etc/sudoers.d/99-vagrant
visudo -cf /etc/sudoers.d/99-vagrant    # sudoers hỏng = mất quyền quản trị máy

# ---------------------------------------------------------------------------
# 4. Báo cáo để đối chiếu nhanh sau khi vagrant up
# ---------------------------------------------------------------------------
LAB_IP=$(ip -4 -o addr show | awk '$4 ~ /^10\.10\.10\./ {split($4,a,"/"); print a[1]}' | head -1)
LAB_IF=$(ip -4 -o addr show | awk '$4 ~ /^10\.10\.10\./ {print $2}' | head -1)
log "OK  host=$(hostname)  lab_ip=${LAB_IP:-CHUA-CO}  lab_iface=${LAB_IF:-CHUA-CO}  $(python3 --version)"
