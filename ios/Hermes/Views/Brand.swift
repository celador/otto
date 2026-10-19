import SwiftUI

enum Theme {
    #if os(macOS)
    /// The Hermes desktop's orange, so Otto on the Mac sits next to it naturally.
    static let accent = Color("MacAccent")
    #else
    static let accent = Color("AccentColor")
    #endif
    /// The "working" orange (status line dot, sidebar dots): the Hermes desktop's accent on every platform.
    static var working: Color {
        #if os(macOS)
        accent
        #else
        Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0xE0 / 255, green: 0x8E / 255, blue: 0x4C / 255, alpha: 1)
            : UIColor(red: 0xC8 / 255, green: 0x76 / 255, blue: 0x31 / 255, alpha: 1) })
        #endif
    }
}

/// The Otto mark (O ring + offset dot), vector, tinted to the text color.
struct OttoMark: View {
    var size: CGFloat = 48

    var body: some View {
        Image("OttoMark")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.primary)
            .accessibilityHidden(true)
    }
}
extension View {
    /// Icon buttons and menus drawn by their own labels (the composer row, reply actions).
    /// iOS already draws them this way; the Mac would otherwise add bezels and menu arrows.
    @ViewBuilder func bareControls() -> some View {
        #if os(macOS)
        self.buttonStyle(.plain).menuStyle(.button).menuIndicator(.hidden)
        #else
        self
        #endif
    }
}
