import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct FileBrowserLayoutTests {
    @Test func hiddenFilePreferenceIsSharedAndRestoredByNewSidebars() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GhosttyCN-Hidden-Preference-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "GhosttyCN-Hidden-Files-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = FileBrowserModel()
        let second = FileBrowserModel()
        first.navigate(root.path)
        second.navigate(root.path)
        let firstWindow = makeBrowserWindow(model: first, preferences: preferences)
        let secondWindow = makeBrowserWindow(model: second, preferences: preferences)
        defer { firstWindow.close(); secondWindow.close(); first.disconnect(); second.disconnect() }
        firstWindow.contentView?.layoutSubtreeIfNeeded()
        secondWindow.contentView?.layoutSubtreeIfNeeded()
        #expect(!first.showsHidden && !second.showsHidden)
        preferences.set(true, forKey: FileBrowserPreferences.showsHiddenKey)
        let deadline = ContinuousClock.now + .seconds(3)
        while !first.showsHidden || !second.showsHidden, ContinuousClock.now < deadline {
            firstWindow.contentView?.layoutSubtreeIfNeeded()
            secondWindow.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(first.showsHidden && second.showsHidden)
        let reopenedPreferences = try #require(UserDefaults(suiteName: suite))
        #expect(reopenedPreferences.bool(forKey: FileBrowserPreferences.showsHiddenKey))
        let reopened = FileBrowserModel()
        reopened.navigate(root.path)
        let reopenedWindow = makeBrowserWindow(model: reopened, preferences: reopenedPreferences)
        defer { reopenedWindow.close(); reopened.disconnect() }
        reopenedWindow.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        #expect(reopened.showsHidden)
        preferences.set(false, forKey: FileBrowserPreferences.showsHiddenKey)
        let resetDeadline = ContinuousClock.now + .seconds(3)
        while first.showsHidden || second.showsHidden, ContinuousClock.now < resetDeadline {
            firstWindow.contentView?.layoutSubtreeIfNeeded()
            secondWindow.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!first.showsHidden && !second.showsHidden)
        #expect(!reopenedPreferences.bool(forKey: FileBrowserPreferences.showsHiddenKey))
    }

    @Test(arguments: [false, true], ["populated", "empty", "filtered"])
    func blankListContextMenuOffersFolderCreationAndRemoteUploads(remote: Bool, state: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GhosttyCN-Blank-Menu-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        if state != "empty" { try Data("fixture".utf8).write(to: root.appendingPathComponent("file.txt")) }
        let suite = "GhosttyCN-Blank-Menu-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "fileBrowser.followSSH") // legacy switch must no longer disable following
        let model = FileBrowserModel { _ in
            SFTPClient(transport: try SFTPTransport(executable: "/usr/libexec/sftp-server", arguments: ["-d", root.path]))
        }
        if remote {
            model.observeTerminal(.ssh(SSHFileConnection(host: "terminal-host")), directory: nil)
        } else {
            model.navigate(root.path)
        }
        let window = makeBrowserWindow(model: model, preferences: preferences)
        defer { window.close(); model.disconnect() }
        let deadline = ContinuousClock.now + .seconds(3)
        while model.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let host = try #require(window.contentView)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let table = try #require(findTable(in: host))
        if state == "populated" {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            try await Task.sleep(for: .milliseconds(20))
        } else if state == "filtered" {
            model.filter = "no matching files"
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        // Ask for the native menu without displaying it or invoking any action.
        let point = NSPoint(x: 12, y: state == "populated" ? table.rect(ofRow: 0).maxY + 20 : 20)
        #expect(table.row(at: point) == -1)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: table.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(table.menu(for: event))
        menu.update()
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles.contains(String(localized: "New folder")))
        #expect(titles.contains(String(localized: "Upload file")) == remote)
        #expect(!titles.contains(String(localized: "Rename")))
        #expect(model.preview == nil)
    }

    private func makeBrowserWindow(model: FileBrowserModel, preferences: UserDefaults) -> NSWindow {
        let host = NSHostingView(rootView: FileBrowserView(model: model, close: {}, preferences: preferences).frame(width: 320, height: 400))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return window
    }

    @Test func nativeListSelectionAndArrowKeysUpdateTheSelectedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GhosttyCN-Selection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["folder-a", "folder-b"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        try Data("preview fixture".utf8).write(to: root.appendingPathComponent("file.txt"))
        let model = FileBrowserModel()
        defer { model.disconnect() }
        model.navigate(root.path)
        let host = NSHostingView(rootView: FileBrowserView(model: model, close: {}).frame(width: 320, height: 400))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        let deadline = ContinuousClock.now + .seconds(3)
        while model.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let table = try #require(findTable(in: host))
        #expect(table.numberOfRows == 3)
        window.makeFirstResponder(table)
        // The same native selection notification used by mouse row selection.
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.selectedFileID == model.visibleFiles[0].id)
        let row = try #require(table.rowView(atRow: 0, makeIfNecessary: true))
        #expect(row.isSelected)
        #expect(row.selectionHighlightStyle != .none)
        let down = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
            charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        table.keyDown(with: down)
        try await Task.sleep(for: .milliseconds(30))
        #expect(table.selectedRow == 1)
        #expect(model.selectedFileID == model.visibleFiles[1].id)
        table.keyDown(with: down)
        try await Task.sleep(for: .milliseconds(30))
        #expect(table.selectedRow == 2)
        #expect(model.selectedFileID == model.visibleFiles[2].id)
        #expect(model.visibleFiles[2].kind == .file)
        let up = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F700}",
            charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126))
        table.keyDown(with: up)
        try await Task.sleep(for: .milliseconds(30))
        #expect(table.selectedRow == 1)
        #expect(model.selectedFileID == model.visibleFiles[1].id)
        #expect(model.preview == nil)
        #expect(model.path == root.path)
        let enter = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        table.keyDown(with: enter)
        try await Task.sleep(for: .milliseconds(50))
        while model.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(URL(fileURLWithPath: model.path).resolvingSymlinksInPath() ==
                root.appendingPathComponent("folder-b").resolvingSymlinksInPath())
    }

    private func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { findTable(in: $0) }.first
    }

    @Test func savedWidthSurvivesNewWindowsAndNarrowLayouts() throws {
        let suite = "GhosttyCN-Sidebar-Layout-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        #expect(FileBrowserPreferences.savedWidth(in: preferences) == 300)
        FileBrowserPreferences.saveWidth(417, in: preferences)
        for side in ["left", "right"] {
            preferences.set(side, forKey: FileBrowserPreferences.positionKey)
            let newWindow = try #require(UserDefaults(suiteName: suite))
            #expect(FileBrowserPreferences.savedWidth(in: newWindow) == 417)
            #expect(FileBrowserPreferences.effectiveWidth(417, available: 1000) == 417)
            #expect(FileBrowserPreferences.effectiveWidth(417, available: 400) == 239)
            #expect(FileBrowserPreferences.savedWidth(in: newWindow) == 417)
            #expect(FileBrowserPreferences.effectiveWidth(FileBrowserPreferences.savedWidth(in: newWindow), available: 1000) == 417)
        }
    }

    @Test func invalidWidthsCannotBreakTheWindowLayout() {
        #expect(FileBrowserPreferences.normalizedWidth(.nan) == 300)
        #expect(FileBrowserPreferences.normalizedWidth(.infinity) == 300)
        #expect(FileBrowserPreferences.normalizedWidth(-20) == 300)
        #expect(FileBrowserPreferences.normalizedWidth(2) == 240)
        #expect(FileBrowserPreferences.normalizedWidth(5000) == 600)
        #expect(FileBrowserPreferences.effectiveWidth(400, available: 100) == 0)
        #expect(FileBrowserPreferences.effectiveWidth(400, available: .infinity) == 0)
    }

    @Test func backgroundMatchesTerminalWithoutDoubleTintingGlass() throws {
        let color = Color(red: 0.18, green: 0.12, blue: 0.23)
        let plain = FileBrowserAppearance(color: color, opacity: 1, usesWindowGlass: false, forceOpaque: false)
        #expect(plain.background.distance(to: NSColor(color)) < 0.001)
        #expect(plain.background.alphaComponent == 1)
        #expect(plain.colorScheme == .dark)
        let transparent = FileBrowserAppearance(color: color, opacity: 0.65, usesWindowGlass: false, forceOpaque: false)
        #expect(abs(transparent.background.alphaComponent - 0.65) < 0.001)
        let glass = FileBrowserAppearance(color: color, opacity: 0.65, usesWindowGlass: true, forceOpaque: false)
        #expect(glass.background.alphaComponent == 0)
        let opaque = FileBrowserAppearance(color: color, opacity: 0.65, usesWindowGlass: true, forceOpaque: true)
        #expect(opaque.background.alphaComponent == 1)
        #expect(opaque.background.distance(to: NSColor(color)) < 0.001)
        let light = FileBrowserAppearance(color: .white, opacity: 1, usesWindowGlass: false, forceOpaque: false)
        #expect(light.colorScheme == .light)
    }

    /// Render offscreen, without opening or modifying the user's terminal.
    /// These PNGs also make the list/terminal background relationship inspectable.
    @Test(arguments: [false, true]) func sidebarRendersAsPartOfTheTerminal(light: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GhosttyCN-Sidebar-Render-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Projects"), withIntermediateDirectories: false)
        try Data("Preview fixture".utf8).write(to: root.appendingPathComponent("README.md"))
        let model = FileBrowserModel()
        model.follow(root)
        let deadline = ContinuousClock.now + .seconds(3)
        while model.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        defer { model.disconnect() }
        model.selectedFileID = model.files.first?.id
        let background = light ? Color(red: 0.97, green: 0.95, blue: 0.91) : Color(red: 0.15, green: 0.11, blue: 0.18)
        let view = FileBrowserSplitLayout(
            isVisible: true, position: light ? "right" : "left", preferredWidth: .constant(320),
            sidebar: FileBrowserView(model: model, close: {}).background(background),
            terminal: background.overlay(Text(verbatim: "❯  cd ~/Projects\n❯  ").font(.system(.body, design: .monospaced)).padding(), alignment: .topLeading))
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .environment(\.colorScheme, light ? .light : .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.backgroundColor = NSColor(background)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        // onAppear refreshes the listing once the offscreen host is attached.
        while model.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: light ? "/private/tmp/ghosttycn-sidebar-light.png" : "/private/tmp/ghosttycn-sidebar-dark.png"))
        #expect(bitmap.pixelsWide >= 1000)
        let left = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 8, y: bitmap.pixelsHigh * 3 / 4))
        let right = try #require(bitmap.colorAt(x: bitmap.pixelsWide * 7 / 8, y: bitmap.pixelsHigh * 3 / 4))
        #expect(left.distance(to: right) < 0.05, "Empty list area should share the terminal's background")
    }
}
