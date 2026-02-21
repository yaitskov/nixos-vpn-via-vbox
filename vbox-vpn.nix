{ config
, lib
, pkgs
, ...
}:
let
  cfg = config.services.literal-flake-input;
  inherit (lib) mkOption types optionals;
  inherit (types) ints;
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
      forwarding all traffic back. VM networking mode is Host-Only
      '';
    };
    packet-mark = mkOption {
      type = types.int;
      default = 2;
      description = "IP packet mark used for choosing alternative routing for traffict from VM";
    };
    routing-table = mkOption {
      type = types.int;
      default = 7;
      description = "routing table with alternaitve default route for traffict from VM";
    };
    ping-target = mkOption {
      type = types.str;
      default = "1.1.1.1";
      description = "Highly available IP address on the Internet";
    };
    vm-nic = mkOption {
      type = types.str;
      default = "vboxnet0";
      description = "Highly available IP address on the Internet";
    };
  };
  vpn-vm = pkgs.writeShellApplication {
    name = "vpn-vm";
    runtimeInputs = with pkgs; [ ];
    text =
      ''
      set -x
      VM=$1
      # https://discourse.nixos.org/t/vagrant-and-virtualbox-fail-to-run-in-a-systemd-unit/24084/4
      export PATH=/run/current-system/sw/bin:$PATH
      # ~ /nix/store/5rs2y36h430jzw4j97s6df5a1m51yzhp-virtualbox-7.2.6/bin:$PATH
      function cleanup() {
        set +e
        VBoxManage controlvm "$VM" poweroff
        systemd-notify --stopping
        exit 0
      }
      function reload() {
        echo Doing reload...
        VBoxManage controlvm "$VM" poweroff || true
        VBoxManage startvm --type headless "$VM"
        systemd-notify --reloading
      }
      trap reload SIGHUP
      trap 'cleanup' SIGINT
      trap 'cleanup' SIGQUIT
      trap 'cleanup' EXIT
      echo "Check status of VM $VM"
      if VBoxManage showvminfo "$VM" | grep '^State: *running' ; then
        echo "VM $VM is aready running"
      else
        VBoxManage startvm --type headless "$VM"
        while : ; do
          VBoxManage showvminfo "$VM" | grep '^State: *running' && break
          echo "Wait for VM $VM to start"
          sleep 2
        done
      fi
      systemd-notify --ready
      set +e
      while : ; do
        if VBoxManage showvminfo "$VM" | grep '^State: *running' ; then
          sleep 123
        else
          VBoxManage startvm --type headless "$VM"
        fi
      done
      '';
  };
  vpn-routing = pkgs.writeShellApplication {
    name = "vpn-routing";
    runtimeInputs = with pkgs; [iputils iproute2 iptables dig];
    text =
      ''
      set -x
      VMNIC=$1
      VMDNS=$2
      GWNIC=
      GWIP=
      VMIP="$(dig "$VMDNS" +short)"
      ROUTING_TABLE=7
      PING_TARGET=1.1.1.1
      PACKET_MARK=2
      VMNET="$(ip route list | grep "dev $VMNIC" | while read -r N _R ; do echo "$N" ; done)"
      while read -r _default _via GWIP_R _dev GWNIC_R _rest ; do
        GWIP="$GWIP_R"
        GWNIC="$GWNIC_R"
        echo "GWIP = $GWIP; GWNIC = $GWNIC"
      done < <(ip route list | grep '^default')

      echo "Start init. Check Host is Online"
      while : ; do
        ping -I "$GWNIC" -W 3 -c 1 "$PING_TARGET" && break
        sleep 1
      done
      echo "Host is Online"

      function cleanup() {
        set +e
        echo "Start cleanup. GWIP = $GWIP; GWNIC = $GWNIC"
        [ -n "$GWIP" ] && [ -n "$GWNIC" ] && ip route replace default via "$GWIP" dev "$GWNIC"
        ip route flush table "$ROUTING_TABLE"
        ip rule list | grep "fwmark 0x$PACKET_MARK lookup $ROUTING_TABLE" | while read -r PREF _REST ; do
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
      ip rule add fwmark "$PACKET_MARK" table "$ROUTING_TABLE"
      # Temp rules to check VPN note is up and keep plain connectivity
      ip route replace default via "$VMIP" dev "$VMNIC" table "$ROUTING_TABLE"
      iptables -t mangle -C OUTPUT -d "$PING_TARGET" -j MARK --set-mark "$PACKET_MARK" || \
        iptables -t mangle -A OUTPUT -d "$PING_TARGET" -j MARK --set-mark "$PACKET_MARK"
      while : ; do
        ping -I "$VMNIC" -W 1 -c 1 "$PING_TARGET" && { echo "VM $VMDNS just started FORWARDING" ; break ; }
        echo "Wait until VM $VMDNS start forwarding packets"
        sleep 1
      done

      # ip rule list
      # 0:	from all lookup local
      # 32765:	from all fwmark 0x2 lookup 7
      ip route replace default via "$VMIP" dev "$VMNIC"
      ip route replace default via "$GWIP" dev "$GWNIC" table "$ROUTING_TABLE"
      iptables -t mangle -F OUTPUT
      iptables -t mangle -C PREROUTING -s "$VMDNS" -j MARK --set-mark "$PACKET_MARK" || \
        iptables -t mangle -A PREROUTING -s "$VMDNS" -j MARK --set-mark "$PACKET_MARK"
      echo "NET routes $PING_TARGET only through $VMDNS"
      ping -W 3 -c 1 "$PING_TARGET"
      echo "ALL traffic goes through VM $VMDNS"
      systemd-notify --ready

      while : ; do
        sleep 90
        ping -W 13 -c 1 "$PING_TARGET" || {
          echo "VM $VMDNS is OFFLINE. Try ping [$PING_TARGET] directly..." ;
          iptables -t mangle -A OUTPUT -d "$PING_TARGET" -j MARK --set-mark "$PACKET_MARK"
          if ping -I "$GWNIC" -W 13 -c 1 "$PING_TARGET" ; then
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
{
  imports = [
    ../vbox.nix
  ];

  networking.hosts = { "192.168.56.101" = ["vpn"]; };


  systemd.services."vpn-vm" = {
    wantedBy = [ "vpn-routing.service" ];
    requires = [ "vboxnet0.service" ];
    after = [ "vboxnet0.service" ];
    enable = true;
    serviceConfig = {
      User = "don";
      Group = "vboxusers";
      Type = "notify";
      StartLimitBurst = 111;
      StartLimitIntervalSec = 9;
      Restart = "always";
      TimeoutStartSec = 65;
      NotifyAccess = "all";
      ExecStart = "${vpn-vm}/bin/vpn-vm oeu";
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
      ExecStart = "${vpn-routing}/bin/vpn-routing vboxnet0 vpn";
    };
  };
}
