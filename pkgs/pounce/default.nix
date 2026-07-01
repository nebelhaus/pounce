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
  version = "0.2.0";

  src = ./.;

  # Use system Swift via xcrun (from Xcode Command Line Tools)
  # This avoids building the entire Swift toolchain from source
  nativeBuildInputs = [ darwin.cctools ];

  buildPhase = ''
    mkdir -p Pounce.app/Contents/MacOS

    # The nebelung palette, rendered from the flake input (see the let-block).
    cp ${nebelungSwiftFile} Palette+nebelung.generated.swift

    # Use xcrun to invoke the system's Swift compiler
    /usr/bin/xcrun swiftc -parse-as-library -o Pounce.app/Contents/MacOS/pounce \
      main.swift Palette+nebelung.generated.swift \
      -framework SwiftUI \
      -framework AppKit \
      -framework ApplicationServices \
      -O

    cp Info.plist Pounce.app/Contents/

    # Bundle the emoji dataset (read at runtime via Bundle.main).
    mkdir -p Pounce.app/Contents/Resources
    cp emoji.json Pounce.app/Contents/Resources/
  '';

  installPhase = ''
    mkdir -p $out/Applications
    cp -r Pounce.app $out/Applications/

    mkdir -p $out/bin
    ln -s $out/Applications/Pounce.app/Contents/MacOS/pounce $out/bin/pounce
    cp ports $out/bin/ports
    chmod +x $out/bin/ports
  '';

  meta = {
    description = "A minimal dmenu-like picker for macOS";
    platforms = lib.platforms.darwin;
  };
}
