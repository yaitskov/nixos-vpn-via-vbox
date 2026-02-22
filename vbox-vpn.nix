{ config
, lib
, pkgs
, ...
}:
let
  cfg = config.services.vbox-vpn;
  inherit (lib) mkOption types optionals;
  inherit (types) ints;
  default-route-metric = import ./default-route-metric.nix { inherit pkgs; };
in
{
  options.services.vbox-vpn = {
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
  };
  config =
    let
      vpn-vm = pkgs.writeShellApplication {
        name = "vpn-vm";
        runtimeInputs = with pkgs; [ ];
        text =
          ''
          set -x
          # https://discourse.nixos.org/t/vagrant-and-virtualbox-fail-to-run-in-a-systemd-unit/24084/4
          export PATH=/run/current-system/sw/bin:$PATH
          function cleanup() {
            set +e
            VBoxManage controlvm "${cfg.vm-name}" poweroff
            systemd-notify --stopping
            exit 0
          }
          function reload() {
            echo Doing reload...
            VBoxManage controlvm "${cfg.vm-name}" poweroff || true
            VBoxManage startvm --type headless "${cfg.vm-name}"
            systemd-notify --reloading
          }
          trap reload SIGHUP
          trap 'cleanup' SIGINT
          trap 'cleanup' SIGQUIT
          trap 'cleanup' EXIT
          echo "Check status of VM ${cfg.vm-name}"
          if VBoxManage showvminfo "${cfg.vm-name}" | grep '^State: *running' ; then
            echo "VM ${cfg.vm-name} is aready running"
          else
            VBoxManage startvm --type headless "${cfg.vm-name}"
            while : ; do
              VBoxManage showvminfo "${cfg.vm-name}" | grep '^State: *running' && break
              echo "Wait for VM ${cfg.vm-name} to start"
              sleep 2
            done
          fi
          systemd-notify --ready
          set +e
          while : ; do
            if VBoxManage showvminfo "${cfg.vm-name}" | grep '^State: *running' ; then
              sleep 123
            else
              VBoxManage startvm --type headless "${cfg.vm-name}"
            fi
          done
          '';
      };
      vpn-routing = pkgs.writeShellApplication {
        name = "vpn-routing";
        runtimeInputs = with pkgs; [iputils iproute2 iptables dig default-route-metric];
        text =
          ''
          set -x
          GWNIC=
          GWIP=
          VMIP="$(dig "${cfg.vm-dns}" +short)"
          VMNET="$(ip route list | grep "dev ${cfg.vm-nic}" | while read -r N _R ; do echo "$N" ; done)"
          DEFAULT_ROUTE_METRIC="$(default-route-metric)"
          while read -r _default _via GWIP_R _dev GWNIC_R _rest ; do
            GWIP="$GWIP_R"
            GWNIC="$GWNIC_R"
            echo "GWIP = $GWIP; GWNIC = $GWNIC"
          done < <(ip route list | grep '^default')

          echo "Start init. Check Host is Online"
          while : ; do
            ping -I "$GWNIC" -W 3 -c 1 "${cfg.ping-target}" && break
            sleep 1
          done
          echo "Host is Online"

          function cleanup() {
            set +e
            echo "Start cleanup. GWIP = $GWIP; GWNIC = $GWNIC"
            # shellcheck disable=SC2086
            [ -n "$GWIP" ] && [ -n "$GWNIC" ] && ip route replace default via "$GWIP" dev "$GWNIC" $DEFAULT_ROUTE_METRIC
            ip route flush table "${toString cfg.routing-table}"
            ip rule list | grep "fwmark 0x${toString cfg.packet-mark} lookup ${toString cfg.routing-table}" | while read -r PREF _REST ; do
              ip rule del pref "''${PREF%:}"
            done
            iptables -t mangle -F PREROUTING
            systemd-notify --stopping
            echo "Cleanup is complete"
            exit 0
          }
          function reload() {
            echo Doing reload...
            systemd-notify --reloading
          }
          trap reload SIGHUP
          trap 'cleanup' SIGINT
          trap 'cleanup' SIGQUIT
          trap 'cleanup' EXIT

          iptables -t nat -C POSTROUTING -s "$VMNET" -j MASQUERADE || \
            iptables -t nat -A POSTROUTING -s "$VMNET" -j MASQUERADE
          ip rule add fwmark "${toString cfg.packet-mark}" table "${toString cfg.routing-table}"
          # Temp rules to check VPN note is up and keep plain connectivity
          ip route replace default via "$VMIP" dev "${cfg.vm-nic}" table "${toString cfg.routing-table}"
          iptables -t mangle -C OUTPUT -d "${cfg.ping-target}" -j MARK --set-mark "${toString cfg.packet-mark}" || \
            iptables -t mangle -A OUTPUT -d "${cfg.ping-target}" -j MARK --set-mark "${toString cfg.packet-mark}"
          while : ; do
            ping -I "${cfg.vm-nic}" -W 1 -c 1 "${cfg.ping-target}" && { echo "VM ${cfg.vm-dns} just started FORWARDING" ; break ; }
            echo "Wait until VM ${cfg.vm-dns} start forwarding packets"
            sleep 1
          done

          # shellcheck disable=SC2086
          ip route replace default via "$VMIP" dev "${cfg.vm-nic}" $DEFAULT_ROUTE_METRIC
          ip route replace default via "$GWIP" dev "$GWNIC" table "${toString cfg.routing-table}"
          iptables -t mangle -F OUTPUT
          iptables -t mangle -C PREROUTING -s "${cfg.vm-dns}" -j MARK --set-mark "${toString cfg.packet-mark}" || \
            iptables -t mangle -A PREROUTING -s "${cfg.vm-dns}" -j MARK --set-mark "${toString cfg.packet-mark}"
          echo "NET routes ${cfg.ping-target} only through ${cfg.vm-dns}"
          ping -W 3 -c 1 "${cfg.ping-target}"
          echo "ALL traffic goes through VM ${cfg.vm-dns}"
          systemd-notify --ready

          while : ; do
            sleep 90
            ping -W 13 -c 1 "${cfg.ping-target}" || {
              echo "VM ${cfg.vm-dns} is OFFLINE. Try ping [${cfg.ping-target}] directly..." ;
              iptables -t mangle -A OUTPUT -d "${cfg.ping-target}" -j MARK --set-mark "${toString cfg.packet-mark}"
              if ping -I "$GWNIC" -W 13 -c 1 "${cfg.ping-target}" ; then
                echo "VM needs to be restarted"
              else
                echo "Total offline just wait"
              fi
              iptables -t mangle -F OUTPUT
            }
          done
          '';
      };
    in
      lib.mkIf cfg.enable {
        boot.kernel.sysctl = {
          "net.ipv4.ip_forward" = 1;
        };

        virtualisation.virtualbox.host.enable = true;
        virtualisation.virtualbox.host.enableExtensionPack = true;
        users.extraGroups.vboxusers.members = [ cfg.user ];

        networking.hosts.${cfg.vm-ipadr} = [cfg.vm-dns];
        systemd.services."vpn-vm" = {
          wantedBy = [ "vpn-routing.service" ];
          requires = [ "vboxnet0.service" ];
          after = [ "vboxnet0.service" ];
          enable = true;
          serviceConfig = {
            User = cfg.user;
            Group = "vboxusers";
            Type = "notify";
            StartLimitBurst = 111;
            StartLimitIntervalSec = 9;
            Restart = "always";
            TimeoutStartSec = 65;
            NotifyAccess = "all";
            ExecStart = "${vpn-vm}/bin/vpn-vm ${cfg.vm-name}";
          };
        };

        systemd.services."vpn-routing" = {
          wantedBy = [ "network-online.target" ];
          requires = [ "vpn-vm.service" "network-online.target" ];
          after = [ "vpn-vm.service" "network-online.target" ];
          enable = true;
          serviceConfig = {
            User = "root";
            Group = "root";
            Type = "notify";
            StartLimitBurst = 1110;
            StartLimitIntervalSec = 4;
            Restart = "always";
            TimeoutStartSec = 26;
            NotifyAccess = "all";
            ExecStart = "${vpn-routing}/bin/vpn-routing";
          };
        };
      };
}
