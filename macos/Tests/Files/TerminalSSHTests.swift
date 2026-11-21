import Foundation
import Darwin
import Testing
@testable import Ghostty

struct TerminalSSHTests {
    @Test func parsesAliasesUsersAndPorts() throws {
        #expect(TerminalSSHDetector.connection(arguments: ["ssh", "93p"])?.host == "93p")
        let connection = try #require(TerminalSSHDetector.connection(arguments: [
            "/usr/bin/ssh", "-vvtt", "-p2222", "-l", "root", "-i", "/tmp/key with spaces",
            "-F", "/tmp/custom config", "-Jjump", "-o", "SendEnv=TERM_PROGRAM", "server"
        ]))
        #expect(connection.host == "server")
        #expect(connection.port == "2222")
        #expect(connection.configFile == "/tmp/custom config")
        #expect(connection.options.contains("User=root"))
        #expect(connection.options.contains("IdentityFile=/tmp/key with spaces"))
        #expect(connection.options.contains("ProxyJump=jump"))
        let arguments = try connection.arguments()
        #expect(arguments.contains("-oStrictHostKeyChecking=yes"))
        #expect(!arguments.contains("SendEnv=TERM_PROGRAM"))
        let uri = try #require(TerminalSSHDetector.connection(arguments: ["ssh", "ssh://root@example.com:2200"]))
        #expect(uri.host == "root@example.com")
        #expect(uri.port == "2200")
    }

    @Test func refusesAmbiguousAndNoninteractiveCommands() {
        for arguments in [
            ["ssh", "-N", "server"], ["ssh", "-G", "server"], ["ssh", "-W", "server:22", "jump"],
            ["ssh", "-s", "server", "sftp"], ["ssh", "server", "command"], ["ssh", "-p"],
            ["ssh", "-o", "ProxyCommand=anything", "server"], ["ssh", "-o", "Unknown=value", "server"],
            ["ssh", "ssh://user:password@server"], ["ssh", "-f", "server"], ["ssh", "-p0", "server"],
            ["ssh", "-F", "relative.conf", "server"]
        ] {
            #expect(TerminalSSHDetector.connection(arguments: arguments) == nil)
        }
        let forwarding = TerminalSSHDetector.connection(arguments: ["ssh", "-L8080:localhost:80", "server"])
        #expect(forwarding?.host == "server")
        #expect(forwarding?.options.isEmpty == true)
        #expect(TerminalSSHDetector.context(foregroundGroup: nil) == .local)
    }

    @Test func recognizesOnlyTheExactApplicationOwnedBootstrap() throws {
        let command = TerminalSSHDetector.automaticDirectoryCommand
        let connection = try #require(TerminalSSHDetector.connection(arguments: [
            "/usr/bin/ssh", "-t", "-p", "2222", "-Jjump", "user@host", command
        ]))
        #expect(connection.host == "user@host")
        #expect(connection.port == "2222")
        #expect(connection.options.contains("ProxyJump=jump"))
        #expect(TerminalSSHDetector.connection(arguments: ["ssh", "host", command + "; echo changed"]) == nil)
        #expect(TerminalSSHDetector.connection(arguments: ["ssh", "host", "sh -c 'echo arbitrary'"]) == nil)
    }

    @Test func onlyDecodesArgumentsNotEnvironment() {
        var argc: Int32 = 3
        var data = withUnsafeBytes(of: &argc) { Data($0) }
        data.append(Data("/usr/bin/ssh\0\0ssh\0\0host\0SECRET=must-not-be-returned\0".utf8))
        #expect(TerminalSSHDetector.decodeArguments(data) == ["ssh", "", "host"])
        #expect(TerminalSSHDetector.decodeArguments(Data([1, 0, 0])) == nil)
        #expect(TerminalSSHDetector.decodeArguments(Data([1, 0, 0, 0, 65])) == nil)
    }

    @Test func readsActualArgvWithoutLaunchingAShell() throws {
        #expect(TerminalSSHDetector.processIDs(group: getpgrp())?.contains(getpid()) == true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let arguments = try #require(TerminalSSHDetector.arguments(pid: process.processIdentifier))
        #expect(arguments.last == "5")
        #expect(arguments.count == 2)
    }

    @Test func appearancePreferencesPersistWithoutChangingGhosttyConfig() throws {
        let suite = "GhosttyCN-FileBrowser-Tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!FileBrowserPreferences.initiallyVisible(in: defaults))
        defaults.set(true, forKey: FileBrowserPreferences.defaultVisibleKey)
        defaults.set("right", forKey: FileBrowserPreferences.positionKey)
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(FileBrowserPreferences.initiallyVisible(in: reopened))
        #expect(reopened.string(forKey: FileBrowserPreferences.positionKey) == "right")
        #expect(FileBrowserPreferences.Position.allCases.count == 2)
    }

    @MainActor @Test func followsSSHAndReturnsToLocalOnExit() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = testModel(root: root)
        model.observeTerminal(.local, directory: root)
        try await waitForIdle(model)
        model.observeTerminal(.ssh(SSHFileConnection(host: "93p")), directory: root)
        try await waitForIdle(model)
        #expect(model.remoteHost == "93p")
        #expect(URL(fileURLWithPath: model.path).resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
        #expect(model.canBrowse)
        model.observeTerminal(.local, directory: root)
        try await waitForIdle(model)
        #expect(model.remoteHost == nil)
        #expect(model.path == root.path)
        model.disconnect()
    }

    @MainActor @Test func cancellingFilesNeverSwitchesTheRemoteTerminalToLocalFiles() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var attempts = 0
        let model = FileBrowserModel { _ in
            attempts += 1
            let transport = attempts == 1 ?
                try SFTPTransport(executable: "/bin/sleep", arguments: ["20"]) :
                try SFTPTransport(executable: "/usr/libexec/sftp-server", arguments: ["-d", root.path])
            return SFTPClient(transport: transport)
        }
        defer { model.disconnect() }
        let context = TerminalSSHContext.ssh(SSHFileConnection(host: "93p"))
        model.observeTerminal(context, directory: root)
        #expect(model.busy)
        #expect(model.remoteHost == "93p")
        model.cancelOperation()
        #expect(!model.busy)
        #expect(model.remoteHost == "93p")
        #expect(!model.canBrowse)
        #expect(model.canRefresh)
        model.observeTerminal(context, directory: root)
        #expect(attempts == 1)
        model.refresh()
        try await waitForIdle(model)
        #expect(attempts == 2)
        #expect(model.remoteHost == "93p")
        #expect(model.error == nil)
        #expect(model.canBrowse)
    }

    @MainActor @Test func remoteFilesBelongOnlyToTheFocusedTerminalHost() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var connections: [String] = []
        let model = FileBrowserModel { connection in
            connections.append(connection.host)
            return SFTPClient(transport: try SFTPTransport(executable: "/usr/libexec/sftp-server", arguments: ["-d", root.path]))
        }
        defer { model.disconnect() }
        for host in ["terminal-a", "terminal-b"] {
            model.observeTerminal(.ssh(SSHFileConnection(host: host)), directory: root)
            try await waitForIdle(model)
            #expect(model.remoteHost == host)
        }
        #expect(connections == ["terminal-a", "terminal-b"])
        model.observeTerminal(.local, directory: root)
        try await waitForIdle(model)
        #expect(model.remoteHost == nil)
        #expect(model.canBrowse)
    }

    @MainActor @Test func unknownSSHDoesNotExposeLocalFileActions() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = testModel(root: root)
        model.observeTerminal(.local, directory: root)
        try await waitForIdle(model)
        model.observeTerminal(.unsupported, directory: root)
        #expect(model.hasUnsupportedSSHConnection)
        #expect(!model.canBrowse)
        #expect(model.files.isEmpty)
        model.makeDirectory("must-not-be-created")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-be-created").path))
        model.observeTerminal(.unsupported, directory: root)
        #expect(model.hasUnsupportedSSHConnection)
        #expect(!model.canBrowse)
        #expect(!model.canRefresh)
        #expect(model.remoteHost == nil)
        model.observeTerminal(.local, directory: root)
        try await waitForIdle(model)
        #expect(model.canBrowse)
        model.disconnect()
    }

    @MainActor @Test func failedAutomaticConnectionDoesNotRetryEveryPoll() async throws {
        var attempts = 0
        let model = FileBrowserModel { _ in attempts += 1; throw FileBrowserError.disconnected }
        let context = TerminalSSHContext.ssh(SSHFileConnection(host: "93p"))
        model.observeTerminal(context, directory: nil)
        model.observeTerminal(context, directory: nil)
        #expect(attempts == 1)
        #expect(model.error != nil)
        #expect(!model.canBrowse)
        #expect(model.canRefresh)
        model.refresh()
        #expect(attempts == 2)
        model.disconnect()
    }

    @MainActor private func testModel(root: URL) -> FileBrowserModel {
        FileBrowserModel { _ in
            SFTPClient(transport: try SFTPTransport(executable: "/usr/libexec/sftp-server", arguments: ["-d", root.path]))
        }
    }

    @MainActor private func waitForIdle(_ model: FileBrowserModel) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while model.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.busy)
    }

    private func temporaryFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GhosttyCN-SSH-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
