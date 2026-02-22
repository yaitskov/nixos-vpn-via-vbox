{ config
, lib
, pkgs
, ...
}:
let
  cfg = config.services.vbox-vpn;
  inherit (lib) mkOption types;
  inherit (types) ints;
  vpn-routing = import ./vpn-routing.nix { inherit pkgs cfg; };
in
{
  options.services.vbox-vpn = import ./options.nix { inherit lib; };
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
            StartLimitInterval = 9;
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
            StartLimitInterval = 4;
            Restart = "always";
            TimeoutStartSec = 26;
            NotifyAccess = "all";
            ExecStart = "${vpn-routing}/bin/vpn-routing";
          };
        };
      };
}
