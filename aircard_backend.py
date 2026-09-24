#!/usr/bin/env python3
"""
Backend engine for AirCard native macOS GUI app.
"""
from __future__ import annotations

import base64
import io
import json
import os
import re
import subprocess
import sys
import time
import zipfile
from pathlib import Path

# Augment PATH so bundled tools and system tools are always found
script_dir = Path(__file__).resolve().parent
bundled_bin = script_dir / "bin"
bundled_lib = script_dir / "lib"
app_bin = Path("/Applications/AirCard.app/Contents/Resources/bin")
app_lib = Path("/Applications/AirCard.app/Contents/Resources/lib")

paths_to_add = [
    str(bundled_bin),
    str(app_bin),
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin"
]
for p in reversed(paths_to_add):
    if os.path.isdir(p) and p not in os.environ.get("PATH", ""):
        os.environ["PATH"] = f"{p}:{os.environ.get('PATH', '')}"

lib_paths = [str(bundled_lib), str(app_lib)]
for lp in lib_paths:
    if os.path.isdir(lp):
        cur_dyld = os.environ.get("DYLD_LIBRARY_PATH", "")
        os.environ["DYLD_LIBRARY_PATH"] = f"{lp}:{cur_dyld}" if cur_dyld else lp

from apply_card_skin import (
    native,
    operation_ok,
    read_file,
    write_file,
    write_files_batch,
    remove_files,
    build_archive_multi,
    ROOT,
    DEVICE_HELPER,
)
from card_assets import CACHE_FILES, build_card_assets
from aircard import (
    find_device_helper,
    get_connected_device,
    has_card_backup,
    list_backed_up_cards,
    BACKED_UP_ASSETS,
    backup_preview_path,
    card_was_flashed,
    discard_card_backup,
    list_connected_devices,
    mark_card_flashed,
    load_saved_cards,
    survey_devices,
    read_card_backup,
    save_card_backup,
    save_cards,
    TARGET_ASSETS,
)


def cmd_device(preferred_udid: str | None = None):
    if not find_device_helper():
        print(json.dumps({"connected": False, "error": "device_helper_missing"}))
        return
    device = get_connected_device(preferred_udid)
    if not device:
        print(json.dumps({"connected": False, "error": "no_device"}))
        return
    probe = native("probe", device["udid"])
    device["airlift_compatible"] = operation_ok(probe)
    device["connected"] = True
    print(json.dumps(device))


def cmd_devices():
    """Lists every connected device so the app can offer a device picker.

    The airlift probe is intentionally skipped here. Probing opens a session on
    each device and is only needed for whichever one the user selects, which the
    app fetches with a follow-up `--device <udid>` call.
    """
    if not find_device_helper():
        print(json.dumps({"connected": False, "error": "device_helper_missing", "devices": []}))
        return
    devices, untrusted = survey_devices()
    print(json.dumps({"connected": bool(devices), "devices": devices, "untrusted": untrusted}))


def cmd_backup(udid: str, card_hash: str) -> bool:
    """Saves a card's current artwork so it can be put back later.

    Deliberately a separate step rather than something the flash does on its
    own: reading a file back off the device moves it and writes it out again,
    and that is not a risk to take on someone's card unless they asked for it.
    Taken once per card, so a later flash cannot overwrite the original with a
    skin that was applied in between.
    """
    if has_card_backup(udid, card_hash):
        print(json.dumps({
            "type": "success", "card": card_hash, "code": "backup.exists",
            "message": f"Original artwork for {card_hash[:12]}... is already saved"
        }))
        sys.stdout.flush()
        return True

    # AirCard has already written to this card and nothing was saved before it
    # did, so what is on the card now is a skin. Saving it would make restore
    # put the skin back, and the one-save rule would then keep it that way.
    if card_was_flashed(udid, card_hash):
        print(json.dumps({
            "type": "error", "card": card_hash, "code": "backup.already_changed",
            "message": f"AirCard has already changed {card_hash[:12]}..., so its original is no longer on the phone."
        }))
        sys.stdout.flush()
        return False

    pkpass_dir = f"/var/mobile/Library/Passes/Cards/{card_hash}.pkpass"
    originals = []
    for asset in BACKED_UP_ASSETS:
        try:
            data = read_file(udid, pkpass_dir, asset)
        except Exception:
            data = None
        if data:
            originals.append((asset, data))

    if not save_card_backup(udid, card_hash, originals):
        # Some but not all of the files came back: say so, and keep nothing,
        # rather than store a backup that would restore the card only partly.
        partial = 0 < len(originals) < len(BACKED_UP_ASSETS)
        print(json.dumps({
            "type": "error", "card": card_hash,
            "code": "backup.incomplete" if partial else "backup.failed",
            "message": f"Could not read the original artwork for {card_hash[:12]}..."
        }))
        sys.stdout.flush()
        return False

    print(json.dumps({
        "type": "success", "card": card_hash, "code": "backup.done",
        "message": f"Saved original artwork for {card_hash[:12]}..."
    }))
    sys.stdout.flush()
    return True


