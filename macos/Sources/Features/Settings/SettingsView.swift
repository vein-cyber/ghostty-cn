import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit

/// Hosts the bundled Ghostty Config web application and bridges its save actions to the
/// native Ghostty configuration loader.
final class SettingsController: NSWindowController,
                                WKNavigationDelegate,
                                WKScriptMessageHandler,
                                WKUIDelegate {
    static let shared = SettingsController()

    private static let messageHandlerName = "ghosttyConfig"
    private static let scheme = "ghostty-config"

    private weak var ghostty: Ghostty.App?
    private let resourceRoot: URL?
    private let schemeHandler: GhosttyConfigSchemeHandler
    private let webView: WKWebView
    private var loaded = false

    private init() {
        let resourceRoot = Bundle.main.resourceURL?
            .appendingPathComponent("ghostty-config", isDirectory: true)
        let schemeHandler = GhosttyConfigSchemeHandler(root: resourceRoot)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: Self.scheme)
        let localization = Bundle.main.preferredLocalizations.first ?? "en"
        let localizationJSON = (try? JSONSerialization.data(
            withJSONObject: localization,
            options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"en\""
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.__ghosttyLocale = \(localizationJSON);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)

        self.resourceRoot = resourceRoot
        self.schemeHandler = schemeHandler
        self.webView = webView
        super.init(window: window)

        configuration.userContentController.add(self, name: Self.messageHandlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        window.contentView = webView
        window.minSize = NSSize(width: 820, height: 580)
        window.title = String(localized: "Ghostty Settings")
        window.center()
        window.setFrameAutosaveName("GhosttySettings")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(for ghostty: Ghostty.App) {
        self.ghostty = ghostty
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        guard !loaded else {
            sendCurrentConfiguration()
            return
        }

        guard resourceRoot != nil,
              let url = URL(string: "\(Self.scheme)://app/settings/application") else {
            showMissingResourcesAlert()
            return
        }

        loaded = true
        webView.load(URLRequest(url: url))
    }

    // MARK: - Web bridge

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageHandlerName,
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "ready":
            sendCurrentConfiguration()

        case "open-config-file":
            ghostty?.openConfigFile()

        case "save":
            guard let generated = body["config"] as? String,
                  let keys = body["keys"] as? [String] else {
                sendResult(ok: false, message: String(localized: "The settings data is invalid."))
                return
            }
            save(
                generated: generated,
                managedKeys: Set(keys).subtracting(GhosttyConfigFileEditor.protectedKeys))

        default:
            break
        }
    }

    private func sendCurrentConfiguration() {
        guard loaded, let url = ghostty?.configFileURL else { return }

        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        dispatchWebEvent(
            "ghostty-native-config",
            detail: ["content": content, "path": url.path])
    }

    private func sendResult(ok: Bool, message: String) {
        dispatchWebEvent("ghostty-native-result", detail: ["ok": ok, "message": message])
    }

    private func dispatchWebEvent(_ name: String, detail: [String: Any]) {
        webView.callAsyncJavaScript(
            "window.dispatchEvent(new CustomEvent(eventName, { detail }));",
            arguments: ["eventName": name, "detail": detail],
            in: nil,
            in: .page)
    }

    // MARK: - Saving

    private func save(generated: String, managedKeys: Set<String>) {
        guard let ghostty, let requestedURL = ghostty.configFileURL else {
            sendResult(ok: false, message: String(localized: "The configuration path is unavailable."))
            return
        }

        do {
            let url = resolvedWriteURL(requestedURL)
            let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let validated = try GhosttyConfigFileEditor.validate(
                generated: generated,
                managedKeys: managedKeys)

            guard try confirmFirstSaveIfNeeded(configURL: url, original: original) else {
                sendResult(ok: false, message: String(localized: "Saving was cancelled."))
                return
            }

            let merged = GhosttyConfigFileEditor.merge(
                original: original,
                generated: validated,
                managedKeys: managedKeys)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try merged.write(to: url, atomically: true, encoding: .utf8)

            ghostty.reloadConfig()
            sendResult(ok: true, message: String(localized: "Configuration saved and reloaded."))
        } catch {
            sendResult(
                ok: false,
                message: String(
                    localized: "Could not save the configuration: \(error.localizedDescription)"))
        }
    }

    private func resolvedWriteURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        return url.resolvingSymlinksInPath()
    }

    private func confirmFirstSaveIfNeeded(configURL: URL, original: String) throws -> Bool {
        guard !original.isEmpty else { return true }

        let backupURL = configURL.appendingPathExtension("before-ghostty-cn")
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: backupURL.path) else { return true }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Let Visual Settings Manage Your Configuration?")
        alert.informativeText = String(localized: "Ghostty will create a backup, preserve comments and unsupported options, and move supported settings into an automatically managed section.")
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        try fileManager.copyItem(at: configURL, to: backupURL)
        return true
    }

    private func showMissingResourcesAlert() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Settings resources are missing.")
        alert.informativeText = String(localized: "Reinstall Ghostty and try again.")
        alert.runModal()
    }

    // MARK: - Navigation

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if url.scheme == Self.scheme {
            decisionHandler(.allow)
            return
        }

        if let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           let scheme = url.scheme,
           ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}

