# -*- mode: ruby -*-
# vi: set ft=ruby :

require "yaml"

BOX                   = "bento/ubuntu-24.04"
BOX_VERSION           = "202510.26.0"
PROVIDER              = "vmware_desktop"
PUBLIC_KEY_PATH       = "vagrant-provision/ansible-key.pub"
DESTINATION_PATH      = "/tmp/ansible-key.pub"
BOOTSTRAP_SCRIPT_PATH = "vagrant-provision/bootstrap.sh"
NETMASK               = "255.255.255.0"
IPV4_CIDR             = 24
MAC_PREFIX            = "00:50:56"
GATEWAY_OCTET         = 254
LAB_ROUTE_METRIC      = 600
ROUTER_NAME           = "fw01"

ZONES = [
  { name: "dmz",    subnet: "192.168.10.0/24" },
  { name: "app",    subnet: "192.168.20.0/24" },
  { name: "db",     subnet: "192.168.30.0/24" },
  { name: "client", subnet: "172.16.10.0/24" },
]

NODES = [
  { name: "fw01",     mem: 512,  cpus: 2, ips: ["192.168.10.254", "192.168.20.254", "192.168.30.254", "172.16.10.254"] },
  { name: "lb01",     mem: 512,  cpus: 1, ips: ["192.168.10.11"] },
  { name: "lb02",     mem: 512,  cpus: 1, ips: ["192.168.10.12"] },
  { name: "web01",    mem: 1024, cpus: 2, ips: ["192.168.20.11"] },
  { name: "web02",    mem: 1024, cpus: 2, ips: ["192.168.20.12"] },
  { name: "nfs01",    mem: 512,  cpus: 1, ips: ["192.168.20.21"] },
  { name: "db01",     mem: 1536, cpus: 2, ips: ["192.168.30.11"] },
  { name: "db02",     mem: 1536, cpus: 2, ips: ["192.168.30.12"] },
  { name: "mgmt01",   mem: 1024, cpus: 2, ips: ["172.16.10.11"] },
  { name: "mon01",    mem: 2048, cpus: 2, ips: ["172.16.10.21"] },
]

def lab_mac(ip, idx)
  o = ip.split(".").map(&:to_i)
  format("#{MAC_PREFIX}:%02x:%02x:%02x", idx, o[2], o[3])
end

def lab_gateway(ip)
  "#{ip.split(".")[0, 3].join(".")}.#{GATEWAY_OCTET}"
end

def lab_zone_subnet(ip)
  "#{ip.split(".")[0, 3].join(".")}.0/#{IPV4_CIDR}"
end

def lab_routes(ip)
  gateway = lab_gateway(ip)

  # fw01 owns .254 in every zone, so it must not route through itself
  return [] if gateway == ip

  routes = [{ "to" => "default", "via" => gateway, "metric" => LAB_ROUTE_METRIC }]

  # explicit cross-zone routes, needed while the NAT default route still wins
  ZONES.each do |zone|
    next if zone[:subnet] == lab_zone_subnet(ip)
    routes << { "to" => zone[:subnet], "via" => gateway }
  end

  routes
end

def lab_netplan(ips)
  ethernets = {}
  ips.each_with_index do |ip, i|
    nic = {
      "match"     => { "macaddress" => lab_mac(ip, i) },
      "dhcp4"     => false,
      "dhcp6"     => false,
      "addresses" => ["#{ip}/#{IPV4_CIDR}"],
    }

    routes = lab_routes(ip)
    nic["routes"] = routes unless routes.empty?

    ethernets["interface#{i}"] = nic
  end
  { "network" => { "version" => 2, "ethernets" => ethernets } }.to_yaml
end

Vagrant.configure("2") do |config|
  config.vm.box         = BOX
  config.vm.box_version = BOX_VERSION
  config.vm.synced_folder ".", "/vagrant", disabled: true

  NODES.each do |node|
    config.vm.define node[:name] do |m|
      m.vm.hostname = node[:name]

      node[:ips].each_with_index do |ip, i|
        m.vm.network "private_network",
          ip:          ip,
          netmask:     NETMASK,
          adapter:     i + 1,
          mac:         lab_mac(ip, i).delete(":"),
          auto_config: false
      end

      m.vm.provider PROVIDER do |v|
        v.vmx["displayName"]          = node[:name]
        v.vmx["memsize"]              = node[:mem].to_s
        v.vmx["numvcpus"]             = node[:cpus].to_s
        v.vmx["cpuid.coresPerSocket"] = "1"
        v.gui          = false
        v.linked_clone = true
      end

      netplan_b64 = [lab_netplan(node[:ips])].pack("m0")
      macs        = node[:ips].each_with_index.map { |ip, i| lab_mac(ip, i) }.join(" ")

      m.vm.provision "shell", name: "netplan", inline: <<~SHELL
        set -eu

        rm -f /etc/netplan/50-vagrant.yaml
        echo '#{netplan_b64}' | base64 -d > /etc/netplan/60-vagrant.yaml
        chmod 600 /etc/netplan/60-vagrant.yaml

        for dev in /sys/class/net/*; do
          addr=$(cat "$dev/address")
          case " #{macs} " in
            *" $addr "*) ip link set "$(basename "$dev")" down ;;
          esac
        done

        netplan apply
        sleep 2
      SHELL

      # Minimum forwarding so Ansible can reach every zone; role firewall owns the real policy
      if node[:name] == ROUTER_NAME
        m.vm.provision "shell", name: "router-forwarding", inline: <<~SHELL
          set -eu

          echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/90-vagrant-router.conf
          sysctl -p /etc/sysctl.d/90-vagrant-router.conf
        SHELL
      end

      m.vm.provision "file",
        source: PUBLIC_KEY_PATH, 
        destination: DESTINATION_PATH

      m.vm.provision "shell", name: "bootstrap",
        path: BOOTSTRAP_SCRIPT_PATH
    end
  end
end
