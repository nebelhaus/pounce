{
  description = "Pounce — a native, scriptable command palette for macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # nebelung is the single source of truth for the default palette; its
    # `palette` output is a plain name -> "#hex" attrset baked into the binary
    # at build time (see pkgs/pounce). Only the palette output is used — the
    # theme-builder packages are never realised — so this stays a pure eval.
    nebelung.url = "github:nebelhaus/nebelung";
    nebelung.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, nebelung }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAll = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };
    in
    {
      # Consume pounce from anywhere: `overlays.default` puts `pounce` and
      # `pounce-commands` into pkgs.
      overlays.default = final: prev: {
        pounce = final.callPackage ./pkgs/pounce { nebelungPalette = nebelung.palette; };
        pounce-commands = final.callPackage ./pkgs/pounce-commands { };
      };

      packages = forAll (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.pounce;
          pounce = pkgs.pounce;
          pounce-commands = pkgs.pounce-commands;
        }
      );

      # `nix run github:nebelhaus/pounce`
      apps = forAll (system: {
        default = {
          type = "app";
          program = "${(pkgsFor system).pounce}/bin/pounce";
        };
      });
    };
}
