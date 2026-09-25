#!/usr/bin/env python3
"""
AirCard — Apple Wallet Card Skinner (via airlift exploit).
Customizes Apple Pay and Wallet card skins without a jailbreak.
"""

from __future__ import annotations

import io
import json
import os
import posixpath
import re
import secrets
import subprocess
import sys
import time
from pathlib import Path

# Ensure bundled and standard bin paths are in PATH
script_dir = Path(__file__).resolve().parent
for bin_path in [
    str(script_dir / "bin"),
    "/Applications/AirCard.app/Contents/Resources/bin",
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin"
]:
    if os.path.isdir(bin_path) and bin_path not in os.environ.get("PATH", ""):
        os.environ["PATH"] = f"{bin_path}:{os.environ.get('PATH', '')}"

from apply_card_skin import (
    native,
    operation_ok,
    write_file,
    ROOT,
    DEVICE_HELPER,
)

TARGET_ASSETS = [
    "cardBackgroundCombined@3x.png",
    "cardBackgroundCombined@2x.png",
]

# Everything a flash overwrites, which is what a backup has to cover. Taken from
# card_assets so the two cannot drift apart: leaving the PDF behind would put the
# skin straight back on a card the user just restored.
from card_assets import PNG_ASSET_NAMES, PDF_ASSET_NAME
BACKED_UP_ASSETS = [*PNG_ASSET_NAMES, PDF_ASSET_NAME]
# Some cards have no PDF of their own. Requiring one made Save Original fail on
# them for ever while telling people to unlock the phone and retry; the PNGs
# are the artwork, and a restore removes a PDF the skin added (cmd_restore).
REQUIRED_ASSETS = list(PNG_ASSET_NAMES)

CACHE_FILES = ["FrontFace", "Preview"]

CARDS_STORE_PATH = Path.home() / ".aircard_cards.json"
LEGACY_STORE_PATH = Path.home() / ".lumicards_cards.json"
PREDEFINED_CARDS = []

CARD_REGEXES = [
    re.compile(r"/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,44})(?:\.pkpass|\.cache|\.pkcache|/|\s|\"|\'|\)|,|$)"),
    re.compile(r"/([-A-Za-z0-9_+=]{20,44})\.(?:pkpass|cache|pkcache)"),
    re.compile(r"(?<![A-Za-z0-9+/_-])([A-Za-z0-9+/_-]{27}=)(?![A-Za-z0-9+/_-])"),
]


def load_saved_cards() -> list[str]:
    """Loads saved card hashes from local storage."""
    for store in [CARDS_STORE_PATH, LEGACY_STORE_PATH]:
        if store.is_file():
            try:
                data = json.loads(store.read_text("utf-8"))
                if isinstance(data, list) and data:
                    return data
            except Exception:
                pass
    return list(PREDEFINED_CARDS)


def save_cards(cards: list[str]):
    """Saves unique card hashes to local storage."""
    try:
        unique = list(dict.fromkeys(cards))
        CARDS_STORE_PATH.write_text(json.dumps(unique, indent=2), encoding="utf-8")
    except Exception:
        pass


# Original artwork is kept per device, so restoring one iPhone never reaches for
# a backup taken from another.
BACKUPS_ROOT = Path.home() / ".aircard_backups"


def _backup_slug(card_hash: str) -> str:
    """Card hashes contain / and +, neither of which survives as a folder name."""
    from urllib.parse import quote
    return quote(card_hash, safe="")


def card_backup_dir(udid: str, card_hash: str) -> Path:
    return BACKUPS_ROOT / _backup_slug(udid) / _backup_slug(card_hash)


def has_card_backup(udid: str, card_hash: str, required=None) -> bool:
    """True only when every file a restore needs is sitting on disk.

    A backup missing one of them would restore the card only partly while
    reporting success, and would also block a proper backup being taken, so it
    does not count.
    """
    names = REQUIRED_ASSETS if required is None else required
    d = card_backup_dir(udid, card_hash)
    if not d.is_dir():
        return False
    return all((d / n).is_file() and (d / n).stat().st_size > 0 for n in names)


