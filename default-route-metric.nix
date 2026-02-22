{ pkgs
, ...
}:
pkgs.writeShellApplication {
  name = "default-route-metric";
  runtimeInputs = with pkgs; [ iproute2 ];
  text =
    ''
    [ "$(ip route list | grep -c '^default')" -gt 1 ]  && { echo "Multiple default routes"; exit 1 ; }
    ip route list | grep '^default' | grep -Eo ' metric [0-9]+'
    '';
}
