import SwiftUI

/// A point-sized sidebar rather than NSSplitView's transient proportional size.
/// Only a completed user drag changes the persisted preference. Stable pane IDs
/// keep the terminal and SFTP session alive when moving/hiding the browser.
struct FileBrowserSplitLayout<Sidebar: View, Terminal: View>: View {
    var isVisible: Bool
    var position: String
    @Binding var preferredWidth: Double
    let sidebar: Sidebar
    let terminal: Terminal
    @State private var dragStart: Double?
    @State private var dragWidth: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = isVisible ? FileBrowserPreferences.effectiveWidth(
                dragWidth ?? preferredWidth, available: geometry.size.width) : 0
            let divider = isVisible ? 1.0 : 0
            let terminalWidth = max(0, geometry.size.width - width - divider)
            ZStack(alignment: .topLeading) {
                ForEach(isVisible ? ["terminal", "files"] : ["terminal"], id: \.self) { pane in
                    if pane == "files" {
                        sidebar
                            .frame(width: width, height: geometry.size.height)
                            .clipped()
                            .offset(x: position == "right" ? terminalWidth + divider : 0)
                    } else {
                        terminal
                            .frame(width: terminalWidth, height: geometry.size.height)
                            .offset(x: isVisible && position != "right" ? width + divider : 0)
                    }
                }
                if isVisible {
                    resizeHandle(available: geometry.size.width, width: width)
                        .position(x: position == "right" ? terminalWidth + 0.5 : width + 0.5,
                                  y: geometry.size.height / 2)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: "fileBrowserSplit")
        }
        .onChange(of: isVisible) { _ in resetDrag() }
        .onChange(of: position) { _ in resetDrag() }
    }

    private func resizeHandle(available: Double, width: Double) -> some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
        }
        .frame(width: 9)
        .backport.pointerStyle(.resizeLeftRight)
        .onHover { hovered in
            if #available(macOS 15, *) { return }
            if hovered { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("fileBrowserSplit"))
            .onChanged { gesture in
                if dragStart == nil { dragStart = width }
                let delta = gesture.translation.width * (position == "right" ? -1 : 1)
                dragWidth = FileBrowserPreferences.effectiveWidth((dragStart ?? width) + delta, available: available)
            }
            .onEnded { _ in
                if let dragWidth { preferredWidth = FileBrowserPreferences.normalizedWidth(dragWidth) }
                resetDrag()
            })
        .onTapGesture(count: 2) { preferredWidth = FileBrowserPreferences.defaultWidth; resetDrag() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("File browser width")
        .accessibilityValue(Text(verbatim: String(Int(width))))
        .accessibilityHint("Drag to resize the file browser. Double-click to reset its width.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: preferredWidth = FileBrowserPreferences.normalizedWidth(width + 10)
            case .decrement: preferredWidth = FileBrowserPreferences.normalizedWidth(width - 10)
            @unknown default: break
            }
        }
    }

    private func resetDrag() { dragStart = nil; dragWidth = nil }
}
