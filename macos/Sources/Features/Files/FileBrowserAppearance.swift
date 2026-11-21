import AppKit
import SwiftUI

struct FileBrowserAppearance {
    let background: NSColor
    let colorScheme: ColorScheme

    static var windowGlassAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    init(color: Color, opacity: Double, usesWindowGlass: Bool, forceOpaque: Bool) {
        let color = NSColor(color)
        colorScheme = color.isLightColor ? .light : .dark
        // Glass is already painted once by TerminalViewContainer. Adding a
        // second tint here would make the sidebar darker/more opaque.
        if usesWindowGlass && !forceOpaque {
            background = .clear
        } else {
            let alpha = forceOpaque ? 1 : (opacity.isFinite ? min(max(opacity, 0), 1) : 1)
            background = color.withAlphaComponent(alpha)
        }
    }
}

/// Observe the same surface colors that drive the window chrome, including
/// theme reloads and OSC 11 changes. The list itself remains transparent.
struct FileBrowserSurfaceAppearance: ViewModifier {
    @ObservedObject var surface: Ghostty.SurfaceView
    var forceOpaque: Bool
    @State private var fullscreen = false

    func body(content: Content) -> some View {
        let config = surface.derivedConfig
        let appearance = FileBrowserAppearance(
            color: surface.backgroundColor ?? config.backgroundColor,
            opacity: config.backgroundOpacity,
            usesWindowGlass: config.backgroundBlur.isGlassStyle && FileBrowserAppearance.windowGlassAvailable,
            forceOpaque: forceOpaque || fullscreen || surface.window?.styleMask.contains(.fullScreen) == true)
        content
            .background(Color(nsColor: appearance.background))
            .environment(\.colorScheme, appearance.colorScheme)
            .onAppear { fullscreen = surface.window?.styleMask.contains(.fullScreen) == true }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) {
                if ($0.object as? NSWindow) === surface.window { fullscreen = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) {
                if ($0.object as? NSWindow) === surface.window { fullscreen = false }
            }
    }
}
