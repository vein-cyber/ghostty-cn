import Foundation

struct BrowserFile: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case directory, file, symbolicLink, other }
    let path: String
    let name: String
    let kind: Kind
    let size: UInt64
    var id: String { path }
    var isDirectory: Bool { kind == .directory }

    static func sorted(_ files: [Self]) -> [Self] {
        files.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

enum FileBrowserError: LocalizedError {
    case invalidName, invalidHost, protocolError, disconnected, timeout, notRegularFile, tooManyFiles
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidName: return String(localized: "Enter a single file name without slashes or control characters.")
        case .invalidHost: return String(localized: "This terminal's SSH connection cannot be used for file browsing.")
        case .protocolError: return String(localized: "The server returned an invalid SFTP response.")
        case .disconnected: return String(localized: "The terminal file connection is closed. Use Refresh to try again.")
        case .timeout: return String(localized: "The file operation timed out. Use Refresh before trying again.")
        case .notRegularFile: return String(localized: "Only regular files can be previewed or transferred. Symbolic links are not followed.")
        case .tooManyFiles: return String(localized: "This folder has too many entries to display safely.")
        case .server(let detail): return String(localized: "File operation failed:") + "\n" + detail
        }
    }
}

enum BrowserPath {
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FileBrowserError.invalidName
        }
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    static func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent
    }

    static func preview(_ data: Data) -> String? {
        guard !data.contains(0) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        // Only trim an incomplete trailing UTF-8 scalar, never arbitrary binary bytes.
        for count in 1...3 where count <= data.count {
            let suffix = Array(data.suffix(count))
            let lead = suffix[0]
            let length = lead >= 0xc2 && lead <= 0xdf ? 2 :
                lead >= 0xe0 && lead <= 0xef ? 3 : lead >= 0xf0 && lead <= 0xf4 ? 4 : 0
            guard length > count, suffix.dropFirst().allSatisfy({ $0 & 0xc0 == 0x80 }) else { continue }
            if let text = String(data: data.dropLast(count), encoding: .utf8) { return text }
        }
        return nil
    }
}

/// Blocking filesystem work stays off the UI executor. No terminal commands are executed.
actor LocalFileBrowser {
    func list(_ path: String) throws -> [BrowserFile] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
        guard urls.count <= 100_000 else { throw FileBrowserError.tooManyFiles }
        return BrowserFile.sorted(try urls.map { url in
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let kind: BrowserFile.Kind
            switch attrs[.type] as? FileAttributeType {
            case .typeDirectory: kind = .directory
            case .typeRegular: kind = .file
            case .typeSymbolicLink: kind = .symbolicLink
            default: kind = .other
            }
            return BrowserFile(path: url.path, name: url.lastPathComponent, kind: kind,
                               size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0)
        })
    }

    func preview(_ path: String) throws -> Data {
        let handle = try regularFile(path)
        defer { try? handle.close() }
        return try handle.read(upToCount: 262_144) ?? Data()
    }

    func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    func rename(_ path: String, to destination: String) throws {
        try FileManager.default.moveItem(atPath: path, toPath: destination)
    }

    func trash(_ path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }
}

/// O_NONBLOCK prevents a replaced file (e.g. a FIFO) from hanging the browser.
func regularFile(_ path: String) throws -> FileHandle {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
        close(descriptor)
        throw FileBrowserError.notRegularFile
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

struct SSHFileConnection: Sendable, Equatable {
    let host: String
    var port: String = ""
    var configFile: String?
    var options: [String] = []

    /// Only endpoint/authentication options can be inherited from a live SSH
    /// command. No remote command, local command, or security-policy overrides.
    static let inheritedOptions: Set<String> = [
        "hostname", "user", "port", "identityfile", "identityagent", "identitiesonly",
        "proxyjump", "hostkeyalias", "userknownhostsfile", "addressfamily", "bindaddress"
    ]

    func arguments() throws -> [String] {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:[]%")
        guard !host.isEmpty, !host.hasPrefix("-"), !host.hasPrefix("@"),
              host.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              port.isEmpty || (UInt16(port).map { $0 > 0 } ?? false) else {
            throw FileBrowserError.invalidHost
        }
        // Ignore remote commands/forwarding in a terminal-oriented SSH config. Retain
        // HostName, User, IdentityFile, IdentityAgent, ProxyJump and other auth settings.
        var args = ["-T", "-a", "-x", "-s", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes",
                    "-oConnectTimeout=15", "-oServerAliveInterval=15", "-oServerAliveCountMax=2",
                    "-oClearAllForwardings=yes", "-oPermitLocalCommand=no", "-oRemoteCommand=none",
                    "-oControlMaster=no", "-oControlPath=none"]
        if !port.isEmpty { args += ["-p", port] }
        if let configFile {
            guard !configFile.contains("\0") else { throw FileBrowserError.invalidHost }
            args += ["-F", configFile]
        }
        for option in options {
            guard let separator = option.firstIndex(of: "="),
                  Self.inheritedOptions.contains(option[..<separator].lowercased()),
                  !option.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw FileBrowserError.invalidHost
            }
            args += ["-o", option]
        }
        return args + [host, "sftp"]
    }
}