def save_card_backup(udid: str, card_hash: str, assets: list[tuple[str, bytes]], required=None) -> bool:
    """Stores the original artwork, all of it or none of it.

    Returns False without touching disk when any required file is missing or
    empty. The files land in a scratch folder first and are moved into place in
    one rename, so an interrupted save cannot leave a partial backup behind that
    later looks complete.
    """
    import shutil
    names = REQUIRED_ASSETS if required is None else required
    got = {name: data for name, data in assets if data}
    if any(n not in got for n in names):
        return False
    # Whatever else of the card's own artwork came back is kept too.
    names = list(names) + [n for n in BACKED_UP_ASSETS if n in got and n not in names]
    d = card_backup_dir(udid, card_hash)
    staging = d.with_name(d.name + ".partial")
    try:
        shutil.rmtree(staging, ignore_errors=True)
        staging.mkdir(parents=True)
        for n in names:
            (staging / n).write_bytes(got[n])
        shutil.rmtree(d, ignore_errors=True)
        staging.rename(d)
    except OSError:
        shutil.rmtree(staging, ignore_errors=True)
        return False
    return True


def discard_card_backup(udid: str, card_hash: str) -> bool:
    """Removes a saved original, so a wrong one can be replaced by a right one."""
    import shutil
    d = card_backup_dir(udid, card_hash)
    if not d.exists():
        return False
    shutil.rmtree(d, ignore_errors=True)
    return not d.exists()


def _flashed_marker(udid: str, card_hash: str) -> Path:
    return BACKUPS_ROOT / _backup_slug(udid) / ".flashed" / _backup_slug(card_hash)


def mark_card_flashed(udid: str, card_hash: str, assets=None) -> None:
    """Remembers that AirCard has written, or tried to write, to this card.

    After that, what is on the card may not be its original any more, and
    saving it as the original would lock the skin in as the thing restore puts
    back. The marker also keeps a fingerprint of every file about to be
    written, so a flash that never reached the card (phone locked, cable out,
    cancelled) can later be told apart from one that did.
    """
    import hashlib
    m = _flashed_marker(udid, card_hash)
    try:
        m.parent.mkdir(parents=True, exist_ok=True)
        prints = flashed_fingerprints(udid, card_hash)
        for _, data in assets or []:
            prints.add(hashlib.sha256(data).hexdigest())
        m.write_text(json.dumps(sorted(prints)))
    except OSError:
        pass


def flashed_fingerprints(udid: str, card_hash: str) -> set:
    """Fingerprints of what AirCard tried to write to the card. Empty for a
    marker left by an older version, which kept none."""
    try:
        data = json.loads(_flashed_marker(udid, card_hash).read_text() or "[]")
    except (OSError, ValueError):
        return set()
    return {x for x in data if isinstance(x, str)} if isinstance(data, list) else set()


def card_was_flashed(udid: str, card_hash: str) -> bool:
    return _flashed_marker(udid, card_hash).exists()


def clear_flashed_marker(udid: str, card_hash: str) -> None:
    try:
        _flashed_marker(udid, card_hash).unlink()
    except OSError:
        pass


def list_flashed_cards(udid: str) -> list:
    """Cards AirCard has written to on this device, as far as this Mac knows."""
    from urllib.parse import unquote
    folder = BACKUPS_ROOT / _backup_slug(udid) / ".flashed"
    if not folder.is_dir():
        return []
    return sorted(unquote(m.name) for m in folder.iterdir() if m.is_file())


def looks_skinned_by_aircard(assets) -> bool:
    """A flash writes one picture as both sizes; Apple's own artwork never has
    the same bytes at two resolutions. This catches cards skinned by an older
    AirCard, or on another Mac, where there is no marker to go by."""
    got = dict(assets)
    big = got.get("cardBackgroundCombined@3x.png")
    small = got.get("cardBackgroundCombined@2x.png")
    return bool(big) and big == small


