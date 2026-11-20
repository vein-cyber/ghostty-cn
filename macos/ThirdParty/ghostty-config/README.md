# Ghostty Config integration

The bundled visual settings interface is built from
[`zerebos/ghostty-config`](https://github.com/zerebos/ghostty-config) at commit
`c25fe4c627c056fb25f3f33ac638aef621a2a6d7` (2026-11-20).

Ghostty Config is licensed under Apache-2.0. The unmodified upstream license is
stored in this directory and in the bundled web resources.

## Local changes

`native-integration.patch` adds a WebKit bridge and a native-only toolbar. It
loads the current Ghostty configuration and sends generated settings to the
macOS host for validated saving. Configuration includes and this fork's update
settings are excluded from visual management.

The native integration also sets an explicit SvelteKit build version (optionally
overridden by `GHOSTTYCN_CONFIG_VERSION`). Client scripts and prerendered HTML
must use the same bootstrap identifier; independently generated timestamp defaults
can leave the embedded page blank. The macOS WebKit integration test loads the
real bundled settings route and verifies the native ready message and Chinese UI.

`zh-Hans-localization.patch` extends the integration with simplified-Chinese
navigation, setting names, inline guidance, controls, built-in tools, and
dialogs. It also removes the GTK and Linux panels from GhosttyCN's navigation,
renames the macOS panel to `Advanced` (`高级`), and redirects the legacy platform
routes while keeping their configuration keys available for raw editing and
round-trip serialization. English remains the source and fallback language.

`help-localization.patch` provides stable, setting-ID-based simplified-Chinese
help for every setting exposed by the GhosttyCN navigation. It also localizes
the shared alert and confirmation controls and adds a coverage test so newly
visible settings cannot be added without corresponding Chinese help.

`vt-window-resize.patch` adds Ghostty's new `vt-window-resize-allowed` setting
to the visual editor, with a Chinese label and help text. It remains disabled
by default, matching Ghostty's core configuration.

`macos-copy-on-select.patch` follows the current macOS core default of
`primary`, updates the English and Chinese help for the private selection
pasteboard, and normalizes legacy `true`/`false` values in the editor. Regression
tests ensure an explicit disabled value survives saving other settings.

## Rebuilding the bundled resources

1. Check out the upstream commit shown above.
2. Apply `native-integration.patch`, `zh-Hans-localization.patch`,
   `help-localization.patch`, `vt-window-resize.patch`, and then
   `macos-copy-on-select.patch`, from the upstream repository root.
3. Run `bun install --frozen-lockfile`, followed by `bun run check`,
   `bun run lint`, `bun run test`, and `bun run build`.
4. Replace `macos/Resources/ghostty-config` with the generated `build`
   directory and copy the upstream `LICENSE` into it as `LICENSE.txt`.

The checked-in bundle is used so normal Ghostty builds do not require Bun,
Node.js, or network access.
