#!/usr/bin/env python3

"""Validate the macOS String Catalogs and their Simplified Chinese values."""

import json
import re
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CATALOG_ROOT = ROOT / "macos" / "Sources"
UNCHANGED_VALUES = {"%@", "%lld%%", "-/%llu", "Ghostty", "GhosttyCN", "GitHub", "PID", "TTY"}
XIB_TABLES = (
    "App/macOS/MainMenu",
    "Features/About/About",
    "Features/ClipboardConfirmation/ClipboardConfirmation",
    "Features/QuickTerminal/QuickTerminal",
    "Features/Settings/ConfigurationErrors",
    "Features/Terminal/Window Styles/Terminal",
    "Features/Terminal/Window Styles/TerminalHiddenTitlebar",
    "Features/Terminal/Window Styles/TerminalTabsTitlebarTahoe",
    "Features/Terminal/Window Styles/TerminalTabsTitlebarVentura",
    "Features/Terminal/Window Styles/TerminalTransparentTitlebar",
)


def may_remain_unchanged(value: str) -> bool:
    """Return whether an identifier-like source value is language-neutral."""
    return value in UNCHANGED_VALUES or re.fullmatch(
        r"(?:[A-Z]|[0-9]|F(?:[1-9]|1[0-9]|20))",
        value,
    ) is not None


def validate_catalog(path: Path, output_root: Path) -> list[str]:
    errors: list[str] = []
    with path.open(encoding="utf-8") as source:
        catalog = json.load(source)

    if catalog.get("sourceLanguage") != "en":
        errors.append(f"{path}: sourceLanguage must be en")

    for key, entry in catalog.get("strings", {}).items():
        if entry.get("shouldTranslate") is False:
            continue

        unit = (
            entry.get("localizations", {})
            .get("zh-Hans", {})
            .get("stringUnit", {})
        )
        if unit.get("state") != "translated" or not unit.get("value"):
            errors.append(f"{path}: missing completed zh-Hans value for {key!r}")
            continue

        source_value = (
            entry.get("localizations", {})
            .get("en", {})
            .get("stringUnit", {})
            .get("value", key)
        )
        if re.search(r"[\u4e00-\u9fff]", source_value):
            errors.append(f"{path}: English source contains Han text for {key!r}")
        if unit["value"] == source_value and not may_remain_unchanged(source_value):
            errors.append(f"{path}: zh-Hans value still matches English for {key!r}")

    output = output_root / path.stem
    output.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [
            "xcrun",
            "xcstringstool",
            "compile",
            str(path),
            "--output-directory",
            str(output),
            "--language",
            "en",
            "--language",
            "zh-Hans",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        errors.append(f"{path}: xcstringstool failed:\n{result.stderr}")

    return errors


def validate_xib_layout() -> list[str]:
    """Ensure AppKit loads the localized table alongside each Base XIB."""
    errors: list[str] = []
    for relative_table in XIB_TABLES:
        table = CATALOG_ROOT / relative_table
        catalog = table.with_suffix(".xcstrings")
        base_xib = table.parent / "Base.lproj" / f"{table.name}.xib"
        root_xib = table.with_suffix(".xib")

        if not catalog.is_file():
            errors.append(f"{catalog}: missing XIB String Catalog")
        if not base_xib.is_file():
            errors.append(f"{base_xib}: XIB must be in Base.lproj")
        if root_xib.exists():
            errors.append(
                f"{root_xib}: unlocalized root XIB shadows the Base localization"
            )

    return errors


def main() -> int:
    catalogs = sorted(CATALOG_ROOT.rglob("*.xcstrings"))
    if not catalogs:
        print("No macOS String Catalogs found")
        return 1

    errors = validate_xib_layout()
    with tempfile.TemporaryDirectory(prefix="ghostty-localizations-") as temporary:
        output_root = Path(temporary)
        for catalog in catalogs:
            errors.extend(validate_catalog(catalog, output_root))

    if errors:
        print("\n".join(errors))
        return 1

    print(f"Validated {len(catalogs)} macOS String Catalogs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