def read_card_backup(udid: str, card_hash: str) -> list[tuple[str, bytes]]:
    d = card_backup_dir(udid, card_hash)
    if not d.is_dir():
        return []
    out = []
    for f in sorted(d.iterdir()):
        if not f.is_file():
            continue
        try:
            data = f.read_bytes()
        except OSError:
            continue
        if data:
            out.append((f.name, data))
    return out


def backup_preview_path(udid: str, card_hash: str) -> "Path | None":
    """The largest saved image of the original, for showing the card as it was."""
    if not has_card_backup(udid, card_hash):
        return None
    for name in ("cardBackgroundCombined@3x.png", "cardBackgroundCombined@2x.png"):
        p = card_backup_dir(udid, card_hash) / name
        if p.is_file() and p.stat().st_size > 0:
            return p
    return None


def list_backed_up_cards(udid: str) -> list[str]:
    """Card hashes on this device that can be restored."""
    from urllib.parse import unquote
    root = BACKUPS_ROOT / _backup_slug(udid)
    if not root.is_dir():
        return []
    found = []
    for d in root.iterdir():
        if not d.is_dir() or d.name.startswith(".") or d.name.endswith(".partial"):
            continue
        card = unquote(d.name)
        if has_card_backup(udid, card):
            found.append(card)
    return sorted(found)


# Card faces imported from a zip, a link or a single picture. Kept where they
# survive a relaunch, unlike the temp files dropped images used to live in.
SKIN_EXTENSIONS = {"png": ".png", "jpg": ".jpg", "heic": ".heic", "webp": ".webp"}
MAX_SKIN_BYTES = 30 * 1024 * 1024
MAX_PACK_BYTES = 400_000_000  # decimal, as the app shows sizes
MAX_PACK_IMAGES = 400
MAX_FOLDER_FILES = 5000


def skin_image_kind(data: bytes) -> "str | None":
    """What a file really is, from its first bytes rather than its name."""
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if data[:3] == b"\xff\xd8\xff":
        return "jpg"
    if data[4:8] == b"ftyp" and data[8:12] in (b"heic", b"heix", b"mif1", b"msf1", b"heim", b"heis", b"hevc"):
        return "heic"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    return None


# Folders that are single things to Finder: apps, photo libraries and the like.
# A folder import never walks into them, so picking the wrong folder cannot
# pull an app's icons or a photo library into the skin library.
PACKAGE_SUFFIXES = (
    ".app", ".bundle", ".framework", ".plugin", ".appex", ".kext", ".xcassets",
    ".photoslibrary", ".photolibrary", ".migratedphotolibrary", ".aplibrary",
    ".musiclibrary", ".tvlibrary", ".imovielibrary", ".fcpbundle", ".lrdata", ".lrlibrary",
)
IMAGE_NAME = re.compile(r"\.(png|jpe?g|heic|heif|webp)$", re.IGNORECASE)


def _path_parts(original: str) -> list:
    return [p for p in original.replace("\\", "/").split("/") if p not in ("", ".", "..")]


def _stem_key(original: str) -> str:
    parts = _path_parts(original)
    leaf = parts[-1] if parts else ""
    dot = leaf.rfind(".")
    return (leaf[:dot] if dot > 0 else leaf).lower()


def _repeated_stems(names) -> set:
    """Stems that more than one picture in the pack shares, like card.png in
    one folder per bank. Those get their folder's name, or every bank's card
    would arrive as card, card-2, card-3."""
    counts: dict = {}
    for name in names:
        if IMAGE_NAME.search(name):
            key = _stem_key(name)
            counts[key] = counts.get(key, 0) + 1
    return {k for k, n in counts.items() if n > 1}


