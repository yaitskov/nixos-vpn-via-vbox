{
  description = "NixOS service vbox-vpn - setups a specificeLiteral Flake Inputs";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/bc16855ba53f3cb6851903a393e7073d1b5911e7";
  };
  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        packageName = "vbox-vpn";
        pkgs = nixpkgs.legacyPackages.${system};
      in
        nixosModules.default = import ./vbox-vpn.nix;
    );
}
