import AppKit
import SwiftUI

@MainActor
final class FileBrowserModel: ObservableObject {
    struct Preview: Identifiable {
        let id = UUID()
        let name: String
        let text: String?
        let truncated: Bool
    }

    @Published private(set) var files: [BrowserFile] = [] {
        didSet { reconcileSelection() }
    }
    @Published private(set) var path = FileManager.default.homeDirectoryForCurrentUser.path {
        didSet { if path != oldValue { selectedFileID = nil } }
    }
    @Published var selectedFileID: BrowserFile.ID?
    @Published private(set) var remoteHost: String?
    @Published private(set) var busy = false
    @Published private(set) var transferred: UInt64?
    @Published var error: String?
    @Published var preview: Preview?
    @Published var showsHidden = false {
        didSet { reconcileSelection() }
    }
    @Published var filter = "" {
        didSet { reconcileSelection() }
    }
    @Published private(set) var terminalSSH: TerminalSSHContext = .local
    private let local = LocalFileBrowser()
    private let makeConnection: (SSHFileConnection) throws -> SFTPClient
    private var remote: SFTPClient?
    private var terminalDirectory: String?
    private var lastAttemptedLocalDirectory: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var automaticConnection = false
    private var connectionFailed = false
    private var appliedContext: TerminalSSHContext?
    private var remoteDirectory: RemoteDirectoryReport?
    private var lastAttemptedRemoteDirectory: String?
    @Published private(set) var hasRemoteDirectoryReport = false

    var canFollowRemoteDirectory: Bool { automaticConnection && remote != nil }

    enum RemoteFolderStatus: Equatable {
        case unavailable, awaitingReport, following
    }

    var remoteFolderStatus: RemoteFolderStatus {
        guard canFollowRemoteDirectory else { return .unavailable }
        return hasRemoteDirectoryReport ? .following : .awaitingReport
    }

    init(makeConnection: @escaping (SSHFileConnection) throws -> SFTPClient = { try SFTPClient(connection: $0) }) {
        self.makeConnection = makeConnection
    }

    var hasUnsupportedSSHConnection: Bool {
        terminalSSH == .unsupported
    }

    private var blocksLocalFiles: Bool {
        terminalSSH != .local && remote == nil
    }

    var canBrowse: Bool { !blocksLocalFiles && (remoteHost == nil || remote != nil) }
    var canRefresh: Bool { !busy && terminalSSH != .unsupported }

    func observeTerminal(
        _ context: TerminalSSHContext, directory: URL?,
        remoteDirectory report: RemoteDirectoryReport? = nil, foregroundGroup: Int? = nil
    ) {
        // Publishing an unchanged context every poll rebuilds open native menus.
        if terminalSSH != context { terminalSSH = context }
        if case .ssh = context, let report, let foregroundGroup,
           UInt64(exactly: foregroundGroup) == report.foregroundGroup {
            remoteDirectory = report
        } else { remoteDirectory = nil }
        let available = remoteDirectory != nil
        if hasRemoteDirectoryReport != available { hasRemoteDirectoryReport = available }
        if context == .local, let directory { terminalDirectory = directory.path }
        synchronizeConnection()
        if context == .local { follow(directory) }
        followRemoteDirectory()
    }

    private func followRemoteDirectory() {
        guard canFollowRemoteDirectory, !busy, let remoteDirectory,
              lastAttemptedRemoteDirectory != remoteDirectory.path else { return }
        lastAttemptedRemoteDirectory = remoteDirectory.path
        if path != remoteDirectory.path { navigate(remoteDirectory.path, manual: false) }
    }

    private func synchronizeConnection() {
        guard !busy else { return }
        guard appliedContext != terminalSSH else { return }
        let previous = appliedContext
        appliedContext = terminalSSH
        switch terminalSSH {
        case .ssh(let connection): connect(connection)
        case .local:
            if automaticConnection || previous == .unsupported {
                disconnect()
                appliedContext = .local
                refresh()
            }
        case .unsupported:
            if automaticConnection { disconnect() }
            appliedContext = .unsupported
            files = []
        }
    }

    var visibleFiles: [BrowserFile] {
        files.filter { (showsHidden || !$0.name.hasPrefix(".")) &&
            (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) }
    }

    private func reconcileSelection() {
        if let selectedFileID, !visibleFiles.contains(where: { $0.id == selectedFileID }) {
            self.selectedFileID = nil
        }
    }

    deinit { remote?.cancel(); task?.cancel() }

    func follow(_ directory: URL?, active: Bool = true) {
        if let directory { terminalDirectory = directory.path }
        guard active, terminalSSH == .local, remote == nil, !busy, let terminalDirectory,
              lastAttemptedLocalDirectory != terminalDirectory else { return }
        lastAttemptedLocalDirectory = terminalDirectory
        if terminalDirectory != path { navigate(terminalDirectory, manual: false) }
    }

    func refresh() {
        guard canRefresh else { return }
        if connectionFailed, case .ssh = terminalSSH {
            appliedContext = nil
            synchronizeConnection()
        } else { navigate(path, manual: false) }
    }

    func navigate(_ destination: String, manual: Bool = true) {
        guard !busy, canBrowse else { return }
        if manual {
            // Consume the current report, not the following feature itself.
            // Browsing stays put until the terminal actually changes directory.
            lastAttemptedLocalDirectory = terminalDirectory
            lastAttemptedRemoteDirectory = remoteDirectory?.path
        }
        let remote = remote
        execute {
            let resolved: String
            let entries: [BrowserFile]
            if let remote {
                resolved = try await remote.realpath(destination)
                entries = try await remote.list(resolved)
            } else {
                resolved = (destination as NSString).expandingTildeInPath
                guard resolved.hasPrefix("/") else { throw FileBrowserError.invalidName }
                entries = try await self.local.list(resolved)
            }
            try Task.checkCancellation()
            self.path = resolved
            self.files = entries
            self.filter = ""
        }
    }