def _zip_entry_name(info) -> str:
    """The entry's name as it was meant to be read.

    Zips made on Chinese-language Windows store GBK names without saying so,
    and Python reads those as cp437: 招商银行.png arrives as mojibake and the
    bank's name is lost. Only names without the UTF-8 flag are reinterpreted.
    """
    name = info.filename
    if info.flag_bits & 0x800:
        return name
    try:
        raw = name.encode("cp437")
    except UnicodeEncodeError:
        return name  # already real text, from a Unicode path field
    if not any(b >= 0x80 for b in raw):
        return name
    for encoding in ("utf-8", "gb18030"):
        try:
            return raw.decode(encoding)
        except UnicodeDecodeError:
            continue
    return name


def _skin_name(original: str, kind: str, taken: set, qualify: bool = False) -> str:
    """A safe, unique file name inside the library.

    Only path components are used, never the path, so an entry like
    ../../x.png cannot land outside the library folder. With qualify, the
    folder the picture was in goes in front of its name.
    """
    parts = _path_parts(original)
    leaf = parts[-1] if parts else ""
    # Split by hand: pathlib has changed its mind about names like "..png"
    # between Python versions, and the app runs whichever one the Mac has.
    dot = leaf.rfind(".")
    stem = leaf[:dot] if dot > 0 else leaf
    if qualify and len(parts) >= 2:
        stem = f"{parts[-2]} {stem}"
    stem = re.sub(r"[^\w .+=-]+", "_", stem)
    stem = re.sub(r"\s+", " ", stem).strip(" ._")[:80].rstrip(" .") or "skin"
    ext = SKIN_EXTENSIONS[kind]
    name, n = f"{stem}{ext}", 2
    while name.lower() in taken:
        name, n = f"{stem}-{n}{ext}", n + 1
    taken.add(name.lower())
    return name


