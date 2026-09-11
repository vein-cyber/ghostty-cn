import AppKit

extension NSAlert {
    static func reviewWindowsAlert(
        messageText: String,
        informativeText: String = String(localized: "If you don't review your windows, any running processes will be terminated"),
        terminateNowButtonTitle: String = String(localized: "Terminate Processes")
    ) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: String(localized: "Review Windows…"))
        alert.addButton(withTitle: terminateNowButtonTitle)
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.alertStyle = .warning

        return alert
    }
}
