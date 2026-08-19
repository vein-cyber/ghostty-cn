import SwiftUI

struct AboutMetadata {
    static let repositoryURL = URL(string: "https://github.com/vein-cyber/ghostty-cn")!

    let productVersion: String
    let upstreamVersion: String
    let build: String?
    let commit: String?

    init(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        upstreamVersion: String = Ghostty.info.version
    ) {
        self.productVersion = Self.nonEmptyString(infoDictionary["GhosttyCNVersion"])
            ?? Self.nonEmptyString(infoDictionary["CFBundleShortVersionString"])
            ?? "0.4.0-dev"
        self.upstreamVersion = upstreamVersion
        self.build = Self.nonEmptyString(infoDictionary["CFBundleVersion"])
        self.commit = Self.nonEmptyString(infoDictionary["GhosttyCommit"])
    }

    var versionURL: URL? {
        guard productVersion.range(
            of: #"^\d+\.\d+\.\d+-cn\.\d+$"#,
            options: .regularExpression
        ) != nil else { return nil }

        return URL(string: "\(Self.repositoryURL.absoluteString)/releases/tag/v\(productVersion)")
    }

    var commitURL: URL? {
        guard let commit else { return nil }
        return URL(string: "\(Self.repositoryURL.absoluteString)/commit/\(commit)")
    }

    var shortCommit: String? {
        commit.map { String($0.prefix(9)) }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct AboutView: View {
    @Environment(\.openURL) var openURL

    private let docsURL = URL(string: "https://ghostty.org/docs")
    private let metadata = AboutMetadata()

    private var copyright: String? { Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String }

    // This creates a background style similar to the Apple "About My Mac" Window
    private struct VisualEffectBackground: NSViewRepresentable {
        let material: NSVisualEffectView.Material
        let blendingMode: NSVisualEffectView.BlendingMode
        let isEmphasized: Bool

        init(material: NSVisualEffectView.Material,
             blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
             isEmphasized: Bool = false) {
            self.material = material
            self.blendingMode = blendingMode
            self.isEmphasized = isEmphasized
        }

        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
            nsView.material = material
            nsView.blendingMode = blendingMode
            nsView.isEmphasized = isEmphasized
        }

        func makeNSView(context: Context) -> NSVisualEffectView {
            let visualEffect = NSVisualEffectView()
            visualEffect.autoresizingMask = [.width, .height]
            return visualEffect
        }
    }

    var body: some View {
        VStack(alignment: .center) {
            CyclingIconView()

            VStack(alignment: .center, spacing: 32) {
                VStack(alignment: .center, spacing: 8) {
                    Text("GhosttyCN")
                        .bold()
                        .font(.title)
                    Text("Fast, native, feature-rich terminal \nemulator pushing modern features.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .tint(.secondary)
                        .opacity(0.8)
                }
                .textSelection(.enabled)

                VStack(spacing: 2) {
                    PropertyRow(
                        label: "Version",
                        text: metadata.productVersion,
                        url: metadata.versionURL
                    )
                    PropertyRow(label: "Based on Ghostty", text: metadata.upstreamVersion)
                    if let build = metadata.build {
                        PropertyRow(label: "Build", text: build)
                    }
                    if let commit = metadata.shortCommit {
                        PropertyRow(label: "Commit", text: commit, url: metadata.commitURL)
                    }
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    if let url = docsURL {
                        Button("Docs") {
                            openURL(url)
                        }
                    }
                    Button("GitHub") {
                        openURL(AboutMetadata.repositoryURL)
                    }
                }

                if let copy = self.copyright {
                    Text(copy)
                        .font(.caption)
                        .textSelection(.enabled)
                        .tint(.secondary)
                        .opacity(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .padding(32)
        .frame(minWidth: 256)
        .background(VisualEffectBackground(material: .underWindowBackground).ignoresSafeArea())
    }

    private struct PropertyRow: View {
        private let label: LocalizedStringKey
        private let text: String
        private let url: URL?

        init(label: LocalizedStringKey, text: String, url: URL? = nil) {
            self.label = label
            self.text = text
            self.url = url
        }

        @ViewBuilder private var textView: some View {
            Text(text)
                .frame(width: 125, alignment: .leading)
                .padding(.leading, 2)
                .tint(.secondary)
                .opacity(0.8)
                .monospaced()
        }

        var body: some View {
            HStack(spacing: 4) {
                Text(label)
                    .frame(width: 126, alignment: .trailing)
                    .padding(.trailing, 2)
                if let url {
                    Link(destination: url) {
                        textView
                    }
                } else {
                    textView
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
        }
    }
}

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView()
    }
}