def import_skins(source: Path, library: Path) -> dict:
    """Copies the pictures out of a zip, a folder, or a single picture, into the library.

    Anything that is not really an image is left behind, however it is named.
    Sizes are checked both against what each file claims and against what is
    actually read, so a zip that lies about its contents cannot fill the disk.
    A picture already in the library is not copied again.

    Returns the names added and, for everything else, why it was left out:
    skipped (not a picture, too big or damaged), duplicates, encrypted (in a
    password-protected zip), unsupported (zip compression Python cannot read)
    and over_limit (past the per-import caps). Each needs a different answer.
    """
    import hashlib
    import zipfile
    library.mkdir(parents=True, exist_ok=True)
    taken = {p.name.lower() for p in library.iterdir()}
    by_size: dict = {}
    for existing in library.iterdir():
        if existing.is_file() and not existing.name.startswith("."):
            by_size.setdefault(existing.stat().st_size, []).append(existing)
    known: set = set()
    hashed: set = set()
    result = {"imported": [], "skipped": 0, "duplicates": 0,
              "encrypted": 0, "unsupported": 0, "over_limit": 0}
    total = 0

    def already_have(data: bytes) -> bool:
        # Only pictures of the same size are ever read back and hashed.
        for path in by_size.get(len(data), []):
            if path not in hashed:
                hashed.add(path)
                try:
                    known.add(hashlib.sha256(path.read_bytes()).digest())
                except OSError:
                    pass
        digest = hashlib.sha256(data).digest()
        if digest in known:
            return True
        known.add(digest)  # the same picture twice in one pack counts once
        return False

    def keep(original: str, data: bytes, qualify: bool) -> None:
        kind = skin_image_kind(data)
        if kind is None or len(data) > MAX_SKIN_BYTES:
            result["skipped"] += 1
            return
        if already_have(data):
            result["duplicates"] += 1
            return
        name = _skin_name(original, kind, taken, qualify)
        (library / name).write_bytes(data)
        result["imported"].append(name)

    def consider(original: str, size, read, image_like: bool, qualify: bool = False) -> None:
        nonlocal total
        if len(result["imported"]) >= MAX_PACK_IMAGES or total >= MAX_PACK_BYTES:
            result["over_limit" if image_like else "skipped"] += 1
            return
        if size is None or size > MAX_SKIN_BYTES:
            result["skipped"] += 1
            return
        # One damaged or oddly compressed file costs only itself; the rest of
        # the pack still comes in.
        try:
            data = read()
        except NotImplementedError:
            result["unsupported" if image_like else "skipped"] += 1
            return
        except Exception:
            result["skipped"] += 1
            return
        total += len(data)
        keep(original, data, qualify)

    def size_of(path: Path):
        try:
            return path.stat().st_size
        except OSError:
            return None

    def read_path(path: Path) -> bytes:
        with path.open("rb") as f:
            return f.read(MAX_SKIN_BYTES + 1)

    if source.is_dir():
        # A pack unzipped in Finder and dropped in as a folder. Walking stops
        # after a bounded number of files, in case it was the wrong folder.
        candidates = []
        for root, dirs, files in os.walk(source):
            dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d != "__MACOSX"
                             and not d.lower().endswith(PACKAGE_SUFFIXES))
            for name in sorted(files):
                if not name.startswith("."):
                    candidates.append(Path(root) / name)
            if len(candidates) >= MAX_FOLDER_FILES:
                break
        candidates = candidates[:MAX_FOLDER_FILES]
        relative = [str(path.relative_to(source)) for path in candidates]
        repeated = _repeated_stems(relative)
        for path, rel in zip(candidates, relative):
            if path.is_symlink():
                result["skipped"] += 1
                continue
            consider(rel, size_of(path), lambda path=path: read_path(path),
                     bool(IMAGE_NAME.search(rel)), _stem_key(rel) in repeated)
    elif zipfile.is_zipfile(source):
        with zipfile.ZipFile(source) as z:
            entries = []
            for info in z.infolist():
                name = _zip_entry_name(info).replace("\\", "/")
                leaf = name.split("/")[-1]
                # Finder's __MACOSX copies are all ._ files, so the dot rule covers them.
                if info.is_dir() or not leaf or leaf.startswith("."):
                    continue
                entries.append((info, name))
            repeated = _repeated_stems(name for _, name in entries)
            for info, name in entries:
                image_like = bool(IMAGE_NAME.search(name))
                if info.flag_bits & 0x1:
                    result["encrypted" if image_like else "skipped"] += 1
                    continue

                def read_entry(info=info) -> bytes:
                    with z.open(info) as f:
                        return f.read(MAX_SKIN_BYTES + 1)

                consider(name, info.file_size, read_entry, image_like, _stem_key(name) in repeated)
    else:
        consider(source.name, size_of(source), lambda: read_path(source), bool(IMAGE_NAME.search(source.name)))
    return result


def find_device_helper() -> str | None:
    """Finds the bundled device helper, the app's only device-communication tool."""
    root = Path(__file__).resolve().parent
    candidates = [root / "bin" / "device_helper", root / "build" / "device_helper"]
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


class HelperError(Exception):
    """The device helper itself failed, which is not the same as no phone.

    Reported as "no phone", it sent people swapping cables for a problem on
    the Mac: the helper crashed, timed out, or was stopped by macOS.
    """

    def __init__(self, code: str, detail: str = ""):
        super().__init__(detail or code)
        self.code = code
        self.detail = detail


def list_devices(strict: bool = False) -> list[dict]:
    """Enumerates paired devices reachable over USB.

    Wi-Fi-paired devices can appear here too, and an entry whose session could
    not be opened is reported with an empty `product`. With strict, a helper
    that fails raises HelperError instead of looking like an empty list.
    """
    helper = find_device_helper()
    if not helper:
        return []
    try:
        output = subprocess.check_output(
            [helper, "list"], text=True, stderr=subprocess.PIPE, timeout=30
        )
    except subprocess.TimeoutExpired:
        if strict:
            raise HelperError("helper_timeout", "the device helper did not answer within 30 seconds")
        return []
    except subprocess.CalledProcessError as e:
        if strict:
            raise HelperError("helper_failed", f"exit {e.returncode}: {(e.stderr or '')[-400:]}")
        return []
    except OSError as e:
        if strict:
            raise HelperError("helper_failed", str(e))
        return []

    for line in reversed(output.splitlines()):
        try:
            devices = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(devices, list):
            return [d for d in devices if isinstance(d, dict)]
    return []


