import io
import json
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import aircard
import aircard_backend

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
JPG = b"\xff\xd8\xff\xe0" + b"\x00" * 64


class SkinImportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.library = self.root / "library"

    def _zip(self, entries):
        path = self.root / "pack.zip"
        with zipfile.ZipFile(path, "w") as z:
            for name, data in entries.items():
                z.writestr(name, data)
        return path

    def test_pictures_come_out_of_a_pack_and_nothing_else(self):
        pack = self._zip({
            "Blue.png": PNG,
            "cards/Red.jpg": JPG,
            "readme.txt": b"hello",
            "__MACOSX/._Blue.png": PNG,
            ".DS_Store": b"junk",
        })
        result = aircard.import_skins(pack, self.library)
        self.assertEqual(sorted(result["imported"]), ["Blue.png", "Red.jpg"])
        self.assertEqual(sorted(p.name for p in self.library.iterdir()), ["Blue.png", "Red.jpg"])

    def test_a_path_cannot_climb_out_of_the_library(self):
        library = self.root / "a" / "b" / "library"
        pack = self._zip({"../../escaped.png": PNG, "..\\..\\windows.png": PNG, "/tmp/absolute.png": PNG})
        aircard.import_skins(pack, library)
        written = [p for p in self.root.rglob("*") if p.is_file() and p != pack]
        self.assertTrue(written)
        for p in written:
            self.assertIn(library, p.parents, f"written outside the library: {p}")
        self.assertEqual(sorted(p.name for p in library.iterdir()), ["absolute.png", "escaped.png", "windows.png"])

    def test_the_name_itself_never_carries_a_path(self):
        for hostile in ["../../x.png", "a/../../x.png", "..\\..\\x.png", "/etc/x.png"]:
            name = aircard._skin_name(hostile, "png", set())
            self.assertNotIn("/", name, hostile)
            self.assertNotIn("\\", name, hostile)
            self.assertEqual(name, "x.png", hostile)

    def test_names_stay_readable_and_safe(self):
        taken = set()
        self.assertEqual(aircard._skin_name("金卡 黑色.png", "png", taken), "金卡 黑色.png")
        self.assertEqual(aircard._skin_name("bad\nname:x.png", "png", taken), "bad_name_x.png")
        self.assertEqual(aircard._skin_name("   .png", "png", taken), "skin.png")
        self.assertEqual(aircard._skin_name("..png", "png", taken), "skin-2.png")

    def test_a_file_named_like_a_picture_but_not_one_is_left_behind(self):
        pack = self._zip({"totally-an-image.png": b"#!/bin/sh\necho gotcha\n"})
        result = aircard.import_skins(pack, self.library)
        self.assertEqual(result["imported"], [])
        self.assertEqual(result["skipped"], 1)

    def test_the_real_type_decides_the_extension(self):
        pack = self._zip({"photo.png": JPG})
        result = aircard.import_skins(pack, self.library)
        self.assertEqual(result["imported"], ["photo.jpg"])

    def test_names_do_not_overwrite_each_other(self):
        pack = self._zip({"a/card.png": PNG, "b/card.png": PNG})
        aircard.import_skins(pack, self.library)
        again = self._zip({"card.png": PNG})
        aircard.import_skins(again, self.library)
        self.assertEqual(sorted(p.name for p in self.library.iterdir()), ["card-2.png", "card-3.png", "card.png"])

    def test_an_oversized_entry_is_never_unpacked(self):
        """Judged on what it claims, before a byte of it is decompressed."""
        pack = self._zip({"big.png": PNG + b"\x00" * 5000, "ok.png": PNG})
        original_open = zipfile.ZipFile.open
        opened = []

        def spy(z, name, *a, **kw):
            opened.append(getattr(name, "filename", name))
            return original_open(z, name, *a, **kw)

        with patch.object(aircard, "MAX_SKIN_BYTES", 100), patch.object(zipfile.ZipFile, "open", spy):
            result = aircard.import_skins(pack, self.library)
        self.assertEqual(result["imported"], ["ok.png"])
        self.assertNotIn("big.png", opened)

    def test_a_broken_entry_costs_only_itself(self):
        """A size that lies, or a damaged entry, must not sink the whole pack."""
        pack = self._zip({"first.png": PNG, "liar.png": PNG + b"\x00" * 5000, "last.png": PNG})
        original_infolist = zipfile.ZipFile.infolist

        def lying_infolist(z):
            items = original_infolist(z)
            for i in items:
                if i.filename == "liar.png":
                    i.file_size = 10
            return items

        with patch.object(zipfile.ZipFile, "infolist", lying_infolist):
            result = aircard.import_skins(pack, self.library)
        self.assertEqual(sorted(result["imported"]), ["first.png", "last.png"])
        self.assertEqual(result["skipped"], 1)

    def test_an_encrypted_entry_is_skipped(self):
        pack = self._zip({"open.png": PNG, "locked.png": PNG})
        original_infolist = zipfile.ZipFile.infolist

        def with_lock(z):
            items = original_infolist(z)
            for i in items:
                if i.filename == "locked.png":
                    i.flag_bits |= 0x1
            return items

        with patch.object(zipfile.ZipFile, "infolist", with_lock):
            result = aircard.import_skins(pack, self.library)
        self.assertEqual(result["imported"], ["open.png"])

    def test_a_large_single_picture_is_not_read_whole(self):
        pic = self.root / "huge.png"
        pic.write_bytes(PNG + b"\x00" * 5000)
        with patch.object(aircard, "MAX_SKIN_BYTES", 100):
            result = aircard.import_skins(pic, self.library)
        self.assertEqual(result["imported"], [])
        self.assertEqual(result["skipped"], 1)

    def test_the_number_of_pictures_is_capped(self):
        pack = self._zip({f"s{i}.png": PNG for i in range(6)})
        with patch.object(aircard, "MAX_PACK_IMAGES", 4):
            result = aircard.import_skins(pack, self.library)
        self.assertEqual(len(result["imported"]), 4)
        self.assertEqual(result["skipped"], 2)

    def test_a_single_picture_imports(self):
        pic = self.root / "single.png"
        pic.write_bytes(PNG)
        self.assertEqual(aircard.import_skins(pic, self.library)["imported"], ["single.png"])

    def test_a_folder_imports_like_a_pack(self):
        """What people have after double-clicking a zip in Finder."""
        folder = self.root / "Pack"
        (folder / "cards").mkdir(parents=True)
        (folder / "Blue.png").write_bytes(PNG)
        (folder / "cards" / "Red.jpg").write_bytes(JPG)
        (folder / "readme.txt").write_bytes(b"hello")
        (folder / ".hidden.png").write_bytes(PNG)
        (folder / ".git").mkdir()
        (folder / ".git" / "inside.png").write_bytes(PNG)
        (folder / "__MACOSX").mkdir()
        (folder / "__MACOSX" / "Blue.png").write_bytes(PNG)
        result = aircard.import_skins(folder, self.library)
        self.assertEqual(sorted(result["imported"]), ["Blue.png", "Red.jpg"])
        self.assertEqual(result["skipped"], 1)

    def test_a_folder_does_not_follow_links_out_of_itself(self):
        folder = self.root / "Pack"
        folder.mkdir()
        elsewhere = self.root / "private.png"
        elsewhere.write_bytes(PNG)
        (folder / "link.png").symlink_to(elsewhere)
        (folder / "real.png").write_bytes(PNG)
        result = aircard.import_skins(folder, self.library)
        self.assertEqual(result["imported"], ["real.png"])

    def test_the_wrong_folder_is_not_walked_forever(self):
        folder = self.root / "Everything"
        folder.mkdir()
        for i in range(12):
            (folder / f"note{i:02d}.txt").write_bytes(b"x")
        (folder / "zz-last.png").write_bytes(PNG)
        with patch.object(aircard, "MAX_FOLDER_FILES", 10):
            result = aircard.import_skins(folder, self.library)
        self.assertEqual(result["imported"], [])
        self.assertLessEqual(result["skipped"], 10)

    def test_the_command_accepts_a_folder(self):
        folder = self.root / "Pack"
        folder.mkdir()
        (folder / "Blue.png").write_bytes(PNG)
        buf = io.StringIO()
        with redirect_stdout(buf):
            ok = aircard_backend.cmd_import_skins(str(folder), str(self.library))
        self.assertTrue(ok)

    def test_the_command_reports_what_it_did(self):
        pack = self._zip({"Blue.png": PNG, "notes.txt": b"x"})
        buf = io.StringIO()
        with redirect_stdout(buf):
            ok = aircard_backend.cmd_import_skins(str(pack), str(self.library))
        out = json.loads(buf.getvalue().strip().splitlines()[-1])
        self.assertTrue(ok)
        self.assertEqual(out["code"], "skins.imported")
        self.assertEqual(out["imported"], ["Blue.png"])
        self.assertEqual(out["skipped"], 1)

    def test_a_pack_with_no_pictures_says_so(self):
        pack = self._zip({"notes.txt": b"x"})
        buf = io.StringIO()
        with redirect_stdout(buf):
            ok = aircard_backend.cmd_import_skins(str(pack), str(self.library))
        self.assertFalse(ok)
        self.assertEqual(json.loads(buf.getvalue().strip().splitlines()[-1])["code"], "skins.none_found")


if __name__ == "__main__":
    unittest.main()
