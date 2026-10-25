import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable {
    case system, light, sepia, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .sepia: "Sepia"
        case .dark: "Dark"
        }
    }

    /// Resolves `.system` against the current color scheme.
    func resolved(for scheme: ColorScheme) -> ReaderTheme {
        guard self == .system else { return self }
        return scheme == .dark ? .dark : .light
    }

    var backgroundHex: String {
        switch self {
        case .system, .light: "#FFFFFF"
        case .sepia: "#F4ECD8"
        case .dark: "#1C1C1E"
        }
    }

    var textHex: String {
        switch self {
        case .system, .light: "#1D1D1F"
        case .sepia: "#5B4636"
        case .dark: "#E5E5E7"
        }
    }

    var linkHex: String {
        switch self {
        case .system, .light: "#0A64C8"
        case .sepia: "#8A5A2B"
        case .dark: "#6CB4FF"
        }
    }

    var background: Color { Color(hex: backgroundHex) }
    var foreground: Color { Color(hex: textHex) }
    var isDark: Bool { self == .dark }
}

enum ReaderFont: String, CaseIterable, Identifiable {
    case publisher, serif, sans

    var id: String { rawValue }

    var label: String {
        switch self {
        case .publisher: "Original"
        case .serif: "Serif"
        case .sans: "Sans Serif"
        }
    }

    var cssFamily: String? {
        switch self {
        case .publisher: nil
        case .serif: "ui-serif, 'New York', Georgia, serif"
        case .sans: "system-ui, -apple-system, 'Helvetica Neue', sans-serif"
        }
    }
}

/// Reader appearance, persisted in user defaults and shared by every book.
struct ReaderAppearance: Equatable {
    var theme: ReaderTheme
    var font: ReaderFont
    var fontScale: Double
    var lineHeight: Double

    static let fontScaleRange = 0.7...2.2

    /// CSS injected into every chapter. Publisher colors are overridden so themes always apply.
    var css: String {
        var rules = [
            """
            :root { color-scheme: \(theme.isDark ? "dark" : "light"); }
            html, body { background-color: \(theme.backgroundHex) !important; color: \(theme.textHex) !important; }
            body {
              max-width: 42em !important;
              margin: 0 auto !important;
              padding: 2.5em 1.4em 5em !important;
              line-height: \(lineHeight) !important;
              -webkit-text-size-adjust: 100%;
              overflow-wrap: break-word;
            }
            p, li, blockquote, dd, dt, td, th, div, span, h1, h2, h3, h4, h5, h6 {
              color: inherit !important;
              background-color: transparent !important;
              line-height: inherit;
            }
            a, a * { color: \(theme.linkHex) !important; }
            img, svg, video, image { max-width: 100% !important; height: auto !important; }
            pre { white-space: pre-wrap; }
            """,
        ]
        if let family = font.cssFamily {
            rules.append("body, p, li, div, span, blockquote, td { font-family: \(family) !important; }")
        }
        if theme.isDark {
            rules.append("img { filter: brightness(0.9); }")
        }
        return rules.joined(separator: "\n")
    }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
