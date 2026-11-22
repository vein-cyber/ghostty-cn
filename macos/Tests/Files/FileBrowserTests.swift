import Foundation
import Darwin
import Testing
@testable import Ghostty

struct FileBrowserTests {
    @Test func directoryTitlesAndHomeAbbreviationsRespectPathBoundaries() {
        let home = "/Users/demo"
        let root = FileBrowserLocation(path: home + "/", homeDirectory: home)
        #expect(root.isHome)
        #expect(root.title == String(localized: "Home folder"))
        #expect(root.displayPath == "~")
        let project = FileBrowserLocation(path: home + "/Projects/ghostty-cn", homeDirectory: home)
        #expect(project.title == "ghostty-cn")
        #expect(project.displayPath == "~/Projects/ghostty-cn")
        #expect(project.expandingHome(in: "~/Projects") == home + "/Projects")
        #expect(project.expandingHome(in: "~") == home)
        #expect(project.expandingHome(in: "~other") == "~other")
        let neighbor = FileBrowserLocation(path: "/Users/demo-other", homeDirectory: home)
        #expect(neighbor.displayPath == "/Users/demo-other")
        #expect(!neighbor.isHome)
        let system = FileBrowserLocation(path: "/var/log", homeDirectory: home)
        #expect(system.title == "log")
        #expect(system.displayPath == "/var/log")
        #expect(FileBrowserLocation(path: "/", homeDirectory: home).title == String(localized: "Root folder"))
        #expect(FileBrowserLocation(path: ".", homeDirectory: nil).title == String(localized: "Files"))
        #expect(FileBrowserLocation(path: "/etc", homeDirectory: "/").displayPath == "~/etc")
    }

    @Test func onlyRegularFilesDisplayTheirSize() {
        for kind: BrowserFile.Kind in [.directory, .symbolicLink, .other] {
            #expect(BrowserFile(path: "/example", name: "example", kind: kind, size: 54).displayedSize == nil)
        }
        #expect(BrowserFile(path: "/example.txt", name: "example.txt", kind: .file, size: 89).displayedSize != nil)
    }

