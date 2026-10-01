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
    // Remove, review, and keep are the same three values in the Qt window
    // (`toneFrom` in ui/linux-qt/main.cpp) and in the CLI (`CliTone` in
    // Sources/AppAtticScan/CLIParse.swift). The system reds and greens are not
    // those values: on a light pane system green reads 1.9:1 against white,
    // so the light pair is spelled out. Both are Apple's dark system values,
    // which the shared dark pair already matches.
    //
    // Written as bytes over 255, so one value is spelled the same way in all
    // three shells and a level cannot drift by a rounding step between them.
    // The light green was the one that had: it sat at 4.40:1 on white, under
    // the 4.5:1 the red and amber above hold and the Qt shell measures its
    // own tones against. It now carries the shared 28/110/48 (6.32:1).
    static let appRed = Color.adaptive(
        light: Color(red: 192.0 / 255.0, green: 28.0 / 255.0, blue: 40.0 / 255.0),
        dark: Color(red: 255.0 / 255.0, green: 69.0 / 255.0, blue: 58.0 / 255.0)
    )
    static let appYellow = Color.adaptive(
        light: Color(red: 158.0 / 255.0, green: 102.0 / 255.0, blue: 0.0),
        dark: Color(red: 255.0 / 255.0, green: 214.0 / 255.0, blue: 10.0 / 255.0)
    )
    static let appGreen = Color.adaptive(
        light: Color(red: 28.0 / 255.0, green: 110.0 / 255.0, blue: 48.0 / 255.0),
        dark: Color(red: 48.0 / 255.0, green: 209.0 / 255.0, blue: 88.0 / 255.0)
    )
}

/// Spacing and shape scale, the same steps `kSpace*` give the Qt shell
/// (`ui/linux-qt/uistyle.h`). A gap, margin, or padding is one of these, so a
/// page reads at the same density whichever shell draws it. `tight` is the one
/// step below the scale, for a label sitting on the value it labels.
enum Metrics {
    static let tight: Double = 2
    static let xs: Double = 4
    static let sm: Double = 8
    static let md: Double = 12
    static let lg: Double = 16
    /// Corner radius of a selected sidebar row and of the small chrome blocks.
    static let radiusSm: Double = 4
    static let radiusMd: Double = 6
}

/// Type roles, the same ones the `aa*Font` functions in `uistyle.h` give the
/// Qt shell. One scale, so a level means the same thing on both platforms.
/// These are the macOS point sizes. The Qt shell derives each role from the
/// desktop application font instead, so the same role can be a different step
/// there: `aaSmallFont` steps one down, not two. Body is 13; the only steps
/// around it are small and instrument value. Nothing sits in between, and
/// nothing goes to display size: this is a utility.
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
