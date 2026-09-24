import tempfile
import unittest
import zipfile
from pathlib import Path

from aircard_backend import parse_passthm_archive


def _theme(files: dict) -> str:
    tmp = tempfile.NamedTemporaryFile(suffix=".passthm", delete=False)
    tmp.close()
    with zipfile.ZipFile(tmp.name, "w") as z:
        for name, data in files.items():
            z.writestr(name, data)
    return tmp.name


def _written(items, leaf):
    """What ends up in the named file, across target folders (must agree)."""
    got = {data for _, name, data in items if name == leaf}
    return got.pop() if len(got) == 1 else got


class RegularAndBoldTests(unittest.TestCase):
    def test_each_weight_keeps_its_own_art_whichever_order_the_zip_is_in(self):
        for order in (("regular", "bold"), ("bold", "regular")):
            files = {
                "regular": ("TelephonyUI-10/en-1---white.png", b"REGULAR-1"),
                "bold": ("TelephonyUI-10/en-1---white-bold.png", b"BOLD-1"),
            }
            theme = _theme(dict(files[k] for k in order))
            items = parse_passthm_archive(theme, "TelephonyUI-10", target_lang="en", target_bold="both")
            self.assertEqual(_written(items, "en-1---white.png"), b"REGULAR-1", order)
            self.assertEqual(_written(items, "en-1---white-bold.png"), b"BOLD-1", order)

    def test_a_theme_with_one_weight_still_fills_both(self):
        theme = _theme({"TelephonyUI-10/en-2---white.png": b"ONLY-2"})
        items = parse_passthm_archive(theme, "TelephonyUI-10", target_lang="en", target_bold="both")
        self.assertEqual(_written(items, "en-2---white.png"), b"ONLY-2")
        self.assertEqual(_written(items, "en-2---white-bold.png"), b"ONLY-2")


class StrayPictureTests(unittest.TestCase):
    def test_a_wallpaper_or_cover_does_not_become_a_key(self):
        theme = _theme({
            "TelephonyUI-10/en-2---white.png": b"KEY-2",
            "TelephonyUI-10/en-3---white.png": b"KEY-3",
            "Wallpaper@3x.png": b"WALLPAPER",
            "cover_2.jpg": b"COVER",
            "preview@2x.png": b"PREVIEW",
        })
        items = parse_passthm_archive(theme, "TelephonyUI-10", target_lang="en", target_bold="regular")
        self.assertEqual(_written(items, "en-2---white.png"), b"KEY-2")
        self.assertEqual(_written(items, "en-3---white.png"), b"KEY-3")
        for _, _, data in items:
            self.assertNotIn(data, (b"WALLPAPER", b"COVER", b"PREVIEW"))

    def test_a_loosely_named_key_is_used_when_nothing_better_exists(self):
        theme = _theme({"key_4.png": b"LOOSE-4"})
        items = parse_passthm_archive(theme, "TelephonyUI-10", target_lang="en", target_bold="regular")
        self.assertEqual(_written(items, "en-4---white.png"), b"LOOSE-4")

    def test_a_proper_key_beats_a_loosely_named_one(self):
        theme = _theme({"key_5.png": b"LOOSE-5", "TelephonyUI-10/en-5---white.png": b"PROPER-5"})
        items = parse_passthm_archive(theme, "TelephonyUI-10", target_lang="en", target_bold="regular")
        self.assertEqual(_written(items, "en-5---white.png"), b"PROPER-5")


if __name__ == "__main__":
    unittest.main()
