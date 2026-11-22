import Foundation

/// Presentation only: abbreviating a location must never change the path used
/// for file operations or mistake a remote home for the Mac's home directory.
struct FileBrowserLocation {
    let path: String
    let homeDirectory: String?

    init(path: String, homeDirectory: String?) {
        self.path = Self.trimmingTrailingSlashes(path)
        self.homeDirectory = homeDirectory.flatMap { $0.isEmpty ? nil : Self.trimmingTrailingSlashes($0) }
    }

    private static func trimmingTrailingSlashes(_ value: String) -> String {
        var value = value
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }

    var isHome: Bool { homeDirectory == path }

    var title: String {
        if isHome { return String(localized: "Home folder") }
        if path == "/" { return String(localized: "Root folder") }
        if !path.hasPrefix("/") { return String(localized: "Files") }
        return (path as NSString).lastPathComponent
    }

    var displayPath: String {
        guard let home = homeDirectory else { return path }
        if path == home { return "~" }
        if home == "/", path.hasPrefix("/") { return "~" + path }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    func expandingHome(in input: String) -> String {
        guard let home = homeDirectory else { return input }
        if input == "~" { return home }
        if input.hasPrefix("~/") { return BrowserPath.join(home, String(input.dropFirst(2))) }
        return input
    }
}
