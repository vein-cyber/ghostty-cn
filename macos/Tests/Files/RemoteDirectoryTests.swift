import Foundation
import Testing
import Combine
@testable import Ghostty

struct RemoteDirectoryTests {
    @Test func parsesBoundedDirectoryHints() throws {
        let report = try #require(RemoteDirectoryReport(
            uri: "file://remote/home/a%20b/%E4%B8%AD%E6%96%87", sequence: 1, foregroundGroup: 42))
        #expect(report.path == "/home/a b/中文")
        #expect(RemoteDirectoryReport(uri: "kitty-shell-cwd://remote/tmp/a%20b", sequence: 1, foregroundGroup: 42)?.path == "/tmp/a%20b")
        for uri in ["https://host/tmp", "file:///tmp", "file://user@host/tmp", "file://host/tmp?q=x",
                    "file://host/tmp#fragment", "file://host/tmp%00bad", "file://host/%0A", "file://host/%FF"] {
            #expect(RemoteDirectoryReport(uri: uri, sequence: 1, foregroundGroup: 42) == nil)
        }
        #expect(RemoteDirectoryReport(uri: "file://host/tmp", sequence: 1, foregroundGroup: 0) == nil)
    }

    @MainActor @Test func unchangedSSHPollsDoNotRebuildOpenMenus() {
        let model = FileBrowserModel()
        #expect(model.remoteFolderStatus == .unavailable)
        var updates = 0
        let observation = model.$terminalSSH.dropFirst().sink { _ in updates += 1 }
        defer { observation.cancel(); model.disconnect() }
        for _ in 0..<5 { model.observeTerminal(.local, directory: nil) }
        #expect(updates == 0)
        for _ in 0..<5 { model.observeTerminal(.unsupported, directory: nil) }
        #expect(updates == 1)
    }

    @MainActor @Test func remoteReportsFollowOnlyTheirOwnSSHSession() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("remote child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let model = FileBrowserModel { _ in
            SFTPClient(transport: try SFTPTransport(executable: "/usr/libexec/sftp-server", arguments: ["-d", root.path]))
        }
        defer { model.disconnect() }
        let context = TerminalSSHContext.ssh(SSHFileConnection(host: "actual-ssh-alias"))
        let report = try #require(RemoteDirectoryReport(
            uri: "file://untrusted-hostname" + child.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!,
            sequence: 1, foregroundGroup: 42))
        model.observeTerminal(context, directory: nil, remoteDirectory: report, foregroundGroup: 41)
        try await waitForIdle(model)
        #expect(!model.hasRemoteDirectoryReport)
        #expect(model.remoteHost == "actual-ssh-alias")
        #expect(model.remoteFolderStatus == .awaitingReport)
        model.observeTerminal(context, directory: nil, remoteDirectory: report, foregroundGroup: 42)
        try await waitForIdle(model)
        #expect(model.hasRemoteDirectoryReport)
        #expect(model.remoteFolderStatus == .following)
        #expect(URL(fileURLWithPath: model.path).resolvingSymlinksInPath() == child.resolvingSymlinksInPath())
        #expect(model.remoteHost == "actual-ssh-alias") // report never selects a connection
        model.navigate(root.path)
        try await waitForIdle(model)
        #expect(model.remoteFolderStatus == .following)
        model.observeTerminal(context, directory: nil, remoteDirectory: report, foregroundGroup: 42)
        #expect(model.path == root.path || URL(fileURLWithPath: model.path).resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
        let parentReport = try #require(RemoteDirectoryReport(
            uri: "file://untrusted-hostname" + root.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!,
            sequence: 2, foregroundGroup: 42))
        model.observeTerminal(context, directory: nil, remoteDirectory: parentReport, foregroundGroup: 42)
        try await waitForIdle(model)
        model.observeTerminal(context, directory: nil, remoteDirectory: report, foregroundGroup: 42)
        try await waitForIdle(model)
        #expect(URL(fileURLWithPath: model.path).resolvingSymlinksInPath() == child.resolvingSymlinksInPath())
        model.observeTerminal(.local, directory: root, remoteDirectory: report, foregroundGroup: 42)
        try await waitForIdle(model)
        #expect(!model.hasRemoteDirectoryReport)
        #expect(model.remoteHost == nil)
        #expect(model.remoteFolderStatus == .unavailable)
        #expect(model.path == root.path)
    }

    @Test func existingAndAutomaticOSC7UseTheSamePathParser() throws {
        let reports = try ["file://server.example/home/user/a%20b", "file://ghosttycn-remote.invalid/home/user/a%20b"].map {
            try #require(RemoteDirectoryReport(uri: $0, sequence: 1, foregroundGroup: 42))
        }
        #expect(reports[0] == reports[1])
        #expect(reports[0].path == "/home/user/a b")
    }

    @Test(arguments: ["bash", "zsh"]) func sessionHooksPreservePromptsAndEncodePaths(
        shell: String
    ) throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("中文 space ' % #")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell == "bash" ? "/bin/bash" : "/bin/zsh")
        process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        let command = RemoteDirectoryIntegration.command
        let prefix = shell == "bash" ? "PROMPT_COMMAND=':;'\n" : "precmd_functions=(':')\n"
        let suffix = shell == "bash" ? "printf '\\nHOOK:%s\\n' \"${PROMPT_COMMAND//$'\\n'/ }\"" :
            "printf '\\nHOOK:%s\\n' \"${precmd_functions[*]}\""
        process.arguments = ["-f", "-c", prefix + command + command + "\ncd -- \"$1\"\n_ghosttycn_report_pwd\n" + suffix, "test", child.path]
        // Bash's -f only disables pathname expansion; zsh's -f also avoids user rc files.
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let text = try #require(String(data: data, encoding: .utf8))
        let reports = text.components(separatedBy: "\u{7}").compactMap { part -> RemoteDirectoryReport? in
            guard let start = part.range(of: "\u{1b}]7;") else { return nil }
            return RemoteDirectoryReport(uri: String(part[start.upperBound...]), sequence: 1, foregroundGroup: 42)
        }
        #expect(reports.count == 3)
        let last = try #require(reports.last)
        #expect(URL(fileURLWithPath: last.path).resolvingSymlinksInPath() == child.resolvingSymlinksInPath())
        let hook = try #require(text.components(separatedBy: "\n").first { $0.hasPrefix("HOOK:") })
        #expect(hook.hasPrefix("HOOK::"))
        #expect(hook.components(separatedBy: "_ghosttycn_report_pwd").count == 2)
    }

    @Test func bashArrayPromptAndExitStatusArePreserved() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.environment = ["PATH": "/usr/bin:/bin"]
        let command = RemoteDirectoryIntegration.command
        process.arguments = ["-c", "declare -ax PROMPT_COMMAND=(':')\n" + command + command +
            "\ndeclare -p PROMPT_COMMAND\nfalse\n_ghosttycn_report_pwd\ntest $? -eq 1"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("declare -ax PROMPT_COMMAND"))
        #expect(text.contains("[0]=\":\""))
        #expect(text.components(separatedBy: "_ghosttycn_report_pwd").count == 2)
    }

    @MainActor private func waitForIdle(_ model: FileBrowserModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.busy)
    }

    private func temporaryFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GhosttyCN-CWD-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