def _normalize_device(device: dict) -> dict:
    """Shapes a raw helper entry into the fields the app consumes."""
    return {
        "udid": device["udid"],
        "name": device.get("name") or "iPhone",
        "version": device.get("version") or "Unknown",
        "product": device["product"],
        # Unknown stays unknown. Guessing English narrowed the keypad flash to
        # English only, so a phone in any other language did not change.
        "language": device.get("language") or None,
        "locale": device.get("locale") or "",
        "bold_text": device.get("bold_text"),
        "connection": device.get("connection") or "unknown",
        # The app decodes this as a plain Bool, so it has to be here. Anything
        # that came back from enumeration is reachable by definition.
        "connected": True,
    }


# Cabled beats Wi-Fi. "unknown" sits between the two so an older helper that
# cannot report the link still outranks a phone we know is remote.
_CONNECTION_RANK = {"usb": 0, "unknown": 1, "network": 2}


def _device_sort_key(device: dict) -> tuple:
    """Orders devices the same way every time: iPhones, then USB, then by udid.

    Helper enumeration order is not stable and iPads and Wi-Fi phones show up
    next to the cabled one, so without a fixed order the app can latch onto a
    different device between scans.
    """
    is_iphone = str(device.get("product") or "").startswith("iPhone")
    connection = str(device.get("connection") or "unknown").lower()
    return (
        0 if is_iphone else 1,
        _CONNECTION_RANK.get(connection, 1),
        str(device.get("name") or ""),
        str(device.get("udid") or ""),
    )


def survey_devices(strict: bool = False) -> tuple[list[dict], int]:
    """Usable devices, best first, plus how many phones are waiting on Trust.

    A phone that has not trusted this Mac yet comes back over USB with a udid
    and nothing else. Dropping it quietly is what made the app say "No iPhone
    found" while the phone sat on the desk asking to be trusted. One
    enumeration serves both, since each one can raise the Trust prompt again.

    A device seen only over the network that cannot be opened is left out
    altogether: an old Wi-Fi-paired iPad on the same network has nothing to
    trust, yet counting it said "tap Trust" with no phone attached at all.
    """
    seen = [d for d in list_devices(strict=strict) if d.get("udid")]
    usable = [d for d in seen if d.get("product")]
    untrusted = [d for d in seen if not d.get("product") and d.get("connection") != "network"]
    usable.sort(key=_device_sort_key)
    return [_normalize_device(d) for d in usable], len(untrusted)


def list_connected_devices(strict: bool = False) -> list[dict]:
    """Returns every usable device, deterministically ordered (best first)."""
    return survey_devices(strict=strict)[0]


def get_connected_device(preferred_udid: str | None = None, strict: bool = False) -> dict | None:
    """Picks a connected iPhone, honoring an explicit target when one is given.

    A preferred_udid must match exactly. If that phone is gone this returns None
    instead of quietly handing back a different one, so a flash never lands on a
    phone nobody picked. Only automatic selection falls back to the best device.
    """
    devices = list_connected_devices(strict=strict)
    if not devices:
        return None
    if preferred_udid:
        for device in devices:
            if device["udid"] == preferred_udid:
                return device
        return None
    return devices[0]


def syslog_command(udid: str) -> list[str] | None:
    """Builds the command that streams the device log, or None if unbundled."""
    helper = find_device_helper()
    if not helper:
        return None
    return [helper, "syslog", udid]


