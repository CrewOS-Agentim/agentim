import AppKit
import SwiftUI

/// Design tokens: one place for agentim's colors, spacing and shapes (flat, rounded, purple).
enum Theme {
    // Colors (semantic; adapt to light and dark mode)
    static let accent = Color.accentColor
    static let surface = Color(nsColor: .textBackgroundColor)
    static let surfaceMuted = Color(nsColor: .windowBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let assistantBubble = Color(nsColor: .textBackgroundColor)
    static let warning = Color.orange

    // Spacing (4/8 pt rhythm)
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32

    // Shapes
    static let radiusSmall: CGFloat = 8
    static let radius: CGFloat = 14
    static let radiusLarge: CGFloat = 20

    /// Readable measure for messages and long text.
    static let readableWidth: CGFloat = 760
    /// Minimum click target (Apple HIG).
    static let target: CGFloat = 44
}

extension View {
    /// The playful, rounded headline style used for titles.
    func headlineStyle(_ size: CGFloat = 22) -> some View {
        font(.system(size: size, weight: .bold, design: .rounded))
    }

    /// A flat card: surface fill and a hairline border.
    func card(radius: CGFloat = Theme.radius, padding: CGFloat = Theme.s4) -> some View {
        self.padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.border))
    }
}

/// Agent Tim's avatar (the app icon).
struct TimAvatar: View {
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityLabel("Agent Tim")
    }
}
