#!/usr/bin/env bash

set -euxo pipefail

old_pot=$(mktemp)
command_po=$(mktemp)
untranslated_po=$(mktemp)
fuzzy_po=$(mktemp)
trap 'rm -f "$old_pot" "$command_po" "$untranslated_po" "$fuzzy_po"' EXIT

cp po/com.mitchellh.ghostty.pot "$old_pot"
zig build update-translations

# Compare previous POT to current POT
msgcmp "$old_pot" po/com.mitchellh.ghostty.pot --use-untranslated

# Compare all other POs to current POT
for f in po/*.po; do
  # Ignore untranslated entries
  msgcmp --use-untranslated "$f" po/com.mitchellh.ghostty.pot;
done

# The macOS command palette and App Intents expose core command metadata through
# gettext. Simplified Chinese must therefore keep every command title and
# description translated and non-fuzzy.
msgfmt --check --check-format -o /dev/null po/zh_CN.po
msggrep -N src/input/command.zig po/zh_CN.po > "$command_po"
msgattrib --force-po --untranslated --no-obsolete --no-wrap "$command_po" \
  -o "$untranslated_po"
msgattrib --force-po --only-fuzzy --no-obsolete --no-wrap "$command_po" \
  -o "$fuzzy_po"

if grep -q '^msgid "[^"]' "$untranslated_po"; then
  echo "po/zh_CN.po has untranslated command metadata" >&2
  exit 1
fi

if grep -q '^msgid "[^"]' "$fuzzy_po"; then
  echo "po/zh_CN.po has fuzzy command metadata" >&2
  exit 1
fi
