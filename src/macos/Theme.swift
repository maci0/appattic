import SwiftCrossUI

extension Color {
    /// Primary label. Adaptive so text stays visible on the AppKit
    /// sidebar material (NSVisualEffectView).
    static let appText = Color.adaptive(
        light: Color(white: 0.12),
        dark: Color(white: 0.96)
    )
    static let appDim = Color.adaptive(
        light: Color(white: 0.32),
        dark: Color(white: 0.68)
    )
    /// List and inspector fill. White in light mode, like Finder.
    static let appBg = Color.adaptive(
        light: Color.white,
        dark: Color(red: 30.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0)
    )
    /// Window chrome: toolbar and status bar. Slightly darker than list fill
    /// so the bar reads as Finder chrome, not a second white pane.
    static let appChrome = Color.adaptive(
        light: Color(white: 0.90),
        dark: Color(red: 46.0 / 255.0, green: 46.0 / 255.0, blue: 46.0 / 255.0)
    )
    /// Row and pane separators. Stronger than SwiftCrossUI Divider (10% black).
    static let appHairline = Color.adaptive(
        light: Color(white: 0.76),
        dark: Color(white: 0.30)
    )
    static let appBlue = Color.system(.blue)
    static let appOnAccent = Color.white
    static let appRed = Color.system(.red)
    // System yellow is unreadable on a light pane. Darker amber in light mode.
    static let appYellow = Color.adaptive(
        light: Color(red: 0.62, green: 0.40, blue: 0.0),
        dark: Color.system(.yellow)
    )
    static let appGreen = Color.system(.green)
}
