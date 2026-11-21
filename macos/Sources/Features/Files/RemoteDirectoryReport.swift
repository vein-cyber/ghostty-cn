import Foundation
import GhosttyKit

/// Untrusted shell output is only a path hint for an already selected SFTP
/// connection. It can never select a host or become a local filesystem path.
struct RemoteDirectoryReport: Equatable, Sendable {
    let sequence: UInt64
    let foregroundGroup: UInt64
    let path: String

    init?(uri: String, sequence: UInt64, foregroundGroup: UInt64) {
        guard foregroundGroup > 0, uri.utf8.count <= 8192 else { return nil }
        let path: String
        if uri.hasPrefix("kitty-shell-cwd://") {
            let rest = uri.dropFirst("kitty-shell-cwd://".count)
            guard let slash = rest.firstIndex(of: "/"), slash != rest.startIndex,
                  !rest[..<slash].contains("@") else { return nil }
            path = String(rest[slash...])
        } else {
            guard let url = URLComponents(string: uri), url.scheme == "file", url.host?.isEmpty == false,
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
                  let decoded = url.percentEncodedPath.removingPercentEncoding else { return nil }
            path = decoded
        }
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        self.path = path
        self.sequence = sequence
        self.foregroundGroup = foregroundGroup
    }
}

/// The exact hook used by automatic setup, also available for troubleshooting.
/// Never sent to an existing terminal automatically; no second Swift copy.
enum RemoteDirectoryIntegration {
    static let command = String(cString: ghostty_ssh_directory_report())
}
