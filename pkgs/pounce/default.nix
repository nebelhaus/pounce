{
  lib,
  stdenvNoCC,
  darwin,
  # The nebelung palette as a name -> "#hex" attrset (from the nebelung flake).
  # This is the single source of truth for the default theme; the Swift below is
  # generated from it at build time so a palette change in nebelung flows here on
  # the next `nix flake update nebelung && nix build` — no hand-copied hex.
  nebelungPalette,
}:

let
  # nebelung's field names don't line up 1:1 with pounce's Palette roles: pounce's
  # `subtext`/`subtext0` map to nebelung's `subtext0`/`overlay0`. Everything else
  # is the same name. Values arrive as "#rrggbb"; Color(hex:) wants no '#'.
  hex = name: lib.removePrefix "#" nebelungPalette.${name};
  nebelungSwift = ''
    // AUTO-GENERATED at build time from the nebelung flake's `palette` output.
    // Do not edit by hand — change palette/nebelung.hex.json in nebelung instead,
    // then `nix flake update nebelung` here. See pkgs/pounce/default.nix.
    import SwiftUI

    extension Palette {
        static let nebelung = Palette(
            base:     Color(hex: "${hex "base"}"),
            surface0: Color(hex: "${hex "surface0"}"),
            surface1: Color(hex: "${hex "surface1"}"),
            surface2: Color(hex: "${hex "surface2"}"),
            text:     Color(hex: "${hex "text"}"),
            subtext:  Color(hex: "${hex "subtext0"}"),
            subtext0: Color(hex: "${hex "overlay0"}"),
            mauve:    Color(hex: "${hex "mauve"}"),
            blue:     Color(hex: "${hex "blue"}"))
    }
  '';
  nebelungSwiftFile = builtins.toFile "Palette+nebelung.generated.swift" nebelungSwift;
in

stdenvNoCC.mkDerivation {
  pname = "pounce";
  version = "0.5.0";

  src = ./.;

  # Use system Swift via xcrun (from Xcode Command Line Tools)
  # This avoids building the entire Swift toolchain from source
  nativeBuildInputs = [ darwin.cctools ];

  buildPhase = ''
    # The nebelung palette, rendered from the flake input (see the let-block).
    cp ${nebelungSwiftFile} Palette+nebelung.generated.swift

    # Compile + assemble via the shared build script (also used by the Homebrew
    # formula in nebelhaus/homebrew-tap) so the two packagings never drift.
    POUNCE_VERSION="$version" bash ./build.sh
  '';

  installPhase = ''
    mkdir -p $out/Applications
    cp -r Pounce.app $out/Applications/

    mkdir -p $out/bin
    ln -s $out/Applications/Pounce.app/Contents/MacOS/pounce $out/bin/pounce
    cp ports $out/bin/ports
    chmod +x $out/bin/ports
  '';

  # The rendered palette Swift, for packagers that build without Nix: the
  # release workflow bakes it into the source tarball via
  #   nix eval --raw .#packages.<sys>.pounce.paletteSwift
  # so a Homebrew build gets the exact palette this flake.lock pins.
  passthru.paletteSwift = nebelungSwift;

  meta = {
    description = "A minimal dmenu-like picker for macOS";
    platforms = lib.platforms.darwin;
  };
}
