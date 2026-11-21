import Foundation

enum FileBrowserPreferences {
    static let defaultVisibleKey = "fileBrowser.defaultVisible"
    static let positionKey = "fileBrowser.position"
    static let showsHiddenKey = "fileBrowser.showsHidden"
    static let widthKey = "fileBrowser.width"
    static let defaultWidth = 300.0
    static let minimumWidth = 240.0
    static let maximumWidth = 600.0

    enum Position: String, CaseIterable {
        case left, right
    }

    static func initiallyVisible(in defaults: UserDefaults = .ghostty) -> Bool {
        defaults.bool(forKey: defaultVisibleKey)
    }

    static func normalizedWidth(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return defaultWidth }
        return min(max(value, minimumWidth), maximumWidth)
    }

    /// Narrow windows adapt without replacing the user's preferred width.
    static func effectiveWidth(_ preferred: Double, available: Double) -> Double {
        guard available.isFinite, available > 0 else { return 0 }
        let limit = max(0, min(maximumWidth, available - 161)) // divider + terminal room
        return min(normalizedWidth(preferred), limit)
    }

    static func savedWidth(in defaults: UserDefaults = .ghostty) -> Double {
        normalizedWidth(defaults.double(forKey: widthKey))
    }

    static func saveWidth(_ width: Double, in defaults: UserDefaults = .ghostty) {
        defaults.set(normalizedWidth(width), forKey: widthKey)
    }
}
