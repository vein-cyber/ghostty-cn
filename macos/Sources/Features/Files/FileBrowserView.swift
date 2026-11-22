import SwiftUI
import UniformTypeIdentifiers

/// A native, opt-in companion to the terminal. Navigating here never sends shell input.
struct FileBrowserView: View {
    @ObservedObject var model: FileBrowserModel
    private var closeWithoutTitlebar: (() -> Void)?
    @FocusState private var pathFocused: Bool
    @State private var namedFile: BrowserFile?
    @State private var naming = false
    @State private var name = ""
    @State private var removing: BrowserFile?
    @State private var showsRemoteIntegration = false
    @State private var showsManualFallback = false
    @AppStorage(FileBrowserPreferences.positionKey, store: .ghostty) private var position = "left"
    @AppStorage(FileBrowserPreferences.defaultVisibleKey, store: .ghostty) private var defaultVisible = false
    @AppStorage(FileBrowserPreferences.showsHiddenKey) private var showsHidden = false

    init(model: FileBrowserModel, closeWithoutTitlebar: (() -> Void)? = nil, preferences: UserDefaults = .ghostty) {
        self.model = model
        self.closeWithoutTitlebar = closeWithoutTitlebar
        _showsHidden = AppStorage(wrappedValue: false, FileBrowserPreferences.showsHiddenKey, store: preferences)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            locationBar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter files", text: $model.filter).textFieldStyle(.plain)
            }
            .font(.system(size: 12, weight: .regular))
            .padding(.horizontal, 7).frame(height: 24)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
            .padding(.horizontal, 10).padding(.bottom, 6)
            List(model.visibleFiles, selection: $model.selectedFileID) { file in
                HStack(spacing: 6) {
                    Image(systemName: icon(file)).symbolRenderingMode(.monochrome)
                        .font(.system(size: 13, weight: .regular)).frame(width: 16)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    Text(verbatim: file.name).lineLimit(1).truncationMode(.middle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color(nsColor: .labelColor))
                    Spacer(minLength: 0)
                    if let size = file.displayedSize {
                        Text(verbatim: size)
                            .font(.system(size: 11, weight: .regular)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
                .background(FileBrowserRowSelectionStyle())
                .accessibilityElement(children: .combine)
                .accessibilityAction { model.activateFiles([file.id]) }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .labelColor).opacity(model.selectedFileID == file.id ? FileBrowserSelection.opacity : 0)))
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .tag(file.id)
            }
            .contextMenu(forSelectionType: BrowserFile.ID.self) { ids in
                if ids.isEmpty {
                    Button("New folder") { namedFile = nil; name = ""; naming = true }
                        .disabled(model.busy || !model.canBrowse)
                    if model.remoteHost != nil {
                        Button("Upload file") { upload() }.disabled(model.busy || !model.canBrowse)
                    }
                } else if ids.count == 1, let file = model.visibleFiles.first(where: { ids.contains($0.id) }) {
                    contextMenu(file)
                }
            } primaryAction: { model.activateFiles($0) }
            .listStyle(.plain).scrollContentBackground(.hidden).disabled(model.busy)
            .environment(\.defaultMinListRowHeight, 24)
            .overlay {
                if model.visibleFiles.isEmpty && !model.busy {
                    Text("No files to display").foregroundStyle(.secondary).padding(8).allowsHitTesting(false)
                }
            }
            if model.busy || model.remoteFolderStatus == .awaitingReport || model.hasUnsupportedSSHConnection {
                Divider()
                footer
            }
        }
        .onAppear { model.showsHidden = showsHidden; model.refresh() }
        .onChange(of: showsHidden) { model.showsHidden = $0 }
        .onChange(of: model.isEditingPath) { pathFocused = $0 }
        .onChange(of: pathFocused) { if !$0, model.isEditingPath { model.cancelEditingPath() } }
        .sheet(isPresented: $naming) { nameForm }
        .sheet(isPresented: $showsRemoteIntegration) { remoteIntegrationForm }
        .sheet(item: $model.preview) { preview in previewSheet(preview) }
        .alert("File operation failed", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } })
        ) {
            Button("OK") { model.error = nil }
        } message: { Text(verbatim: model.error ?? "") }
        .alert("Remove this item?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button(LocalizedStringKey(model.remoteHost == nil ? "Move to Trash" : "Delete item"), role: .destructive) {
                if let file = removing { model.remove(file) }
                removing = nil
            }
        } message: {
            VStack {
                Text(verbatim: removing?.name ?? "")
                Text(LocalizedStringKey(model.remoteHost == nil ? "The item will be moved to the Trash." :
                     "Remote deletion is permanent. Folders must be empty."))
            }
        }
    }

    private var locationBar: some View {
        HStack(spacing: 6) {
            if model.isEditingPath {
                TextField("Folder path", text: $model.pathDraft)
                    .accessibilityIdentifier("fileBrowserPathEditor")
                    .textFieldStyle(.plain).focused($pathFocused)
                    .onSubmit { model.submitPath() }
                    .onExitCommand { model.cancelEditingPath() }
                    .padding(.horizontal, 5)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel("Folder path")
            } else {
                Button { model.beginEditingPath() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.location.isHome ? "house" : "folder")
                        Text(verbatim: model.location.displayPath).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(model.path)
                .accessibilityLabel("Folder path").accessibilityValue(model.path)
                .accessibilityIdentifier("fileBrowserPathButton")
                .accessibilityHint("Click to edit the folder path")
            }
            Button { model.navigate(BrowserPath.parent(model.path)) } label: {
                Image(systemName: "arrow.up").frame(width: 20, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Parent folder").accessibilityLabel("Parent folder").disabled(model.path == "/")
        }
        .font(.system(size: 12, weight: .regular)).frame(height: 24)
        .disabled(model.busy || !model.canBrowse)
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(verbatim: model.location.title).font(.system(size: 13, weight: .medium))
                .lineLimit(1).truncationMode(.middle).help(model.path).layoutPriority(1)
            if let host = model.remoteHost {
                Label { Text(verbatim: host) } icon: { Image(systemName: "network") }
                    .font(.system(size: 11, weight: .regular)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(host)
                    .frame(minWidth: 40, maxWidth: 88, alignment: .leading).layoutPriority(2)
            }
            Spacer(minLength: 0)
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 20, height: 24).contentShape(Rectangle())
            }
                .help("Refresh files").accessibilityLabel("Refresh files").disabled(!model.canRefresh)
            Menu {
                Section("Sidebar position") {
                    Button { position = "left" } label: {
                        if position == "left" { Label("Left side", systemImage: "checkmark") } else { Text("Left side") }
                    }
                    Button { position = "right" } label: {
                        if position == "right" { Label("Right side", systemImage: "checkmark") } else { Text("Right side") }
                    }
                }
                Toggle("Show file browser in new windows", isOn: $defaultVisible)
                Divider()
                Toggle("Show hidden files", isOn: $showsHidden)
            } label: { Image(systemName: "ellipsis").frame(width: 20, height: 24).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.busy)
                .accessibilityLabel("File browser options")
            // Hidden-titlebar and quick terminals have no window action to close the pane.
            if let closeWithoutTitlebar {
                Button(action: closeWithoutTitlebar) { Image(systemName: position == "right" ? "sidebar.right" : "sidebar.left") }
                    .help("Hide file browser")
            }
        }.buttonStyle(.plain).font(.system(size: 13, weight: .regular))
            .frame(height: 30).padding(.horizontal, 10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if model.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    if let transferred = model.transferred {
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(clamping: transferred), countStyle: .file))
                    } else { Text("Loading files…") }
                    Spacer()
                    if model.remoteHost != nil {
                        Button("Cancel") { model.cancelOperation() }
                    }
                }
            }
            if model.remoteHost != nil {
                if model.remoteFolderStatus == .awaitingReport {
                    HStack {
                        Text("Remote folder not reported yet").foregroundStyle(.secondary)
                        Button("Learn why") { showsRemoteIntegration = true }.buttonStyle(.link)
                    }.font(.caption)
                }
            } else if model.hasUnsupportedSSHConnection {
                Text("The file browser cannot follow this terminal's SSH connection. It will resume when the terminal connection changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(8)
    }

    @ViewBuilder private func contextMenu(_ file: BrowserFile) -> some View {
        Button(LocalizedStringKey(file.isDirectory ? "Open folder" : file.kind == .symbolicLink ? "Open linked item" : "Preview file")) {
            model.showPreview(file)
        }
        Button("Copy path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path, forType: .string)
        }
        if model.remoteHost == nil {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }
        } else if file.kind == .file || file.kind == .symbolicLink {
            Button("Download file") { download(file) }
        }
        Divider()
        Button("Rename") { namedFile = file; name = file.name; naming = true }
        Button(LocalizedStringKey(model.remoteHost == nil ? "Move to Trash" : "Delete item")) { removing = file }
    }

    private var remoteIntegrationForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remote folder troubleshooting").font(.headline)
            Text("Folder following waits for the remote shell to report its current folder. File browsing and transfers remain available without these reports.")
                .fixedSize(horizontal: false, vertical: true)
            Text("After updating, open a new GhosttyCN terminal and reconnect with ssh. Automatic setup supports Bash 4+ and Zsh; custom SSH commands, disabled shell integration, other shells and nested connections may need manual browsing.")
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Manual fallback for an existing session", isExpanded: $showsManualFallback) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Only for Bash or Zsh: review and run this command in the intended remote shell. It enables reports for this session without changing startup files. GhosttyCN never types it into an existing session.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: RemoteDirectoryIntegration.command)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }.frame(height: 180)
                    Button("Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(RemoteDirectoryIntegration.command, forType: .string)
                    }
                }.padding(.top, 8)
            }
            HStack {
                Spacer()
                Button("Close") { showsRemoteIntegration = false }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 560)
            .onDisappear { showsManualFallback = false }
    }

    private var nameForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LocalizedStringKey(namedFile == nil ? "New folder" : "Rename")).font(.headline)
            TextField("Name", text: $name)
            HStack {
                Spacer()
                Button("Cancel") { naming = false }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    naming = false
                    if let file = namedFile { model.rename(file, name: name) } else { model.makeDirectory(name) }
                }.keyboardShortcut(.defaultAction).disabled(name.isEmpty)
            }
        }.padding(20).frame(width: 340)
    }

    private func previewSheet(_ preview: FileBrowserModel.Preview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: preview.name).font(.headline).lineLimit(1)
                Spacer()
                Button("Close") { model.preview = nil }.keyboardShortcut(.cancelAction)
            }
            if let text = preview.text {
                ScrollView([.vertical, .horizontal]) {
                    Text(verbatim: text).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if preview.truncated { Text("Preview limited to the first 256 KiB.").foregroundStyle(.secondary) }
            } else { Text("This file is not UTF-8 text and cannot be previewed.") }
            Text("Read-only preview").font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(minWidth: 500, idealWidth: 700, minHeight: 320, idealHeight: 500)
    }

    private func icon(_ file: BrowserFile) -> String {
        switch file.kind {
        case .directory: return "folder"
        case .symbolicLink: return "link"
        case .file: return "doc"
        case .other: return "questionmark.square"
        }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { result in
            if result == .OK, let url = panel.url { model.upload(url) }
        }
    }

    private func download(_ file: BrowserFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        panel.begin { result in
            if result == .OK, let url = panel.url { model.download(file, to: url) }
        }
    }
}