    @MainActor @Test func remoteHomeAndDirectoryTitleFollowTheRemoteSessionOnly() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let model = FileBrowserModel { _ in
            SFTPClient(transport: try SFTPTransport(executable: "/usr/libexec/sftp-server", arguments: ["-d", root.path]))
        }
        defer { model.disconnect() }
        model.observeTerminal(.ssh(SSHFileConnection(host: "fixture-host")), directory: nil)
        try await waitForIdle(model)
        #expect(model.remoteHome == model.path)
        #expect(model.location.title == String(localized: "Home folder"))
        #expect(model.location.displayPath == "~")
        model.navigate("~/Projects")
        try await waitForIdle(model)
        #expect(model.error == nil)
        #expect(model.location.title == "Projects")
        #expect(model.location.displayPath == "~/Projects")
        #expect(model.remoteHost == "fixture-host")
        model.navigate("~")
        try await waitForIdle(model)
        #expect(model.location.title == String(localized: "Home folder"))
        model.disconnect()
        #expect(model.remoteHome == nil)
        #expect(model.remoteHost == nil)
        #expect(model.location.homeDirectory == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @MainActor @Test func primaryActionPreviewsFilesAndIgnoresMissingOrHiddenItems() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("preview content".utf8).write(to: root.appendingPathComponent("file.txt"))
        try Data("hidden content".utf8).write(to: root.appendingPathComponent(".hidden"))
        let model = FileBrowserModel()
        defer { model.disconnect() }
        model.navigate(root.path)
        try await waitForIdle(model)
        let file = try #require(model.files.first { $0.name == "file.txt" })
        let hidden = try #require(model.files.first { $0.name == ".hidden" })
        let invalidSelections: [Set<BrowserFile.ID>] = [[], ["missing"], [hidden.id], [file.id, hidden.id]]
        for ids in invalidSelections {
            model.activateFiles(ids)
            #expect(model.preview == nil)
            #expect(!model.busy)
        }
        model.activateFiles([file.id])
        try await waitForIdle(model)
        #expect(model.preview?.name == "file.txt")
        #expect(model.preview?.text == "preview content")
        #expect(model.selectedFileID == file.id)
        model.preview = nil
        model.filter = "no matches"
        model.activateFiles([file.id])
        #expect(model.preview == nil)
        #expect(model.selectedFileID == nil)
    }

    @MainActor @Test func selectionSurvivesRefreshAndClearsWhenNoLongerVisible() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("file.txt")
        let hidden = root.appendingPathComponent(".hidden")
        try Data("preview".utf8).write(to: file)
        try Data().write(to: hidden)
        let model = FileBrowserModel()
        defer { model.disconnect() }
        model.navigate(root.path)
        try await waitForIdle(model)
        let item = try #require(model.files.first { $0.name == "file.txt" })
        model.selectedFileID = item.id
        #expect(model.preview == nil) // selecting never opens or navigates
        model.refresh()
        try await waitForIdle(model)
        #expect(model.selectedFileID == item.id)
        model.filter = "folder"
        #expect(model.selectedFileID == nil)
        model.filter = ""
        model.showsHidden = true
        model.selectedFileID = try #require(model.files.first { $0.name == ".hidden" }).id
        model.showsHidden = false
        #expect(model.selectedFileID == nil)
        model.selectedFileID = item.id
        try FileManager.default.removeItem(at: file)
        model.refresh()
        try await waitForIdle(model)
        #expect(model.selectedFileID == nil)
        model.selectedFileID = try #require(model.files.first { $0.name == "folder" }).id
        model.navigate(folder.path)
        try await waitForIdle(model)
        #expect(model.selectedFileID == nil)
        #expect(model.path == folder.path)
    }

    @Test func fileActionTranslationsDoNotReuseTheKeyboardDeleteKey() throws {
        let path = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let chinese = try #require(Bundle(path: path))
        let actions = ["New folder": "新建文件夹",
                       "Upload file": "上传文件", "Download file": "下载文件",
                       "Rename": "重命名", "Delete item": "删除", "Learn why": "了解原因"]
        for (key, expected) in actions {
            let title = chinese.localizedString(forKey: key, value: nil, table: "Localizable")
            #expect(title == expected)
            #expect(!title.contains("…") && !title.contains("..."))
        }
        #expect(chinese.localizedString(forKey: "Delete", value: nil, table: "Localizable") == "删除键")
    }

    @Test func validatesNamesAndSSHArguments() throws {
        for name in ["", ".", "..", "a/b", "bad\nname", "bad\0name"] {
            #expect(throws: (any Error).self) { try BrowserPath.validateName(name) }
        }
        try BrowserPath.validateName("中文 'quotes' $file.txt")
        for host in ["-oProxyCommand=evil", "host;touch foo", "a\nb", "", "@host"] {
            #expect(throws: (any Error).self) { try SSHFileConnection(host: host).arguments() }
        }
        #expect(throws: (any Error).self) { try SSHFileConnection(host: "host", port: "0").arguments() }
        let arguments = try SSHFileConnection(host: "user@my-server", port: "2222").arguments()
        #expect(arguments.suffix(4) == ["-p", "2222", "user@my-server", "sftp"])
        #expect(arguments.contains("-oBatchMode=yes"))
        #expect(arguments.contains("-oStrictHostKeyChecking=yes"))
        #expect(arguments.contains("-oPermitLocalCommand=no"))
        #expect(arguments.contains("-oControlPath=none"))
        #expect(BrowserPath.join("/", "test") == "/test")
        #expect(BrowserPath.parent("/") == "/")
    }

    @Test func validatesPacketsAndTextPreviews() throws {
        var packet = SFTPPacket()
        packet.put64(0x1020_3040_5060_7080)
        packet.putString("你好\nfile")
        #expect(try packet.uint64() == 0x1020_3040_5060_7080)
        #expect(try packet.string() == "你好\nfile")
        #expect(throws: (any Error).self) { try packet.uint32() }
        var invalid = SFTPPacket(data: Data([0xff, 0xff, 0xff, 0xff]))
        #expect(throws: (any Error).self) { try invalid.bytes() }
        #expect(BrowserPath.preview(Data([65, 0, 66])) == nil)
        #expect(BrowserPath.preview(Data("中文".utf8).dropLast()) == "中")
        #expect(BrowserPath.preview(Data([0xff, 0xfe, 0xfd, 0xfc])) == nil)
        #expect(BrowserPath.preview(Data([0xff])) == nil)
    }

    @Test func localFilesAndSymlinks() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = LocalFileBrowser()
        try await local.makeDirectory(root.appendingPathComponent("folder").path)
        let file = root.appendingPathComponent("中文 $ 'file.txt")
        try Data("hello 世界".utf8).write(to: file)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let listing = try await local.list(root.path)
        #expect(listing.first?.name == "folder")
        #expect(listing.first(where: { $0.name == "link" })?.kind == .symbolicLink)
        #expect(try await local.preview(file.path) == Data("hello 世界".utf8))
        #expect(try await local.preview(link.path) == Data("hello 世界".utf8))
        let renamed = root.appendingPathComponent("renamed")
        try await local.rename(file.path, to: renamed.path)
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        await #expect(throws: (any Error).self) { try await local.rename(renamed.path, to: link.path) }
    }

    /// Exercises real v3 framing/handles, partial reads, EOF and mutations against
    /// Apple's OpenSSH SFTP server, without any network or user SSH credentials.
    @Test func sftpRoundTripAndSafeMutations() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = try SFTPTransport(executable: "/usr/libexec/sftp-server", arguments: [])
        let client = SFTPClient(transport: transport)
        defer { client.cancel() }
        let home = try await client.start()
        #expect(home.hasPrefix("/"))
        let canonical = try await client.realpath(root.path)
        let folder = BrowserPath.join(canonical, "空 folder ' ; $test")
        try await client.makeDirectory(folder)
        // Include enough bytes for multiple packets, binary NULs, and non-ASCII names.
        let data = Data((0..<200_000).map { UInt8($0 % 256) })
        let source = root.appendingPathComponent("中文 '$file.bin")
        try data.write(to: source)
        try await client.upload(source, to: folder, progress: { _ in })
        let files = try await client.list(folder)
        let file = try #require(files.first)
        #expect(file.name == source.lastPathComponent)
        #expect(file.kind == .file)
        #expect(file.size == UInt64(data.count))
        #expect(try await client.preview(file.path) == data)
        let download = root.appendingPathComponent("download.bin")
        try await client.download(file.path, to: download, progress: { _ in })
        #expect(try Data(contentsOf: download) == data)
        let permissions = try FileManager.default.attributesOfItem(atPath: download.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        // Existing destinations must never be overwritten.
        await #expect(throws: (any Error).self) {
            try await client.upload(source, to: folder, progress: { _ in })
        }
        await #expect(throws: (any Error).self) {
            try await client.download(file.path, to: download, progress: { _ in })
        }
        #expect(try Data(contentsOf: download) == data)
        #expect(try await client.list(folder).count == 1) // failed upload cleaned its staging file
        let renamedPath = BrowserPath.join(folder, "renamed\nfile.bin")
        try await client.rename(file.path, to: renamedPath)
        let renamed = try #require(try await client.list(folder).first)
        #expect(renamed.name == "renamed\nfile.bin")
        await #expect(throws: (any Error).self) {
            try await client.remove(BrowserFile(path: folder, name: "folder", kind: .directory, size: 0))
        }
        try await client.remove(renamed)
        try await client.remove(BrowserFile(path: folder, name: "folder", kind: .directory, size: 0))
        #expect(!FileManager.default.fileExists(atPath: folder))
        client.cancel()
        await #expect(throws: (any Error).self) { try await client.list(canonical) }
    }

    @Test func sftpFollowsFileLinksAndBoundsPreview() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("big.txt")
        try Data(repeating: 65, count: 300_000).write(to: file)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let transport = try SFTPTransport(executable: "/usr/libexec/sftp-server", arguments: [])
        let client = SFTPClient(transport: transport)
        defer { client.cancel() }
        _ = try await client.start()
        #expect(try await client.preview(file.path).count == 262_144)
        #expect(try await client.preview(link.path).count == 262_144)
        let destination = root.appendingPathComponent("download.txt")
        try await client.download(link.path, to: destination, progress: { _ in })
        #expect(try Data(contentsOf: destination).count == 300_000)
    }

    @MainActor @Test(arguments: [false, true])
    func primaryActionFollowsDirectoryAndFileLinks(remote: Bool) async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("linked text".utf8).write(to: folder.appendingPathComponent("file.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("folder-link").path, withDestinationPath: "folder")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("chain").path, withDestinationPath: "folder-link")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("file-link").path, withDestinationPath: "chain/file.txt")
        let model = FileBrowserModel { _ in
            SFTPClient(transport: try SFTPTransport(executable: "/usr/libexec/sftp-server", arguments: ["-d", root.path]))
        }
        defer { model.disconnect() }
        if remote {
            model.observeTerminal(.ssh(SSHFileConnection(host: "test-host")), directory: nil)
        } else { model.follow(root) }
        try await waitForIdle(model)
        let canonicalRoot = model.path
        let link = try #require(model.files.first { $0.name == "chain" })
        #expect(link.kind == .symbolicLink)
        model.activateFiles([link.id])
        try await waitForIdle(model)
        #expect(model.error == nil)
        #expect(URL(fileURLWithPath: model.path).resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
        #expect(model.files.map(\.name) == ["file.txt"])
        #expect(model.preview == nil)
        // The unchanged terminal report must not snap back after opening a directory link.
        if !remote { model.follow(root); #expect(!model.busy) }
        model.navigate(canonicalRoot)
        try await waitForIdle(model)
        let file = try #require(model.files.first { $0.name == "file-link" })
        model.activateFiles([file.id])
        try await waitForIdle(model)
        #expect(model.error == nil)
        #expect(model.preview?.name == "file-link")
        #expect(model.preview?.text == "linked text")
    }

    @Test(arguments: [false, true])
    func brokenCyclicAndSpecialFileLinksFailWithoutHanging(remote: Bool) async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, target) in [("broken", "missing"), ("loop-a", "loop-b"), ("loop-b", "loop-a"), ("pipe-link", "pipe")] {
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(name).path, withDestinationPath: target)
        }
        #expect(mkfifo(root.appendingPathComponent("pipe").path, 0o600) == 0)
        let local = LocalFileBrowser()
        let client = SFTPClient(transport: try SFTPTransport(executable: "/usr/libexec/sftp-server", arguments: [], timeout: 2))
        defer { client.cancel() }
        _ = try await client.start()
        let start = ContinuousClock.now
        for name in ["broken", "loop-a", "pipe-link"] {
            let path = root.appendingPathComponent(name).path
            await #expect(throws: (any Error).self) {
                if remote { _ = try await client.preview(path) } else { _ = try await local.preview(path) }
            }
        }
        #expect(ContinuousClock.now - start < .seconds(3))
        let entries = try await local.list(root.path)
        #expect(entries.count == 5) // Failure must not hide or delete broken links.
    }

    @Test func sftpMutatesLinksWithoutChangingTheirTargets() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let content = folder.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: content)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let client = SFTPClient(transport: try SFTPTransport(executable: "/usr/libexec/sftp-server", arguments: []))
        defer { client.cancel() }
        _ = try await client.start()
        let renamed = root.appendingPathComponent("renamed-link")
        try await client.rename(link.path, to: renamed.path)
        let entry = try #require(try await client.list(root.path).first { $0.name == "renamed-link" })
        #expect(entry.kind == .symbolicLink)
        try await client.remove(entry)
        #expect(try Data(contentsOf: content) == Data("keep".utf8))
        #expect(!FileManager.default.fileExists(atPath: renamed.path))
    }

    @Test func stalledConnectionsCanBeCancelledAndTimeOut() async throws {
        let transport = try SFTPTransport(executable: "/bin/sleep", arguments: ["30"])
        let client = SFTPClient(transport: transport)
        let pending = Task { try await client.start() }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        client.cancel()
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(ContinuousClock.now - start < .seconds(2))
        let timedTransport = try SFTPTransport(executable: "/bin/sleep", arguments: ["30"], timeout: 0.1)
        let timedClient = SFTPClient(transport: timedTransport)
        defer { timedClient.cancel() }
        await #expect(throws: (any Error).self) { try await timedClient.start() }
    }

    @MainActor @Test func followsLocalDirectoryAndKeepsManualLocation() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let model = FileBrowserModel()
        model.follow(root, active: false)
        #expect(!model.busy)
        model.follow(root)
        try await waitForIdle(model)
        #expect(model.path == root.path)
        model.navigate(folder.path)
        try await waitForIdle(model)
        model.follow(root)
        #expect(model.path == folder.path)
        model.follow(folder)
        try await waitForIdle(model)
        model.follow(root)
        try await waitForIdle(model)
        #expect(model.path == root.path)
        // A failed follow must not repeatedly retry and leave the browser busy.
        model.follow(root.appendingPathComponent("does-not-exist"))
        try await waitForIdle(model)
        #expect(model.error != nil)
        model.follow(root.appendingPathComponent("does-not-exist"))
        #expect(!model.busy)
        model.disconnect()
        #expect(model.files.isEmpty)
        #expect(!model.busy)
    }

    @MainActor private func waitForIdle(_ model: FileBrowserModel) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while model.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.busy)
    }

    private func temporaryFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GhosttyCN-Files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
