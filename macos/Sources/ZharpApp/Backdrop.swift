import AppKit

/// The window's background treatment.
///
/// Windows offers Mica and Acrylic; macOS has no equivalent of either, so this
/// exposes the platform's own vocabulary instead - background blur, off or in
/// three strengths, backed by `NSVisualEffectView` materials. The `backdrop`
/// settings key still accepts the Windows names so a settings.json carried over
/// from that build lands on the closest macOS material.
enum Backdrop: String, CaseIterable {
    case off
    case light
    case medium
    case strong

    static func parse(_ raw: String?) -> Backdrop {
        switch raw?.lowercased() {
        case "off", "none", "opaque":
            return .off
        case "medium", "sidebar":
            return .medium
        // Acrylic is Windows' heavy blur; the nearest macOS material is the
        // full-screen UI one.
        case "strong", "hud", "acrylic":
            return .strong
        // Mica is a subtle wallpaper tint; under-window background is its
        // closest macOS counterpart.
        default:
            return .light
        }
    }

    var label: String {
        switch self {
        case .off: return "Off (opaque)"
        case .light: return "Light"
        case .medium: return "Medium"
        case .strong: return "Strong"
        }
    }

    /// macOS has no blur-radius knob - it has materials, and only some of them
    /// actually sample the desktop behind the window. These three do; the
    /// under-window and window-background materials are near-flat tints and
    /// read as "blur is broken".
    var material: NSVisualEffectView.Material {
        switch self {
        case .off, .light: return .sidebar
        case .medium: return .fullScreenUI
        case .strong: return .hudWindow
        }
    }

    var blurs: Bool { self != .off }

    /// True when macOS is set to Reduce transparency (System Settings >
    /// Accessibility > Display). Every `NSVisualEffectView` then falls back to a
    /// flat panel color, so the app renders opaque instead - otherwise that
    /// fallback bleeds through the wash and shifts the theme color.
    static var suppressedBySystem: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// What to actually render, after the accessibility setting has its say.
    var effective: Backdrop {
        Self.suppressedBySystem ? .off : self
    }
}
