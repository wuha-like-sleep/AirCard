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
        ]
        result = lift(r"(struct SkinImportResult \{.*?\n\})\n")
        body = "\n".join(parts).replace("nonisolated ", "")
        return "import Foundation\n\n" + result + "\n\nenum AppViewModel {\n" + body + "}\n"

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
            for name, source in [("added", pack), ("none", empty), ("missing", root / "gone.zip")]:
                buf = io.StringIO()
                with redirect_stdout(buf):
                    aircard_backend.cmd_import_skins(str(source), str(root / "lib"))
                outputs[name] = buf.getvalue()
        literal = lambda text: "\"\"\"\n" + text.replace("\\", "\\\\") + "\"\"\""
        driver = textwrap.dedent("""
            import Foundation
            func show(_ r: SkinImportResult) -> String { "\\(r.code)|\\(r.imported.joined(separator: ","))|\\(r.skipped)" }
            print(show(AppViewModel.parseSkinImport(Data(ADDED.utf8))))
            print(show(AppViewModel.parseSkinImport(Data(NONE.utf8))))
            print(show(AppViewModel.parseSkinImport(Data(MISSING.utf8))))
            print(show(AppViewModel.parseSkinImport(nil)))
            print(show(AppViewModel.parseSkinImport(Data("Traceback (most recent call last):".utf8))))
            print(show(AppViewModel.parseSkinImport(Data((NONE + "\\n" + ADDED).utf8))))
        """)
        driver = (driver.replace("ADDED", literal(outputs["added"]))
                        .replace("NONE", literal(outputs["none"]))
                        .replace("MISSING", literal(outputs["missing"])))
        out = run_swift({"lifted.swift": self._statics(), "main.swift": driver}).strip().splitlines()
        self.assertEqual(out, [
            "skins.imported|Blue.png|1",
            "skins.none_found||1",
            "skins.not_found||0",
            "skins.unreadable||0",
            "skins.unreadable||0",
            "skins.imported|Blue.png|1",
        ])

    def test_the_library_lists_every_kind_the_importer_writes(self):
        """A kind written but not listed would import 'successfully' and never show."""
        sys.path.insert(0, str(REPO))
        import aircard
        listed = lift(r'nonisolated static let skinFileExtensions: Set<String> = \[([^\]]*)\]')
        listed = set(re.findall(r'"([a-z0-9]+)"', listed))
        written = {ext.lstrip(".") for ext in aircard.SKIN_EXTENSIONS.values()}
        self.assertEqual(written - listed, set())

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


if __name__ == "__main__":
    unittest.main()
