import Foundation

/// Requests and transfers are serialized on this actor. A cancel ends only this
/// browser's SSH process, not the terminal or a user's shared SSH control master.
actor SFTPClient {
    nonisolated let transport: SFTPTransport
    private var sequence: UInt32 = 0

    init(connection: SSHFileConnection) throws {
        transport = try SFTPTransport(arguments: connection.arguments())
    }

    init(transport: SFTPTransport) { self.transport = transport }

    nonisolated func cancel() { transport.cancel() }

    func start() throws -> String {
        var packet = SFTPPacket(data: Data([1]))
        packet.put(3)
        try send(packet)
        var response = try receive()
        guard response.data.first == 2 else { throw FileBrowserError.protocolError }
        response.offset = 1
        guard try response.uint32() == 3 else { throw FileBrowserError.protocolError }
        return try realpath(".")
    }

    func realpath(_ path: String) throws -> String {
        var response = try request(16) { $0.putString(path) }
        try expect(104, response: &response)
        guard try response.uint32() == 1 else { throw FileBrowserError.protocolError }
        return try response.string()
    }

    func list(_ path: String) throws -> [BrowserFile] {
        let directory = try handle(11) { $0.putString(path) }
        defer { try? close(directory) }
        var entries: [BrowserFile] = []
        while true {
            var response = try request(12) { $0.putBytes(directory) }
            if try isEOF(&response) { break }
            try expect(104, response: &response)
            let count = try response.uint32()
            guard count <= 100_000, entries.count + Int(count) <= 100_000 else {
                throw FileBrowserError.tooManyFiles
            }
            for _ in 0..<count {
                let name = try response.string()
                _ = try response.string() // longname is display-only and deliberately ignored
                let entry = try response.attributes(path: BrowserPath.join(path, name), name: name)
                if name == "." || name == ".." { continue }
                // The server must not supply paths outside the requested directory.
                guard !name.isEmpty, !name.contains("/") else { throw FileBrowserError.protocolError }
                entries.append(entry)
            }
            guard count > 0 else { throw FileBrowserError.protocolError }
        }
        return BrowserFile.sorted(entries)
    }

    func preview(_ path: String) throws -> Data {
        let file = try openRegular(path)
        defer { try? close(file) }
        var result = Data()
        while result.count < 262_144 {
            guard let data = try read(file, offset: UInt64(result.count), count: 32_768) else { break }
            result.append(data)
        }
        return result
    }

    func makeDirectory(_ path: String) throws {
        try status(request(14) { $0.putString(path); $0.put(0) })
    }

    func rename(_ path: String, to destination: String) throws {
        try status(request(18) { $0.putString(path); $0.putString(destination) })
    }

    /// Directories must be empty. Never recursively delete or follow symlinks.
    func remove(_ file: BrowserFile) throws {
        try status(request(file.isDirectory ? 15 : 13) { $0.putString(file.path) })
    }

    func download(_ path: String, to destination: URL, progress: @Sendable (UInt64) -> Void) throws {
        let file = try openRegular(path)
        defer { try? close(file) }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".ghosttycn-download-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }
        var offset: UInt64 = 0
        while let data = try read(file, offset: offset, count: 32_768) {
            try output.write(contentsOf: data)
            offset += UInt64(data.count)
            progress(offset)
        }
        try output.synchronize()
        try output.close()
        // moveItem refuses to replace an existing destination.
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    func upload(_ source: URL, to directory: String, progress: @Sendable (UInt64) -> Void) throws {
        try BrowserPath.validateName(source.lastPathComponent)
        let input = try regularFile(source.path)
        defer { try? input.close() }
        let temporary = BrowserPath.join(directory, ".ghosttycn-upload-" + UUID().uuidString)
        let destination = BrowserPath.join(directory, source.lastPathComponent)
        let file = try handle(3) {
            $0.putString(temporary)
            $0.put(2 | 8 | 32) // WRITE | CREAT | EXCL: never truncate an existing file
            $0.put(4) // permissions
            $0.put(0o600)
        }
        var completed = false
        defer {
            if !completed {
                try? close(file)
                try? status(request(13) { $0.putString(temporary) })
            }
        }
        var offset: UInt64 = 0
        while let data = try input.read(upToCount: 32_768), !data.isEmpty {
            try status(request(6) { $0.putBytes(file); $0.put64(offset); $0.putBytes(data) })
            offset += UInt64(data.count)
            progress(offset)
        }
        try close(file)
        // SFTP v3 RENAME must fail if destination exists. Do not use posix-rename.
        try rename(temporary, to: destination)
        completed = true
    }

    private func openRegular(_ path: String) throws -> Data {
        // OPEN + FSTAT checks the opened object too, protecting against stale listings.
        var info = try request(7) { $0.putString(path) } // LSTAT
        try expect(105, response: &info)
        guard try info.attributes(path: path, name: "").kind == .file else {
            throw FileBrowserError.notRegularFile
        }
        let file = try handle(3) { $0.putString(path); $0.put(1); $0.put(0) }
        do {
            var attributes = try request(8) { $0.putBytes(file) }
            try expect(105, response: &attributes)
            guard try attributes.attributes(path: path, name: "").kind == .file else {
                throw FileBrowserError.notRegularFile
            }
            return file
        } catch {
            try? close(file)
            throw error
        }
    }

    private func read(_ handle: Data, offset: UInt64, count: UInt32) throws -> Data? {
        var response = try request(5) { $0.putBytes(handle); $0.put64(offset); $0.put(count) }
        if try isEOF(&response) { return nil }
        try expect(103, response: &response)
        let data = try response.bytes()
        guard !data.isEmpty, data.count <= count else { throw FileBrowserError.protocolError }
        return data
    }

    private func close(_ handle: Data) throws { try status(request(4) { $0.putBytes(handle) }) }

    private func handle(_ type: UInt8, payload: (inout SFTPPacket) -> Void) throws -> Data {
        var response = try request(type, payload: payload)
        try expect(102, response: &response)
        return try response.bytes()
    }

    private func request(_ type: UInt8, payload: (inout SFTPPacket) -> Void) throws -> SFTPPacket {
        sequence &+= 1
        var packet = SFTPPacket(data: Data([type]))
        packet.put(sequence)
        payload(&packet)
        try send(packet)
        var response = try receive()
        response.offset = 1
        guard try response.uint32() == sequence else { throw FileBrowserError.protocolError }
        return response
    }

    private func send(_ packet: SFTPPacket) throws {
        var frame = SFTPPacket()
        frame.putBytes(packet.data)
        try transport.write(frame.data)
    }

    private func receive() throws -> SFTPPacket {
        var length = SFTPPacket(data: try transport.read(4))
        let size = Int(try length.uint32())
        guard size > 0, size <= 1_048_576 else {
            cancel()
            throw FileBrowserError.protocolError
        }
        return SFTPPacket(data: try transport.read(size))
    }

    private func status(_ response: SFTPPacket) throws {
        var response = response
        guard response.data.first == 101 else { throw FileBrowserError.protocolError }
        let code = try response.uint32()
        let message = try response.string()
        if code != 0 { throw FileBrowserError.server(message) }
    }

    private func expect(_ type: UInt8, response: inout SFTPPacket) throws {
        if response.data.first == 101 { try status(response) }
        guard response.data.first == type else { throw FileBrowserError.protocolError }
    }

    private func isEOF(_ response: inout SFTPPacket) throws -> Bool {
        guard response.data.first == 101 else { return false }
        var copy = response
        return try copy.uint32() == 1
    }
}
