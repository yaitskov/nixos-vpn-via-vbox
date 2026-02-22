{ pkgs
, cfg
, ...
}:
pkgs.writeShellApplication {
  name = "vpn-routing";
  runtimeInputs = with pkgs; [iputils iproute2 iptables dig networkmanager];
  text =
    ''
    set -x
    GWNIC=
    GWIP=
    VMIP="$(dig "${cfg.vm-dns}" +short)"
    VMNET="$(ip route list | grep "dev ${cfg.vm-nic}" | while read -r N _R ; do echo "$N" ; done)"

    function restartOnReconnect() {
      nmcli monitor | while read -r a ; do
        if [ "Connectivity is now 'full'" == "$a" ] ; then
          echo "Restart to fix default route after NetworkManager"
          kill "$1"
          break
        fi
      done
    }

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

    restartOnReconnect "$$" &
    function cleanDefaults() {
      while ip route del default ; do : ; done
    }
    function cleanup() {
      set +e
      echo "Start cleanup. GWIP = $GWIP; GWNIC = $GWNIC"
      [ -n "$GWIP" ] && [ -n "$GWNIC" ] && {
        cleanDefaults
        ip route add default via "$GWIP" dev "$GWNIC"
      }
      ip route flush table "${toString cfg.routing-table}"
      ip rule list | \
        grep "fwmark 0x${toString cfg.packet-mark} lookup ${toString cfg.routing-table}" | \
        while read -r PREF _REST ; do
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

    cleanDefaults
    ip route add default via "$VMIP" dev "${cfg.vm-nic}"
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
          systemctl restart vpn-vm
        else
          echo "Total offline just wait"
        fi
        iptables -t mangle -F OUTPUT
      }
    done
    '';
}
