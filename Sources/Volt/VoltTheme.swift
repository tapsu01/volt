import AppKit
import SwiftUI

enum VoltTheme {
    static let hairline = dynamicColor(
        light: NSColor(calibratedRed: 0.86, green: 0.88, blue: 0.91, alpha: 1),
        dark: NSColor(calibratedRed: 0.22, green: 0.23, blue: 0.25, alpha: 1)
    )
    static let appBackground = dynamicColor(
        light: NSColor(calibratedRed: 0.985, green: 0.99, blue: 0.995, alpha: 1),
        dark: NSColor(calibratedRed: 0.10, green: 0.105, blue: 0.115, alpha: 1)
    )
    static let toolbarBackground = dynamicColor(
        light: NSColor(calibratedRed: 0.985, green: 0.99, blue: 0.995, alpha: 1),
        dark: NSColor(calibratedRed: 0.12, green: 0.125, blue: 0.135, alpha: 1)
    )
    static let sidebarBackground = dynamicColor(
        light: NSColor(calibratedRed: 0.965, green: 0.975, blue: 0.988, alpha: 1),
        dark: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.15, alpha: 1)
    )
    static let paneBackground = dynamicColor(
        light: .white,
        dark: NSColor(calibratedRed: 0.085, green: 0.09, blue: 0.10, alpha: 1)
    )
    static let controlBackground = dynamicColor(
        light: .white,
        dark: NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.18, alpha: 1)
    )
    static let transferBackground = dynamicColor(
        light: NSColor(calibratedRed: 0.955, green: 0.965, blue: 0.978, alpha: 1),
        dark: NSColor(calibratedRed: 0.115, green: 0.12, blue: 0.13, alpha: 1)
    )
    static let transferPanelBackground = dynamicColor(
        light: NSColor(calibratedRed: 0.985, green: 0.988, blue: 0.993, alpha: 1),
        dark: NSColor(calibratedRed: 0.14, green: 0.145, blue: 0.155, alpha: 1)
    )
    static let selectedFill = Color.accentColor.opacity(0.12)
    static let rowStripe = dynamicColor(
        light: NSColor(calibratedRed: 0.965, green: 0.978, blue: 0.995, alpha: 1),
        dark: NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.18, alpha: 1)
    )
    static let mutedText = Color.secondary

    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let bestMatch = appearance.bestMatch(from: [.darkAqua, .aqua])
            return bestMatch == .darkAqua ? dark : light
        })
    }
}