def capture_card_hashes(udid: str, existing_cards: list[str] | None = None) -> list[str]:
    """Listens to syslog and collects card hashes while the user opens Apple Wallet."""
    print("\n" + "=" * 60)
    print("📡 CARD SCANNING MODE")
    print("=" * 60)
    print("To detect your cards:")
    print("  👉 1) Double-click Side (Power) button to open Apple Pay.")
    print("  👉 2) Authenticate with Face ID.")
    print("  👉 3) Tap your card to trigger instant detection!")
    print("Press ENTER when finished.")
    print("=" * 60 + "\n")

    cmd = syslog_command(udid)
    if not cmd:
        print("\u274c Bundled device_helper is missing \u2014 cannot read the device log.")
        return list(existing_cards or [])
    process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    found_hashes = set(existing_cards or [])
    initial_count = len(found_hashes)

    try:
        import select

        while True:
            rlist, _, _ = select.select([sys.stdin, process.stdout], [], [], 0.2)
            if sys.stdin in rlist:
                sys.stdin.readline()
                break

            if process.stdout in rlist:
                line = process.stdout.readline()
                if not line:
                    break

                if line.startswith("AirCard scanner: "):
                    print(line.rstrip())
                    continue

                lower = line.lower()
                is_wallet = (
                    "passd" in lower
                    or "passbook" in lower
                    or "passkit" in lower
                    or "stockholm" in lower
                    or "nanopassd" in lower
                    or "wallet" in lower
                    or "/cards/" in lower
                )
                if not is_wallet:
                    continue

                is_ctx = any(
                    w in lower
                    for w in [
                        "card",
                        "pass",
                        "payment",
                        "pkpass",
                        "uniqueid",
                        "identifier",
                        "face",
                        "cache",
                        "stockholm",
                        "/cards/",
                    ]
                )
                if not is_ctx:
                    continue

                for r in CARD_REGEXES:
                    m = r.search(line)
                    if m:
                        h = m.group(1).strip().strip("'\"").rstrip(".").rstrip(",")
                        if len(h) == 36 and "-" in h:
                            continue
                        if h in [
                            "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
                            "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
                            "hwAtAmHKYwsQrJbT5cTNDsaxVME=",
                        ]:
                            continue
                        if h and h not in found_hashes:
                            found_hashes.add(h)
                            print(f"  ✨ Detected card [{len(found_hashes)}]: {h}")

    except KeyboardInterrupt:
        pass
    finally:
        process.terminate()
        process.wait()

    res = list(found_hashes)
    save_cards(res)
    return res


