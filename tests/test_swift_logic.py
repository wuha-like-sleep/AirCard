"""Exercises pure Swift logic from AirCardApp.swift without a Swift test target.

The app is one file built with raw swiftc, so there is nowhere to hang XCTest.
Instead each check lifts the exact source of one type or function out of
AirCardApp.swift, compiles it next to a small driver, and runs it. The code
under test is never copied by hand, so these cannot drift from what ships.
"""

import platform
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SWIFT_SOURCE = REPO / "AirCardApp.swift"


def lift(pattern: str) -> str:
    """The first block of AirCardApp.swift matching pattern, verbatim."""
    src = SWIFT_SOURCE.read_text(encoding="utf-8")
    m = re.search(pattern, src, re.S | re.M)
    if not m:
        raise AssertionError(f"could not find {pattern!r} in AirCardApp.swift")
    return m.group(1)


def run_swift(sources: dict, timeout: int = 180) -> str:
    """Compile the given files into one binary, run it, return stdout."""
    sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                         capture_output=True, text=True, check=True).stdout.strip()
    with tempfile.TemporaryDirectory() as tmp:
        paths = []
        for name, body in sources.items():
            p = Path(tmp) / name
            p.write_text(body, encoding="utf-8")
            paths.append(str(p))
        binary = Path(tmp) / "run"
        # Built for the machine running the tests. A fixed arm64 target compiled
        # fine on an Intel Mac and then could not be run there.
        arch = "arm64" if platform.machine() == "arm64" else "x86_64"
        build = subprocess.run(
            ["swiftc", "-sdk", sdk, "-target", f"{arch}-apple-macosx14.0", *paths, "-o", str(binary)],
            capture_output=True, text=True, timeout=timeout,
        )
        if build.returncode != 0:
            raise AssertionError("driver did not compile:\n" + build.stderr[-2000:])
        result = subprocess.run([str(binary), tmp], capture_output=True, text=True, timeout=timeout)
        if result.returncode != 0:
            raise AssertionError(result.stdout + result.stderr)
        return result.stdout


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "needs swiftc on macOS")
class CardFaceDesignTests(unittest.TestCase):
    """What the designer previews is what it renders, including drag direction."""

    def test_render_matches_the_preview(self):
        design = lift(r"(struct CardFaceDesign \{.*?\n\})\n")
        driver = textwrap.dedent('''
            import AppKit
            import SwiftUI

            // Red on top, blue below, twice the card's height: centred, the
            // boundary sits exactly on the card's vertical midpoint.
            func source() -> NSImage {
                let img = NSImage(size: NSSize(width: 1536, height: 1938))
                img.lockFocus()
                NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 1536, height: 969).fill()
                NSColor.red.setFill();  NSRect(x: 0, y: 969, width: 1536, height: 969).fill()
                img.unlockFocus()
                return img
            }
            func colour(_ image: NSImage, fromTop f: Double) -> String {
                let rep = image.representations.first as! NSBitmapImageRep
                let c = rep.colorAt(x: rep.pixelsWide / 2, y: Int(Double(rep.pixelsHigh) * f))!
                    .usingColorSpace(.deviceRGB)!
                if c.redComponent > 0.5 && c.blueComponent < 0.5 { return "red" }
                if c.blueComponent > 0.5 { return "blue" }
                return c.redComponent < 0.1 && c.greenComponent < 0.1 ? "black" : "other"
            }
            var failures: [String] = []
            func expect(_ what: String, _ got: String, _ want: String) {
                if got != want { failures.append("\\(what): got \\(got), want \\(want)") }
            }

            var d = CardFaceDesign(source: source())
            let centred = d.render()!
            let rep = centred.representations.first as! NSBitmapImageRep
            expect("size", "\\(rep.pixelsWide)x\\(rep.pixelsHigh)", "1536x969")
            expect("centred, 30% down", colour(centred, fromTop: 0.30), "red")
            expect("centred, 70% down", colour(centred, fromTop: 0.70), "blue")

            // Dragging down in the preview must move the picture down on the card.
            d.offset = CGSize(width: 0, height: 0.1)
            expect("dragged down, 60% down", colour(d.render()!, fromTop: 0.60), "red")
            d.offset = CGSize(width: 0, height: -0.1)
            expect("dragged up, 40% down", colour(d.render()!, fromTop: 0.40), "blue")

            // Zoomed out, the background shows at the edge.
            d = CardFaceDesign(source: source(), zoom: 0.5, background: .black)
            let small = d.render()!.representations.first as! NSBitmapImageRep
            let edge = small.colorAt(x: 10, y: small.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
            expect("zoomed out, left edge", edge.redComponent < 0.1 && edge.blueComponent < 0.1 ? "black" : "other", "black")

            if failures.isEmpty { print("ok") } else { print(failures.joined(separator: "\\n")); exit(1) }
        ''')
        out = run_swift({"design.swift": "import AppKit\nimport SwiftUI\n\n" + design, "main.swift": driver})
        self.assertEqual(out.strip(), "ok")


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "needs swiftc on macOS")
class BackendStartupTests(unittest.TestCase):
    """The interpreter probe and the failure diagnosis behind the setup errors."""

    def _lifted(self) -> str:
        probe = lift(r"(    nonisolated static func firstWorkingPython\(.*?\n    \}\n)")
        kinds = lift(r"(    enum BackendFailure: Equatable \{.*?\n    \}\n)")
        diagnose = lift(r"(    nonisolated static func diagnoseBackendFailure\(.*?\n    \}\n)")
        body = (probe + "\n" + kinds + "\n" + diagnose).replace("nonisolated ", "")
        return "import Foundation\n\nenum AppViewModel {\n" + body + "}\n"

    def test_probe_skips_interpreters_that_cannot_run(self):
        real = shutil.which("python3")
        self.assertIsNotNone(real, "needs a python3 on PATH to act as the working interpreter")
        driver = textwrap.dedent(f'''
            import Foundation
            let dir = CommandLine.arguments[1]
            func shim(_ name: String, _ script: String) -> String {{
                let path = dir + "/" + name
                try! script.write(toFile: path, atomically: true, encoding: .utf8)
                chmod(path, 0o755)
                return path
            }}
            // Stands in for /usr/bin/python3 when the Xcode licence was never accepted.
            let licence = shim("licence", "#!/bin/sh\\necho 'You have not agreed to the Xcode license agreements.' >&2\\nexit 69\\n")
            // Stands in for the shim sitting on the Command Line Tools install prompt.
            let hang = shim("hang", "#!/bin/sh\\nsleep 60\\n")
            let real = "{real}"
            var failures: [String] = []
            func expect(_ what: String, _ got: String?, _ want: String?) {{
                if got != want {{ failures.append("\\(what): got \\(got ?? "nil"), want \\(want ?? "nil")") }}
            }}
            expect("blocked shim first", AppViewModel.firstWorkingPython(in: [licence, real]), real)
            expect("hanging shim first", AppViewModel.firstWorkingPython(in: [hang, real], timeout: 1), real)
            expect("nothing works", AppViewModel.firstWorkingPython(in: [licence]), nil)
            expect("missing path", AppViewModel.firstWorkingPython(in: ["/no/such/python3", real]), real)
            if failures.isEmpty {{ print("ok") }} else {{ print(failures.joined(separator: "\\n")); exit(1) }}
        ''')
        out = run_swift({"lifted.swift": self._lifted(), "main.swift": driver})
        self.assertEqual(out.strip(), "ok")

    def test_failures_are_named_from_apples_own_messages(self):
        driver = textwrap.dedent('''
            import Foundation
            let cases: [(String, AppViewModel.BackendFailure)] = [
                ("You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license' from within a Terminal window", .xcodeLicence),
                ("xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools), missing xcrun", .commandLineTools),
                // Points at an Xcode that is gone: installing tools would not help.
                ("xcrun: error: invalid active developer path (/Applications/Xcode.app/Contents/Developer), missing xcrun", .staleDeveloperPath),
                ("Traceback (most recent call last):\\nModuleNotFoundError: No module named 'foo'", .unknown),
                ("", .unknown),
            ]
            var failures: [String] = []
            for (text, want) in cases {
                let got = AppViewModel.diagnoseBackendFailure(text)
                if got != want { failures.append("\\(text.prefix(40)): got \\(got), want \\(want)") }
            }
            if failures.isEmpty { print("ok") } else { print(failures.joined(separator: "\\n")); exit(1) }
        ''')
        out = run_swift({"lifted.swift": self._lifted(), "main.swift": driver})
        self.assertEqual(out.strip(), "ok")


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "needs swiftc on macOS")
class DeviceWatchTests(unittest.TestCase):
    """When the app looks for a phone on its own, and when it must not."""

    def test_the_timer_never_re_asks_a_phone_waiting_on_trust(self):
        rule = lift(r"(    nonisolated static func shouldLookForDevice\(.*?\n    \})\n")
        driver = textwrap.dedent('''
            import Foundation
            func look(_ t: Bool, _ dev: Bool, _ busy: Bool, _ st: String, _ act: Bool) -> Bool {
                AppViewModel.shouldLookForDevice(fromTimer: t, hasDevice: dev, busy: busy, lastState: st, appActive: act)
            }
            let cases: [(String, Bool, Bool)] = [
                // Nothing plugged in yet: keep looking, it cannot raise a prompt.
                ("timer, nothing seen, app in front", look(true, false, false, "none", true), true),
                // Phone waiting on Trust: listing it asks to pair again.
                ("timer, waiting on Trust", look(true, false, false, "untrusted", true), false),
                // Coming back to the app is the person's own move, so look once.
                ("back to app, waiting on Trust", look(false, false, false, "untrusted", true), true),
                ("timer, app in background", look(true, false, false, "none", false), false),
                ("already connected", look(true, true, false, "connected", true), false),
                // Coming back with a phone set: it may have been unplugged or swapped.
                ("back to app, phone set", look(false, true, false, "connected", true), true),
                ("mid flash", look(true, false, true, "none", true), false),
                ("back to app, mid flash", look(false, false, true, "none", true), false),
                // Tools missing: running the shim again only brings Apple's
                // install dialog back, so neither the timer nor a return does.
                ("timer, tools missing", look(true, false, false, "backend:commandLineTools", true), false),
                ("back to app, tools missing", look(false, false, false, "backend:commandLineTools", true), false),
                ("back to app, licence not accepted", look(false, false, false, "backend:xcodeLicence", true), false),
            ]
            var failures: [String] = []
            for (name, got, want) in cases where got != want {
                failures.append("\\(name): got \\(got), want \\(want)")
            }
            if failures.isEmpty { print("ok") } else { print(failures.joined(separator: "\\n")); exit(1) }
        ''')
        out = run_swift({
            "rule.swift": "import Foundation\n\nenum AppViewModel {\n" + rule.replace("nonisolated ", "") + "\n}\n",
            "main.swift": driver,
        })
        self.assertEqual(out.strip(), "ok")


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "needs swiftc on macOS")
class WindowSizeTests(unittest.TestCase):
    """A 13-inch screen at Larger Text is about 560 points tall to work with."""

    def test_the_window_fits_a_small_screen(self):
        minimum = float(lift(r"static let minimumHeight: CGFloat = ([0-9.]+)"))
        self.assertLessEqual(minimum, 560)

    def test_the_log_never_crowds_out_the_rest(self):
        fn = lift(r"(    nonisolated static func shownLogHeight\(.*?\n    \}\n)").replace("nonisolated ", "")
        driver = textwrap.dedent("""
            import Foundation
            print(ContentView.shownLogHeight(wanted: 520, window: 540))
            print(ContentView.shownLogHeight(wanted: 180, window: 900))
            print(ContentView.shownLogHeight(wanted: 20, window: 900))
            print(ContentView.shownLogHeight(wanted: 520, window: 100))
        """)
        out = run_swift({"lifted.swift": "import Foundation\n\nenum ContentView {\n" + fn + "}\n", "main.swift": driver})
        self.assertEqual(out.strip().splitlines(), ["216.0", "180.0", "80.0", "80.0"])


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "needs swiftc on macOS")
class DevicePickTests(unittest.TestCase):
    def test_an_ipad_is_never_picked_as_the_iphone(self):
        info = lift(r"(struct DeviceInfo: Codable \{.*?\n\})\n")
        fn = lift(r"(    nonisolated static func pickDevice\(.*?\n    \}\n)").replace("nonisolated ", "")
        driver = textwrap.dedent(r"""
            import Foundation
            func dev(_ id: String, _ product: String) -> DeviceInfo {
                DeviceInfo(udid: id, name: id, version: "18", product: product, language: nil, locale: nil,
                           bold_text: nil, airlift_compatible: nil, connection: "usb", connected: true, error: nil)
            }
            let ipad = dev("ipad", "iPad13,4"), phone = dev("phone", "iPhone16,1"), other = dev("other", "iPhone15,2")
            print(AppViewModel.pickDevice(from: [ipad], current: nil) ?? "none")
            print(AppViewModel.pickDevice(from: [ipad, phone], current: nil) ?? "none")
            print(AppViewModel.pickDevice(from: [phone, other], current: "other") ?? "none")
            print(AppViewModel.pickDevice(from: [ipad, phone], current: "ipad") ?? "none")
        """)
        out = run_swift({"lifted.swift": "import Foundation\n\n" + info + "\n\nenum AppViewModel {\n" + fn + "}\n", "main.swift": driver})
        # A device chosen by hand is kept, even an iPad; it is only never picked alone.
        self.assertEqual(out.strip().splitlines(), ["none", "phone", "other", "ipad"])

    def test_failed_cards_are_listed_as_they_are_labelled(self):
        fn = lift(r"(    nonisolated static func cardList\(.*?\n    \}\n)").replace("nonisolated ", "")
        driver = 'import Foundation\nprint(AppViewModel.cardList([5, 3]))\nprint(AppViewModel.cardList([2]))\n'
        stub = "import Foundation\n\nfunc L(_ key: String, _ fallback: String) -> String { fallback }\n\nenum AppViewModel {\n" + fn + "}\n"
        out = run_swift({"lifted.swift": stub, "main.swift": driver}).strip().splitlines()
        self.assertEqual(out, ["Card #3 and Card #5", "Card #2"])


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "needs swiftc on macOS")
class CardsPerPhoneTests(unittest.TestCase):
    def test_each_phone_sees_its_own_cards(self):
        fn = lift(r"(    nonisolated static func cardsForDevice\(.*?\n    \}\n)").replace("nonisolated ", "")
        driver = textwrap.dedent(r"""
            import Foundation
            var store: [String: [String]] = [:]
            // First phone after an upgrade takes the old, unfiled list.
            var r = AppViewModel.cardsForDevice("A", store: store, unassigned: ["a1", "a2"])
            print(r.cards); store = r.store
            // Another phone sees nothing of A's.
            r = AppViewModel.cardsForDevice("B", store: store, unassigned: [])
            print(r.cards); store = r.store
            store["B"] = ["b1"]
            // Back to A: A's list, unchanged; B's stays B's.
            r = AppViewModel.cardsForDevice("A", store: store, unassigned: [])
            print(r.cards, r.store["B"] ?? [])
            // Something added with no phone known goes to the next phone, once.
            r = AppViewModel.cardsForDevice("A", store: store, unassigned: ["a2", "new"])
            print(r.cards)
        """)
        out = run_swift({"lifted.swift": "import Foundation\n\nenum AppViewModel {\n" + fn + "}\n", "main.swift": driver})
        self.assertEqual(out.strip().splitlines(), [
            '["a1", "a2"]', "[]", '["a1", "a2"] ["b1"]', '["a1", "a2", "new"]',
        ])


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "needs swiftc on macOS")
class LogFileTests(unittest.TestCase):
    def test_the_log_is_kept_and_does_not_grow_for_ever(self):
        fn = lift(r"(    nonisolated static func appendToLogFile\(.*?\n    \}\n)").replace("nonisolated ", "")
        fn = fn.replace("at url: URL = logFileURL", "at url: URL")
        driver = textwrap.dedent(r"""
            import Foundation
            let dir = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Logs/AirCard")
            let file = dir.appendingPathComponent("AirCard.log")
            AppViewModel.appendToLogFile("first", at: file, limit: 40)
            AppViewModel.appendToLogFile("second", at: file, limit: 40)
            print((try? String(contentsOf: file, encoding: .utf8)) ?? "missing", terminator: "|")
            AppViewModel.appendToLogFile(String(repeating: "x", count: 50), at: file, limit: 40)
            AppViewModel.appendToLogFile("after rotation", at: file, limit: 40)
            print((try? String(contentsOf: file, encoding: .utf8)) ?? "missing", terminator: "|")
            print(FileManager.default.fileExists(atPath: dir.appendingPathComponent("AirCard.1.log").path))
        """)
        out = run_swift({"lifted.swift": "import Foundation\n\nenum AppViewModel {\n" + fn + "}\n", "main.swift": driver})
        self.assertEqual(out.strip(), "first\nsecond\n|after rotation\n|true")


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "needs swiftc on macOS")
class OriginalsTests(unittest.TestCase):
    """What is said after reading originals, and who is asked before a flash."""

    def _lifted(self):
        parts = [lift(r"(    nonisolated static func originalsReadMessage\(.*?\n    \}\n)"),
                 lift(r"(    nonisolated static func originalsWorthSaving\(.*?\n    \}\n)")]
        body = "\n".join(parts).replace("nonisolated ", "")
        return "import Foundation\n\nfunc L(_ key: String, _ fallback: String) -> String { fallback }\n\nenum AppViewModel {\n" + body + "}\n"

    def test_each_count_is_said_on_its_own(self):
        driver = textwrap.dedent(r"""
            import Foundation
            print(AppViewModel.originalsReadMessage(read: 2, total: 5, alreadyChanged: 1, failed: 2))
            print(AppViewModel.originalsReadMessage(read: 4, total: 5, alreadyChanged: 1, failed: 0))
            print(AppViewModel.originalsReadMessage(read: 3, total: 5, alreadyChanged: 0, failed: 2))
            print(AppViewModel.originalsReadMessage(read: 5, total: 5, alreadyChanged: 0, failed: 0))
        """)
        out = run_swift({"lifted.swift": self._lifted(), "main.swift": driver}).strip().splitlines()
        self.assertEqual(out, [
            "Originals read: 2 of 5. 1 were already changed by AirCard, so their originals are not on the phone. For the other 2, unlock the iPhone and try again.",
            "Originals read: 4 of 5. 1 were already changed by AirCard, so their originals are not on the phone.",
            "Originals read: 3 of 5. Unlock the iPhone and try again for the rest.",
            "Originals read: 5 of 5.",
        ])

    def test_only_cards_whose_original_can_still_be_saved_are_asked_about(self):
        driver = textwrap.dedent(r"""
            import Foundation
            print(AppViewModel.originalsWorthSaving(sending: ["a", "b", "c", "d"], saved: ["a"], flashed: ["b"], declined: ["c"]))
        """)
        out = run_swift({"lifted.swift": self._lifted(), "main.swift": driver})
        self.assertEqual(out.strip(), '["d"]')


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "needs swiftc on macOS")
class CardNumberPasteTests(unittest.TestCase):
    """Card numbers pasted by hand, in the shapes people actually paste them."""

    def test_pasted_card_numbers(self):
        parse = lift(r"(    nonisolated static func parseCardHashes\(.*?\n    \})\n")
        driver = textwrap.dedent('''
            import Foundation
            let h = "M6nDwZrkYbFlsodLgCbvyFZQ1cc="
            let cases: [(String, [String], Int)] = [
                (h, [h], 0),
                ("\\"" + h + "\\"", [h], 0),                                   // quoted
                ("(" + h + ")", [h], 0),                                       // bracketed
                ("\\u{201C}" + h + "\\u{201D}", [h], 0),                        // curly quotes
                (h + ".pkpass", [h], 0),                                       // file name
                ("/var/mobile/Library/Passes/Cards/" + h + ".pkpass", [h], 0), // full path
                (h + ".", [h], 0),                                             // end of a sentence
                (h + ", " + h, [h], 0),                                        // same one twice
                ("abc", [], 1),                                                // too short
                ("hello world", [], 2),                                        // not numbers at all
                ("ab/cd+ef_gh-ijklmnopqrstu=", ["ab/cd+ef_gh-ijklmnopqrstu="], 0), // slash is legal
            ]
            var failures: [String] = []
            for (input, wantValid, wantInvalid) in cases {
                let got = AppViewModel.parseCardHashes(input)
                if got.valid != wantValid || got.invalid.count != wantInvalid {
                    failures.append("\\(input): valid \\(got.valid) invalid \\(got.invalid)")
                }
            }
            if failures.isEmpty { print("ok") } else { print(failures.joined(separator: "\\n")); exit(1) }
        ''')
        out = run_swift({
            "parse.swift": "import Foundation\n\nenum AppViewModel {\n" + parse.replace("nonisolated ", "") + "\n}\n",
            "main.swift": driver,
        })
        self.assertEqual(out.strip(), "ok")


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "needs swiftc on macOS")
class SavedCardCleanupTests(unittest.TestCase):
    def test_numbers_saved_by_older_versions_are_cleaned_once(self):
        parse = lift(r"(    nonisolated static func parseCardHashes\(.*?\n    \})\n").replace("nonisolated ", "")
        clean = lift(r"(    nonisolated static func cleanSavedHashes\(.*?\n    \}\n)").replace("nonisolated ", "")
        driver = textwrap.dedent(r"""
            import Foundation
            let h = "M6nDwZrkYbFlsodLgCbvyFZQ1cc=", g = "Qx2pLm9ZrT0aB7cD1eF3gH5iJ8k="
            print(AppViewModel.cleanSavedHashes(["\"" + h + "\"", "(" + g + ")", h, "junk"]))
            print(AppViewModel.cleanSavedHashes([h, g]) == [h, g])
        """)
        out = run_swift({"lifted.swift": "import Foundation\n\nenum AppViewModel {\n" + parse + "\n" + clean + "}\n", "main.swift": driver})
        self.assertEqual(out.strip().splitlines(), ['["M6nDwZrkYbFlsodLgCbvyFZQ1cc=", "Qx2pLm9ZrT0aB7cD1eF3gH5iJ8k="]', "true"])


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "needs swiftc on macOS")
class PasscodeTargetTests(unittest.TestCase):
    """Each phone's keypad targets come from that phone, never the last one."""

    def test_targets_come_from_the_phone_alone(self):
        lang = lift(r"(enum PasscodeLanguageTarget: String, CaseIterable, Identifiable \{.*?\n\})\n")
        bold = lift(r"(enum PasscodeBoldTarget: String, CaseIterable, Identifiable \{.*?\n\})\n")
        fn = lift(r"(    nonisolated static func passcodeTargets\(.*?\n    \}\n)").replace("nonisolated ", "")
        lifted = ("import Foundation\n\nfunc L(_ key: String, _ fallback: String) -> String { fallback }\n\n"
                  + lang + "\n\n" + bold + "\n\nenum AppViewModel {\n" + fn + "}\n")
        driver = textwrap.dedent(r"""
            import Foundation
            let cases: [(String?, Bool?, String)] = [
                ("ru-RU", true, "ru bold"),
                ("zh-Hans-CN", false, "zh regular"),
                ("pt_BR", nil, "pt both"),
                ("EN", nil, "en both"),
                ("nl", nil, "all both"),
                (nil, nil, "all both"),
                ("", true, "all bold"),
                ("other", nil, "all both"),
                ("all", nil, "all both"),
            ]
            var failures: [String] = []
            for (language, boldText, want) in cases {
                let t = AppViewModel.passcodeTargets(language: language, boldText: boldText)
                let got = "\(t.language.code) \(t.bold.code)"
                if got != want { failures.append("\(language ?? "nil"), \(String(describing: boldText)): got \(got), want \(want)") }
            }
            if failures.isEmpty { print("ok") } else { print(failures.joined(separator: "\n")); exit(1) }
        """)
        out = run_swift({"lifted.swift": lifted, "main.swift": driver})
        self.assertEqual(out.strip(), "ok")


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "needs swiftc on macOS")
class SkinLibraryTests(unittest.TestCase):
    """Links people paste, the library's order, and the importer's output."""

    def _statics(self) -> str:
        parts = [
            lift(r"(    nonisolated static func skinDownloadURL\(.*?\n    \}\n)"),
            lift(r"(    nonisolated static func orderSkinNames\(.*?\n    \}\n)"),
            lift(r"(    nonisolated static func parseSkinImport\(.*?\n    \}\n)"),
            lift(r"(    nonisolated static func skinImportLines\(.*?\n    \}\n)"),
            lift(r"(    nonisolated static func picturesIn\(.*?\n    \}\n)"),
        ]
        result = lift(r"(struct SkinImportResult \{.*?\n\})\n")
        body = "\n".join(parts).replace("nonisolated ", "")
        stub = "func L(_ key: String, _ fallback: String) -> String { fallback }\n\n"
        return "import Foundation\n\n" + stub + result + "\n\nenum AppViewModel {\n" + body + "}\n"

    def test_links_people_paste(self):
        driver = textwrap.dedent(r"""
            import Foundation
            let cases: [(String, String?)] = [
                ("example.com/pack.zip", "https://example.com/pack.zip"),
                ("  http://example.com/a.png \n", "https://example.com/a.png"),
                ("https://github.com/u/r/blob/main/pack.zip", "https://github.com/u/r/blob/main/pack.zip?raw=true"),
                ("https://github.com/u/r/blob/main/pack.zip?raw=false", "https://github.com/u/r/blob/main/pack.zip?raw=true"),
                ("https://github.com/u/r/releases/download/v1/pack.zip", "https://github.com/u/r/releases/download/v1/pack.zip"),
                ("https://www.dropbox.com/s/abc/pack.zip?dl=0", "https://www.dropbox.com/s/abc/pack.zip?dl=1"),
                ("https://dropbox.com.example.net/x.zip?dl=0", "https://dropbox.com.example.net/x.zip?dl=0"),
                ("https://example.com/卡面 包.zip", "https://example.com/%E5%8D%A1%E9%9D%A2%20%E5%8C%85.zip"),
                ("file:///etc/passwd", nil),
                ("ftp://example.com/pack.zip", nil),
                ("javascript:alert(1)", nil),
                ("not a link", nil),
                ("localhost", nil),
                ("", nil),
                ("https://a.com/x.zip\nhttps://b.com/y.zip", nil),
            ]
            var failures: [String] = []
            for (text, want) in cases {
                let got = AppViewModel.skinDownloadURL(text)?.absoluteString
                if got != want { failures.append("\(text.debugDescription): got \(got ?? "nil"), want \(want ?? "nil")") }
            }
            let order = AppViewModel.orderSkinNames(
                ["b.png", "a10.png", "a2.png", "new2.png", "new1.png"],
                recent: ["new2.png", "new1.png", "gone.png", "new2.png"])
            if order != ["new2.png", "new1.png", "a2.png", "a10.png", "b.png"] { failures.append("order: \(order)") }
            if failures.isEmpty { print("ok") } else { print(failures.joined(separator: "\n")); exit(1) }
        """)
        out = run_swift({"lifted.swift": self._statics(), "main.swift": driver})
        self.assertEqual(out.strip(), "ok")

    def test_the_app_reads_what_the_importer_prints(self):
        """Run the real command, feed its output to the app's parser."""
        import io
        import zipfile
        from contextlib import redirect_stdout
        sys.path.insert(0, str(REPO))
        import aircard_backend
        png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 32
        outputs = {}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pack = root / "pack.zip"
            with zipfile.ZipFile(pack, "w") as z:
                z.writestr("Blue.png", png)
                z.writestr("notes.txt", b"x")
            empty = root / "empty.zip"
            with zipfile.ZipFile(empty, "w") as z:
                z.writestr("notes.txt", b"x")
            for name, source in [("added", pack), ("none", empty), ("missing", root / "gone.zip"), ("again", pack)]:
                buf = io.StringIO()
                with redirect_stdout(buf):
                    aircard_backend.cmd_import_skins(str(source), str(root / "lib"))
                outputs[name] = buf.getvalue()
        literal = lambda text: "\"\"\"\n" + text.replace("\\", "\\\\") + "\"\"\""
        driver = textwrap.dedent("""
            import Foundation
            func show(_ r: SkinImportResult) -> String { "\\(r.code)|\\(r.imported.joined(separator: ","))|\\(r.skipped)|\\(r.duplicates)" }
            print(show(AppViewModel.parseSkinImport(Data(ADDED.utf8))))
            print(show(AppViewModel.parseSkinImport(Data(NONE.utf8))))
            print(show(AppViewModel.parseSkinImport(Data(MISSING.utf8))))
            print(show(AppViewModel.parseSkinImport(nil)))
            print(show(AppViewModel.parseSkinImport(Data("Traceback (most recent call last):".utf8))))
            print(show(AppViewModel.parseSkinImport(Data((NONE + "\\n" + ADDED).utf8))))
            print(show(AppViewModel.parseSkinImport(Data(AGAIN.utf8))))
        """)
        driver = (driver.replace("ADDED", literal(outputs["added"]))
                        .replace("NONE", literal(outputs["none"]))
                        .replace("MISSING", literal(outputs["missing"]))
                        .replace("AGAIN", literal(outputs["again"])))
        out = run_swift({"lifted.swift": self._statics(), "main.swift": driver}).strip().splitlines()
        self.assertEqual(out, [
            "skins.imported|Blue.png|1|0",
            "skins.none_found||1|0",
            "skins.not_found||0|0",
            # No answer at all is the backend not running, not a bad file.
            "skins.no_output||0|0",
            "skins.no_output||0|0",
            "skins.imported|Blue.png|1|0",
            "skins.nothing_new||1|1",
        ])

    def test_each_outcome_gets_its_own_line(self):
        driver = textwrap.dedent(r"""
            import Foundation
            func lines(_ r: SkinImportResult, unreadable: Int = 0) -> String {
                let out = AppViewModel.skinImportLines(r, unreadable: unreadable)
                return (out.isError ? "ERROR " : "") + out.lines.joined(separator: " / ")
            }
            var r = SkinImportResult(); r.imported = ["a", "b"]; r.skipped = 1
            print(lines(r))
            r = SkinImportResult(); r.duplicates = 3
            print(lines(r))
            r = SkinImportResult(); r.imported = ["a"]; r.duplicates = 2; r.encrypted = 4; r.overLimit = 5
            print(lines(r))
            r = SkinImportResult(); r.unsupported = 2
            print(lines(r))
            r = SkinImportResult(); r.skipped = 3
            print(lines(r))
            r = SkinImportResult()
            print(lines(r, unreadable: 1))
        """)
        out = run_swift({"lifted.swift": self._statics(), "main.swift": driver}).strip().splitlines()
        self.assertEqual(out, [
            "Added 2 to the library. / 1 skipped: not a picture, or too big.",
            "Everything in it is already in the library.",
            "Added 1 to the library. / 2 were already in the library. / 4 are in a password-protected zip. Open it in Finder with its password, then add the folder it makes. / 5 more were left out, because one import takes up to 400 pictures. Add the rest separately.",
            "ERROR 2 are packed in a way AirCard cannot unpack. Double-click the zip in Finder, then add the folder it makes.",
            "ERROR No card pictures were found. They need to be PNG, JPEG, HEIC or WebP files.",
            "ERROR That file could not be opened. If it is a zip, double-click it in Finder to check it is not damaged.",
        ])

    def test_a_folder_is_counted_the_way_it_would_be_imported(self):
        driver = textwrap.dedent(r"""
            import Foundation
            let fm = FileManager.default
            let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Downloads")
            func put(_ path: String) {
                let url = root.appendingPathComponent(path)
                try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try! Data("x".utf8).write(to: url)
            }
            put("a.png"); put("b.JPG"); put("pack/c.webp"); put("notes.txt"); put(".hidden.png")
            put("Some.app/Contents/Resources/icon.png")
            put("Photos Library.photoslibrary/originals/d.heic")
            print(AppViewModel.picturesIn(folder: root))
        """)
        out = run_swift({"lifted.swift": self._statics(), "main.swift": driver})
        self.assertEqual(out.strip(), "3")

    def test_the_library_lists_every_kind_the_importer_writes(self):
        """A kind written but not listed would import 'successfully' and never show."""
        sys.path.insert(0, str(REPO))
        import aircard
        listed = lift(r'nonisolated static let skinFileExtensions: Set<String> = \[([^\]]*)\]')
        listed = set(re.findall(r'"([a-z0-9]+)"', listed))
        written = {ext.lstrip(".") for ext in aircard.SKIN_EXTENSIONS.values()}
        self.assertEqual(written - listed, set())

    def test_the_download_limit_is_the_import_limit(self):
        """One number, in the units the app shows: a download that stops at a
        different size than the importer allows reads as a broken promise."""
        sys.path.insert(0, str(REPO))
        import aircard
        swift = int(lift(r"static let maxBytes: Int64 = ([0-9_]+)").replace("_", ""))
        self.assertEqual(swift, aircard.MAX_PACK_BYTES)
        self.assertEqual(swift % 1_000_000, 0, "the limit should be a round number of MB as shown")

    def test_thumbnails_are_small_and_bad_files_give_none(self):
        thumb = lift(r"(    nonisolated static func skinThumbnail\(.*?\n    \}\n)").replace("nonisolated ", "")
        driver = textwrap.dedent("""
            import AppKit
            let dir = CommandLine.arguments[1]
            let big = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 1500, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            try! big.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir + "/big.png"))
            try! Data("not a picture".utf8).write(to: URL(fileURLWithPath: dir + "/bad.png"))
            if let t = AppViewModel.skinThumbnail(URL(fileURLWithPath: dir + "/big.png")) { print("\\(t.width)x\\(t.height)") } else { print("nil") }
            print(AppViewModel.skinThumbnail(URL(fileURLWithPath: dir + "/bad.png")) == nil ? "nil" : "image")
        """)
        out = run_swift({"lifted.swift": "import Foundation\nimport ImageIO\n\nenum AppViewModel {\n" + thumb + "}\n", "main.swift": driver})
        self.assertEqual(out.strip().splitlines(), ["440x220", "nil"])

    def test_downloads_against_a_real_server(self):
        """404, a web page, a size over the cap, and a good file, over real HTTP."""
        import http.server
        import threading

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                if self.path == "/pack.zip":
                    body = b"PK\x05\x06" + b"\x00" * 18
                    self.send_response(200)
                    self.send_header("Content-Type", "application/zip")
                    self.send_header("Content-Disposition", 'attachment; filename="My Pack.zip"')
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                elif self.path == "/page":
                    body = b"<!doctype html><title>Share</title>"
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                elif self.path == "/huge.zip":
                    self.send_response(200)
                    self.send_header("Content-Type", "application/zip")
                    self.send_header("Content-Length", str(500 * 1024 * 1024))
                    self.end_headers()
                    try:
                        self.wfile.write(b"PK" + b"\x00" * 1024)
                    except OSError:
                        pass
                else:
                    self.send_error(404)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        base = f"http://127.0.0.1:{server.server_address[1]}"

        downloader = lift(r"(final class SkinDownloader: NSObject, URLSessionDataDelegate \{.*?\n\})\n")
        driver = textwrap.dedent("""
            import Foundation
            let folder = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("dl")
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            func fetch(_ path: String) -> String {
                var outcome: String?
                let d = SkinDownloader(url: URL(string: "BASE" + path)!, folder: folder,
                                       onProgress: { _ in },
                                       onFinish: { result in
                    switch result {
                    case .success(let file):
                        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
                        outcome = "file \\(file.lastPathComponent) \\(size)"
                    case .failure(let f):
                        outcome = "\\(f)"
                    }
                })
                d.start()
                let deadline = Date().addingTimeInterval(30)
                while outcome == nil && Date() < deadline {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
                return outcome ?? "timeout"
            }
            print(fetch("/pack.zip"))
            print(fetch("/missing.zip"))
            print(fetch("/page"))
            print(fetch("/huge.zip"))
            let names: [(String?, String)] = [(nil, "https://x.com/"), ("../../x.zip", ""), ("a:b.png", ""), (nil, "https://x.com/p/pack.zip")]
            for (suggested, url) in names {
                print(SkinDownloader.fileName(suggested: suggested, url: URL(string: url.isEmpty ? "https://x.com/q" : url)!))
            }
        """).replace("BASE", base)
        out = run_swift({"downloader.swift": "import Foundation\n\n" + downloader, "main.swift": driver}).strip().splitlines()
        self.assertEqual(out, [
            "file My Pack.zip 22",
            "status(404)",
            "webPage",
            "tooLarge",
            "download",
            "download",
            "a_b.png",
            "pack.zip",
        ])


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "needs swiftc on macOS")
class InstallGuardTests(unittest.TestCase):
    """One AirCard per Mac: where it runs from, what replaces what, what gets cleared."""

    def _lifted(self, fake_commands: bool = False) -> str:
        guard = lift(r"(enum InstallGuard \{.*?\n\})\n\nextension InstallGuard \{")
        guard = guard.replace("nonisolated ", "")
        if fake_commands:
            # The relaunch script, with opening and ejecting swapped for marker
            # files, so what it does and in which order can be watched.
            guard = (guard.replace('/usr/bin/open "$2"', '/usr/bin/touch "$2.opened"')
                          .replace('/usr/bin/hdiutil detach "$3" -quiet >/dev/null 2>&1', '/bin/sleep 0.3; /usr/bin/touch "$3.ejected"'))
        return "import Foundation\n\nfunc L(_ key: String, _ fallback: String) -> String { fallback }\n\n" + guard + "\n"

    def test_decisions(self):
        driver = textwrap.dedent(r"""
            import Foundation
            typealias G = InstallGuard
            var failures: [String] = []
            func expect<T: Equatable>(_ what: String, _ got: T, _ want: T) {
                if got != want { failures.append("\(what): got \(got), want \(want)") }
            }
            let tmp = URL(fileURLWithPath: CommandLine.arguments[1])
            func copy(_ v: String, _ b: String, _ p: String = "/x/AirCard.app", id: String? = "com.mak5er.aircard") -> G.AppCopy {
                .init(url: URL(fileURLWithPath: p), version: v, build: b, bundleID: id)
            }

            // Versions
            expect("1.4.0 vs 1.3.1", G.compareVersions("1.4.0", "1.3.1"), .orderedDescending)
            expect("1.10 vs 1.9", G.compareVersions("1.10", "1.9"), .orderedDescending)
            expect("1.4 vs 1.4.0", G.compareVersions("1.4", "1.4.0"), .orderedSame)
            expect("1.3.0 vs 1.4.0", G.compareVersions("1.3.0", "1.4.0"), .orderedAscending)
            expect("same version, newer build", G.compare(copy("1.4.0", "10"), copy("1.4.0", "9")), .orderedDescending)
            expect("label, versions differ", G.label(copy("1.3.0", "8"), against: copy("1.4.0", "9")), "1.3.0")
            expect("label, only builds differ", G.label(copy("1.4.0", "8"), against: copy("1.4.0", "9")), "1.4.0 (8)")

            // Where it runs from
            let apps = tmp.appendingPathComponent("Applications")
            try! FileManager.default.createDirectory(at: apps.appendingPathComponent("Utilities"), withIntermediateDirectories: true)
            try! FileManager.default.createSymbolicLink(at: tmp.appendingPathComponent("AppsLink"), withDestinationURL: apps)
            let folders = [apps]
            expect("in Applications", G.placement(of: apps.appendingPathComponent("AirCard.app"), applicationsFolders: folders, onDiskImage: false), .installed)
            expect("in a subfolder", G.placement(of: apps.appendingPathComponent("Utilities/AirCard.app"), applicationsFolders: folders, onDiskImage: false), .installed)
            expect("through a symlink", G.placement(of: tmp.appendingPathComponent("AppsLink/AirCard.app"), applicationsFolders: folders, onDiskImage: false), .installed)
            expect("look-alike folder", G.placement(of: tmp.appendingPathComponent("Applications2/AirCard.app"), applicationsFolders: folders, onDiskImage: false), .elsewhere)
            expect("disk image", G.placement(of: URL(fileURLWithPath: "/Volumes/AirCard/AirCard.app"), applicationsFolders: folders, onDiskImage: true), .diskImage)
            expect("Downloads", G.placement(of: URL(fileURLWithPath: "/Users/x/Downloads/AirCard.app"), applicationsFolders: folders, onDiskImage: false), .elsewhere)

            // What moving in does
            let old = copy("1.3.0", "8"), now = copy("1.4.0", "9", "/y/AirCard.app"), newer = copy("1.5.0", "10")
            expect("nothing installed", G.moveDecision(own: now, installed: nil), .moveIn)
            expect("older installed", G.moveDecision(own: now, installed: old), .replace(older: old))
            expect("newer installed", G.moveDecision(own: now, installed: newer), .openInstalled(newer: newer))
            expect("same installed", G.moveDecision(own: now, installed: copy("1.4.0", "9")), .openInstalledSame(copy("1.4.0", "9")))
            let linkTarget = tmp.appendingPathComponent("Real/AirCard.app")
            try! FileManager.default.createDirectory(at: linkTarget, withIntermediateDirectories: true)
            try! FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("AirCard.app"), withDestinationURL: linkTarget)
            expect("installed is this copy through a link",
                   G.moveDecision(own: copy("1.4.0", "9", linkTarget.path), installed: copy("1.4.0", "9", apps.appendingPathComponent("AirCard.app").path)),
                   .alreadyInstalled)

            // Only an older AirCard may be thrown away
            expect("older AirCard", G.safeToReplace(old, with: now), true)
            expect("newer AirCard", G.safeToReplace(newer, with: now), false)
            expect("same AirCard", G.safeToReplace(copy("1.4.0", "9"), with: now), false)
            expect("another app", G.safeToReplace(copy("0.1", "1", id: "com.example.other"), with: now), false)
            expect("no bundle id", G.safeToReplace(copy("0.1", "1", id: nil), with: now), false)
            expect("nothing there", G.safeToReplace(nil, with: now), false)

            // "Don't ask again" holds for that version only
            expect("never refused", G.shouldOfferMove(own: now, refused: nil), true)
            expect("this version refused", G.shouldOfferMove(own: now, refused: G.refusalKey(now)), false)
            expect("an older version refused", G.shouldOfferMove(own: now, refused: "1.3.0|8"), true)
            expect("a newer build of it", G.shouldOfferMove(own: copy("1.4.0", "10"), refused: "1.4.0|9"), true)

            // Two copies at once: exactly one yields, whatever the order
            let t0 = Date(timeIntervalSince1970: 1000), t1 = Date(timeIntervalSince1970: 1001)
            for (a, b) in [((t0, Int32(50)), (t1, Int32(40))), ((t0, Int32(50)), (t0, Int32(40))), ((t0, Int32(50)), (nil as Date?, Int32(40)))] {
                let aYields = G.shouldYield(theirLaunch: b.0, theirPID: b.1, myLaunch: a.0, myPID: a.1)
                let bYields = G.shouldYield(theirLaunch: a.0, theirPID: a.1, myLaunch: b.0, myPID: b.1)
                expect("exactly one yields for \(a) vs \(b)", aYields != bYields, true)
            }
            expect("the later one yields", G.shouldYield(theirLaunch: t0, theirPID: 99, myLaunch: t1, myPID: 1), true)

            // Which copies count as strays
            let own = apps.appendingPathComponent("Utilities/AirCard.app")
            let found = [
                own,
                tmp.appendingPathComponent("AppsLink/Utilities/AirCard.app"),   // own, spelt differently
                URL(fileURLWithPath: "/Users/x/Downloads/AirCard.app"),         // a stray
                URL(fileURLWithPath: "/Users/x/Downloads/AirCard.app/"),        // the same stray again
                URL(fileURLWithPath: "/Users/x/.Trash/AirCard.app"),            // already in the Trash
                URL(fileURLWithPath: "/Volumes/Apps/.Trashes/501/AirCard.app"), // in a Trash on a disk it shares
                URL(fileURLWithPath: "/Volumes/AirCard/AirCard.app"),           // on the disk image
                URL(fileURLWithPath: "/Volumes/Backup/Applications/AirCard.app"), // a backup clone
                URL(fileURLWithPath: "/Users/x/Desktop/AirCard.app"),           // running right now
                URL(fileURLWithPath: "/Users/x/old/AirCard.app"),               // kept on purpose
                URL(fileURLWithPath: "/Users/x/gone/AirCard.app"),              // no longer exists
            ]
            let strays = G.strayCopies(found: found, own: own,
                                       running: ["/Users/x/Desktop/AirCard.app"], kept: ["/Users/x/old/AirCard.app"],
                                       exists: { !$0.path.contains("/gone/") },
                                       onDiskImage: { $0.path.hasPrefix("/Volumes/AirCard/") },
                                       sameVolume: { !$0.path.hasPrefix("/Volumes/Backup/") })
            expect("strays", strays.map(\.path), ["/Users/x/Downloads/AirCard.app"])

            // Never clear a newer copy from an older one; equal is not newer
            let me = copy("1.3.0", "8", "/Applications/AirCard.app")
            expect("newer elsewhere", G.strayPlan(own: me, strays: [copy("1.2.4", "7", "/a"), copy("1.4.0", "9", "/b"), copy("1.3.5", "8", "/c")]), .openNewer(copy("1.4.0", "9", "/b")))
            expect("only older", G.strayPlan(own: copy("1.4.0", "9"), strays: [copy("1.3.0", "8", "/a")]), .clear([copy("1.3.0", "8", "/a")]))
            expect("equal version", G.strayPlan(own: copy("1.4.0", "9"), strays: [copy("1.4.0", "9", "/b")]), .clear([copy("1.4.0", "9", "/b")]))
            expect("same version, higher build", G.strayPlan(own: copy("1.4.0", "9"), strays: [copy("1.4.0", "10", "/b")]), .openNewer(copy("1.4.0", "10", "/b")))
            expect("none", G.strayPlan(own: copy("1.4.0", "9"), strays: []), .nothing)

            // Only the disk image is ejected
            expect("eject the image", G.ejectTarget(placement: .diskImage, volume: URL(fileURLWithPath: "/Volumes/AirCard")), URL(fileURLWithPath: "/Volumes/AirCard"))
            expect("never from elsewhere", G.ejectTarget(placement: .elsewhere, volume: URL(fileURLWithPath: "/Volumes/USB")), nil)
            expect("never the system disk", G.ejectTarget(placement: .diskImage, volume: URL(fileURLWithPath: "/")), nil)
            expect("nothing to eject", G.ejectTarget(placement: .diskImage, volume: nil), nil)

            // What counts as a disk image: what hdiutil lists, not "read-only"
            let info = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>images</key><array><dict><key>image-path</key><string>/Users/x/Downloads/AirCard 1.4.0.dmg</string><key>system-entities</key><array><dict><key>dev-entry</key><string>/dev/disk4</string></dict><dict><key>dev-entry</key><string>/dev/disk4s1</string><key>mount-point</key><string>/Volumes/AirCard 1.4.0</string></dict></array></dict><dict><key>image-path</key><string>/Users/x/Other.dmg</string><key>system-entities</key><array><dict><key>dev-entry</key><string>/dev/disk5</string></dict></array></dict></array></dict></plist>"#
            expect("mount points", G.diskImageMountPoints(fromHdiutilInfo: Data(info.utf8)), ["/Volumes/AirCard 1.4.0"])
            expect("nothing mounted", G.diskImageMountPoints(fromHdiutilInfo: Data("garbage".utf8)), [])

            if failures.isEmpty { print("ok") } else { print(failures.joined(separator: "\n")); exit(1) }
        """)
        out = run_swift({"lifted.swift": self._lifted(), "main.swift": driver})
        self.assertEqual(out.strip(), "ok")

    def test_installing_replaces_the_old_copy_and_never_half_way(self):
        driver = textwrap.dedent(r"""
            import Foundation
            typealias G = InstallGuard
            let fm = FileManager.default
            let tmp = URL(fileURLWithPath: CommandLine.arguments[1])
            var failures: [String] = []
            func expect(_ what: String, _ ok: Bool) { if !ok { failures.append(what) } }
            func quarantine(_ path: String) { setxattr(path, "com.apple.quarantine", "0081;x;y;", 9, 0, 0) }
            func makeApp(_ at: URL, version: String) {
                let contents = at.appendingPathComponent("Contents")
                try! fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
                let plist: NSDictionary = ["CFBundleShortVersionString": version, "CFBundleVersion": "1", "CFBundleIdentifier": "com.mak5er.aircard"]
                plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
                try! Data("bin".utf8).write(to: contents.appendingPathComponent("MacOS/AirCard"))
                // Quarantined the way a download is: the bundle, its folders and files.
                for path in [at.path, contents.path, contents.appendingPathComponent("MacOS/AirCard").path] { quarantine(path) }
            }
            func hasQuarantine(_ url: URL) -> Bool { getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 }
            func version(_ url: URL) -> String? { G.appCopy(at: url)?.version }
            func onlyTheApp(_ what: String, _ dir: URL) {
                let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                expect("\(what): \(names)", names == ["AirCard.app"])
            }

            let downloads = tmp.appendingPathComponent("Downloads")
            let apps = tmp.appendingPathComponent("Applications")
            let trash = tmp.appendingPathComponent("Trash")
            for d in [downloads, apps, trash] { try! fm.createDirectory(at: d, withIntermediateDirectories: true) }
            let source = downloads.appendingPathComponent("AirCard.app")
            makeApp(source, version: "1.4.0")
            let toTrash: (URL) throws -> URL? = { old in
                let dest = trash.appendingPathComponent(UUID().uuidString + ".app")
                try fm.moveItem(at: old, to: dest)
                return dest
            }
            let installed = apps.appendingPathComponent("AirCard.app")

            // Fresh install
            _ = try! G.install(source, into: apps, discard: toTrash)
            expect("installed as AirCard.app", version(installed) == "1.4.0")
            for path in [installed, installed.appendingPathComponent("Contents"), installed.appendingPathComponent("Contents/MacOS/AirCard")] {
                expect("quarantine cleared on \(path.lastPathComponent)", !hasQuarantine(path))
            }
            expect("source untouched by install", version(source) == "1.4.0")
            onlyTheApp("no staging left", apps)

            // Replacing an older one: the old one goes to the Trash, not away
            try! fm.removeItem(at: installed)
            makeApp(installed, version: "1.3.0")
            _ = try! G.install(source, into: apps, discard: toTrash)
            expect("new version in place", version(installed) == "1.4.0")
            let trashed = try! fm.contentsOfDirectory(atPath: trash.path)
            expect("old version in the Trash", trashed.count == 1 && version(trash.appendingPathComponent(trashed[0])) == "1.3.0")

            // If the old one cannot be put away, nothing changes
            try! fm.removeItem(at: installed)
            makeApp(installed, version: "1.3.0")
            struct Refused: Error {}
            do { _ = try G.install(source, into: apps, discard: { _ in throw Refused() }); expect("a refused discard is reported", false) } catch {}
            expect("old copy still installed", version(installed) == "1.3.0")
            onlyTheApp("no staging left after a refused discard", apps)

            // The old one went to the Trash but the final rename failed: it is put back
            do {
                _ = try G.install(source, into: apps, discard: { old in
                    let away = try toTrash(old)
                    for name in try fm.contentsOfDirectory(atPath: apps.path) where name.hasPrefix(G.stagingPrefix) {
                        try fm.removeItem(at: apps.appendingPathComponent(name))
                    }
                    return away
                })
                expect("a failed rename is reported", false)
            } catch {}
            expect("old copy put back after a failed rename", version(installed) == "1.3.0")

            // A copy that fails part way (one unreadable file) leaves nothing behind
            let broken = downloads.appendingPathComponent("Broken.app")
            makeApp(broken, version: "1.4.0")
            let locked = broken.appendingPathComponent("Contents/MacOS/Locked")
            try! Data("x".utf8).write(to: locked)
            chmod(locked.path, 0)
            do { _ = try G.install(broken, into: apps, discard: toTrash); expect("a failed copy is reported", false) } catch {}
            chmod(locked.path, 0o644)
            expect("installed app untouched by a failed copy", version(installed) == "1.3.0")
            onlyTheApp("no half-built copy left behind", apps)

            // A missing source changes nothing either
            do { _ = try G.install(downloads.appendingPathComponent("Missing.app"), into: apps, discard: toTrash); expect("a missing source is reported", false) } catch {}
            onlyTheApp("nothing left after a missing source", apps)

            // Leftovers from an attempt that was killed are cleared on the next one
            try! fm.createDirectory(at: apps.appendingPathComponent(G.stagingPrefix + "old.app/Contents"), withIntermediateDirectories: true)
            _ = try! G.install(source, into: apps, discard: toTrash)
            onlyTheApp("old leftovers cleared", apps)

            // Not translocated: the location is itself
            expect("original location of a plain path", G.originalLocation(of: source) == source)

            // Clearing quarantine reaches the bundle itself, where Gatekeeper
            // looks. A plain copy drops a folder's own mark, so this is
            // checked on a bundle marked in place rather than through install.
            let marked = downloads.appendingPathComponent("Marked.app")
            makeApp(marked, version: "1.4.0")
            expect("fixture is quarantined at the root", hasQuarantine(marked))
            G.clearQuarantine(marked)
            for path in [marked, marked.appendingPathComponent("Contents"), marked.appendingPathComponent("Contents/MacOS/AirCard")] {
                expect("quarantine cleared in place on \(path.lastPathComponent)", !hasQuarantine(path))
            }

            if failures.isEmpty { print("ok") } else { print(failures.joined(separator: "\n")); exit(1) }
        """)
        out = run_swift({"lifted.swift": self._lifted(), "main.swift": driver})
        self.assertEqual(out.strip(), "ok")

    def test_the_relaunch_script_waits_then_ejects_then_opens(self):
        driver = textwrap.dedent(r"""
            import Foundation
            let tmp = URL(fileURLWithPath: CommandLine.arguments[1])
            let fm = FileManager.default
            var failures: [String] = []
            func expect(_ what: String, _ ok: Bool) { if !ok { failures.append(what) } }
            func run(pid: Int32, eject: URL?) -> Process {
                let sh = Process()
                sh.executableURL = URL(fileURLWithPath: "/bin/sh")
                sh.arguments = InstallGuard.relaunchArguments(pid: pid, open: tmp.appendingPathComponent("App"), eject: eject)
                try! sh.run()
                return sh
            }
            // Waits while the process it was given is alive
            let sleeper = Process()
            sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
            sleeper.arguments = ["1"]
            try! sleeper.run()
            let sh = run(pid: sleeper.processIdentifier, eject: tmp.appendingPathComponent("Vol"))
            Thread.sleep(forTimeInterval: 0.4)
            expect("still waiting while the app runs", sh.isRunning && !fm.fileExists(atPath: tmp.path + "/App.opened"))
            sh.waitUntilExit()
            expect("finished only after the app did", !sleeper.isRunning)
            let opened = (try? fm.attributesOfItem(atPath: tmp.path + "/App.opened")[.modificationDate] as? Date) ?? nil
            let ejected = (try? fm.attributesOfItem(atPath: tmp.path + "/Vol.ejected")[.modificationDate] as? Date) ?? nil
            expect("ejected and opened", opened != nil && ejected != nil)
            if let opened, let ejected { expect("ejected before opening", ejected <= opened) }
            // Nothing to eject: opens without trying
            try? fm.removeItem(atPath: tmp.path + "/App.opened")
            let done = Process(); done.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try! done.run(); done.waitUntilExit()
            run(pid: done.processIdentifier, eject: nil).waitUntilExit()
            expect("opened with nothing to eject", fm.fileExists(atPath: tmp.path + "/App.opened"))
            expect("nothing ejected without a volume", (try? fm.contentsOfDirectory(atPath: tmp.path).filter { $0.hasSuffix(".ejected") && $0 != "Vol.ejected" }) == [])
            if failures.isEmpty { print("ok") } else { print(failures.joined(separator: "\n")); exit(1) }
        """)
        out = run_swift({"lifted.swift": self._lifted(fake_commands=True), "main.swift": driver})
        self.assertEqual(out.strip(), "ok")

    def test_the_relaunch_script_cannot_be_hijacked_by_a_name(self):
        driver = textwrap.dedent(r"""
            import Foundation
            let tmp = URL(fileURLWithPath: CommandLine.arguments[1])
            let done = Process()
            done.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try! done.run(); done.waitUntilExit()
            // Each name is built to run a command if it were pasted into the script:
            // one through $(...) inside double quotes, one by closing the quotes.
            let names = ["App $(touch \(tmp.path)/pwned).app", "App\"; touch \(tmp.path)/pwned2; echo \".app"]
            for name in names {
                let sh = Process()
                sh.executableURL = URL(fileURLWithPath: "/bin/sh")
                sh.arguments = InstallGuard.relaunchArguments(pid: done.processIdentifier, open: tmp.appendingPathComponent(name), eject: nil)
                sh.standardError = FileHandle.nullDevice
                sh.standardOutput = FileHandle.nullDevice
                try! sh.run(); sh.waitUntilExit()
            }
            let hijacked = FileManager.default.fileExists(atPath: tmp.path + "/pwned") || FileManager.default.fileExists(atPath: tmp.path + "/pwned2")
            print(hijacked ? "hijacked" : "ok")
        """)
        out = run_swift({"lifted.swift": self._lifted(), "main.swift": driver})
        self.assertEqual(out.strip(), "ok")


if __name__ == "__main__":
    unittest.main()
