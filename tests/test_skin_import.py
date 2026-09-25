import io
import json
import os
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import aircard
import aircard_backend

PNG_HEAD = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
JPG_HEAD = b"\xff\xd8\xff\xe0" + b"\x00" * 64
_counter = [0]


def png(tag=None):
    """A PNG-looking file; every call is a different picture unless tagged alike."""
    if tag is None:
        _counter[0] += 1
        tag = f"unique-{_counter[0]}"
    return PNG_HEAD + tag.encode()


def jpg(tag=None):
    if tag is None:
        _counter[0] += 1
        tag = f"unique-{_counter[0]}"
    return JPG_HEAD + tag.encode()


class SkinImportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.library = self.root / "library"

    def _zip(self, entries, name="pack.zip"):
        path = self.root / name
        with zipfile.ZipFile(path, "w") as z:
            for entry, data in entries.items():
                z.writestr(entry, data)
        return path

    def _names(self):
        return sorted(p.name for p in self.library.iterdir())

    # What comes in, and what does not

    def test_pictures_come_out_of_a_pack_and_nothing_else(self):
        pack = self._zip({
            "Blue.png": png(),
            "cards/Red.jpg": jpg(),
            "readme.txt": b"hello",
            "__MACOSX/._Blue.png": png(),
            ".DS_Store": b"junk",
        })
        result = aircard.import_skins(pack, self.library)
        self.assertEqual(sorted(result["imported"]), ["Blue.png", "Red.jpg"])
        self.assertEqual(self._names(), ["Blue.png", "Red.jpg"])
        self.assertEqual(result["skipped"], 1)

    def test_a_file_named_like_a_picture_but_not_one_is_left_behind(self):
        pack = self._zip({"totally-an-image.png": b"#!/bin/sh\necho gotcha\n"})
        result = aircard.import_skins(pack, self.library)
        self.assertEqual(result["imported"], [])
        self.assertEqual(result["skipped"], 1)

    def test_the_real_type_decides_the_extension(self):
        pack = self._zip({"photo.png": jpg()})
        self.assertEqual(aircard.import_skins(pack, self.library)["imported"], ["photo.jpg"])

    def test_a_single_picture_imports(self):
        pic = self.root / "single.png"
        pic.write_bytes(png())
        self.assertEqual(aircard.import_skins(pic, self.library)["imported"], ["single.png"])

    # Names

    def test_a_path_cannot_climb_out_of_the_library(self):
        library = self.root / "a" / "b" / "library"
        pack = self._zip({"../../escaped.png": png(), "..\\..\\windows.png": png(), "/tmp/absolute.png": png()})
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
        # Even with the folder added in front
        self.assertEqual(aircard._skin_name("../../evil/x.png", "png", set(), qualify=True), "evil x.png")

    def test_names_stay_readable_and_safe(self):
        taken = set()
        self.assertEqual(aircard._skin_name("金卡 黑色.png", "png", taken), "金卡 黑色.png")
        self.assertEqual(aircard._skin_name("bad\nname:x.png", "png", taken), "bad_name_x.png")
        self.assertEqual(aircard._skin_name("   .png", "png", taken), "skin.png")
        self.assertEqual(aircard._skin_name("..png", "png", taken), "skin-2.png")

    def test_different_pictures_with_one_name_do_not_overwrite_each_other(self):
        aircard.import_skins(self._zip({"card.png": png()}), self.library)
        aircard.import_skins(self._zip({"card.png": png()}, "again.zip"), self.library)
        self.assertEqual(self._names(), ["card-2.png", "card.png"])

    def test_one_folder_per_bank_keeps_the_bank_names(self):
        pack = self._zip({"ICBC/card.png": png(), "CMB/card.png": png(), "Visa Gold/front.png": png()})
        result = aircard.import_skins(pack, self.library)
        self.assertEqual(sorted(result["imported"]), ["CMB card.png", "ICBC card.png", "front.png"])

    def test_names_from_chinese_windows_zips_are_read_as_written(self):
        """No UTF-8 flag, GBK bytes: Python alone reads them as cp437 mojibake."""
        gbk = "招商银行.png".encode("gbk")

        class GbkInfo(zipfile.ZipInfo):
            def _encodeFilenameFlags(self):
                return gbk, self.flag_bits & ~0x800

        pack = self.root / "gbk.zip"
        with zipfile.ZipFile(pack, "w") as z:
            z.writestr(GbkInfo("placeholder.png"), png())
        with zipfile.ZipFile(pack) as z:
            self.assertNotEqual(z.infolist()[0].filename, "招商银行.png", "the fixture must reproduce the problem")
        self.assertEqual(aircard.import_skins(pack, self.library)["imported"], ["招商银行.png"])

    def test_names_that_say_they_are_utf8_are_left_alone(self):
        pack = self._zip({"工商银行.png": png()})
        self.assertEqual(aircard.import_skins(pack, self.library)["imported"], ["工商银行.png"])

    def test_accented_names_that_say_they_are_utf8_are_not_reread(self):
        """é is also a cp437 character, so rereading a flagged name mangles it."""
        pack = self._zip({"Crème.png": png(), "Éclair.png": png()})
        self.assertEqual(sorted(aircard.import_skins(pack, self.library)["imported"]), ["Crème.png", "Éclair.png"])

    def test_dot_folders_in_zip_paths_do_not_hide_the_bank_name(self):
        pack = self._zip({"./ICBC/./card.png": png(), "./CMB/./card.png": png()})
        self.assertEqual(sorted(aircard.import_skins(pack, self.library)["imported"]), ["CMB card.png", "ICBC card.png"])

    # The same picture twice

    def test_importing_the_same_pack_again_adds_nothing(self):
        entries = {"Blue.png": png(), "Red.png": png()}
        aircard.import_skins(self._zip(entries), self.library)
        again = aircard.import_skins(self._zip(entries, "again.zip"), self.library)
        self.assertEqual(again["imported"], [])
        self.assertEqual(again["duplicates"], 2)
        self.assertEqual(self._names(), ["Blue.png", "Red.png"])

    def test_the_same_picture_twice_in_one_pack_comes_in_once(self):
        same = png("same")
        result = aircard.import_skins(self._zip({"a.png": same, "b/a copy.png": same}), self.library)
        self.assertEqual(len(result["imported"]), 1)
        self.assertEqual(result["duplicates"], 1)

    # Size, count and damage

    def test_an_oversized_entry_is_never_unpacked(self):
        """Judged on what it claims, before a byte of it is decompressed."""
        pack = self._zip({"big.png": png() + b"\x00" * 5000, "ok.png": png()})
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
        pack = self._zip({"first.png": png(), "liar.png": png() + b"\x00" * 5000, "last.png": png()})
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

    def test_a_password_protected_pack_says_so(self):
        pack = self._zip({"open.png": png(), "locked.png": png(), "locked.txt": b"x"})
        original_infolist = zipfile.ZipFile.infolist

        def with_lock(z):
            items = original_infolist(z)
            for i in items:
                if i.filename.startswith("locked"):
                    i.flag_bits |= 0x1
            return items

        with patch.object(zipfile.ZipFile, "infolist", with_lock):
            result = aircard.import_skins(pack, self.library)
        self.assertEqual(result["imported"], ["open.png"])
        self.assertEqual(result["encrypted"], 1)
        self.assertEqual(result["skipped"], 1)

    def test_compression_python_cannot_read_says_so(self):
        pack = self._zip({"ok.png": png(), "deflate64.png": png()})
        original_infolist = zipfile.ZipFile.infolist

        def deflate64(z):
            items = original_infolist(z)
            for i in items:
                if i.filename == "deflate64.png":
                    i.compress_type = 9
            return items

        with patch.object(zipfile.ZipFile, "infolist", deflate64):
            result = aircard.import_skins(pack, self.library)
        self.assertEqual(result["imported"], ["ok.png"])
        self.assertEqual(result["unsupported"], 1)

    def test_the_number_of_pictures_is_capped_and_says_so(self):
        pack = self._zip({f"s{i}.png": png() for i in range(6)} | {"notes.txt": b"x"})
        with patch.object(aircard, "MAX_PACK_IMAGES", 4):
            result = aircard.import_skins(pack, self.library)
        self.assertEqual(len(result["imported"]), 4)
        self.assertEqual(result["over_limit"], 2)

    def test_a_large_single_picture_is_not_read_whole(self):
        pic = self.root / "huge.png"
        pic.write_bytes(png() + b"\x00" * 5000)
        with patch.object(aircard, "MAX_SKIN_BYTES", 100):
            result = aircard.import_skins(pic, self.library)
        self.assertEqual(result["imported"], [])
        self.assertEqual(result["skipped"], 1)

    # Folders

    def test_a_folder_imports_like_a_pack(self):
        """What people have after double-clicking a zip in Finder."""
        folder = self.root / "Pack"
        (folder / "cards").mkdir(parents=True)
        (folder / "Blue.png").write_bytes(png())
        (folder / "cards" / "Red.jpg").write_bytes(jpg())
        (folder / "readme.txt").write_bytes(b"hello")
        (folder / ".hidden.png").write_bytes(png())
        (folder / ".git").mkdir()
        (folder / ".git" / "inside.png").write_bytes(png())
        (folder / "__MACOSX").mkdir()
        (folder / "__MACOSX" / "Blue.png").write_bytes(png())
        result = aircard.import_skins(folder, self.library)
        self.assertEqual(sorted(result["imported"]), ["Blue.png", "Red.jpg"])
        self.assertEqual(result["skipped"], 1)

    def test_a_folder_never_walks_into_apps_or_photo_libraries(self):
        folder = self.root / "Downloads"
        for inner in ["Some.app/Contents/Resources", "Photos Library.photoslibrary/originals", "Asset.xcassets/x.imageset"]:
            (folder / inner).mkdir(parents=True)
            (folder / inner / "picture.png").write_bytes(png())
        (folder / "real.png").write_bytes(png())
        result = aircard.import_skins(folder, self.library)
        self.assertEqual(result["imported"], ["real.png"])

    def test_a_folder_per_bank_keeps_the_bank_names(self):
        folder = self.root / "Pack"
        for bank in ["ICBC", "CMB"]:
            (folder / bank).mkdir(parents=True)
            (folder / bank / "card.png").write_bytes(png())
        result = aircard.import_skins(folder, self.library)
        self.assertEqual(sorted(result["imported"]), ["CMB card.png", "ICBC card.png"])

    def test_a_folder_does_not_follow_links_out_of_itself(self):
        folder = self.root / "Pack"
        folder.mkdir()
        elsewhere = self.root / "private.png"
        elsewhere.write_bytes(png())
        (folder / "link.png").symlink_to(elsewhere)
        (folder / "real.png").write_bytes(png())
        result = aircard.import_skins(folder, self.library)
        self.assertEqual(result["imported"], ["real.png"])

    def test_the_wrong_folder_is_not_walked_forever(self):
        folder = self.root / "Everything"
        folder.mkdir()
        for i in range(12):
            (folder / f"note{i:02d}.txt").write_bytes(b"x")
        (folder / "zz-last.png").write_bytes(png())
        with patch.object(aircard, "MAX_FOLDER_FILES", 10):
            result = aircard.import_skins(folder, self.library)
        self.assertEqual(result["imported"], [])
        self.assertLessEqual(result["skipped"], 10)

    # The command the app runs

    def _run(self, source):
        buf = io.StringIO()
        with redirect_stdout(buf):
            ok = aircard_backend.cmd_import_skins(str(source), str(self.library))
        return ok, json.loads(buf.getvalue().strip().splitlines()[-1])

    def test_the_command_reports_what_it_did(self):
        ok, out = self._run(self._zip({"Blue.png": png(), "notes.txt": b"x"}))
        self.assertTrue(ok)
        self.assertEqual(out["code"], "skins.imported")
        self.assertEqual(out["imported"], ["Blue.png"])
        self.assertEqual(out["skipped"], 1)
        for key in ("duplicates", "encrypted", "unsupported", "over_limit"):
            self.assertIn(key, out)

    def test_a_pack_with_no_pictures_says_so(self):
        ok, out = self._run(self._zip({"notes.txt": b"x"}))
        self.assertFalse(ok)
        self.assertEqual(out["code"], "skins.none_found")

    def test_a_pack_already_in_the_library_is_not_an_error(self):
        entries = {"Blue.png": png(), "readme.txt": b"made by someone"}
        self._run(self._zip(entries))
        ok, out = self._run(self._zip(entries, "again.zip"))
        self.assertTrue(ok)
        self.assertEqual(out["code"], "skins.nothing_new")
        self.assertEqual(out["duplicates"], 1)

    def test_the_command_accepts_a_folder(self):
        folder = self.root / "Pack"
        folder.mkdir()
        (folder / "Blue.png").write_bytes(png())
        ok, _ = self._run(folder)
        self.assertTrue(ok)


if __name__ == "__main__":
    unittest.main()