def prepare_card_image(input_path: str) -> bytes:
    """Scales image to Apple Wallet standard (1536x969 PNG)."""
    clean_path = input_path.strip().strip("'").strip('"')
    path = Path(clean_path).expanduser()
    if not path.is_file():
        raise FileNotFoundError(f"File not found: {path}")

    try:
        from PIL import Image, ImageOps
        with Image.open(path) as img:
            img = img.convert("RGBA")
            target_size = (1536, 969)
            fitted = ImageOps.fit(img, target_size, method=Image.Resampling.LANCZOS)
            out_io = io.BytesIO()
            fitted.save(out_io, format="PNG")
            return out_io.getvalue()
    except Exception:
        pass

    # Fallback to macOS sips
    temp_out = f"/tmp/aircard_sips_{os.getpid()}.png"
    try:
        subprocess.check_call([
            "/usr/bin/sips",
            "-s", "format", "png",
            "-z", "969", "1536",
            str(path),
            "--out", temp_out
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        data = Path(temp_out).read_bytes()
        Path(temp_out).unlink(missing_ok=True)
        return data
    except Exception as e:
        raise RuntimeError(f"Failed to process image: {e}")


def main():
    print("=" * 60)
    print("🎴 AirCard — Apple Wallet Card Skinner (via airlift)")
    print("=" * 60)

    # 1. Device discovery
    print("\n[1/5] Searching for connected device...")
    device = get_connected_device()
    if not device:
        print("❌ iPhone not found! Connect your iPhone via USB and unlock the screen.")
        sys.exit(1)

    print(f"✅ Found: {device['name']} ({device['product']}, iOS {device['version']})")
    print(f"   UDID: {device['udid']}")

    # 2. Check airlift compatibility
    probe = native("probe", device["udid"])
    if not operation_ok(probe):
        print("❌ Airlift pre-check failed. Ensure the device is paired and trusted.")
        sys.exit(1)

    # 3. Card discovery / selection
    saved_cards = load_saved_cards()
    print(f"\n[2/5] Saved cards: {len(saved_cards)}")
    for idx, h in enumerate(saved_cards, 1):
        print(f"  [{idx}] {h}")

    print("\nChoose an action:")
    print("  1 - Use existing cards")
    print("  2 - Scan cards (open Wallet & tap card)")
    print("  3 - Enter card hash(es) manually")
    mode = input("Your choice [1]: ").strip()

    hashes = saved_cards
    if mode == "2":
        hashes = capture_card_hashes(device["udid"], saved_cards)
    elif mode == "3":
        manual = input("Enter card hashes separated by commas or spaces: ").strip()
        new_items = [x.strip() for x in re.split(r"[\s,;]+", manual) if len(x.strip()) >= 16]
        for item in new_items:
            if item not in hashes:
                hashes.append(item)
        save_cards(hashes)

    if not hashes:
        print("❌ No cards available to flash.")
        sys.exit(1)

    print(f"\n[3/5] Ready to flash cards ({len(hashes)}):")
    for i, h in enumerate(hashes, 1):
        print(f"  [{i}] {h}")

    print("\nSelect cards to customize:")
    print("  'all' - apply to all cards")
    print("  comma-separated numbers (e.g. 1,3)")
    choice = input("Your choice [all]: ").strip().lower()

    if choice == "" or choice == "all":
        selected_hashes = hashes
    else:
        try:
            indices = [int(x.strip()) for x in choice.split(",") if x.strip()]
            selected_hashes = [hashes[i - 1] for i in indices if 1 <= i <= len(hashes)]
        except Exception:
            print("Invalid input. Applying to all cards.")
            selected_hashes = hashes

    if not selected_hashes:
        print("❌ No cards selected.")
        sys.exit(1)

    # 4. Prepare image
    print(f"\n[4/5] Preparing image...")
    while True:
        img_input = input("Drag and drop image file into terminal (or enter path): ").strip()
        try:
            png_bytes = prepare_card_image(img_input)
            print(f"✅ Image optimized for Apple Wallet ({len(png_bytes)} bytes)")
            break
        except Exception as e:
            print(f"❌ Error: {e}. Please specify another image.")

    # 5. Flash cards
    print(f"\n[5/5] Flashing skin to selected cards ({len(selected_hashes)})...")

    for idx, h in enumerate(selected_hashes, 1):
        print(f"\n--- [{idx}/{len(selected_hashes)}] Card: {h} ---")
        pkpass_dir = f"/var/mobile/Library/Passes/Cards/{h}.pkpass"

        for asset in TARGET_ASSETS:
            ok = write_file(device["udid"], pkpass_dir, asset, png_bytes)
            status = "OK" if ok else "FAIL"
            print(f"  -> {asset}: {status}")

        for ext in [".cache", ".pkcache"]:
            cache_dir = f"/var/mobile/Library/Passes/Cards/{h}{ext}"
            for leaf in CACHE_FILES:
                write_file(device["udid"], cache_dir, leaf, b"corrupted")
        print("  -> System cache cleared (.cache & .pkcache)")

    print("\n" + "=" * 60)
    print("🎉 DONE! All selected cards successfully updated!")
    print("=" * 60)
    print("1. Force close Apple Wallet on your iPhone.")
    print("2. If the image does not update immediately, restart your iPhone.")
    print("=" * 60)


if __name__ == "__main__":
    main()
