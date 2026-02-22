# NixOS service for VPN inside VirtualBox

The service starts the specified VirtualBox VM and setups host network in
such a way that all outgoing traffic is redirected to the VM and
traffic from VM goes to original gateway.

Service tracks NetworkManager reconnects and restarts VM if it traffic
stops comming through.

## Setup

``` nix
  inputs = {
    vbox-vpn.url = "github:yaitskov/nixos-vpn-via-vbox";
  };
  # ...
    modules = [
    # ...
    vbox-vpn.nixosModules.${system}.default
    ({ ... }: {
      services.vbox-vpn = {
        enable = true;
        user = "dan";
        vm-name = "oeu";
      };
    })
    ];
  # ...
```

### Requirements to VM networking
The VM should work as a router forwarding all traffic back.
Kill switch should be disabled in VPN.

Example for Debian 13.

Turn off default route management by NetworkManager and set name server

``` shell
nmcli --fields UUID,TYPE  connection show | grep ethernet | \
  while read CU _CT ; do
    nmcli con mod $CU ipv4.dns 8.8.8.8
    nmcli con mod $CU ipv4.never-default yes
  done

```

#### /etc/systemd/system/set-gw.service

``` ini
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
```

#### /etc/systemd/system/set-gw.sh

``` shell
#!/bin/bash

set -e
set -x

ip route replace default via 192.168.56.1 dev enp0s3

```

#### /etc/systemd/system/router.sh

``` ini
[Unit]
Description=Forwarding Packets
After=network-online.target
Requires=network-online.target
[Service]
Type=simple
ExecStart=/etc/systemd/system/router.sh

[Install]
WantedBy=multi-user.target
```

#### /etc/systemd/system/router.sh

``` shell
#!/bin/bash

set -e
set -x

echo 1 > /proc/sys/net/ipv4/ip_forward
echo 0 > /proc/sys/net/ipv4/conf/enp0s3/send_redirects

iptables -A FORWARD  -j ACCEPT
iptables -t nat -A POSTROUTING -j MASQUERADE

```

## See also

[vpn-router](https://github.com/yaitskov/vpn-router) to allows devices
on local network bypass VPN with a click.
