import Foundation
import Darwin

/// One private SSH subprocess per browser. Pipes carry binary SFTP, never shell commands.
/// Only cancellation and stderr capture cross threads; their state is lock-protected.
final class SFTPTransport: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var cancelled = false
    private var diagnostics = Data()
    private let timeout: TimeInterval

    init(executable: String = "/usr/bin/ssh", arguments: [String], timeout: TimeInterval = 30) throws {
        self.timeout = timeout
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            lock.lock()
            diagnostics.append(data.prefix(max(0, 8192 - diagnostics.count)))
            lock.unlock()
        }
        try process.run()
        // Process has duplicated these descriptors into the child.
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        for handle in [input.fileHandleForWriting, output.fileHandleForReading] {
            let descriptor = handle.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    deinit {
        cancel()
        errors.fileHandleForReading.readabilityHandler = nil
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if process.isRunning { process.terminate() }
        lock.unlock()
        let child = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    private func check() throws {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped { throw CancellationError() }
    }

    private func wait(_ descriptor: Int32, for event: Int16, until deadline: ContinuousClock.Instant) throws {
        while true {
            try check()
            guard ContinuousClock.now < deadline else {
                cancel()
                throw FileBrowserError.timeout
            }
            var descriptor = pollfd(fd: descriptor, events: event, revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result > 0 { return }
            if result < 0, errno != EINTR { throw FileBrowserError.disconnected }
        }
    }

    func write(_ data: Data) throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(input.fileHandleForWriting.fileDescriptor, for: Int16(POLLOUT), until: deadline)
                let count = Darwin.write(input.fileHandleForWriting.fileDescriptor,
                                         bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count } else if count < 0, errno == EAGAIN || errno == EINTR { continue } else { throw failure() }
            }
        }
    }

    func read(_ size: Int) throws -> Data {
        let deadline = ContinuousClock.now + .seconds(timeout)
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < size {
                try wait(output.fileHandleForReading.fileDescriptor, for: Int16(POLLIN), until: deadline)
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor,
                                        bytes.baseAddress!.advanced(by: offset), size - offset)
                if count > 0 { offset += count } else if count < 0, errno == EAGAIN || errno == EINTR { continue } else { throw failure() }
            }
        }
        return data
    }

    private func failure() -> Error {
        lock.lock()
        let detail = (String(data: diagnostics, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
        return detail.isEmpty ? FileBrowserError.disconnected : FileBrowserError.server(detail)
    }
}

/// SFTP v3 framing. All lengths and server-controlled counts are bounded before use.
struct SFTPPacket {
    var data = Data()
    var offset = 0

    mutating func put(_ value: UInt32) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    mutating func put64(_ value: UInt64) {
        put(UInt32(value >> 32))
        put(UInt32(value & 0xffff_ffff))
    }

    mutating func putBytes(_ value: Data) {
        put(UInt32(value.count))
        data.append(value)
    }

    mutating func putString(_ value: String) { putBytes(Data(value.utf8)) }

    mutating func uint32() throws -> UInt32 {
        guard data.count - offset >= 4 else { throw FileBrowserError.protocolError }
        defer { offset += 4 }
        return data[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func uint64() throws -> UInt64 { try (UInt64(uint32()) << 32) | UInt64(uint32()) }

    mutating func bytes() throws -> Data {
        let size = Int(try uint32())
        guard size <= data.count - offset else { throw FileBrowserError.protocolError }
        defer { offset += size }
        return Data(data[offset..<offset + size])
    }

    mutating func string() throws -> String {
        guard let string = String(data: try bytes(), encoding: .utf8), !string.contains("\0") else {
            throw FileBrowserError.protocolError
        }
        return string
    }

    mutating func attributes(path: String, name: String) throws -> BrowserFile {
        let flags = try uint32()
        guard flags & ~UInt32(0x8000_000f) == 0 else { throw FileBrowserError.protocolError }
        let size = flags & 1 != 0 ? try uint64() : 0
        if flags & 2 != 0 { _ = try uint64() } // uid, gid
        let permissions = flags & 4 != 0 ? try uint32() : 0
        if flags & 8 != 0 { _ = try uint64() } // atime, mtime
        if flags & 0x8000_0000 != 0 {
            let count = try uint32()
            guard count <= 1024 else { throw FileBrowserError.protocolError }
            for _ in 0..<count { _ = try bytes(); _ = try bytes() }
        }
        let kind: BrowserFile.Kind
        switch permissions & 0xf000 {
        case 0x4000: kind = .directory
        case 0x8000: kind = .file
        case 0xa000: kind = .symbolicLink
        default: kind = .other
        }
        return BrowserFile(path: path, name: name, kind: kind, size: size)
    }
}
