import Testing
@testable import Ghostty

struct GhosttyConfigFileEditorTests {
    @Test func mergePreservesCommentsAndUnknownSettings() {
        let original = """
        # My terminal settings
        font-size = 14
        future-setting = enabled

        # Keep this comment
        background = 111111
        """
        let generated = """
        font-size = 16
        background = 222222
        """

        let result = GhosttyConfigFileEditor.merge(
            original: original,
            generated: generated,
            managedKeys: ["font-size", "background"])

        #expect(result.contains("# My terminal settings"))
        #expect(result.contains("future-setting = enabled"))
        #expect(result.contains("# Keep this comment"))
        #expect(!result.contains("font-size = 14"))
        #expect(!result.contains("background = 111111"))
        #expect(result.contains("font-size = 16"))
        #expect(result.contains("background = 222222"))
    }

    @Test func mergeReplacesAnExistingManagedSection() {
        let original = """
        keep = true

        \(GhosttyConfigFileEditor.startMarker)
        font-size = 12
        \(GhosttyConfigFileEditor.endMarker)
        """

        let result = GhosttyConfigFileEditor.merge(
            original: original,
            generated: "font-size = 18",
            managedKeys: ["font-size"])

        #expect(result.contains("keep = true"))
        #expect(!result.contains("font-size = 12"))
        #expect(result.contains("font-size = 18"))
        #expect(result.components(separatedBy: GhosttyConfigFileEditor.startMarker).count == 2)
    }

    @Test func validationRejectsUnknownSettings() {
        #expect(throws: GhosttyConfigFileEditor.EditorError.self) {
            try GhosttyConfigFileEditor.validate(
                generated: "config-file = surprise",
                managedKeys: ["font-size"])
        }
    }

    @Test func nativeBridgeProtectsConfigurationIncludes() {
        let requestedKeys: Set<String> = [
            "font-size",
            "config-file",
            "config-default-files",
            "auto-update",
            "auto-update-channel",
        ]
        let managedKeys = requestedKeys.subtracting(GhosttyConfigFileEditor.protectedKeys)

        #expect(managedKeys == ["font-size"])
    }

    @Test func validationAllowsEqualsInsideValues() throws {
        let result = try GhosttyConfigFileEditor.validate(
            generated: "keybind = super+t=new_tab",
            managedKeys: ["keybind"])

        #expect(result == "keybind = super+t=new_tab")
    }
}
