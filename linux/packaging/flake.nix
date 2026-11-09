{
  description = "Pleazyng packages from immutable, checksum-pinned Linux releases";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/4fe25e12eb9f4c744966dd3de5a05246cf098601";
  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forSystems = function: builtins.listToAttrs (map (system: {
        name = system;
        value = function system;
      }) systems);
    in {
      packages = forSystems (system:
        let
          package = import ./nix/default.nix {
            pkgs = import nixpkgs { inherit system; };
          };
        in {
          pleazyng = package;
          default = package;
        });
    };
}
