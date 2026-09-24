"""Exercises pure Swift logic from AirCardApp.swift without a Swift test target.

The app is one file built with raw swiftc, so there is nowhere to hang XCTest.
Instead each check lifts the exact source of one type or function out of
AirCardApp.swift, compiles it next to a small driver, and runs it. The code
under test is never copied by hand, so these cannot drift from what ships.
"""

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
        build = subprocess.run(
            ["swiftc", "-sdk", sdk, "-target", "arm64-apple-macosx14.0", *paths, "-o", str(binary)],
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
                ("mid flash", look(true, false, true, "none", true), false),
                ("back to app, mid flash", look(false, false, true, "none", true), false),
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


if __name__ == "__main__":
    unittest.main()
