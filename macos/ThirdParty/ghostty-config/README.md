# Ghostty Config integration

The bundled visual settings interface is built from
[`zerebos/ghostty-config`](https://github.com/zerebos/ghostty-config) at commit
`d9cd47256b024380baffba06b72f384534d882a6` (2026-08-02).

Ghostty Config is licensed under Apache-2.0. The unmodified upstream license is
stored in this directory and in the bundled web resources.

## Local changes

`native-integration.patch` adds a WebKit bridge, a native-only toolbar, and
simplified-Chinese labels for the settings navigation, search, and setting
names. It loads the current Ghostty configuration and sends generated settings
to the macOS host for validated saving. Configuration includes and this fork's
disabled update settings are excluded from visual management.

## Rebuilding the bundled resources

1. Check out the upstream commit shown above.
2. Apply `native-integration.patch` from the upstream repository root.
3. Run `bun install --frozen-lockfile`, followed by `bun run check`,
   `bun run lint`, `bun run test`, and `bun run build`.
4. Replace `macos/Resources/ghostty-config` with the generated `build`
   directory and copy the upstream `LICENSE` into it as `LICENSE.txt`.

The checked-in bundle is used so normal Ghostty builds do not require Bun,
Node.js, or network access.
