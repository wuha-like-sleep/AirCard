import io
import json
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path

import aircard_backend


def _lines(fn, *args):
    buf = io.StringIO()
    with redirect_stdout(buf):
        ok = fn(*args)
    return ok, [json.loads(l) for l in buf.getvalue().splitlines() if l.strip()]


class PasscodeFlashFailureTests(unittest.TestCase):
    """Every failure must reach the app as a line it can read.

    The reader needs "type" and "message". A bare {"ok": false, "error": ...}
    was dropped, so the person only ever saw "exit code 1".
    """

    def _assert_readable_failure(self, lines, code):
        errors = [l for l in lines if l.get("type") == "error"]
        self.assertTrue(errors, f"no error line the app can read: {lines}")
        self.assertEqual(errors[-1]["code"], code)
        self.assertTrue(errors[-1]["message"])

    def test_missing_theme_file(self):
        ok, lines = _lines(aircard_backend.cmd_flash_passthm, "udid", "/no/such/theme.passthm")
        self.assertFalse(ok)
        self._assert_readable_failure(lines, "passthm.missing")

    def test_theme_with_no_keypad_images(self):
        with tempfile.TemporaryDirectory() as tmp:
            theme = Path(tmp) / "empty.passthm"
            with zipfile.ZipFile(theme, "w") as z:
                z.writestr("readme.txt", "no images here")
            ok, lines = _lines(aircard_backend.cmd_flash_passthm, "udid", str(theme))
        self.assertFalse(ok)
        self._assert_readable_failure(lines, "passthm.no_images")

    def test_unreadable_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            theme = Path(tmp) / "broken.passthm"
            theme.write_bytes(b"this is not a zip file")
            ok, lines = _lines(aircard_backend.cmd_flash_passthm, "udid", str(theme))
        self.assertFalse(ok)
        errors = [l for l in lines if l.get("type") == "error"]
        self.assertTrue(errors and errors[-1].get("message"), f"unreadable archive gave no readable line: {lines}")


if __name__ == "__main__":
    unittest.main()


class PasscodeInspectFailureTests(unittest.TestCase):
    """Reading a theme that fails says why, in a code the app turns into words."""

    def _code(self, path):
        buf = io.StringIO()
        with redirect_stdout(buf):
            aircard_backend.cmd_inspect_passthm(str(path))
        out = json.loads(buf.getvalue().strip().splitlines()[-1])
        self.assertFalse(out["ok"])
        return out["code"]

    def test_each_cause_has_its_own_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            picture = root / "key.png"
            picture.write_bytes(b"\x89PNG\r\n\x1a\n" + b"\x00" * 16)
            empty = root / "empty.passthm"
            with zipfile.ZipFile(empty, "w") as z:
                z.writestr("readme.txt", "hello")
            self.assertEqual(self._code(root / "gone.passthm"), "passthm.missing")
            self.assertEqual(self._code(picture), "passthm.not_a_theme")
            self.assertEqual(self._code(empty), "passthm.no_images")

    def test_the_app_has_words_for_every_specific_code(self):
        """A code the app does not know falls back to the generic line."""
        import re
        src = (Path(aircard_backend.__file__).parent / "AirCardApp.swift").read_text(encoding="utf-8")
        start = src.index("static func passcodeFailureMessage(code: String)")
        handled = set(re.findall(r'case "(passthm\.[a-z_]+)"', src[start:start + 3000]))
        backend = Path(aircard_backend.__file__).read_text(encoding="utf-8")
        body = backend[backend.index("def cmd_inspect_passthm"):backend.index("def cmd_flash_passthm")]
        emitted = set(re.findall(r'"code": "(passthm\.[a-z_]+)"', body)) - {"passthm.unreadable"}
        self.assertTrue(emitted)
        self.assertEqual(emitted - handled, set())


class PasscodePreviewTests(unittest.TestCase):
    """The preview shows each key's own picture, never a wallpaper or cover."""

    def _preview(self, entries):
        import base64
        with tempfile.TemporaryDirectory() as tmp:
            theme = Path(tmp) / "theme.passthm"
            with zipfile.ZipFile(theme, "w") as z:
                for name, data in entries.items():
                    z.writestr(name, data)
            buf = io.StringIO()
            with redirect_stdout(buf):
                aircard_backend.cmd_inspect_passthm(str(theme))
        out = json.loads(buf.getvalue().strip().splitlines()[-1])
        self.assertTrue(out["ok"], out)
        return {k: base64.b64decode(v.split(",", 1)[1]) for k, v in out["keys_preview"].items()}

    def test_a_wallpaper_is_not_shown_as_a_key(self):
        png = lambda tag: b"\x89PNG\r\n\x1a\n" + tag
        preview = self._preview({
            "TelephonyUI-10/Wallpaper@3x.png": png(b"wallpaper"),
            "TelephonyUI-10/cover_2.jpg": png(b"cover"),
            "TelephonyUI-10/en-3---white.png": png(b"three"),
            "TelephonyUI-10/key_1.png": png(b"one"),
        })
        self.assertEqual(preview.get("3"), png(b"three"))
        self.assertEqual(preview.get("1"), png(b"one"))
        self.assertNotIn("2", preview)
        self.assertNotIn(png(b"wallpaper"), preview.values())
