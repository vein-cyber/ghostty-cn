# Ghostty Config integration

The bundled visual settings interface is built from
[`zerebos/ghostty-config`](https://github.com/zerebos/ghostty-config) at commit
`0f51dceafa3e74cd7a24fecc471fd2354f6a0ea6` (2026-08-29).

Ghostty Config is licensed under Apache-2.0. The unmodified upstream license is
stored in this directory and in the bundled web resources.

## Local changes

`native-integration.patch` adds a WebKit bridge and a native-only toolbar. It
loads the current Ghostty configuration and sends generated settings to the
macOS host for validated saving. Configuration includes and this fork's update
settings are excluded from visual management.

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

## Rebuilding the bundled resources

1. Check out the upstream commit shown above.
2. Apply `native-integration.patch`, `zh-Hans-localization.patch`, and then
   `help-localization.patch`, from the upstream repository root.
3. Run `bun install --frozen-lockfile`, followed by `bun run check`,
   `bun run lint`, `bun run test`, and `bun run build`.
4. Replace `macos/Resources/ghostty-config` with the generated `build`
   directory and copy the upstream `LICENSE` into it as `LICENSE.txt`.

The checked-in bundle is used so normal Ghostty builds do not require Bun,
Node.js, or network access.
