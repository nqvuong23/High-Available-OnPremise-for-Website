# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# 7 VM lab cho ticket #P1-0001. Máy admin mgmt01 (Debian 13) tạo tay, KHÔNG nằm ở đây.
# Chạy trên Windows PowerShell:  vagrant up --provider vmware_desktop

BOX_UBUNTU  = "bento/ubuntu-24.04"
BOX_ROCKY   = "bento/rockylinux-9"
BOX_VERSION = "202510.26.0"      # đổi cho khớp `vagrant box list` nếu bạn tải bản khác
LAB_PREFIX  = "10.10.10."        # trùng subnet của VMnet1 (host-only)
PUBKEY      = "provision/lab_ansible.pub"

# name, box, octet cuối, RAM (MB). Tổng 6656 MB; cộng mgmt01 1024 MB = 7680 MB.
NODES = [
  { name: "lb01",  box: BOX_UBUNTU, host: 11, mem: 512  },
  { name: "lb02",  box: BOX_UBUNTU, host: 12, mem: 512  },
  { name: "web01", box: BOX_ROCKY,  host: 21, mem: 1024 },
  { name: "web02", box: BOX_ROCKY,  host: 22, mem: 1024 },
  { name: "db01",  box: BOX_ROCKY,  host: 31, mem: 1536 },
  { name: "db02",  box: BOX_ROCKY,  host: 32, mem: 1536 },
  { name: "nfs01", box: BOX_UBUNTU, host: 41, mem: 512  },
]

unless File.exist?(PUBKEY)
  abort <<~MSG

    [LỖI] Chưa có #{PUBKEY}

    Khoá SSH phải được sinh trên mgmt01 TRƯỚC, rồi copy public key về đây:
      1. Trên mgmt01 : ssh-keygen -t ed25519 -f ~/.ssh/lab_ansible -C "ansible@lab" -N ""
      2. Trên Windows: scp mgmt01:~/.ssh/lab_ansible.pub #{PUBKEY}

    Xem docs/m1-lab-setup.md bước 1 và 2.
  MSG
end

Vagrant.configure("2") do |config|
  # Repo nằm trên NTFS; HGFS chỉ gây rắc rối quyền file. Ansible đẩy file qua SSH.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  NODES.each do |n|
    config.vm.define n[:name] do |node|
      node.vm.box         = n[:box]
      node.vm.box_version = BOX_VERSION
      node.vm.hostname    = n[:name]

      # NIC1 = NAT (VMnet8) do provider tự gắn: đường vagrant ssh và đường ra Internet.
      # NIC2 = mạng lab, khớp subnet của VMnet1 nên provider dùng lại vmnet có sẵn.
      node.vm.network "private_network",
        ip: "#{LAB_PREFIX}#{n[:host]}", netmask: "255.255.255.0"

      node.vm.provider "vmware_desktop" do |v|
        v.gui             = false
        v.linked_clone    = true          # dùng chung đĩa nền của box, tiết kiệm nhiều GB
        v.vmx["memsize"]  = n[:mem].to_s
        v.vmx["numvcpus"] = "1"
        v.vmx["displayName"] = "p1-#{n[:name]}"
      end

      node.vm.provision "file",
        source: PUBKEY, destination: "/tmp/lab_ansible.pub"

      node.vm.provision "shell", path: "provision/bootstrap.sh"
    end
  end
end
