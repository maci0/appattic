import Foundation
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

/// Type roles, the same ones the `aa*Font` functions in `uistyle.h` give the
/// Qt shell. One scale, so a level means the same thing on both platforms.
/// Body is 13; the only steps around it are small (one down) and instrument
/// value (two up). Nothing sits in between, and nothing goes to display size:
/// this is a utility.
///
/// `Double`, because `Font.system(size:weight:design:)` takes a `Double`.
enum TypeScale {
    /// Row text, list values, buttons.
    static let body: Double = 13
    /// Secondary columns, counts, status text.
    static let small: Double = 11
    /// Section and page headings, inspector headings.
    static let title: Double = 13
    /// Instrument labels, uppercase, at `small`.
    static let label: Double = 11
    /// Instrument values under a label: body plus two, for the readout.
    static let value: Double = 15
    /// Paths, versions, scripts.
    static let monoBody: Double = 13
    /// Mono in a secondary column.
    static let monoSmall: Double = 11
}
