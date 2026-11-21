import Foundation
import Darwin
import GhosttyKit

enum TerminalSSHContext: Equatable, Sendable {
    case local
    case ssh(SSHFileConnection)
    case unsupported
}

enum TerminalSSHDetector {
    static let automaticDirectoryCommand = String(cString: ghostty_ssh_directory_command())
    /// Inspect only the focused PTY's foreground group and our own user. Never
    /// infer a host from terminal output, OSC strings, window titles or history.
    static func context(foregroundGroup: Int?) -> TerminalSSHContext {
        guard let foregroundGroup, let group = Int32(exactly: foregroundGroup), group > 0 else { return .local }
        guard let pids = processIDs(group: group) else { return .unsupported }
        var candidates: [(pid: Int32, parent: Int32)] = []
        var hasCustomSSH = false
        for pid in pids where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
                  info.pbi_uid == getuid(), info.pbi_pgid == UInt32(group) else { continue }
            var executable = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &executable, UInt32(executable.count)) > 0 else { continue }
            // The system OpenSSH binary is the supported automatic transport.
            // Custom SSH binaries and ambiguous wrappers cannot be linked safely.
            let path = String(cString: executable)
            guard path == "/usr/bin/ssh" else {
                if (path as NSString).lastPathComponent == "ssh" { hasCustomSSH = true }
                continue
            }
            candidates.append((pid, Int32(info.pbi_ppid)))
        }
        // Exclude ProxyJump's child SSH process. Ambiguous pipelines are not guessed.
        let primary = candidates.filter { candidate in !candidates.contains { $0.pid == candidate.parent } }
        guard !primary.isEmpty else { return hasCustomSSH ? .unsupported : .local }
        guard primary.count == 1, let argv = arguments(pid: primary[0].pid),
              let connection = connection(arguments: argv) else { return .unsupported }
        return .ssh(connection)
    }

    static func processIDs(group: Int32) -> [Int32]? {
        var pids = [Int32](repeating: 0, count: 128)
        let capacity = Int32(pids.count * MemoryLayout<Int32>.size)
        // Unlike proc_listpids, this wrapper returns a PID count, not a byte count.
        let count = proc_listpgrppids(group, &pids, capacity)
        guard count > 0, count < pids.count else { return nil }
        return Array(pids.prefix(Int(count)))
    }

    /// KERN_PROCARGS2 also includes environment data. Decode exactly argc
    /// arguments, then discard the buffer; never retain or log the environment.
    static func arguments(pid: Int32) -> [String]? {
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 262_144
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&query, UInt32(query.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return decodeArguments(Data(buffer.prefix(size)))
    }

    static func decodeArguments(_ data: Data) -> [String]? {
        guard data.count >= 4 else { return nil }
        let count = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= 4096 else { return nil }
        var index = 4
        guard let executableEnd = data[index...].firstIndex(of: 0) else { return nil }
        index = executableEnd
        while index < data.count, data[index] == 0 { index += 1 }
        var result: [String] = []
        for _ in 0..<count {
            guard index < data.count, let end = data[index...].firstIndex(of: 0),
                  let argument = String(data: data[index..<end], encoding: .utf8) else { return nil }
            result.append(argument)
            index = end + 1
        }
        return result
    }

    /// Parse argv boundaries, not shell text. Unknown options fail closed rather
    /// than accidentally connecting as the wrong user, port, or destination.
    static func connection(arguments argv: [String]) -> SSHFileConnection? {
        guard argv.count >= 2 else { return nil }
        var index = 1
        var options: [String] = []
        var config: String?
        var port = ""
        while index < argv.count {
            let argument = argv[index]
            if argument == "--" { index += 1; break }
            if !argument.hasPrefix("-") { break }
            let flags = Array(argument.dropFirst())
            guard !flags.isEmpty else { return nil }
            var cursor = 0
            while cursor < flags.count {
                let flag = flags[cursor]
                if "vqtaATCxXY".contains(flag) { cursor += 1; continue }
                if flag == "4" || flag == "6" {
                    options.removeAll { $0.lowercased().hasPrefix("addressfamily=") }
                    options.append("AddressFamily=" + (flag == "4" ? "inet" : "inet6"))
                    cursor += 1
                    continue
                }
                guard "plioFJLRDEb".contains(flag) else { return nil }
                let value: String
                if cursor + 1 < flags.count { value = String(flags[(cursor + 1)...]) } else {
                    index += 1
                    guard index < argv.count else { return nil }
                    value = argv[index]
                }
                switch flag {
                case "p": port = value
                case "l":
                    options.removeAll { $0.lowercased().hasPrefix("user=") }
                    options.append("User=" + value)
                case "i": options.append("IdentityFile=" + value)
                case "F":
                    // A relative config path is relative to the terminal's cwd, not
                    // the GUI process's cwd. Do not silently load a different file.
                    guard value.hasPrefix("/") || value == "none" else { return nil }
                    config = value
                case "J": options.append("ProxyJump=" + value)
                case "b": options.append("BindAddress=" + value)
                case "L", "R", "D", "E": break // forwarding and logs are intentionally not copied
                case "o":
                    let parts = value.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0.isWhitespace })
                    guard parts.count == 2 else { return nil }
                    let key = parts[0].lowercased()
                    if SSHFileConnection.inheritedOptions.contains(key) {
                        options.append(String(parts[0]) + "=" + parts[1].trimmingCharacters(in: .whitespaces))
                    } else if !["sendenv", "setenv", "controlmaster", "controlpath", "controlpersist",
                                "serveraliveinterval", "serveralivecountmax", "stricthostkeychecking"].contains(key) {
                        return nil
                    }
                default: return nil
                }
                break // argument-taking flags consume the remainder of this token
            }
            index += 1
        }
        // A remote command, subsystem, tunnel or background job isn't an interactive shell.
        guard index == argv.count - 1 ||
                (index == argv.count - 2 && argv.last == automaticDirectoryCommand) else { return nil }
        var host = argv[index]
        if host.hasPrefix("ssh://") {
            guard let uri = URLComponents(string: host), uri.password == nil,
                  uri.query == nil, uri.fragment == nil, uri.path.isEmpty,
                  let hostname = uri.host else { return nil }
            host = uri.user.map { $0 + "@" + hostname } ?? hostname
            if let uriPort = uri.port { port = String(uriPort) }
        }
        let connection = SSHFileConnection(host: host, port: port, configFile: config, options: options)
        guard (try? connection.arguments()) != nil else { return nil }
        return connection
    }
}