def cmd_restore(udid: str, card_hash: str) -> bool:
    """Puts a card's original artwork back and clears the rendered faces."""
    originals = read_card_backup(udid, card_hash)
    if not originals:
        print(json.dumps({
            "type": "error",
            "card": card_hash,
            "code": "restore.no_backup",
            "message": "No original artwork was saved for this card, so it cannot be restored."
        }))
        sys.stdout.flush()
        return False

    pkpass_dir = f"/var/mobile/Library/Passes/Cards/{card_hash}.pkpass"
    total_steps = 2
    all_ok = True

    print(json.dumps({
        "type": "progress", "card": card_hash, "step": 1, "total": total_steps,
        "code": "restore.writing",
        "message": f"Restoring {len(originals)} original artwork files..."
    }))
    sys.stdout.flush()

    try:
        ok = write_files_batch(udid, pkpass_dir, originals)
    except (OSError, RuntimeError, subprocess.SubprocessError):
        ok = False
    if not ok:
        for asset, payload in originals:
            try:
                ok_single = write_file(udid, pkpass_dir, asset, payload)
            except Exception:
                ok_single = False
            if not ok_single:
                all_ok = False

    # Same cache clearing the flash does, or Wallet keeps showing the skin.
    print(json.dumps({
        "type": "progress", "card": card_hash, "step": 2, "total": total_steps,
        "code": "restore.clearing_cache",
        "message": "Clearing rendered card faces..."
    }))
    sys.stdout.flush()
    for ext in [".cache", ".pkcache"]:
        cache_dir = f"/var/mobile/Library/Passes/Cards/{card_hash}{ext}"
        try:
            ok_cache = remove_files(udid, cache_dir, list(CACHE_FILES))
        except Exception:
            ok_cache = False
        if not ok_cache:
            all_ok = False

    if not all_ok:
        print(json.dumps({
            "type": "error", "card": card_hash, "step": 2, "total": total_steps,
            "code": "restore.failed",
            "message": f"Could not fully restore {card_hash[:12]}..."
        }))
        sys.stdout.flush()
        return False

    print(json.dumps({
        "type": "success", "card": card_hash, "step": 2, "total": total_steps,
        "code": "restore.done",
        "message": f"Restored {card_hash[:12]}... to its original artwork"
    }))
    sys.stdout.flush()
    return True


def cmd_discard_backup(udid: str, card_hash: str) -> bool:
    """Deletes a saved original, so a wrong one can be replaced."""
    ok = discard_card_backup(udid, card_hash)
    print(json.dumps({
        "type": "success" if ok else "error", "card": card_hash,
        "code": "backup.discarded" if ok else "backup.discard_failed",
        "message": "Saved original removed." if ok else "Could not remove the saved original."
    }))
    sys.stdout.flush()
    return ok


def cmd_backups(udid: str):
    """Which cards on this device have their original saved, and where to see it."""
    cards = list_backed_up_cards(udid)
    previews = {}
    for card in cards:
        path = backup_preview_path(udid, card)
        if path:
            previews[card] = str(path)
    print(json.dumps({"ok": True, "cards": cards, "previews": previews}))


def cmd_get_saved_cards():
    cards = load_saved_cards()
    print(json.dumps({"ok": True, "cards": cards}))


