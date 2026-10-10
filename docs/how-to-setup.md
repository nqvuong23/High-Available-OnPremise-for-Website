# How to setup 

## The task list

1. ...
2. ...

## Step 1: Install tool

- VMware Workstation Pro 25H2
- Vagrant, Vagrant VMware Utility

## Step 2: Setup VMware Workstation Pro

Create 5 Virtual Network:
- **VMnet1:** 192.168.10.0/24 (Host-only, DHCP disabled)
- **VMnet2:** 192.168.20.0/24 (Host-only, DHCP disabled)
- **VMnet3:** 192.168.30.0/24 (Host-only, DHCP disabled)
- **VMnet4:** 172.16.10.0/24 (Host-only, DHCP disabled)
- **VMnet5:** 10.10.10.0/24 (NAT)

## Step 3: Setup VM `mgmt01` as an Admin VM

- Add VMnet4 and VMnet5 in VM Settings
- Install necessary packages

```
# Default Debian 13 don't have `sudo`, Ubuntu may be available
su -
apt install sudo
```

```
# skip this command if sudo is available
usermod -aG sudo [username] 
# logout and login with new login-shell
```

- Set static IP with `ifupdown` (Debian) (or Netplan when working with Ubuntu): 

- Tạo private và public key `ansible-key` rồi từ window host dùng lệnh `scp` copy 2 file này từ debian VM ra window host