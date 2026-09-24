import unittest

import aircard_backend


class ThemeVersionDetectionTests(unittest.TestCase):
    """Which TelephonyUI layout a theme provides decides nothing on its own, but
    it used to override the phone's version, so it has to be read correctly."""

    def test_the_newest_layout_wins(self):
        detect = aircard_backend.detect_theme_version
        # What AirCard's own creator exports: both folders, 10 first.
        self.assertEqual(detect(["TelephonyUI-10/en-1---white.png", "TelephonyUI-9/en-1---white.png"]), "TelephonyUI-10")
        # Order in the zip must not matter.
        self.assertEqual(detect(["TelephonyUI-9/en-1---white.png", "TelephonyUI-10/en-1---white.png"]), "TelephonyUI-10")
        self.assertEqual(detect(["TelephonyUI-9/a.png", "TelephonyUI-8/a.png"]), "TelephonyUI-9")
        self.assertEqual(detect(["TelephonyUI-8/a.png"]), "TelephonyUI-8")
        self.assertEqual(detect(["en-1---white.png"]), "TelephonyUI-10")


if __name__ == "__main__":
    unittest.main()
