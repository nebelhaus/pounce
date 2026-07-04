import SwiftUI

// MARK: - Theme

// A palette is the full set of colors the UI paints with. Add a new one below and
// expose it from `named(_:)` to make it selectable via `"theme"` in config.json.
struct Palette {
    let base, surface0, surface1, surface2: Color
    let text, subtext, subtext0: Color
    let mauve, blue: Color   // accent (selection/highlight) + secondary accent

    // nebelung — the custom desaturated Catppuccin used across the nebelhaus rice,
    // and the default theme. Its `static let nebelung` is GENERATED at build time
    // from the nebelung flake's palette (see pkgs/pounce/default.nix), so it lives
    // in Palette+nebelung.generated.swift rather than here.

    // mocha — stock Catppuccin Mocha (pounce's original look).
    static let mocha = Palette(
        base:     Color(hex: "1e1e2e"),
        surface0: Color(hex: "313244"),
        surface1: Color(hex: "45475a"),
        surface2: Color(hex: "585b70"),
        text:     Color(hex: "cdd6f4"),
        subtext:  Color(hex: "a6adc8"),
        subtext0: Color(hex: "6c7086"),
        mauve:    Color(hex: "cba6f7"),
        blue:     Color(hex: "89b4fa"))

    static func named(_ name: String) -> Palette {
        switch name.lowercased() {
        case "mocha": return .mocha
        default:      return .nebelung
        }
    }
}

// Static façade over the active palette so views keep reading `Theme.base` etc.
// `current` is swapped in per request from the loaded Settings (see the socket
// handler), so editing `"theme"` in config.json takes effect on the next open.
enum Theme {
    static var current: Palette = .nebelung

    static var base: Color { current.base }
    static var surface0: Color { current.surface0 }
    static var surface1: Color { current.surface1 }
    static var surface2: Color { current.surface2 }
    static var text: Color { current.text }
    static var subtext: Color { current.subtext }
    static var subtext0: Color { current.subtext0 }
    static var mauve: Color { current.mauve }
    static var blue: Color { current.blue }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}
