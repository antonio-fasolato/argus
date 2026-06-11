import SwiftUI
import AppKit

extension Color {
    static let appBg = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.047, green: 0.047, blue: 0.063, alpha: 1)
            : NSColor(srgbRed: 0.96,  green: 0.96,  blue: 0.97,  alpha: 1)
    })

    static let appSidebar = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.055, green: 0.055, blue: 0.075, alpha: 1)
            : NSColor(srgbRed: 0.93,  green: 0.93,  blue: 0.95,  alpha: 1)
    })

    static let appSurface = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.086, green: 0.086, blue: 0.110, alpha: 1)
            : NSColor(srgbRed: 0.99,  green: 0.99,  blue: 1.00,  alpha: 1)
    })

    static let appBorder = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.145, green: 0.145, blue: 0.188, alpha: 1)
            : NSColor(srgbRed: 0.86,  green: 0.86,  blue: 0.90,  alpha: 1)
    })

    static let appTextPrimary = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)
    })

    static let appTextSecondary = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.55, alpha: 1)
            : NSColor(srgbRed: 0.40, green: 0.40, blue: 0.44, alpha: 1)
    })

    static let appTextTertiary = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.35, alpha: 1)
            : NSColor(srgbRed: 0.60, green: 0.60, blue: 0.64, alpha: 1)
    })

    static let appAccent  = Color(red: 0.486, green: 0.416, blue: 0.969)
    static let appGold    = Color(red: 0.950, green: 0.780, blue: 0.220)

    static let modelOpus   = Color(red: 0.612, green: 0.384, blue: 0.922)
    static let modelSonnet = Color(red: 0.275, green: 0.565, blue: 0.902)
    static let modelHaiku  = Color(red: 0.306, green: 0.784, blue: 0.471)

    static func forModel(_ model: String) -> Color {
        if model.contains("opus")   { return .modelOpus }
        if model.contains("haiku")  { return .modelHaiku }
        return .modelSonnet
    }
}

func formatTokens(_ n: Int) -> String {
    switch n {
    case let x where x >= 1_000_000_000: return String(format: "%.1fB", Double(x) / 1_000_000_000)
    case let x where x >= 1_000_000:     return String(format: "%.1fM", Double(x) / 1_000_000)
    case let x where x >= 1_000:         return String(format: "%.1fK", Double(x) / 1_000)
    default: return "\(n)"
    }
}

func formatCost(_ cost: Double) -> String {
    if cost >= 1000  { return String(format: "$%.1fK", cost / 1000) }
    if cost >= 1     { return String(format: "$%.2f", cost) }
    if cost >= 0.001 { return String(format: "$%.3f", cost) }
    return String(format: "$%.4f", cost)
}

func modelDisplayName(_ model: String) -> String {
    model
        .replacingOccurrences(of: "claude-", with: "")
        .replacingOccurrences(of: "-20250929", with: "")
        .replacingOccurrences(of: "-20251001", with: "")
        .split(separator: "-")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

// Ingestion source ids stored in messages.source ("claude_code" | "cowork")
func sourceDisplayName(_ source: String) -> String {
    switch source {
    case "claude_code": return "Claude Code"
    case "cowork":      return "Cowork"
    case "chat":        return "Chat"
    default:
        return source
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

func sourceIconName(_ source: String) -> String {
    switch source {
    case "claude_code": return "terminal"
    case "cowork":      return "macwindow"
    case "chat":        return "bubble.left"
    default:            return "questionmark.circle"
    }
}
