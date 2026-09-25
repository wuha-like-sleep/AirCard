"""The first-launch guide is the first thing a new user reads, and the only
thing standing between an unnotarised download and a working app."""

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


class FirstLaunchGuideTests(unittest.TestCase):
    def test_the_self_built_guide_leads_with_what_works_on_current_macos(self):
        text = (REPO / "dmg_assets" / "README.txt").read_text(encoding="utf-8")
        self.assertIn("Open Anyway", text)
        self.assertIn("Privacy & Security", text)
        # Control-click > Open stopped working for unnotarised apps in macOS 15.
        self.assertLess(text.index("Open Anyway"), text.index("Control-click"))

    def test_no_guide_asks_for_sudo(self):
        for path in [REPO / "README.md", *sorted((REPO / "dmg_assets").glob("README*.txt"))]:
            self.assertNotIn("sudo xattr", path.read_text(encoding="utf-8"), path.name)

    def test_the_signed_guide_does_not_send_people_through_workarounds(self):
        text = (REPO / "dmg_assets" / "README-signed.txt").read_text(encoding="utf-8")
        self.assertNotIn("xattr", text)
        self.assertNotIn("Control-click", text)

    def test_every_guide_says_to_replace_rather_than_keep_both(self):
        """Keep Both is how a Mac ends up with AirCard and AirCard 2."""
        for path in [REPO / "README.md", *sorted((REPO / "dmg_assets").glob("README*.txt"))]:
            text = path.read_text(encoding="utf-8")
            self.assertIn("Replace", text, path.name)
            self.assertIn("Keep Both", text, path.name)

    def test_build_picks_the_guide_by_signing(self):
        script = (REPO / "build.sh").read_text(encoding="utf-8")
        self.assertRegex(script, r'if \[ "\$CODESIGN_IDENTITY" = "-" \]; then\s+DMG_README="dmg_assets/README.txt"\s+else\s+DMG_README="dmg_assets/README-signed.txt"')
        # Both ways of making the DMG must carry it.
        self.assertIn('--add-file "README.txt" "$DMG_README"', script)
        self.assertIn('cp "$DMG_README" "$DMG_STAGING/README.txt"', script)

    def test_button_names_in_the_guide_are_the_apps_own(self):
        strings = (REPO / "locales" / "en.lproj" / "Localizable.strings").read_text(encoding="utf-8")
        english = set(re.findall(r'= "([^"]*)";', strings))
        for path in sorted((REPO / "dmg_assets").glob("README*.txt")):
            for name in re.findall(r'"([A-Z][^"]{2,40})"', path.read_text(encoding="utf-8")):
                # Names that belong to macOS and Finder, not to AirCard.
                if name in {"AirCard", "Applications", "Open Anyway", "Replace", "Keep Both"}:
                    continue
                self.assertIn(name, english, f"{path.name} names a button the app does not have: {name}")


if __name__ == "__main__":
    unittest.main()