def cmd_save_cards(cards_json: str):
    try:
        cards = json.loads(cards_json)
        if isinstance(cards, list):
            save_cards(cards)
            print(json.dumps({"ok": True}))
            return
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        return
    print(json.dumps({"ok": False, "error": "Invalid format"}))


def cmd_prepare_image(src: str, dst: str):
    path = Path(src).expanduser()
    if not path.is_file():
        print(json.dumps({"ok": False, "error": f"File not found: {src}"}))
        return
    try:
        from PIL import Image, ImageOps
        with Image.open(path) as img:
            img = img.convert("RGBA")
            target_size = (1536, 969)
            fitted = ImageOps.fit(img, target_size, method=Image.Resampling.LANCZOS)
            fitted.save(dst, format="PNG")
        print(json.dumps({"ok": True, "path": dst}))
        return
    except ImportError:
        pass
    except Exception as e:
        pass
    
    # Fallback to macOS built-in sips tool (built into every macOS, 0 dependencies!)
    try:
        import subprocess
        subprocess.check_call([
            "/usr/bin/sips",
            "-s", "format", "png",
            "-z", "969", "1536",
            str(path),
            "--out", str(dst)
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(json.dumps({"ok": True, "path": dst}))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


def cmd_flash(udid: str, card_hash: str, image_path: str) -> bool:
    img_path = Path(image_path)
    if not img_path.is_file():
        print(json.dumps({"ok": False, "error": "Image file not found"}))
        return False

    try:
        asset_payloads = build_card_assets(img_path.read_bytes())
    except (OSError, subprocess.SubprocessError):
        print(json.dumps({
            "type": "error",
            "card": card_hash,
            "message": "Failed to prepare card artwork"
        }))
        sys.stdout.flush()
        return False

    pkpass_dir = f"/var/mobile/Library/Passes/Cards/{card_hash}.pkpass"
    # Marked before the write rather than after it succeeds: a write that fails
    # part way can still have changed the card.
    mark_card_flashed(udid, card_hash)
    
    total_steps = 4
    step = 0
    all_ok = True

    step += 1
    print(json.dumps({
        "type": "progress",
        "card": card_hash,
        "step": step,
        "total": total_steps,
        "message": f"Writing {len(asset_payloads)} artwork files (fast batch)..."
    }))
    sys.stdout.flush()

    try:
        ok = write_files_batch(udid, pkpass_dir, asset_payloads)
    except (OSError, RuntimeError, subprocess.SubprocessError):
        ok = False

    if not ok:
        # The batch write can take many minutes to give up, and the per-file
        # retry after it is just as quiet. Say so, or the bar sits still and
        # people conclude it has hung.
        print(json.dumps({
            "type": "progress",
            "card": card_hash,
            "step": step,
            "total": total_steps,
            "code": "flash.retrying",
            "message": "The iPhone was slow to take the files, trying them one at a time..."
        }))
        sys.stdout.flush()
        # Fallback to individual writes if batch fails
        for asset, payload in asset_payloads:
            try:
                ok_single = write_file(udid, pkpass_dir, asset, payload)
            except Exception:
                ok_single = False
            if not ok_single:
                all_ok = False

    # Wallet v2: genuinely unlink rendered faces. Writing corrupt bytes here can
    # leave the previous artwork resident indefinitely on iOS 27.
    for ext in [".cache", ".pkcache"]:
        cache_dir = f"/var/mobile/Library/Passes/Cards/{card_hash}{ext}"
        step += 1
        print(json.dumps({
            "type": "progress",
            "card": card_hash,
            "step": step,
            "total": total_steps,
            "message": f"Invalidating cache ({ext})..."
        }))
        sys.stdout.flush()
        try:
            ok_cache = remove_files(udid, cache_dir, list(CACHE_FILES))
        except Exception:
            ok_cache = False
        if not ok_cache:
            all_ok = False
            print(json.dumps({
                "type": "error",
                "card": card_hash,
                "step": step,
                "total": total_steps,
                "message": f"Could not clear Wallet cache ({ext}); card was not reported as updated."
            }))
            sys.stdout.flush()

    step += 1
    if not all_ok:
        print(json.dumps({
            "type": "error",
            "card": card_hash,
            "step": step,
            "total": total_steps,
            "message": f"Failed to update {card_hash[:12]}..."
        }))
        sys.stdout.flush()
        return False

    print(json.dumps({
        "type": "success",
        "card": card_hash,
        "step": step,
        "total": total_steps,
        "message": f"Successfully updated {card_hash[:12]}..."
    }))
    sys.stdout.flush()
    return True


KEYPAD_SUBTEXTS = {
    "0": "+",
    "1": "",
    "2": "A B C",
    "3": "D E F",
    "4": "G H I",
    "5": "J K L",
    "6": "M N O",
    "7": "P Q R S",
    "8": "T U V",
    "9": "W X Y Z",
}

# Cyrillic keypad subtexts for Russian & Ukrainian locales
CYRILLIC_SUBTEXTS_RU = {
    "2": "А Б В Г",
    "3": "Д Е Ж З",
    "4": "И Й К Л",
    "5": "М Н О П",
    "6": "Р С Т У",
    "7": "Ф Х Ц Ч",
    "8": "Ш Щ Ъ Ы",
    "9": "Ь Э Ю Я",
}

CYRILLIC_SUBTEXTS_UK = {
    "2": "А Б В Г",
    "3": "Д Е Ж З",
    "4": "І Ї Й К",
    "5": "Л М Н О",
    "6": "П Р С Т",
    "7": "У Ф Х Ц",
    "8": "Ч Ш Щ Ь",
    "9": "Ю Я",
}


# System locales supported for TelephonyUI passcode keypad caches
KEYPAD_LOCALES = [
    "en", "other", "ru", "uk", "es", "fr", "de", "it", "pt", "tr", "pl", "nl", "ja", "ko", "zh", "ar", "he"
]


def parse_passthm_archive(
    passthm_path: str,
    telephony_ver: str = "TelephonyUI-10",
    target_lang: str = "all",
    target_bold: str = "both"
) -> list[tuple[str, str, bytes]]:
    path = Path(passthm_path).expanduser()
    if not path.is_file():
        raise FileNotFoundError(f"Passcode theme file not found: {passthm_path}")

    with zipfile.ZipFile(path, "r") as z:
        image_entries = [
            n for n in z.namelist()
            if not n.startswith("__MACOSX")
            and not n.endswith("/")
            and not Path(n).name.startswith(".")
            and any(n.lower().endswith(ext) for ext in (".png", ".jpg", ".jpeg"))
        ]
        if not image_entries:
            return []

        # Support universal (TelephonyUI-8 + 9 + 10) or specific folder
        norm_ver = (telephony_ver or "TelephonyUI-10").strip()
        if norm_ver.lower() in ("all", "universal"):
            target_dirs = [
                "/var/mobile/Library/Caches/TelephonyUI-10",
                "/var/mobile/Library/Caches/TelephonyUI-9",
                "/var/mobile/Library/Caches/TelephonyUI-8",
            ]
        else:
            target_dirs = [f"/var/mobile/Library/Caches/{norm_ver}"]

        items_dict: dict[str, bytes] = {}
        # Each output name remembers how good a match its current image was, so
        # a better source always wins regardless of the order files sit in the
        # zip: a real key name beats a digit found somewhere in a file name, and
        # the matching weight beats an unstyled image, which beats the other
        # weight. Without this, a bold key's art overwrote the regular one (or the
        # reverse), and Wallpaper@3x.png became key 3.
        rank: dict[str, int] = {}

        def put(name: str, payload: bytes, score: int) -> None:
            if score >= rank.get(name, -1):
                if score > rank.get(name, -1) or name not in items_dict:
                    items_dict[name] = payload
                    rank[name] = score

        # Normalize target_lang & target_bold
        target_lang = (target_lang or "all").lower().strip()
        target_bold = (target_bold or "both").lower().strip()

        for entry in image_entries:
            leaf = Path(entry).name
            data = z.read(entry)

            stem = Path(leaf).stem
            # Which weight this image was drawn for, before the suffix goes.
            if re.search(r"-white-bold$", stem, flags=re.IGNORECASE):
                src_style = "bold"
            elif re.search(r"-white$", stem, flags=re.IGNORECASE):
                src_style = "regular"
            else:
                src_style = None
            stem_clean = re.sub(r"--?white(?:-bold)?$", "", stem, flags=re.IGNORECASE)
            m = re.search(r"^(?:([a-zA-Z]+)-)?([0-9*#])(?:-([^-\n]+))?", stem_clean)
            digit = None
            subtext = ""
            orig_lang = None
            exact = False
            if m:
                orig_lang = m.group(1)
                digit = m.group(2)
                exact = True
                if m.group(3):
                    subtext = m.group(3).strip()
            if not digit:
                # Last resort for keys named like key_1.png. A scale suffix is not
                # a key, and neither is anything that is plainly not a key.
                loose = re.sub(r"@\d+x$", "", stem, flags=re.IGNORECASE)
                if not re.search(r"wallpaper|background|cover|preview|thumb|icon|banner|screenshot|poster|\bbg\b",
                                 loose, flags=re.IGNORECASE):
                    m2 = re.search(r"([0-9*#])", loose)
                    if m2:
                        digit = m2.group(1)

            # Strip non-subtext keywords from subtext
            if subtext and subtext.lower() in ("bold", "regular", "white", "black", "light", "dark", "normal"):
                subtext = ""

            # If user requested universal (all + both), keep raw leaf
            if target_lang == "all" and target_bold == "both":
                put(leaf, data, 100)

            if digit:
                if target_lang == "all":
                    langs = list(KEYPAD_LOCALES)
                    if orig_lang and orig_lang.lower() not in langs:
                        langs.insert(0, orig_lang.lower())
                else:
                    # Put target_lang FIRST, other SECOND
                    langs = [target_lang]
                    if target_lang != "other":
                        langs.append("other")

                if target_bold == "bold":
                    bold_suffixes = ["-bold"]
                elif target_bold == "regular":
                    bold_suffixes = [""]
                else:
                    bold_suffixes = ["", "-bold"]

                std_subtext = KEYPAD_SUBTEXTS.get(digit)

                for lang in langs:
                    for bold_suffix in bold_suffixes:
                        slot = "bold" if bold_suffix else "regular"
                        style_score = 3 if src_style == slot else (2 if src_style is None else 1)
                        score = (20 if exact else 10) + style_score
                        # 1. Blank subtext variant (e.g. ru-5---white-bold.png)
                        put(f"{lang}-{digit}---white{bold_suffix}.png", data, score)

                        # 2. Standard Latin subtext (e.g. ru-5-J K L--white-bold.png)
                        if std_subtext:
                            put(f"{lang}-{digit}-{std_subtext}--white{bold_suffix}.png", data, score)
                            if " " in std_subtext:
                                put(f"{lang}-{digit}-{std_subtext.replace(' ', '')}--white{bold_suffix}.png", data, score)

                        # 3. Cyrillic subtexts for Russian & Ukrainian
                        if lang in ("ru", "all") and digit in CYRILLIC_SUBTEXTS_RU:
                            cyr_ru = CYRILLIC_SUBTEXTS_RU[digit]
                            put(f"{lang}-{digit}-{cyr_ru}--white{bold_suffix}.png", data, score)
                        if lang in ("uk", "all") and digit in CYRILLIC_SUBTEXTS_UK:
                            cyr_uk = CYRILLIC_SUBTEXTS_UK[digit]
                            put(f"{lang}-{digit}-{cyr_uk}--white{bold_suffix}.png", data, score)

                        # 4. Custom subtext variant if present in the source asset
                        if subtext:
                            put(f"{lang}-{digit}-{subtext}--white{bold_suffix}.png", data, score)

        res = []
        for tdir in target_dirs:
            for leaf, data in items_dict.items():
                res.append((tdir, leaf, data))
        return res


def detect_theme_version(names) -> str:
    """The newest TelephonyUI layout a theme provides.

    The first folder mentioning 9 or 8 used to decide it, so a theme carrying
    both 10 and 9 (every theme AirCard's own creator exports) read as 9, and on
    iOS 18 the keypad went where iOS 18 does not look.
    """
    found = set()
    for entry in names:
        low = entry.lower()
        for v in ("10", "9", "8"):
            if f"telephonyui-{v}" in low or f"telephony-{v}" in low:
                found.add(v)
    for v in ("10", "9", "8"):
        if v in found:
            return f"TelephonyUI-{v}"
    return "TelephonyUI-10"


def cmd_inspect_passthm(passthm_path: str):
    path = Path(passthm_path).expanduser()
    if not path.is_file():
        print(json.dumps({"ok": False, "error": f"File not found: {passthm_path}"}))
        return
    try:
        with zipfile.ZipFile(path, "r") as z:
            detected_ver = detect_theme_version(z.namelist())

        items = parse_passthm_archive(str(path), detected_ver)
        if not items:
            print(json.dumps({"ok": False, "error": "No image assets found in archive"}))
            return

        keys_preview = {}
        for _, leaf, data in items:
            m = re.search(r'^[a-zA-Z]+-([0-9*#])-?', leaf)
            digit = m.group(1) if m else None
            if not digit:
                m2 = re.search(r'([0-9*#])', leaf)
                if m2:
                    digit = m2.group(1)
            if digit and digit not in keys_preview:
                b64 = base64.b64encode(data).decode("utf-8")
                mime = "image/png" if leaf.lower().endswith(".png") else "image/jpeg"
                keys_preview[digit] = f"data:{mime};base64,{b64}"

        print(json.dumps({
            "ok": True,
            "name": path.stem,
            "detected_version": detected_ver,
            "file_count": len(items),
            "keys_preview": keys_preview
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


def cmd_flash_passthm(
    udid: str,
    passthm_path: str,
    telephony_ver: str = "TelephonyUI-10",
    target_lang: str = "all",
    target_bold: str = "both"
) -> bool:
    path = Path(passthm_path).expanduser()
    if not path.is_file():
        print(json.dumps({"ok": False, "type": "error", "code": "passthm.missing", "error": "Passcode theme file not found", "message": "Passcode theme file not found"}))
        return False

    try:
        items_to_write = parse_passthm_archive(str(path), telephony_ver, target_lang, target_bold)
        if not items_to_write:
            print(json.dumps({"ok": False, "type": "error", "code": "passthm.no_images", "error": "No image assets found in archive", "message": "No image assets found in archive"}))
            return False

        # Group items by target directory (e.g. /var/mobile/Library/Caches/TelephonyUI-10)
        items_by_dir: dict[str, list[tuple[str, bytes]]] = {}
        for tdir, leaf, payload in items_to_write:
            items_by_dir.setdefault(tdir, []).append((leaf, payload))

        # Check for marker files like _big or _small in the theme package
        try:
            with zipfile.ZipFile(path, "r") as z:
                for entry in z.namelist():
                    leaf_name = Path(entry).name
                    if leaf_name in ("_big", "_small") and not entry.endswith("/"):
                        marker_data = z.read(entry)
                        for tdir in items_by_dir:
                            if not any(leaf == leaf_name for leaf, _ in items_by_dir[tdir]):
                                items_by_dir[tdir].append((leaf_name, marker_data))
        except Exception:
            pass

        total_steps = sum(len(f) for f in items_by_dir.values())
        processed_files = 0

        print(json.dumps({
            "type": "progress",
            "step": 0,
            "total": total_steps,
            "message": f"Flashing passcode theme '{path.stem}' ({total_steps} assets)..."
        }))
        sys.stdout.flush()

        for tdir, dir_files in items_by_dir.items():
            tdir_name = Path(tdir).name
            base_step = processed_files

            def make_progress_handler(base: int):
                def on_atc_progress(p: dict):
                    idx = p.get("index", 0)
                    leaf = p.get("leaf", "")
                    curr = min(base + idx, total_steps)
                    print(json.dumps({
                        "type": "progress",
                        "step": curr,
                        "total": total_steps,
                        "leaf": leaf,
                        "message": f"Writing {leaf} ({curr}/{total_steps})..."
                    }))
                    sys.stdout.flush()
                return on_atc_progress

            print(json.dumps({
                "type": "progress",
                "step": base_step,
                "total": total_steps,
                "message": f"Flashing {len(dir_files)} asset(s) into {tdir_name}..."
            }))
            sys.stdout.flush()

            ok = write_files_batch(
                udid,
                tdir,
                dir_files,
                retries=3,
                progress_callback=make_progress_handler(base_step),
            )

            if not ok:
                # If batch failed, fallback to file-by-file write for this directory
                print(json.dumps({
                    "type": "warning",
                    "message": f"Batch write notice for {tdir_name}, falling back to file-by-file write..."
                }))
                sys.stdout.flush()

                failed_leaves = []
                for f_idx, (leaf, payload) in enumerate(dir_files, 1):
                    curr = base_step + f_idx
                    print(json.dumps({
                        "type": "progress",
                        "step": curr,
                        "total": total_steps,
                        "leaf": leaf,
                        "message": f"[Fallback] Writing {leaf} ({curr}/{total_steps})..."
                    }))
                    sys.stdout.flush()

                    single_ok = write_file(udid, tdir, leaf, payload, retries=3)
                    if not single_ok:
                        failed_leaves.append(leaf)
                    time.sleep(0.08)

                if failed_leaves:
                    print(json.dumps({
                        "type": "error",
                        "code": "passthm.write_failed",
                        "message": f"Could not write {len(failed_leaves)} file(s) in {tdir_name}: {', '.join(failed_leaves[:5])}"
                    }))
                    sys.stdout.flush()
                    return False

            processed_files += len(dir_files)

        print(json.dumps({
            "type": "success",
            "step": total_steps,
            "total": total_steps,
            "message": f"Passcode theme '{path.stem}' successfully applied! Lock your iPhone to check."
        }))
        sys.stdout.flush()
        return True

    except Exception as e:
        # A line the app can read. {"ok": false, "error": ...} alone was dropped
        # by the reader, which needs "message", so the reason never surfaced.
        print(json.dumps({"ok": False, "type": "error", "code": "passthm.failed", "error": str(e), "message": str(e)}))
        return False


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "No command provided"}))
        sys.exit(1)

    cmd = sys.argv[1]
    norm_cmd = cmd.lstrip("-")
    if norm_cmd == "device":
        cmd_device(sys.argv[2] if len(sys.argv) > 2 else None)
    elif norm_cmd == "devices":
        cmd_devices()
    elif norm_cmd == "cards":
        cmd_get_saved_cards()
    elif norm_cmd == "backups" and len(sys.argv) > 2:
        cmd_backups(sys.argv[2])
    elif norm_cmd == "backup" and len(sys.argv) > 3:
        if not cmd_backup(sys.argv[2], sys.argv[3]):
            sys.exit(1)
    elif norm_cmd == "discard-backup" and len(sys.argv) > 3:
        if not cmd_discard_backup(sys.argv[2], sys.argv[3]):
            sys.exit(1)
    elif norm_cmd == "restore" and len(sys.argv) > 3:
        if not cmd_restore(sys.argv[2], sys.argv[3]):
            sys.exit(1)
    elif norm_cmd == "save-cards" and len(sys.argv) > 2:
        cmd_save_cards(sys.argv[2])
    elif norm_cmd == "prepare-image" and len(sys.argv) > 3:
        cmd_prepare_image(sys.argv[2], sys.argv[3])
    elif norm_cmd == "flash" and len(sys.argv) > 4:
        if not cmd_flash(sys.argv[2], sys.argv[3], sys.argv[4]):
            sys.exit(1)
    elif norm_cmd == "inspect-passthm" and len(sys.argv) > 2:
        cmd_inspect_passthm(sys.argv[2])
    elif norm_cmd == "flash-passthm" and len(sys.argv) > 3:
        t_ver = sys.argv[4] if len(sys.argv) > 4 else "TelephonyUI-10"
        t_lang = sys.argv[5] if len(sys.argv) > 5 else "all"
        t_bold = sys.argv[6] if len(sys.argv) > 6 else "both"
        if not cmd_flash_passthm(sys.argv[2], sys.argv[3], t_ver, t_lang, t_bold):
            sys.exit(1)
    else:
        print(json.dumps({"error": f"Unknown command: {cmd}"}))
        sys.exit(1)


if __name__ == "__main__":
    main()
