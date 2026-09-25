import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import Mock, patch

import aircard
import aircard_backend

CARD = "M6nDwZrkYbFlsodLgCbvyFZQ1cc="
UDID = "00008150-001405803C47801C"
NAMES = list(aircard.BACKED_UP_ASSETS)


def complete(tag=b"orig"):
    """One payload for every file a restore needs."""
    return [(n, tag + n.encode()) for n in NAMES]


class _TempBackups(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        p = patch.object(aircard, "BACKUPS_ROOT", Path(self.tmp.name))
        p.start()
        self.addCleanup(p.stop)

    def _events(self, fn, *args):
        buf = io.StringIO()
        with redirect_stdout(buf):
            result = fn(*args)
        return result, [json.loads(l) for l in buf.getvalue().splitlines() if l.strip()]


class BackupCoverageTests(unittest.TestCase):
    def test_backup_covers_every_file_a_flash_writes(self):
        """A file left behind puts the skin straight back on a restored card."""
        import card_assets
        written = set(card_assets.PNG_ASSET_NAMES) | {card_assets.PDF_ASSET_NAME}
        self.assertEqual(written - set(aircard.BACKED_UP_ASSETS), set())


class BackupStorageTests(_TempBackups):
    def test_round_trip(self):
        self.assertFalse(aircard.has_card_backup(UDID, CARD))
        self.assertTrue(aircard.save_card_backup(UDID, CARD, complete()))
        self.assertTrue(aircard.has_card_backup(UDID, CARD))
        self.assertEqual(dict(aircard.read_card_backup(UDID, CARD)), dict(complete()))

    def test_a_partial_set_is_refused_and_nothing_is_written(self):
        """Two of three files would restore the card only partly."""
        self.assertFalse(aircard.save_card_backup(UDID, CARD, complete()[:-1]))
        self.assertFalse(aircard.has_card_backup(UDID, CARD))
        self.assertFalse(aircard.card_backup_dir(UDID, CARD).exists())

    def test_an_empty_file_is_not_a_backup(self):
        payload = complete()
        payload[0] = (payload[0][0], b"")
        self.assertFalse(aircard.save_card_backup(UDID, CARD, payload))

    def test_a_folder_missing_a_file_does_not_count(self):
        """A backup left incomplete by an older version must not pass as whole."""
        d = aircard.card_backup_dir(UDID, CARD)
        d.mkdir(parents=True)
        for n, data in complete()[:-1]:
            (d / n).write_bytes(data)
        self.assertFalse(aircard.has_card_backup(UDID, CARD))
        self.assertEqual(aircard.list_backed_up_cards(UDID), [])

    def test_a_write_that_fails_part_way_leaves_nothing_behind(self):
        real_write = Path.write_bytes
        calls = {"n": 0}

        def flaky(self, data):
            calls["n"] += 1
            if calls["n"] == 2:
                raise OSError("disk full")
            return real_write(self, data)

        with patch.object(Path, "write_bytes", flaky):
            self.assertFalse(aircard.save_card_backup(UDID, CARD, complete()))
        self.assertFalse(aircard.has_card_backup(UDID, CARD))
        self.assertFalse(aircard.card_backup_dir(UDID, CARD).exists())
        leftovers = list(Path(self.tmp.name).rglob("*.partial"))
        self.assertEqual(leftovers, [])

    def test_hashes_with_slashes_survive_the_filesystem(self):
        awkward = "ab/cd+ef=="
        self.assertTrue(aircard.save_card_backup(UDID, awkward, complete()))
        self.assertEqual(aircard.list_backed_up_cards(UDID), [awkward])

    def test_backups_are_kept_per_device(self):
        aircard.save_card_backup(UDID, CARD, complete())
        other = "00008130-000000000000000A"
        self.assertFalse(aircard.has_card_backup(other, CARD))
        self.assertEqual(aircard.list_backed_up_cards(other), [])

    def test_the_flashed_marker_is_not_mistaken_for_a_card(self):
        aircard.mark_card_flashed(UDID, CARD)
        self.assertEqual(aircard.list_backed_up_cards(UDID), [])

    def test_discard_makes_room_for_a_new_backup(self):
        aircard.save_card_backup(UDID, CARD, complete(b"wrong"))
        self.assertTrue(aircard.discard_card_backup(UDID, CARD))
        self.assertFalse(aircard.has_card_backup(UDID, CARD))
        self.assertTrue(aircard.save_card_backup(UDID, CARD, complete(b"right")))
        self.assertEqual(dict(aircard.read_card_backup(UDID, CARD)), dict(complete(b"right")))


class RestoreCommandTests(_TempBackups):
    def test_restore_without_a_backup_touches_nothing(self):
        batch, single, remove = Mock(), Mock(), Mock()
        with patch.object(aircard_backend, "write_files_batch", batch), \
                patch.object(aircard_backend, "write_file", single), \
                patch.object(aircard_backend, "remove_files", remove):
            ok, events = self._events(aircard_backend.cmd_restore, UDID, CARD)
        self.assertFalse(ok)
        self.assertEqual(events[-1]["code"], "restore.no_backup")
        batch.assert_not_called()
        single.assert_not_called()
        remove.assert_not_called()

    def test_restore_writes_every_original_and_clears_caches(self):
        aircard.save_card_backup(UDID, CARD, complete())
        batch = Mock(return_value=True)
        remove = Mock(return_value=True)
        with patch.object(aircard_backend, "write_files_batch", batch), \
                patch.object(aircard_backend, "remove_files", remove):
            ok, events = self._events(aircard_backend.cmd_restore, UDID, CARD)
        self.assertTrue(ok)
        self.assertEqual(events[-1]["code"], "restore.done")
        target, payload = batch.call_args[0][1], batch.call_args[0][2]
        self.assertIn(CARD, target)
        self.assertEqual(sorted(n for n, _ in payload), sorted(NAMES))
        self.assertEqual(remove.call_count, 2)

    def test_restore_reports_failure_when_the_write_fails(self):
        aircard.save_card_backup(UDID, CARD, complete())
        with patch.object(aircard_backend, "write_files_batch", Mock(return_value=False)), \
                patch.object(aircard_backend, "write_file", Mock(return_value=False)), \
                patch.object(aircard_backend, "remove_files", Mock(return_value=True)):
            ok, events = self._events(aircard_backend.cmd_restore, UDID, CARD)
        self.assertFalse(ok)
        self.assertEqual(events[-1]["code"], "restore.failed")

    def test_restore_fails_when_the_cache_cannot_be_cleared(self):
        aircard.save_card_backup(UDID, CARD, complete())
        with patch.object(aircard_backend, "write_files_batch", Mock(return_value=True)), \
                patch.object(aircard_backend, "remove_files", Mock(side_effect=[True, False])):
            ok, events = self._events(aircard_backend.cmd_restore, UDID, CARD)
        self.assertFalse(ok)
        self.assertEqual(events[-1]["code"], "restore.failed")


class BackupCommandTests(_TempBackups):
    def _reader(self, missing=()):
        data = dict(complete(b"phone"))
        return Mock(side_effect=lambda udid, target, leaf: None if leaf in missing else data[leaf])

    def test_backup_reads_and_stores_every_file(self):
        with patch.object(aircard_backend, "read_file", self._reader()):
            ok, events = self._events(aircard_backend.cmd_backup, UDID, CARD)
        self.assertTrue(ok)
        self.assertEqual(events[-1]["code"], "backup.done")
        self.assertTrue(aircard.has_card_backup(UDID, CARD))

    def test_one_unreadable_file_means_no_backup_and_says_so(self):
        with patch.object(aircard_backend, "read_file", self._reader(missing={NAMES[-1]})):
            ok, events = self._events(aircard_backend.cmd_backup, UDID, CARD)
        self.assertFalse(ok)
        self.assertEqual(events[-1]["code"], "backup.incomplete")
        self.assertFalse(aircard.has_card_backup(UDID, CARD))

    def test_a_full_disk_is_not_blamed_on_the_phone(self):
        """Every file was read; only saving it failed. Retrying with the phone
        unlocked, as a read failure tells people to, can never fix that."""
        with patch.object(aircard_backend, "read_file", self._reader()), \
                patch.object(Path, "write_bytes", Mock(side_effect=OSError("No space left on device"))):
            ok, events = self._events(aircard_backend.cmd_backup, UDID, CARD)
        self.assertFalse(ok)
        self.assertEqual(events[-1]["code"], "backup.write_failed")
        self.assertFalse(aircard.has_card_backup(UDID, CARD))

    def test_the_app_has_words_for_every_backup_code(self):
        import re
        src = (Path(aircard_backend.__file__).parent / "AirCardApp.swift").read_text(encoding="utf-8")
        start = src.index("static func originalArtworkMessage(code: String)")
        handled = set(re.findall(r'case "([a-z_.]+)"', src[start:start + 3000]))
        backend = Path(aircard_backend.__file__).read_text(encoding="utf-8")
        body = backend[backend.index("def cmd_backup"):backend.index("def cmd_backups")]
        emitted = {c for c in re.findall(r'"code": "(backup\.[a-z_]+)"', body)}
        emitted |= set(re.findall(r'"(backup\.[a-z_]+)" if', body)) | set(re.findall(r'else "(backup\.[a-z_]+)"', body))
        errors = emitted - {"backup.exists", "backup.done", "backup.discarded"}
        self.assertIn("backup.write_failed", errors)
        self.assertEqual(errors - handled, set())

    def test_nothing_readable_is_a_plain_failure(self):
        with patch.object(aircard_backend, "read_file", Mock(return_value=None)):
            ok, events = self._events(aircard_backend.cmd_backup, UDID, CARD)
        self.assertFalse(ok)
        self.assertEqual(events[-1]["code"], "backup.failed")

    def test_a_raising_reader_is_a_failure(self):
        with patch.object(aircard_backend, "read_file", Mock(side_effect=RuntimeError("boom"))):
            ok, events = self._events(aircard_backend.cmd_backup, UDID, CARD)
        self.assertFalse(ok)
        self.assertEqual(events[-1]["code"], "backup.failed")

    def test_an_existing_backup_is_never_overwritten(self):
        aircard.save_card_backup(UDID, CARD, complete(b"pristine"))
        reader = Mock()
        with patch.object(aircard_backend, "read_file", reader):
            ok, events = self._events(aircard_backend.cmd_backup, UDID, CARD)
        self.assertTrue(ok)
        self.assertEqual(events[-1]["code"], "backup.exists")
        reader.assert_not_called()
        self.assertEqual(dict(aircard.read_card_backup(UDID, CARD)), dict(complete(b"pristine")))

    def test_a_card_already_skinned_by_aircard_is_not_saved_as_the_original(self):
        """Saving it would make restore put the skin back, for good."""
        aircard.mark_card_flashed(UDID, CARD)
        reader = Mock()
        with patch.object(aircard_backend, "read_file", reader):
            ok, events = self._events(aircard_backend.cmd_backup, UDID, CARD)
        self.assertFalse(ok)
        self.assertEqual(events[-1]["code"], "backup.already_changed")
        reader.assert_not_called()
        self.assertFalse(aircard.has_card_backup(UDID, CARD))

    def test_discard_command(self):
        aircard.save_card_backup(UDID, CARD, complete())
        ok, events = self._events(aircard_backend.cmd_discard_backup, UDID, CARD)
        self.assertTrue(ok)
        self.assertEqual(events[-1]["code"], "backup.discarded")
        self.assertFalse(aircard.has_card_backup(UDID, CARD))


class FlashMarksCardTests(_TempBackups):
    def test_a_flash_records_that_the_card_was_changed(self):
        with patch.object(aircard_backend, "build_card_assets", return_value=complete()), \
                patch.object(aircard_backend, "write_files_batch", return_value=True), \
                patch.object(aircard_backend, "remove_files", return_value=True), \
                tempfile.NamedTemporaryFile(suffix=".png") as img, \
                redirect_stdout(io.StringIO()):
            aircard_backend.cmd_flash(UDID, CARD, img.name)
        self.assertTrue(aircard.card_was_flashed(UDID, CARD))

    def test_a_failed_flash_still_counts(self):
        """A write that fails part way can still have changed the card."""
        with patch.object(aircard_backend, "build_card_assets", return_value=complete()), \
                patch.object(aircard_backend, "write_files_batch", return_value=False), \
                patch.object(aircard_backend, "write_file", return_value=False), \
                patch.object(aircard_backend, "remove_files", return_value=True), \
                tempfile.NamedTemporaryFile(suffix=".png") as img, \
                redirect_stdout(io.StringIO()):
            aircard_backend.cmd_flash(UDID, CARD, img.name)
        self.assertTrue(aircard.card_was_flashed(UDID, CARD))


class OriginalPreviewTests(_TempBackups):
    def test_the_saved_original_can_be_shown(self):
        aircard.save_card_backup(UDID, CARD, complete())
        path = aircard.backup_preview_path(UDID, CARD)
        self.assertIsNotNone(path)
        self.assertEqual(path.name, "cardBackgroundCombined@3x.png")

    def test_no_preview_without_a_complete_backup(self):
        self.assertIsNone(aircard.backup_preview_path(UDID, CARD))

    def test_backups_command_reports_where_each_original_is(self):
        aircard.save_card_backup(UDID, CARD, complete())
        _, events = self._events(aircard_backend.cmd_backups, UDID)
        out = events[-1]
        self.assertEqual(out["cards"], [CARD])
        self.assertTrue(out["previews"][CARD].endswith("cardBackgroundCombined@3x.png"))


if __name__ == "__main__":
    unittest.main()
