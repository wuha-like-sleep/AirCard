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
