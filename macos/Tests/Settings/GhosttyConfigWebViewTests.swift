import AppKit
import Testing
import WebKit
@testable import Ghostty

@MainActor
struct GhosttyConfigWebViewTests {
    @Test func bundledSettingsStartsOverNativeScheme() async throws {
        let root = try #require(Bundle.main.resourceURL)
            .appendingPathComponent("ghostty-config", isDirectory: true)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            GhosttyConfigSchemeHandler(root: root), forURLScheme: "ghostty-config")
        let probe = SettingsWebProbe()
        configuration.userContentController.add(probe, name: "ghosttyConfig")
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            window.__ghosttyLocale = "zh-Hans";
            const report = message => window.webkit.messageHandlers.ghosttyConfig.postMessage({action: "test-error", message});
            window.addEventListener("error", event => report(String(event.message)));
            window.addEventListener("unhandledrejection", event => report(String(event.reason) + "\\n" + (event.reason?.stack ?? "")));
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1120, height: 760),
            configuration: configuration)
        webView.navigationDelegate = probe
        let url = try #require(URL(string: "ghostty-config://app/settings/application"))
        webView.load(URLRequest(url: url))

        let deadline = ContinuousClock.now + .seconds(15)
        while !probe.ready, probe.failures.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let body = try await bodyText(in: webView)
        #expect(probe.ready, "Settings never became ready: \(probe.failures); body: \(body)")
        #expect(probe.failures.isEmpty, "Settings script errors: \(probe.failures)")
        #expect(body.contains("高级"))
        #expect(body.contains("应用并重新加载"))
        webView.stopLoading()
        configuration.userContentController.removeScriptMessageHandler(forName: "ghosttyConfig")
    }

    private func bodyText(in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript("document.body.innerText") { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value as? String ?? "")
                }
            }
        }
    }
}

@MainActor
private final class SettingsWebProbe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var ready = false
    var failures: [String] = []

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        if body["action"] as? String == "ready" {
            ready = true
        } else if body["action"] as? String == "test-error" {
            failures.append(body["message"] as? String ?? "Unknown script error")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failures.append(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failures.append(error.localizedDescription)
    }
}
