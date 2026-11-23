import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
@Suite(.serialized) // Native windows share AppKit focus and field-editor state.
struct FileBrowserLayoutTests {
    @Test func compactPathOpensAnEditorAndReturnNavigatesWhileEscapeCancels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GhosttyCN-Path-Editor-" + UUID().uuidString)
        let child = root.appendingPathComponent("child folder")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FileBrowserModel()
        model.navigate(root.path)
        let suite = "GhosttyCN-Path-Editor-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let window = makeBrowserWindow(model: model, preferences: preferences)
        defer { window.close(); model.disconnect() }
        let host = try #require(window.contentView)
        let deadline = ContinuousClock.now + .seconds(3)
        while model.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        for cancel in [true, false] {
            // Invoke the same begin-edit action as the location button, then
            // exercise Return/Esc through the actual native text field/editor.
            model.beginEditingPath()
            try await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()
            #expect(model.isEditingPath)
            let field = try #require(findTextField(in: host, value: model.path))
            window.makeFirstResponder(field)
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.selectAll(nil)
            editor.insertText(child.path, replacementRange: editor.selectedRange())
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: cancel ? "\u{1b}" : "\r",
                charactersIgnoringModifiers: cancel ? "\u{1b}" : "\r", isARepeat: false, keyCode: cancel ? 53 : 36))
            editor.keyDown(with: event)
            try await Task.sleep(for: .milliseconds(40))
            while model.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(model.error == nil)
            #expect(model.path == (cancel ? root.path : child.path))
            host.layoutSubtreeIfNeeded()
            #expect(!model.isEditingPath)
        }
    }

    private func findTextField(in view: NSView, value: String) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, field.stringValue == value { return field }
        return view.subviews.lazy.compactMap { findTextField(in: $0, value: value) }.first
    }

    @Test func fileButtonIconIsCenteredInsideCompactBounds() {
        let size = FileBrowserButtonLayout.size
        let bounds = NSRect(origin: .zero, size: size)
        let layout = FileBrowserButtonLayout(bounds: bounds)
        #expect(layout.icon.minX == bounds.maxX - layout.icon.maxX)
        #expect(bounds.contains(layout.icon))
        #expect(layout.icon.midX == bounds.midX)
        #expect(layout.icon.midY == bounds.midY)
        #expect(size.height == 24)
        #expect(size.width == 28)
    }

    @Test func iconOnlyButtonTracksSidebarPositionWithoutLosingItsState() async throws {
        let suite = "GhosttyCN-Sidebar-Icon-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let accessory = FileBrowserTitlebarAccessory(preferences: preferences) {}
        accessory.sync(isVisible: true)
        #expect(accessory.button.title.isEmpty)
        #expect(accessory.button.accessibilityLabel() == String(localized: "File Browser"))
        #expect(accessory.symbolName == "sidebar.left")
        preferences.set("right", forKey: FileBrowserPreferences.positionKey)
        let deadline = ContinuousClock.now + .seconds(2)
        while accessory.symbolName != "sidebar.right", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(accessory.symbolName == "sidebar.right")
        #expect(accessory.button.state == .on)
        #expect(accessory.button.toolTip == String(localized: "Hide file browser"))
        preferences.set("left", forKey: FileBrowserPreferences.positionKey)
        accessory.sync(isVisible: false)
        #expect(accessory.symbolName == "sidebar.left")
        #expect(accessory.button.state == .off)
    }

    @Test(arguments: [false, true])
    func fileButtonUsesTransparentAndSubtleNeutralStates(light: Bool) async throws {
        let accessory = FileBrowserTitlebarAccessory {}
        let background = light ? NSColor(white: 0.94, alpha: 1) : NSColor(white: 0.13, alpha: 1)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 60))
        host.wantsLayer = true
        host.layer?.backgroundColor = background.cgColor
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.contentView = host
        // The accessory's own root must remain at the origin of its AppKit container.
        // Render its actual button separately without repositioning that protected root.
        accessory.button.removeFromSuperview()
        accessory.button.translatesAutoresizingMaskIntoConstraints = true
        accessory.button.frame = NSRect(origin: NSPoint(x: 20, y: 14), size: accessory.button.fittingSize)
        host.addSubview(accessory.button)
        defer { window.close() }
        var samples: [NSColor] = []
        for visible in [false, true] {
            accessory.sync(isVisible: visible)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/private/tmp/ghosttycn-file-button-\(light ? "light" : "dark")-\(visible ? "on" : "off").png"))
            let point = accessory.button.convert(NSPoint(x: 8, y: 4), to: host)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let pixel = try #require(bitmap.colorAt(x: Int(point.x * scale), y: Int((host.bounds.height - point.y) * scale)))
            let rgb = try #require(pixel.usingColorSpace(.deviceRGB))
            #expect(abs(rgb.redComponent - rgb.blueComponent) < 0.04, "Selection must be neutral, not accent blue")
            if !visible {
                let outside = try #require(bitmap.colorAt(x: 5, y: 5))
                #expect(pixel.distance(to: outside) < 0.03, "Inactive button should have no background")
            }
            samples.append(pixel)
        }
        #expect(samples[0].distance(to: samples[1]) > 0.02, "Selected button must remain distinguishable")
        // distance() weights the RGB channels, so a 10% neutral shift has distance 0.3.
        #expect(samples[0].distance(to: samples[1]) < 0.3, "Selected button should have only a subtle tint")
    }

    @Test func titlebarButtonRemainsAvailableWhenTheSidebarCloses() throws {
        var visible = false
        var clicks = 0
        let accessory = FileBrowserTitlebarAccessory { visible.toggle(); clicks += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.addTitlebarAccessoryViewController(accessory)
        defer { window.close() }
        accessory.sync(isVisible: false)
        #expect(accessory.button.state == .off)
        #expect(accessory.button.toolTip == String(localized: "Show file browser"))
        accessory.button.performClick(nil)
        accessory.sync(isVisible: visible)
        #expect(visible && clicks == 1)
        #expect(accessory.button.state == .on)
        #expect(accessory.button.toolTip == String(localized: "Hide file browser"))
        accessory.button.performClick(nil)
        accessory.sync(isVisible: visible)
        #expect(!visible && clicks == 2)
        #expect(!accessory.view.isHidden && !accessory.button.isHidden)
        #expect(window.titlebarAccessoryViewControllers.contains { $0 === accessory })
    }

    @Test(arguments: [false, true])
    func updatePillStaysCenteredWhenItAppearsAndCollapsesWhenIdle(hasToolbar: Bool) async throws {
        let window = TerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.awakeFromNib()
        window.appearance = NSAppearance(named: .darkAqua)
        if hasToolbar {
            window.toolbar = NSToolbar(identifier: "TitlebarAlignmentTest")
            window.toolbarStyle = .unifiedCompact
        }
        defer { window.close() }
        let update = UpdateViewModel()
        window.updateAccessory.view = window.makeUpdateAccessoryView(model: update)
        for visible in [true, false, true] {
            update.state = visible ? .notFound(.init(acknowledgement: {})) : .idle
            try await Task.sleep(for: .milliseconds(80))
            window.layoutIfNeeded()
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            if visible {
                try checkTitlebarSpacing(window)
            } else {
                #expect(window.updateAccessory.view.frame.width <= 1, "Idle updates must not reserve empty titlebar space")
            }
        }
    }

    @Test(arguments: [false, true])
    func titlebarTabsReserveSpaceForThePersistentFileButton(tabsInTitlebar: Bool) async throws {
        func makeWindow(_ title: String) -> TerminalWindow {
            let rect = NSRect(x: 0, y: 0, width: 1100, height: 500)
            let style: NSWindow.StyleMask = [.titled, .closable, .resizable]
            let window: TerminalWindow
            if tabsInTitlebar {
                if #available(macOS 26.0, *) {
                    window = TitlebarTabsTahoeTerminalWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
                } else {
                    window = TitlebarTabsVenturaTerminalWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
                }
            } else {
                window = TerminalWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
            }
            window.isReleasedWhenClosed = false
            window.awakeFromNib()
            window.title = title
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(white: 0.14, alpha: 1)
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView:
                Color(nsColor: window.backgroundColor)
                    .overlay(Text(verbatim: "❯  cd ~/Projects\n❯  ")
                        .font(.system(size: 13, design: .monospaced)).padding(16), alignment: .topLeading)
                    .environment(\.colorScheme, .dark))
            // Exercise the real accessory with a visible blue update pill, not
            // only its transparent hosting view (which can hide padding bugs).
            if window.supportsUpdateAccessory {
                let update = UpdateViewModel()
                update.state = .notFound(.init(acknowledgement: {}))
                window.updateAccessory.view = window.makeUpdateAccessoryView(model: update)
            }
            return window
        }
        let first = makeWindow("project — zsh")
        let second = makeWindow("server — ssh")
        let third = makeWindow("logs — zsh")
        defer { first.close(); second.close(); third.close() }
        first.fileBrowserAccessory.sync(isVisible: true)
        try await Task.sleep(for: .milliseconds(80))
        try checkTitlebarSpacing(first)
        try saveTitlebarWindow(first, name: tabsInTitlebar ? "tabs-single" : "native-single")
        first.addTabbedWindow(second, ordered: .above)
        first.addTabbedWindow(third, ordered: .above)
        for selected in [first, second, third, first] {
            first.tabGroup?.selectedWindow = selected
            for width in [CGFloat(1100), 650] {
                selected.setContentSize(NSSize(width: width, height: 500))
                try await Task.sleep(for: .milliseconds(80))
                (selected as? TitlebarTabsTahoeTerminalWindow)?.setupTabBar()
                selected.contentView?.superview?.layoutSubtreeIfNeeded()
                let accessory = selected.fileBrowserAccessory
                #expect(selected.fileBrowserTitlebarWidth == FileBrowserButtonLayout.size.width +
                        FileBrowserTitlebarAccessory.accessorySpacing + FileBrowserTitlebarAccessory.outerInset)
                let button = accessory.button.convert(accessory.button.bounds, to: nil)
                #expect(button.maxX <= selected.frame.width)
                #expect(button.maxX >= selected.frame.width - 40)
                try checkTitlebarSpacing(selected)
                if tabsInTitlebar {
                    let tabs = try #require(selected.tabBarView)
                    let tabFrame = tabs.convert(tabs.bounds, to: nil)
                    let actionFrame = accessory.view.convert(accessory.view.bounds, to: nil)
                    #expect(tabFrame.maxX <= actionFrame.minX + 1, "Tabs must not cover the file action")
                    #expect(tabFrame.width > 150)
                    if let newTab = selected.titlebarView?.firstDescendant(withClassName: "NSTabBarNewTabButton") {
                        let plus = newTab.convert(newTab.bounds, to: nil)
                        #expect(abs(plus.midY - button.midY) <= 2, "File and new-tab controls should share a vertical center")
                    }
                }
            }
        }
        try saveTitlebarWindow(first, name: tabsInTitlebar ? "tabs-multiple" : "native-multiple")
    }

    private func checkTitlebarSpacing(_ window: TerminalWindow) throws {
        window.layoutIfNeeded()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.fileBrowserAccessory.view.layoutSubtreeIfNeeded()
        let close = try #require(window.standardWindowButton(.closeButton))
        let controls = close.convert(close.bounds, to: nil)
        let button = window.fileBrowserAccessory.button
        let frame = button.convert(button.bounds, to: nil)
        // A native tab group may add another row below the titlebar. Align to
        // the actual window controls, not the combined container's midpoint.
        #expect(abs(frame.midY - controls.midY) <= 1,
                "\(type(of: window)): button \(frame), controls \(controls), accessory \(window.fileBrowserAccessory.view.frame)")
        #expect(window.frame.height - frame.maxY >= 4)
        let rowBottom = controls.midY - (window.frame.height - controls.midY)
        #expect(frame.minY - rowBottom >= 4)
        #expect(abs(window.frame.width - frame.maxX - 16) <= 1)
        #expect(frame.height == 24)
        #expect(button.font?.pointSize == 13)
        guard window.supportsUpdateAccessory else { return }
        let pill = try updatePillFrame(window)
        #expect(abs(pill.midY - controls.midY) <= 1,
                """
                Update pill \(pill) must align to window controls \(controls);
                host \(window.updateAccessory.view.frame), safe area \(window.updateAccessory.view.safeAreaInsets),
                file host \(window.fileBrowserAccessory.view.frame)
                """)
        #expect(abs(frame.minX - pill.maxX - 12) <= 1,
                "Update pill and sidebar action must have a 12-point gap")
    }

    /// Measure the colored pixels, so asymmetric SwiftUI padding cannot pass
    /// simply because the outer NSHostingView is correctly centered by AppKit.
    private func updatePillFrame(_ window: TerminalWindow) throws -> NSRect {
        let host = try #require(window.contentView?.superview)
        let update = window.updateAccessory.view
        let area = host.convert(update.bounds, from: update)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        var pixels = NSRect.null
        let top = host.isFlipped ? area.minY : host.bounds.maxY - area.maxY
        for y in max(0, Int(top * scale))..<min(bitmap.pixelsHigh, Int(ceil((top + area.height) * scale))) {
            for x in max(0, Int(area.minX * scale))..<min(bitmap.pixelsWide, Int(ceil(area.maxX * scale))) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.blueComponent > color.redComponent + 0.2,
                      color.blueComponent > color.greenComponent + 0.1 else { continue }
                pixels = pixels.union(NSRect(x: x, y: y, width: 1, height: 1))
            }
        }
        #expect(!pixels.isNull, "A visible blue update pill must be rendered")
        guard !pixels.isNull else { return .zero }
        let rect = NSRect(x: pixels.minX / scale,
                          y: host.isFlipped ? pixels.minY / scale : host.bounds.maxY - pixels.maxY / scale,
                          width: pixels.width / scale, height: pixels.height / scale)
        return host.convert(rect, to: nil)
    }

    private func saveTitlebarWindow(_ window: TerminalWindow, name: String) throws {
        let frame = try #require(window.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/private/tmp/ghosttycn-titlebar-\(name).png"))
    }

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
        let host = NSHostingView(rootView: FileBrowserView(model: model, preferences: preferences).frame(width: 320, height: 400))
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
        let host = NSHostingView(rootView: FileBrowserView(model: model).frame(width: 320, height: 400))
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
        #expect((24...26).contains(table.rect(ofRow: 0).height))
        window.makeFirstResponder(table)
        // The same native selection notification used by mouse row selection.
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.selectedFileID == model.visibleFiles[0].id)
        let row = try #require(table.rowView(atRow: 0, makeIfNecessary: true))
        #expect(row.isSelected)
        #expect(row.selectionHighlightStyle == .none) // SwiftUI paints a subtle neutral selection instead.
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
            sidebar: FileBrowserView(model: model).background(background),
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
