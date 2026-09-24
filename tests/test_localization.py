"""Checks every shipped translation against the English source.

A .strings file that is missing keys still loads, and the app silently falls
back to English for whatever is absent, so nothing fails loudly on its own.
A translation that drops a %@ is worse: it crashes at the moment the user hits
that screen. Both are caught here instead.
"""

import re
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOCALES = REPO / "locales"
BASE = "en"

# "key" = "value";  the value may contain escaped quotes
ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')
# %@ %d %1$@ %2$d %.1f %% ...
SPECIFIER = re.compile(r'%(?:(\d+)\$)?[-+ 0#]*[\d.]*([@dioux%fFeEgGsS])')


def parse(path):
    out = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("//") or line.startswith("/*") or line.startswith("*"):
            continue
        m = ENTRY.match(line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def specifiers(text):
    """Multiset of specifier types, ignoring position so word order can change."""
    return sorted(t for _, t in SPECIFIER.findall(text) if t != "%")


def strings_files():
    return sorted(LOCALES.glob("*.lproj/Localizable.strings"))


class LocalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base_path = LOCALES / f"{BASE}.lproj" / "Localizable.strings"
        assert cls.base_path.is_file(), f"missing base strings file: {cls.base_path}"
        cls.base = parse(cls.base_path)

    def test_every_key_the_app_uses_is_in_the_strings_file(self):
        """A key added in code but never put in en.lproj shows English in every
        language, and the parity checks above cannot see it: they only compare
        the strings files with each other."""
        src = (REPO / "AirCardApp.swift").read_text(encoding="utf-8")
        used = set(re.findall(r'\bLM?\(\s*"((?:[^"\\]|\\.)*)"\s*,', src))
        missing = sorted(used - set(self.base))
        self.assertEqual(missing, [], f"used in AirCardApp.swift but not in en.lproj: {missing}")

    def test_no_key_in_the_strings_file_is_dead(self):
        src = (REPO / "AirCardApp.swift").read_text(encoding="utf-8")
        used = set(re.findall(r'\bLM?\(\s*"((?:[^"\\]|\\.)*)"\s*,', src))
        dead = sorted(set(self.base) - used)
        self.assertEqual(dead, [], f"in en.lproj but no longer used by the app: {dead}")

    def test_base_is_not_empty(self):
        self.assertGreater(len(self.base), 50, "English source looks truncated")

    def test_every_language_has_every_key(self):
        for path in strings_files():
            lang = path.parent.name
            if lang == f"{BASE}.lproj":
                continue
            entries = parse(path)
            missing = sorted(set(self.base) - set(entries))
            orphan = sorted(set(entries) - set(self.base))
            self.assertEqual(missing, [], f"{lang} is missing keys (would fall back to English): {missing[:8]}")
            self.assertEqual(orphan, [], f"{lang} has keys the app never asks for: {orphan[:8]}")

    def test_format_specifiers_survive_translation(self):
        for path in strings_files():
            lang = path.parent.name
            entries = parse(path)
            for key, english in self.base.items():
                want = specifiers(english)
                if not want:
                    continue
                if key not in entries:
                    continue  # reported by the key-parity test
                got = specifiers(entries[key])
                self.assertEqual(
                    got, want,
                    f"{lang} / {key}: format specifiers changed "
                    f"({want} -> {got}). This crashes at runtime.",
                )

    # Strings that may legitimately read the same as English: product and brand
    # names, format-only strings, and words spelled the same in some languages.
    SAME_AS_ENGLISH_OK = {
        "ui.aircard", "ui.twitter_x", "ui.ok", "ui.zoom", "tab.wallet_cards",
        "ui.device_subtitle", "ui.device_with_link",
        "ui.percent", "ui.telephonyui_8_ios_14_15", "ui.telephonyui_9_ios_16_17",
        "ui.telephonyui_10_ios_18", "ui.original_badge",
    }

    def test_nothing_is_left_in_english(self):
        """Every string differs from the English unless it is named above.

        This used to be a threshold, a quarter of the long strings, and it let the
        error dialog's own title ship in English in nine languages. A named list
        is the only version of this check that cannot be quietly outgrown.
        """
        for path in strings_files():
            lang = path.parent.name
            if lang == f"{BASE}.lproj":
                continue
            entries = parse(path)
            left = sorted(
                k for k, v in entries.items()
                if v == self.base.get(k) and k not in self.SAME_AS_ENGLISH_OK
            )
            self.assertEqual(left, [], f"{lang} still has English for: {left}")

    def test_escapes_are_not_doubled(self):
        """A \\n in a .strings file renders as a backslash and an n, not a line.

        Round-tripping a file through a script that escapes on the way back out
        doubles every backslash, and it compounds on each pass. Nothing else here
        notices: the keys all match, the format specifiers all survive.
        """
        for path in strings_files():
            lang = path.parent.name
            for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if line.lstrip().startswith(("/*", "//", "*")):
                    continue
                self.assertNotIn(
                    "\\\\", line,
                    f"{lang} line {n} has a doubled backslash, which shows up on "
                    f"screen as literal text: {line[:90]}",
                )

    def test_line_breaks_survive_translation(self):
        for path in strings_files():
            lang = path.parent.name
            entries = parse(path)
            for key, english in self.base.items():
                if key not in entries:
                    continue
                want = english.count("\\n")
                got = entries[key].count("\\n")
                self.assertEqual(
                    got, want,
                    f"{lang} / {key}: {want} line break(s) in English, {got} here",
                )

    def test_source_wording_has_no_em_dashes(self):
        """Em dashes are the quickest tell that text was machine-written.

        Only the English source is checked. Russian and Ukrainian use the dash as
        ordinary punctuation, so banning it in translations would be wrong.
        """
        dashed = sorted(k for k, v in self.base.items() if "\u2014" in v)
        self.assertEqual(dashed, [], f"English strings with an em dash: {dashed}")

    def test_files_are_well_formed(self):
        for path in strings_files():
            result = subprocess.run(["plutil", "-lint", str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, f"{path.parent.name} is malformed: {result.stdout}{result.stderr}")

    def test_declared_languages_all_exist(self):
        """build.sh refuses to ship without these, so keep the two lists in step."""
        build = (REPO / "build.sh").read_text(encoding="utf-8")
        m = re.search(r"^LANGS=\(([^)]*)\)", build, re.M)
        self.assertIsNotNone(m, "LANGS array not found in build.sh")
        declared = m.group(1).split()
        for lang in declared:
            self.assertTrue(
                (LOCALES / f"{lang}.lproj" / "Localizable.strings").is_file(),
                f"build.sh declares {lang} but locales/{lang}.lproj/Localizable.strings is missing",
            )


if __name__ == "__main__":
    unittest.main()