/// Serves the generated Svelte site from the application bundle without network access.
private final class GhosttyConfigSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL?

    init(root: URL?) {
        self.root = root
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let root,
              let requestURL = urlSchemeTask.request.url,
              let decodedPath = requestURL.path.removingPercentEncoding else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let components = decodedPath.split(separator: "/").map(String.init)
        guard !components.contains("..") else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }

        var fileURL = components.reduce(root) { url, component in
            url.appendingPathComponent(component)
        }
        if components.isEmpty {
            fileURL = root.appendingPathComponent("index.html")
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            fileURL.appendPathComponent("index.html")
        }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = root.appendingPathComponent("404.html")
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: mimeType.hasPrefix("text/") ? "utf-8" : nil)
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

enum GhosttyConfigFileEditor {
    static let startMarker = "# --- Ghostty CN visual settings ---"
    static let endMarker = "# --- End Ghostty CN visual settings ---"
    static let protectedKeys: Set<String> = [
        "auto-update",
        "auto-update-channel",
        "config-default-files",
        "config-file",
    ]

    enum EditorError: LocalizedError {
        case invalidKey
        case invalidLine(String)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidKey:
                String(localized: "The settings editor returned an invalid configuration key.")
            case .invalidLine(let line):
                String(localized: "The settings editor returned an invalid line: \(line)")
            case .tooLarge:
                String(localized: "The generated configuration is too large.")
            }
        }
    }

    static func validate(generated: String, managedKeys: Set<String>) throws -> String {
        guard generated.utf8.count <= 2 * 1_024 * 1_024 else {
            throw EditorError.tooLarge
        }
        guard !managedKeys.isEmpty,
              managedKeys.allSatisfy(isValidKey) else {
            throw EditorError.invalidKey
        }

        let normalized = normalizeNewlines(generated)
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let key = assignmentKey(in: text), managedKeys.contains(key) else {
                throw EditorError.invalidLine(text)
            }
        }
        return normalized.trimmingCharacters(in: .newlines)
    }

    static func merge(
        original: String,
        generated: String,
        managedKeys: Set<String>
    ) -> String {
        let normalized = normalizeNewlines(original)
        var output: [String] = []
        var insideManagedSection = false

        for substring in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(substring)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == startMarker {
                insideManagedSection = true
                continue
            }
            if trimmed == endMarker {
                insideManagedSection = false
                continue
            }
            if insideManagedSection { continue }
            if let key = assignmentKey(in: line), managedKeys.contains(key) { continue }
            output.append(line)
        }

        while output.last?.isEmpty == true { output.removeLast() }
        if !output.isEmpty { output.append("") }
        output.append(startMarker)
        output.append("# Managed by Ghostty Settings. A backup is created before the first save.")
        if !generated.isEmpty {
            output.append(contentsOf: generated.split(separator: "\n").map(String.init))
        }
        output.append(endMarker)
        output.append("")
        return output.joined(separator: "\n")
    }

    private static func normalizeNewlines(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func assignmentKey(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              let equals = trimmed.firstIndex(of: "=") else { return nil }

        let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
        return isValidKey(key) ? key : nil
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard let first = key.first, first.isASCII, first.isLetter else { return false }
        return key.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-")
        }
    }
}