    /// Remote browsing is only derived from the focused terminal's SSH context.
    private func connect(_ connection: SSHFileConnection) {
        do {
            _ = try connection.arguments()
            remote?.cancel()
            remote = nil
            automaticConnection = true
            connectionFailed = false
            remoteHost = connection.host
            lastAttemptedRemoteDirectory = nil
            files = []
            path = "."
            let client = try makeConnection(connection)
            remote = client
            execute {
                do {
                    let directory = try await client.start()
                    let entries = try await client.list(directory)
                    try Task.checkCancellation()
                    self.path = directory
                    self.files = entries
                } catch {
                    client.cancel()
                    if self.remote === client { self.connectionFailed = true }
                    throw error
                }
            }
        } catch { connectionFailed = true; self.error = error.localizedDescription }
    }

    func disconnect() {
        generation = UUID()
        task?.cancel()
        task = nil
        remote?.cancel()
        remote = nil
        remoteHost = nil
        automaticConnection = false
        connectionFailed = false
        appliedContext = nil
        lastAttemptedLocalDirectory = nil
        lastAttemptedRemoteDirectory = nil
        busy = false
        transferred = nil
        files = []
        preview = nil
        path = terminalDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Stop only the pending file operation, never switch to local files while
    /// the terminal is still remote. Refresh can retry this terminal connection.
    func cancelOperation() {
        generation = UUID()
        task?.cancel()
        task = nil
        remote?.cancel()
        remote = nil
        connectionFailed = true
        busy = false
        transferred = nil
        files = []
        preview = nil
    }

    /// Shared primary action for Return, double-click and accessibility.
    /// Only the current visible item can be activated, never a stale path.
    func activateFiles(_ ids: Set<BrowserFile.ID>) {
        guard !busy, canBrowse, ids.count == 1,
              let file = visibleFiles.first(where: { ids.contains($0.id) }) else { return }
        selectedFileID = file.id
        showPreview(file)
    }

    func showPreview(_ file: BrowserFile) {
        if file.isDirectory { navigate(file.path); return }
        let remote = remote
        execute {
            guard file.kind == .file else { throw FileBrowserError.notRegularFile }
            let data: Data
            if let remote { data = try await remote.preview(file.path) } else { data = try await self.local.preview(file.path) }
            try Task.checkCancellation()
            self.preview = Preview(name: file.name, text: BrowserPath.preview(data), truncated: file.size > UInt64(data.count))
        }
    }

    func makeDirectory(_ name: String) {
        guard canBrowse else { return }
        let remote = remote
        let destination = BrowserPath.join(path, name)
        execute {
            try BrowserPath.validateName(name)
            if let remote { try await remote.makeDirectory(destination) } else { try await self.local.makeDirectory(destination) }
            try await self.reload(remote)
        }
    }

    func rename(_ file: BrowserFile, name: String) {
        guard canBrowse else { return }
        let remote = remote
        let destination = BrowserPath.join(BrowserPath.parent(file.path), name)
        execute {
            try BrowserPath.validateName(name)
            if let remote { try await remote.rename(file.path, to: destination) } else { try await self.local.rename(file.path, to: destination) }
            try await self.reload(remote)
        }
    }

    func remove(_ file: BrowserFile) {
        guard canBrowse else { return }
        let remote = remote
        execute {
            if let remote { try await remote.remove(file) } else { try await self.local.trash(file.path) }
            try await self.reload(remote)
        }
    }

    func upload(_ source: URL) {
        guard let remote else { return }
        let directory = path
        execute {
            self.transferred = 0
            try await remote.upload(source, to: directory, progress: self.progressReporter())
            try await self.reload(remote)
        }
    }

    func download(_ file: BrowserFile, to destination: URL) {
        guard let remote else { return }
        execute {
            self.transferred = 0
            try await remote.download(file.path, to: destination, progress: self.progressReporter())
        }
    }

    private func progressReporter() -> @Sendable (UInt64) -> Void {
        let id = generation
        return { [weak self] count in
            // One UI update per 256 KiB, independent of network packet size.
            guard count % 262_144 < 32_768 else { return }
            Task { @MainActor [weak self] in
                guard let self, generation == id, busy else { return }
                transferred = count
            }
        }
    }

    private func reload(_ remote: SFTPClient?) async throws {
        let entries: [BrowserFile]
        if let remote { entries = try await remote.list(path) } else { entries = try await local.list(path) }
        try Task.checkCancellation()
        files = entries
    }

    private func execute(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        let id = UUID()
        generation = id
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == id {
                    busy = false
                    transferred = nil
                    task = nil
                    synchronizeConnection()
                    if error == nil, terminalSSH == .local { follow(nil) }
                    if error == nil { followRemoteDirectory() }
                }
            }
            do { try await operation() } catch is CancellationError { /* Closing the browser cancels its connection. */ } catch {
                if generation == id {
                    self.error = error.localizedDescription
                    if automaticConnection, let failure = error as? FileBrowserError {
                        switch failure {
                        case .disconnected, .timeout, .protocolError: connectionFailed = true
                        default: break
                        }
                    }
                }
            }
        }
    }
}
