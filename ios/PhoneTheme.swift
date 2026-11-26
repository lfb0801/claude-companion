import SwiftUI

/// Catppuccin Latte in light mode, Mocha in dark mode.
struct Palette {
  let base, mantle, crust, surface0, surface1, overlay, text, subtext: Color
  let mauve, red, blue, green, peach, teal: Color

  static let mocha = Palette(
    base: Color(hex: 0x1e1e2e), mantle: Color(hex: 0x181825), crust: Color(hex: 0x11111b),
    surface0: Color(hex: 0x313244), surface1: Color(hex: 0x45475a), overlay: Color(hex: 0x6c7086),
    text: Color(hex: 0xcdd6f4), subtext: Color(hex: 0xa6adc8),
    mauve: Color(hex: 0xcba6f7), red: Color(hex: 0xf38ba8), blue: Color(hex: 0x89b4fa),
    green: Color(hex: 0xa6e3a1), peach: Color(hex: 0xfab387), teal: Color(hex: 0x94e2d5))

  static let latte = Palette(
    base: Color(hex: 0xeff1f5), mantle: Color(hex: 0xe6e9ef), crust: Color(hex: 0xdce0e8),
    surface0: Color(hex: 0xccd0da), surface1: Color(hex: 0xbcc0cc), overlay: Color(hex: 0x9ca0b0),
    text: Color(hex: 0x4c4f69), subtext: Color(hex: 0x6c6f85),
    mauve: Color(hex: 0x8839ef), red: Color(hex: 0xd20f39), blue: Color(hex: 0x1e66f5),
    green: Color(hex: 0x40a02b), peach: Color(hex: 0xfe640b), teal: Color(hex: 0x179299))

  static func `for`(_ scheme: ColorScheme) -> Palette { scheme == .dark ? .mocha : .latte }

  /// Text on a filled accent: the page colour itself reads on both Latte and Mocha accents.
  var onAccent: Color { base }
}

extension Color {
  init(hex: UInt32) {
    self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
  }
}
