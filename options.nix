{ lib
, ...
}:
let
  inherit (lib) mkOption types;
  inherit (types) ints;
in
{
  enable = lib.mkEnableOption "vbox-vpn";
  user = mkOption {
    type = types.str;
    default = null;
    description = "user name on behalf of Vbox VM is running";
  };
  vm-dns = mkOption {
    type = types.str;
    default = "vpn";
    description = "local domain name of VM";
  };
  vm-name = mkOption {
    type = types.str;
    default = "vpn";
    description = ''VirtualBox VM name. It is expected that VM is configured as a router
      forwarding incoming all traffic back. VM networking mode is Host-Only.

      Sample for Debian 13:
      /etc/systemd/system/set-gw.service:
        [Unit]
        Description=Set Gateway
        After=network.target
        Requires=network.target
        [Service]
        Type=simple
        Restart=on-failure
        ExecStart=/etc/systemd/system/set-gw.sh
        StartLimitBurst=2222

        [Install]
        WantedBy=multi-user.target

      /etc/systemd/system/set-gw.sh:
        #!/bin/bash

        set -e
        set -x

        ip route replace default via 192.168.56.1 dev enp0s3

      /etc/systemd/system/router.sh:
        [Unit]
        Description=Forwarding Packets
        After=network-online.target
        Requires=network-online.target
        [Service]
        Type=simple
        ExecStart=/etc/systemd/system/router.sh

        [Install]
        WantedBy=multi-user.target

      /etc/systemd/system/router.sh:
        #!/bin/bash

        set -e
        set -x

        echo 1 > /proc/sys/net/ipv4/ip_forward
        echo 0 > /proc/sys/net/ipv4/conf/enp0s3/send_redirects

        iptables -A FORWARD  -j ACCEPT
        iptables -t nat -A POSTROUTING -j MASQUERADE
      '';
  };
  packet-mark = mkOption {
    type = ints.u8;
    default = 2;
    description = "IP packet mark used for choosing alternative routing for traffict from VM";
  };
  routing-table = mkOption {
    type = ints.u8;
    default = 7;
    description = "routing table with alternaitve default route for traffict from VM";
  };
  vm-ipadr = mkOption {
    type = types.str;
    default = "192.168.56.101";
    description = "VM IP address";
  };
  ping-target = mkOption {
    type = types.str;
    default = "1.1.1.1";
    description = "Highly available IP address on the Internet";
  };
  vm-nic = mkOption {
    type = types.str;
    default = "vboxnet0";
    description = "VirtualBox NIC connecting with VPN VM";
  };
}
