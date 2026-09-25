import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

// UI text lives in Resources/<lang>.lproj/Localizable.strings. The English wording
// stays at the call site as the fallback, so a missing key still renders normally.
func L(_ key: String, _ fallback: String) -> String {
    Bundle.main.localizedString(forKey: key, value: fallback, table: nil)
}

// Same lookup, for the few strings that carry ** ** emphasis. Text(String) does
// not render markdown, so those would otherwise show the asterisks themselves.
func LM(_ key: String, _ fallback: String) -> AttributedString {
    let text = L(key, fallback)
    return (try? AttributedString(markdown: text)) ?? AttributedString(text)
}

// MARK: - Models

struct DeviceInfo: Codable {
    var udid: String?
    var name: String?
    var version: String?
    var product: String?
    var language: String?
    var locale: String?
    var bold_text: Bool?
    var airlift_compatible: Bool?
    var connection: String?
    var connected: Bool
    var error: String?
}

struct SavedCardsResponse: Codable {
    var ok: Bool
    var cards: [String]?
    // Card hash to the saved original's image, for showing the card as it is.
    var previews: [String: String]?
    // Cards AirCard has written to on this device.
    var flashed: [String]?
}

struct DeviceListResponse: Codable {
    var connected: Bool
    var devices: [DeviceInfo]?
    // Phones seen but not yet trusting this Mac. Optional so an older backend
    // that does not send it still decodes.
    var untrusted: Int?
    var error: String?
}

// One picture in the skin library. Only the location is held; the preview is
// made when its cell first comes into view (see SkinThumbnail).
struct SkinLibraryItem: Identifiable {
    let url: URL
    // Changes whenever the file does (modification time and size), so a picture
    // replaced under the same name does not keep showing the old preview.
    var version: String = ""
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

// Previews are made as cells scroll into view and kept in a bounded cache, so a
// library of hundreds of pictures opens at once instead of after every preview
// has been made, and does not hold hundreds of decoded images in memory.
struct SkinThumbnail: View {
    let url: URL
    var version: String = ""
    @State private var image: NSImage?
    @State private var failed = false

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 240
        return cache
    }()

    private var key: String { url.path + "|" + version }

    var body: some View {
        ZStack {
            Color(NSColor.controlBackgroundColor)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundColor(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: key) {
            let key = self.key
            failed = false
            if let cached = Self.cache.object(forKey: key as NSString) {
                image = cached
                return
            }
            image = nil
            let source = url
            let made = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                AppViewModel.skinThumbnail(source)
            }.value
            guard !Task.isCancelled else { return }
            if let made {
                let thumbnail = NSImage(cgImage: made, size: .zero)
                Self.cache.setObject(thumbnail, forKey: key as NSString)
                image = thumbnail
            } else {
                failed = true
            }
        }
    }
}

// A line under the library's import controls: progress, what was added, or
// what went wrong. Shown in the sheet itself, since an alert on the window
// behind it may not appear while the sheet is up.
struct SkinLibraryNote: Equatable {
    let text: String
    var isError = false
    // Each note is new even when the words repeat, so VoiceOver hears it again.
    let id = UUID()
}

// What the backend said about one import.
struct SkinImportResult {
    var imported: [String] = []
    var skipped = 0
    var duplicates = 0
    var encrypted = 0
    var unsupported = 0
    var overLimit = 0
    var code = ""

    mutating func add(_ other: SkinImportResult) {
        imported += other.imported
        skipped += other.skipped
        duplicates += other.duplicates
        encrypted += other.encrypted
        unsupported += other.unsupported
        overLimit += other.overLimit
    }
}

// Fetches a pack or picture from a link into a folder of its own. It stops at
// the size the importer would refuse anyway, so a wrong link cannot fill the
// disk, and a link that turns out to be a web page is caught before anything
// tries to unpack it.
final class SkinDownloader: NSObject, URLSessionDataDelegate {
    enum Failure: Error, Equatable {
        case status(Int)
        case webPage
        case tooLarge
        case network(String)
        // The link works in a browser but not here: plain http, a certificate
        // problem, or a connection too slow to hold. The browser can fetch it.
        case needsBrowser(String)
        case cancelled
    }

    // Matches MAX_PACK_BYTES in aircard.py. Decimal, like the size shown while
    // downloading: in binary units the counter went on to 419 MB and then
    // said it had stopped at 400.
    static let maxBytes: Int64 = 400_000_000

    private let url: URL
    private let folder: URL
    private let onProgress: @MainActor (Int64) -> Void
    private let onFinish: @MainActor (Result<URL, Failure>) -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var file: URL?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var failure: Failure?

    init(url: URL, folder: URL,
         onProgress: @escaping @MainActor (Int64) -> Void,
         onFinish: @escaping @MainActor (Result<URL, Failure>) -> Void) {
        self.url = url
        self.folder = folder
        self.onProgress = onProgress
        self.onFinish = onFinish
        super.init()
    }

    func start() {
        let config = URLSessionConfiguration.ephemeral
        // Only a connection that goes quiet fails. A slow one that keeps
        // moving is allowed to finish: a fixed 15 minutes cut off every large
        // pack on a slow line at the same point, retry after retry.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        // Callbacks arrive on the main queue, which is what lets them call
        // straight into the view model below.
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        task = session.dataTask(with: url)
        task?.resume()
    }

    func cancel() {
        failure = .cancelled
        task?.cancel()
    }

    // The name the server gives the file, made safe to use as one, so a single
    // picture keeps its own name in the library.
    static func fileName(suggested: String?, url: URL) -> String {
        let raw = suggested ?? url.lastPathComponent
        let cleaned = raw.map { "/:\\".contains($0) || $0.isNewline ? "_" : $0 }
        let name = String(cleaned).trimmingCharacters(in: .whitespaces)
        let meaningless = name.allSatisfy { "_. ".contains($0) }
        return meaningless || name.hasPrefix(".") ? "download" : name
    }

    static func browserCanHelp(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
                .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                .serverCertificateHasUnknownRoot, .clientCertificateRejected, .timedOut].contains(code)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = .status(http.statusCode)
        } else if response.mimeType?.lowercased() == "text/html" {
            failure = .webPage
        } else if response.expectedContentLength > Self.maxBytes {
            failure = .tooLarge
        } else {
            let file = folder.appendingPathComponent(Self.fileName(suggested: response.suggestedFilename, url: url))
            if FileManager.default.createFile(atPath: file.path, contents: nil),
               let handle = try? FileHandle(forWritingTo: file) {
                self.file = file
                self.handle = handle
            } else {
                failure = .network(CocoaError(.fileWriteUnknown).localizedDescription)
            }
        }
        completionHandler(failure == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += Int64(data.count)
        if received > Self.maxBytes {
            failure = .tooLarge
            dataTask.cancel()
            return
        }
        do {
            try handle?.write(contentsOf: data)
        } catch {
            failure = .network(error.localizedDescription)
            dataTask.cancel()
            return
        }
        let received = self.received
        MainActor.assumeIsolated { onProgress(received) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        // The session keeps its delegate alive until it is invalidated.
        session.finishTasksAndInvalidate()
        self.session = nil
        let result: Result<URL, Failure>
        if let failure {
            result = .failure(failure)
        } else if let error {
            result = .failure(Self.browserCanHelp(error) ? .needsBrowser(error.localizedDescription) : .network(error.localizedDescription))
        } else if let file {
            result = .success(file)
        } else {
            result = .failure(.network(URLError(.zeroByteResource).localizedDescription))
        }
        MainActor.assumeIsolated { onFinish(result) }
    }
}

// MARK: - One copy per Mac

// Keeps a single, current AirCard on a Mac. People ran it straight from the
// disk image, dragged a new version in with "Keep Both", or had an old download
// lying around, then opened the wrong one and met an older AirCard. Cards, saved
// originals and the skin library live outside the app, so every copy shares
// them and replacing one loses nothing.
//
// This part only decides and moves files; the prompts are in the extension
// below, so the decisions can be tested without an app running.
enum InstallGuard {
    struct AppCopy: Equatable {
        let url: URL
        let version: String
        let build: String
        var bundleID: String? = nil
    }

    enum Placement: Equatable {
        case installed      // inside an Applications folder
        case diskImage      // on a mounted disk image, which is what the DMG is
        case elsewhere      // Downloads, the Desktop, a build folder, another disk...
    }

    enum MoveDecision: Equatable {
        case alreadyInstalled        // the installed one is this very copy, through a link
        case moveIn
        case replace(older: AppCopy)
        case openInstalled(newer: AppCopy)
        case openInstalledSame(AppCopy)
    }

    enum StrayPlan: Equatable {
        case nothing
        case openNewer(AppCopy)
        case clear([AppCopy])
    }

    // Numeric, part by part, so 1.10 is newer than 1.9 and 1.4 equals 1.4.0.
    nonisolated static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let y = b.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // Version first, then build number.
    nonisolated static func compare(_ a: AppCopy, _ b: AppCopy) -> ComparisonResult {
        let byVersion = compareVersions(a.version, b.version)
        return byVersion != .orderedSame ? byVersion : compareVersions(a.build, b.build)
    }

    // How a copy is named to people: its version, and its build too when that
    // is the only thing telling it apart from the other copy.
    nonisolated static func label(_ copy: AppCopy, against other: AppCopy) -> String {
        compareVersions(copy.version, other.version) == .orderedSame
            && compareVersions(copy.build, other.build) != .orderedSame
            ? "\(copy.version) (\(copy.build))" : copy.version
    }

    nonisolated static func appCopy(at url: URL) -> AppCopy? {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return AppCopy(url: url,
                       version: info["CFBundleShortVersionString"] as? String ?? "0",
                       build: info["CFBundleVersion"] as? String ?? "0",
                       bundleID: info["CFBundleIdentifier"] as? String)
    }

    // One spelling per location, so the same folder reached through a symlink
    // or a trailing slash is recognised as the same place. resolvingSymlinksInPath
    // gives up on a path that does not exist, and /var is itself a link to
    // /private/var, so one place could come out spelt two ways and this copy
    // would not recognise itself. The deepest part that exists is resolved with
    // realpath and the rest put back on.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while existing.path != "/" && !FileManager.default.fileExists(atPath: existing.path) {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var base = existing.path
        if let resolved = realpath(existing.path, nil) {
            base = String(cString: resolved)
            free(resolved)
        }
        // Joined by hand: standardizing again would strip /private from the
        // part that exists and not from the rest, which is the mismatch this
        // function is here to prevent.
        return rest.isEmpty ? base : (base == "/" ? "" : base) + "/" + rest.joined(separator: "/")
    }

    nonisolated static func placement(of url: URL, applicationsFolders: [URL], onDiskImage: Bool) -> Placement {
        let path = canonicalPath(url)
        if applicationsFolders.contains(where: { path.hasPrefix(canonicalPath($0) + "/") }) { return .installed }
        return onDiskImage ? .diskImage : .elsewhere
    }

    // Never offers to put an older copy over a newer one.
    nonisolated static func moveDecision(own: AppCopy, installed: AppCopy?) -> MoveDecision {
        guard let installed else { return .moveIn }
        if canonicalPath(installed.url) == canonicalPath(own.url) { return .alreadyInstalled }
        switch compare(own, installed) {
        case .orderedDescending: return .replace(older: installed)
        case .orderedSame: return .openInstalledSame(installed)
        case .orderedAscending: return .openInstalled(newer: installed)
        }
    }

    // The move offer comes back for a newer copy than the one turned down, so
    // one "Don't ask again" does not silence it for every later version.
    nonisolated static func shouldOfferMove(own: AppCopy, refused: String?) -> Bool {
        guard let refused else { return true }
        let parts = refused.split(separator: "|", maxSplits: 1).map(String.init)
        let turnedDown = AppCopy(url: own.url, version: parts.first ?? "0", build: parts.count > 1 ? parts[1] : "0")
        return compare(own, turnedDown) == .orderedDescending
    }

    nonisolated static func refusalKey(_ own: AppCopy) -> String { own.version + "|" + own.build }

    // Two copies opened at the same moment each see the other. Both yielding
    // left nothing open, so both apply the same rule and exactly one yields:
    // the one that started later, or on a tie the higher process number.
    nonisolated static func shouldYield(theirLaunch: Date?, theirPID: Int32, myLaunch: Date?, myPID: Int32) -> Bool {
        let theirs = theirLaunch ?? .distantFuture
        let mine = myLaunch ?? .distantFuture
        return theirs != mine ? theirs < mine : theirPID < myPID
    }

    // Stray copies worth offering to clear: not this one, not in any Trash,
    // not on a disk image (it goes away when ejected), not on another disk (a
    // backup clone is not a stray), not running, and not one the person
    // already chose to keep.
    nonisolated static func strayCopies(found: [URL], own: URL, running: Set<String>, kept: Set<String>,
                                        exists: (URL) -> Bool, onDiskImage: (URL) -> Bool,
                                        sameVolume: (URL) -> Bool) -> [URL] {
        let ownPath = canonicalPath(own)
        var seen = Set<String>()
        return found.filter { url in
            let path = canonicalPath(url)
            guard path != ownPath, seen.insert(path).inserted else { return false }
            let inTrash = path.split(separator: "/").contains { $0 == ".Trash" || $0 == ".Trashes" }
            return exists(url)
                && !inTrash
                && !onDiskImage(url)
                && sameVolume(url)
                && !running.contains(path)
                && !kept.contains(path)
        }
    }

    // A newer copy elsewhere is dealt with first: this older one must never
    // offer to throw away the newer. Once that one is running, its own check
    // offers to clear this one. An equal copy is not newer, or two equal
    // copies would send the person back and forth for ever.
    nonisolated static func strayPlan(own: AppCopy, strays: [AppCopy]) -> StrayPlan {
        if let newest = strays.filter({ compare($0, own) == .orderedDescending })
            .max(by: { compare($0, $1) == .orderedAscending }) {
            return .openNewer(newest)
        }
        return strays.isEmpty ? .nothing : .clear(strays)
    }

    // What may be thrown away to make room: only an AirCard, and only an older
    // one than the copy moving in. Checked again just before, since the folder
    // can change while a prompt is up.
    nonisolated static func safeToReplace(_ existing: AppCopy?, with own: AppCopy) -> Bool {
        guard let existing else { return false }
        if let id = existing.bundleID, let ownID = own.bundleID, id != ownID { return false }
        if existing.bundleID == nil { return false }
        return compare(own, existing) == .orderedDescending
    }

    struct NotReplaceable: LocalizedError {
        var errorDescription: String? {
            L("install.not_replaceable", "Applications already has something called AirCard.app that is not an older AirCard, so it was left alone.")
        }
    }

    nonisolated static let stagingPrefix = ".AirCard-installing-"

    // Copies the app into the folder as AirCard.app. The copy is made next to
    // it under a hidden name first, so a failure part way leaves the installed
    // app untouched and no half-built copy behind; an older AirCard.app is
    // handed to `discard` (the Trash, in the app) only once the new copy is
    // complete, and put back if the final rename fails.
    nonisolated static func install(_ source: URL, into folder: URL,
                                    discard: (URL) throws -> URL?) throws -> URL {
        let fm = FileManager.default
        // Leftovers of an attempt that was killed part way; only this code
        // makes names like these.
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix(stagingPrefix) && name.hasSuffix(".app") {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
        let destination = folder.appendingPathComponent("AirCard.app")
        let staging = folder.appendingPathComponent(stagingPrefix + UUID().uuidString + ".app")
        var placed = false
        defer { if !placed { try? fm.removeItem(at: staging) } }
        try fm.copyItem(at: source, to: staging)
        clearQuarantine(staging)
        var discarded: URL?
        if fm.fileExists(atPath: destination.path) {
            discarded = try discard(destination)
        }
        do {
            try fm.moveItem(at: staging, to: destination)
            placed = true
        } catch {
            if let discarded { try? fm.moveItem(at: discarded, to: destination) }
            throw error
        }
        return destination
    }

    // The copy has already been opened and allowed once, from where it was;
    // without this the moved copy would be stopped again as a fresh download.
    nonisolated static func clearQuarantine(_ bundle: URL) {
        let attribute = "com.apple.quarantine"
        removexattr(bundle.path, attribute, XATTR_NOFOLLOW)
        guard let items = FileManager.default.enumerator(atPath: bundle.path) else { return }
        for case let item as String in items {
            removexattr(bundle.appendingPathComponent(item).path, attribute, XATTR_NOFOLLOW)
        }
    }

    // Waits for this process to end, ejects the disk image it ran from if
    // there was one, and opens the installed copy. The paths are passed as
    // arguments, never pasted into the script, so no name can break out of it.
    nonisolated static let relaunchScript = """
    while /bin/kill -0 "$1" >/dev/null 2>&1; do /bin/sleep 0.2; done
    if [ -n "$3" ]; then /usr/bin/hdiutil detach "$3" -quiet >/dev/null 2>&1; fi
    /usr/bin/open "$2"
    """

    nonisolated static func relaunchArguments(pid: Int32, open app: URL, eject volume: URL?) -> [String] {
        ["-c", relaunchScript, "aircard-relaunch", String(pid), app.path, volume?.path ?? ""]
    }

    // Only the disk image the app ran from is ejected, never whatever other
    // disk it happened to be on.
    nonisolated static func ejectTarget(placement: Placement, volume: URL?) -> URL? {
        guard placement == .diskImage, let volume, volume.path.hasPrefix("/Volumes/") else { return nil }
        return volume
    }

    // Mount points of attached disk images, from `hdiutil info -plist`. Being
    // read-only is not enough to be the DMG: Time Machine, a locked card or a
    // read-only share are too, and must never be ejected or treated as one.
    nonisolated static func diskImageMountPoints(fromHdiutilInfo data: Data) -> Set<String> {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        var points = Set<String>()
        for image in images {
            for entity in image["system-entities"] as? [[String: Any]] ?? [] {
                if let point = entity["mount-point"] as? String { points.insert(point) }
            }
        }
        return points
    }

    nonisolated static func mountedDiskImages() -> Set<String> {
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        run.arguments = ["info", "-plist"]
        let pipe = Pipe()
        run.standardOutput = pipe
        run.standardError = FileHandle.nullDevice
        guard (try? run.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        run.waitUntilExit()
        return diskImageMountPoints(fromHdiutilInfo: data)
    }

    nonisolated static func isOnDiskImage(_ url: URL, mounted: Set<String>) -> Bool {
        guard let volume = volume(of: url) else { return false }
        let point = canonicalPath(volume)
        return mounted.contains(point) || mounted.contains(volume.path)
    }

    // Where a copy run from Downloads or a disk image was really opened from.
    // macOS runs such a copy from a random read-only folder (App Translocation),
    // and only Security.framework knows the original.
    nonisolated static func originalLocation(of url: URL) -> URL {
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isSym = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let origSym = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return url }
        let isTranslocated = unsafeBitCast(isSym, to: IsTranslocated.self)
        let originalPath = unsafeBitCast(origSym, to: OriginalPath.self)
        var translocated = false
        guard isTranslocated(url as CFURL, &translocated, nil), translocated,
              let original = originalPath(url as CFURL, nil)?.takeRetainedValue() else { return url }
        return original as URL
    }

    nonisolated static func volume(of url: URL) -> URL? {
        (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
    }
}

extension InstallGuard {
    static let keptCopiesKey = "installGuard.keptCopies"
    static let refusedMoveKey = "installGuard.refusedMoveFor"
    static let useHereKey = "installGuard.useCopyAt"

    static var systemApplications: URL { URL(fileURLWithPath: "/Applications", isDirectory: true) }
    static var userApplications: URL {
        FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)[0]
    }
    static var applicationsFolders: [URL] { [systemApplications, userApplications] }

    // At launch: hand over to a copy that is already running, otherwise offer
    // to move into Applications, or, once there, to clear out stray copies.
    @MainActor static func runAtLaunch() {
        guard let running = appCopy(at: Bundle.main.bundleURL) else { return }
        if handOverToRunningCopy(own: running) { return }
        let original = originalLocation(of: Bundle.main.bundleURL)
        let own = AppCopy(url: original, version: running.version, build: running.build, bundleID: running.bundleID)
        let place = placement(of: original, applicationsFolders: applicationsFolders,
                              onDiskImage: isOnDiskImage(original, mounted: mountedDiskImages()))
        if place == .installed {
            offerToClearStrayCopies(own: own)
        } else {
            offerToMoveIn(own: own, placement: place)
        }
    }

    // Two copies running at once both talk to the phone and both write the card
    // list. The one that started first stays; this one brings it forward and quits.
    @MainActor static func handOverToRunningCopy(own: AppCopy) -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: {
            $0.processIdentifier != me.processIdentifier && !$0.isTerminated
                && shouldYield(theirLaunch: $0.launchDate, theirPID: $0.processIdentifier,
                               myLaunch: me.launchDate, myPID: me.processIdentifier)
        }) else { return false }
        let otherVersion = other.bundleURL.flatMap { appCopy(at: $0) }?.version ?? "?"
        if compareVersions(otherVersion, own.version) != .orderedSame {
            _ = ask(title: L("install.running_title", "AirCard is already open"),
                    body: String(format: L("install.running_body", "AirCard %1$@ is already open. Quit it first if you want to use version %2$@."), otherVersion, own.version),
                    buttons: [L("ui.ok", "OK")])
        }
        other.activate()
        NSApp.terminate(nil)
        return true
    }

    // The installed copy to measure against: the newest AirCard in either
    // Applications folder.
    static func installedCopies() -> [AppCopy] {
        applicationsFolders.compactMap { appCopy(at: $0.appendingPathComponent("AirCard.app")) }
    }

    // Where a move goes: /Applications when this account can write there,
    // otherwise the account's own Applications folder, so a standard user is
    // not shown an offer that can only fail, again at every launch.
    static func moveTarget() -> URL {
        FileManager.default.isWritableFile(atPath: systemApplications.path) ? systemApplications : userApplications
    }

    @MainActor static func offerToMoveIn(own: AppCopy, placement: Placement) {
        let defaults = UserDefaults.standard
        if (defaults.stringArray(forKey: useHereKey) ?? []).contains(canonicalPath(own.url)) { return }
        let newest = installedCopies().max { compare($0, $1) == .orderedAscending }
        switch moveDecision(own: own, installed: newest) {
        case .alreadyInstalled:
            offerToClearStrayCopies(own: own)
        case .openInstalled(let newer):
            let answer = ask(title: L("install.newer_installed_title", "A newer AirCard is already installed"),
                             body: String(format: L("install.newer_installed_body", "Applications has AirCard %1$@, and this copy is %2$@."), label(newer, against: own), label(own, against: newer)),
                             buttons: [L("install.open_installed", "Open the Installed One"), L("install.use_this_copy", "Use This Copy")])
            if answer == 0 { switchTo(newer.url) } else { rememberUseHere(own) }
        case .openInstalledSame(let same):
            let answer = ask(title: L("install.same_installed_title", "AirCard is already in Applications"),
                             body: String(format: L("install.same_installed_body", "The copy in Applications is the same version, %@. Use that one, so there is one AirCard in use on this Mac?"), own.version),
                             buttons: [L("install.open_installed", "Open the Installed One"), L("install.use_this_copy", "Use This Copy")])
            if answer == 0 { switchTo(same.url) } else { rememberUseHere(own) }
        case .moveIn, .replace:
            guard shouldOfferMove(own: own, refused: defaults.string(forKey: refusedMoveKey)) else { return }
            let target = moveTarget()
            var body = placement == .diskImage
                ? L("install.move_body_disk_image", "AirCard is running from its disk image. Moved into Applications, it keeps working after the disk image is ejected, and this Mac has one copy of it.")
                : String(format: L("install.move_body_folder", "AirCard is running from “%@”. Moved into Applications, it is where you would look for it, and this Mac has one copy of it."),
                         FileManager.default.displayName(atPath: own.url.deletingLastPathComponent().path))
            let replaced = appCopy(at: target.appendingPathComponent("AirCard.app"))
            if let replaced, safeToReplace(replaced, with: own) {
                body += "\n\n" + String(format: L("install.move_replaces", "The older AirCard %@ in Applications goes to the Trash."), label(replaced, against: own))
            }
            let (answer, neverAgain) = askWithNeverAgain(
                title: L("install.move_title", "Move AirCard to Applications?"), body: body,
                buttons: [L("install.move_button", "Move to Applications"), L("install.not_now", "Not Now")])
            if answer == 0 {
                moveIn(own: own, placement: placement, into: target)
            } else if neverAgain {
                defaults.set(refusalKey(own), forKey: refusedMoveKey)
            }
        }
    }

    static func rememberUseHere(_ own: AppCopy) {
        let defaults = UserDefaults.standard
        let places = Set(defaults.stringArray(forKey: useHereKey) ?? []).union([canonicalPath(own.url)])
        defaults.set(Array(places).sorted(), forKey: useHereKey)
    }

    @MainActor static func moveIn(own: AppCopy, placement: Placement, into folder: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let installed = try install(own.url, into: folder) { old in
                // Looked at again now, not when the prompt was built.
                guard safeToReplace(appCopy(at: old), with: own) else { throw NotReplaceable() }
                var trashed: NSURL?
                try FileManager.default.trashItem(at: old, resultingItemURL: &trashed)
                return trashed as URL?
            }
            // Moved, not copied: a copy left in Downloads would be the next
            // stray. A disk image is ejected instead, once this copy has quit.
            let eject = ejectTarget(placement: placement, volume: volume(of: own.url))
            if placement == .elsewhere {
                try? FileManager.default.trashItem(at: own.url, resultingItemURL: nil)
            }
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = relaunchArguments(pid: ProcessInfo.processInfo.processIdentifier, open: installed, eject: eject)
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            _ = ask(title: L("install.move_failed_title", "AirCard could not be moved"),
                    body: String(format: L("install.move_failed_body", "%@\n\nYou can drag AirCard into Applications in Finder instead."), error.localizedDescription),
                    buttons: [L("ui.ok", "OK")])
        }
    }

    @MainActor static func offerToClearStrayCopies(own: AppCopy) {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let defaults = UserDefaults.standard
        let kept = Set(defaults.stringArray(forKey: keptCopiesKey) ?? [])
        let running = Set(NSRunningApplication.runningApplications(withBundleIdentifier: id).compactMap { $0.bundleURL.map { canonicalPath($0) } })
        let mounted = mountedDiskImages()
        let ownVolume = volume(of: own.url).map { canonicalPath($0) }
        let urls = strayCopies(found: NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id),
                               own: own.url, running: running, kept: kept,
                               exists: { FileManager.default.fileExists(atPath: $0.path) },
                               onDiskImage: { isOnDiskImage($0, mounted: mounted) },
                               sameVolume: { url in volume(of: url).map { canonicalPath($0) } == ownVolume })
        let strays = urls.compactMap { appCopy(at: $0) }
        switch strayPlan(own: own, strays: strays) {
        case .nothing:
            return
        case .openNewer(let newer):
            let answer = ask(title: L("install.newer_elsewhere_title", "A newer AirCard is on this Mac"),
                             body: String(format: L("install.newer_elsewhere_body", "AirCard %1$@ is in %2$@, and this one is %3$@. Open the newer one?"), label(newer, against: own), place(of: newer.url), label(own, against: newer)),
                             buttons: [L("install.open_newer", "Open the Newer One"), L("install.keep_them", "Keep Them")])
            if answer == 0 { switchTo(newer.url) } else { remember(kept: [newer.url]) }
        case .clear(let copies):
            let list = copies.map { String(format: L("install.copy_line", "AirCard %1$@ in %2$@"), label($0, against: own), place(of: $0.url)) }
                .joined(separator: "\n")
            // Only called older when they are: a same-version copy is an extra,
            // not an older AirCard.
            let allOlder = copies.allSatisfy { compare($0, own) == .orderedAscending }
            let body = allOlder
                ? String(format: L("install.copies_body", "%@\n\nOpening one of them by mistake starts an older AirCard. Move them to the Trash? Your cards, saved originals and skin library stay, because every copy shares them."), list)
                : String(format: L("install.copies_body_extra", "%1$@\n\nThis AirCard is %2$@, so these are extra copies. Move them to the Trash, so one AirCard is in use? Your cards, saved originals and skin library stay, because every copy shares them."), list, own.version)
            let answer = ask(title: L("install.copies_title", "Other copies of AirCard are on this Mac"), body: body,
                             buttons: [L("skins.move_to_trash", "Move to Trash"), L("install.keep_them", "Keep Them")])
            if answer == 0 {
                var failed: [String] = []
                for copy in copies {
                    do { try FileManager.default.trashItem(at: copy.url, resultingItemURL: nil) }
                    catch { failed.append(place(of: copy.url)) }
                }
                if !failed.isEmpty {
                    _ = ask(title: L("install.copies_title", "Other copies of AirCard are on this Mac"),
                            body: String(format: L("install.trash_failed", "These could not be moved to the Trash, so they are still there:\n%@"), failed.joined(separator: "\n")),
                            buttons: [L("ui.ok", "OK")])
                }
            } else {
                remember(kept: copies.map(\.url))
            }
        }
    }

    // The folder as Finder names it, with its parent, in the person's language.
    static func place(of app: URL) -> String {
        let parts = FileManager.default.componentsToDisplay(forPath: app.deletingLastPathComponent().path) ?? [app.deletingLastPathComponent().lastPathComponent]
        return parts.suffix(2).joined(separator: " › ")
    }

    static func remember(kept urls: [URL]) {
        let defaults = UserDefaults.standard
        let kept = Set(defaults.stringArray(forKey: keptCopiesKey) ?? []).union(urls.map { canonicalPath($0) })
        defaults.set(Array(kept).sorted(), forKey: keptCopiesKey)
    }

    // Opened only after this copy has quit. Opened straight away, the other
    // copy's launch check could find this one still running and hand over to
    // it just as this one quits, leaving nothing open.
    @MainActor static func switchTo(_ app: URL) {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = relaunchArguments(pid: ProcessInfo.processInfo.processIdentifier, open: app, eject: nil)
        do {
            try relaunch.run()
        } catch {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
        NSApp.terminate(nil)
    }

    // Returns the index of the button pressed.
    @MainActor static func ask(title: String, body: String, buttons: [String]) -> Int {
        askWithNeverAgain(title: title, body: body, buttons: buttons, offerNeverAgain: false).answer
    }

    @MainActor static func askWithNeverAgain(title: String, body: String, buttons: [String],
                                             offerNeverAgain: Bool = true) -> (answer: Int, neverAgain: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        for button in buttons { alert.addButton(withTitle: button) }
        if offerNeverAgain {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L("install.dont_ask", "Don't ask again")
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        return (response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue,
                offerNeverAgain && alert.suppressionButton?.state == .on)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        InstallGuard.runAtLaunch()
    }

    // Closing the window used to quit on the spot, mid-flash: the rest of the
    // cards were never sent and nothing said which went through. While the
    // phone is being written to, the app keeps running without its window;
    // the Dock icon brings it back.
    @MainActor func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(AppViewModel.shared?.isFlashing ?? false)
    }

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppViewModel.shared?.isFlashing == true else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("quit.busy_title", "AirCard is still working with your iPhone")
        alert.informativeText = L("quit.busy_body", "Quitting now can leave a card with only part of its new artwork. Let it finish, or quit anyway.")
        alert.addButton(withTitle: L("quit.keep_working", "Let It Finish"))
        alert.addButton(withTitle: L("quit.quit_anyway", "Quit Anyway"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}

struct CardItem: Identifiable, Hashable {
    let id: String
    var isSelected: Bool = true
    var customImageURL: URL? = nil
    var customImage: NSImage? = nil
    // The editable design behind customImage, when it came from the designer.
    // Without it, reopening the designer started from the flattened render, so
    // the picture could not be re-framed and zooming out showed its old edges.
    var design: CardFaceDesign? = nil
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: CardItem, rhs: CardItem) -> Bool {
        lhs.id == rhs.id && lhs.isSelected == rhs.isSelected && lhs.customImageURL == rhs.customImageURL
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case walletCards = "Apple Wallet"
    case passcodeThemes = "Passcode (.passthm)"
    var id: String { rawValue }
    // rawValue is the tag and Codable identity, so display text goes through here.
    var title: String {
        switch self {
        case .walletCards: return L("tab.wallet_cards", "Apple Wallet")
        case .passcodeThemes: return L("tab.passcode_themes", "Passcode (.passthm)")
        }
    }
}

struct PasscodeThemeInfo: Identifiable {
    var id: String { filePath }
    let name: String
    let filePath: String
    let detectedVersion: String
    let fileCount: Int
    let keysPreview: [String: NSImage]
}

enum PasscodeTabMode: String, CaseIterable, Identifiable {
    case applyTheme = "Apply .passthm"
    case themeCreator = "Theme Creator"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .applyTheme: return L("mode.apply_theme", "Apply .passthm")
        case .themeCreator: return L("mode.theme_creator", "Theme Creator")
        }
    }
}

enum CreatorSubMode: String, CaseIterable, Identifiable {
    case posterSlice = "Poster Slice (Puzzle)"
    case individualKeys = "Individual Keys"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .posterSlice: return L("mode.poster_slice", "Poster Slice (Puzzle)")
        case .individualKeys: return L("mode.individual_keys", "Individual Keys")
        }
    }
}

enum PasscodeLanguageTarget: String, CaseIterable, Identifiable {
    case all = "All Languages (Universal)"
    case uk = "Ukrainian (uk)"
    case ru = "Russian (ru)"
    case en = "English (en)"
    case other = "Other / Fallback"
    case es = "Spanish (es)"
    case de = "German (de)"
    case fr = "French (fr)"
    case pl = "Polish (pl)"
    case it = "Italian (it)"
    case pt = "Portuguese (pt)"
    case tr = "Turkish (tr)"
    case ja = "Japanese (ja)"
    case ko = "Korean (ko)"
    case zh = "Chinese (zh)"
    case ar = "Arabic (ar)"
    case he = "Hebrew (he)"
    
    var id: String { rawValue }

    // Each language is named the way it names itself, so a Ukrainian picking
    // Ukrainian sees the word they would look for. Only the two generic entries
    // are translated.
    var title: String {
        switch self {
        case .all: return L("lang.all", "All Languages (Universal)")
        case .other: return L("lang.other", "Other / Fallback")
        case .uk: return "Українська (uk)"
        case .ru: return "Русский (ru)"
        case .en: return "English (en)"
        case .es: return "Español (es)"
        case .de: return "Deutsch (de)"
        case .fr: return "Français (fr)"
        case .pl: return "Polski (pl)"
        case .it: return "Italiano (it)"
        case .pt: return "Português (pt)"
        case .tr: return "Türkçe (tr)"
        case .ja: return "日本語 (ja)"
        case .ko: return "한국어 (ko)"
        case .zh: return "中文 (zh)"
        case .ar: return "العربية (ar)"
        case .he: return "עברית (he)"
        }
    }

    var code: String {
        switch self {
        case .all: return "all"
        case .uk: return "uk"
        case .ru: return "ru"
        case .en: return "en"
        case .other: return "other"
        case .es: return "es"
        case .de: return "de"
        case .fr: return "fr"
        case .pl: return "pl"
        case .it: return "it"
        case .pt: return "pt"
        case .tr: return "tr"
        case .ja: return "ja"
        case .ko: return "ko"
        case .zh: return "zh"
        case .ar: return "ar"
        case .he: return "he"
        }
    }
}

enum PasscodeBoldTarget: String, CaseIterable, Identifiable {
    case both = "Universal (Regular + Bold)"
    case boldOnly = "Bold Text Only (Fast)"
    case regularOnly = "Regular Font Only (Fast)"
    
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: return L("bold.both", "Universal (Regular + Bold)")
        case .boldOnly: return L("bold.bold_only", "Bold Text Only (Fast)")
        case .regularOnly: return L("bold.regular_only", "Regular Font Only (Fast)")
        }
    }

    // .code is the argument the backend takes; it has no business on screen.
    var shortTitle: String {
        switch self {
        case .both: return L("bold.short_both", "Regular + Bold")
        case .boldOnly: return L("bold.short_bold", "Bold")
        case .regularOnly: return L("bold.short_regular", "Regular")
        }
    }
    
    var code: String {
        switch self {
        case .both: return "both"
        case .boldOnly: return "bold"
        case .regularOnly: return "regular"
        }
    }
}

struct KeypadButtonGeometry: Identifiable {
    var id: String { digit }
    let digit: String
    let letters: String
    let row: Int
    let col: Int
}

struct KeypadLayout {
    static let buttonDiameter: CGFloat = 75.0
    static let gridWidth: CGFloat = 305.0 // 915.0 / 3
    static let gridHeight: CGFloat = 1148.0 / 3.0 // 382.6666666666667
    static let colWidth: CGFloat = 305.0 / 3.0 // 101.66666666666667
    static let rowHeight: CGFloat = 1148.0 / 12.0 // 287.0 / 3 = 95.66666666666667
    static let horizontalSpacing: CGFloat = 24.0
    static let verticalSpacing: CGFloat = 18.0
    
    static let allButtons: [KeypadButtonGeometry] = [
        KeypadButtonGeometry(digit: "1", letters: "", row: 0, col: 0),
        KeypadButtonGeometry(digit: "2", letters: "A B C", row: 0, col: 1),
        KeypadButtonGeometry(digit: "3", letters: "D E F", row: 0, col: 2),
        KeypadButtonGeometry(digit: "4", letters: "G H I", row: 1, col: 0),
        KeypadButtonGeometry(digit: "5", letters: "J K L", row: 1, col: 1),
        KeypadButtonGeometry(digit: "6", letters: "M N O", row: 1, col: 2),
        KeypadButtonGeometry(digit: "7", letters: "P Q R S", row: 2, col: 0),
        KeypadButtonGeometry(digit: "8", letters: "T U V", row: 2, col: 1),
        KeypadButtonGeometry(digit: "9", letters: "W X Y Z", row: 2, col: 2),
        KeypadButtonGeometry(digit: "0", letters: "+", row: 3, col: 1)
    ]
    
    static let keypadSubtexts: [String: String] = [
        "0": "+",
        "1": "",
        "2": "A B C",
        "3": "D E F",
        "4": "G H I",
        "5": "J K L",
        "6": "M N O",
        "7": "P Q R S",
        "8": "T U V",
        "9": "W X Y Z"
    ]
    
    static func cellFrame(for button: KeypadButtonGeometry) -> CGRect {
        let x = CGFloat(button.col) * colWidth
        let y = CGFloat(button.row) * rowHeight
        return CGRect(x: x, y: y, width: colWidth, height: rowHeight)
    }
}

// MARK: - Keypad Slicing Engine

class KeypadSlicer {
    static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cg
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(image.size.width)),
            pixelsHigh: max(1, Int(image.size.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        
        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
    
    static func slicePoster(
        image: NSImage,
        zoom: Double = 1.0,
        offset: CGPoint = .zero,
        maskToCircles: Bool = false
    ) -> [String: NSImage] {
        guard let cgImg = cgImage(from: image) else { return [:] }
        let imgW = CGFloat(cgImg.width)
        let imgH = CGFloat(cgImg.height)
        guard imgW > 0 && imgH > 0 else { return [:] }
        
        // Standard iOS TelephonyUI @3x grid dimensions
        let gridW: CGFloat = 915.0
        let gridH: CGFloat = 1148.0
        let colW: CGFloat = 305.0
        let rowH: CGFloat = 287.0
        
        let imgAspect = imgW / imgH
        let gridAspect = gridW / gridH
        
        let scaledW: CGFloat
        let scaledH: CGFloat
        if imgAspect > gridAspect {
            // Image is wider than grid -> fit height
            scaledH = gridH * CGFloat(max(0.1, zoom))
            scaledW = scaledH * imgAspect
        } else {
            // Image is taller than grid -> fit width
            scaledW = gridW * CGFloat(max(0.1, zoom))
            scaledH = scaledW / imgAspect
        }
        
        // Match user's pan offset in SwiftUI points (scaled to 3x)
        let imageX = (gridW - scaledW) / 2.0 + offset.x * 3.0
        let imageY = (gridH - scaledH) / 2.0 + offset.y * 3.0
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var results: [String: NSImage] = [:]
        
        for button in KeypadLayout.allButtons {
            let isZeroSeamless = (!maskToCircles && button.digit == "0")
            let tileW: CGFloat = isZeroSeamless ? gridW : colW
            let tileH: CGFloat = rowH
            
            let cellX: CGFloat = isZeroSeamless ? 0.0 : CGFloat(button.col) * colW
            let cellY: CGFloat = CGFloat(button.row) * rowH
            
            let relX = imageX - cellX
            let relY = imageY - cellY
            let destCGY = tileH - relY - scaledH
            
            guard let ctx = CGContext(
                data: nil,
                width: Int(tileW),
                height: Int(tileH),
                bitsPerComponent: 8,
                bytesPerRow: Int(tileW) * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            
            ctx.clear(CGRect(x: 0, y: 0, width: tileW, height: tileH))
            
            if maskToCircles {
                let circleDiameter: CGFloat = 225.0
                let circleX = (tileW - circleDiameter) / 2.0
                let circleY = (tileH - circleDiameter) / 2.0
                ctx.addEllipse(in: CGRect(x: circleX, y: circleY, width: circleDiameter, height: circleDiameter))
                ctx.clip()
            }
            
            ctx.draw(cgImg, in: CGRect(x: relX, y: destCGY, width: scaledW, height: scaledH))
            
            if let outCG = ctx.makeImage() {
                results[button.digit] = NSImage(cgImage: outCG, size: NSSize(width: tileW, height: tileH))
            }
        }
        return results
    }
    
    static func cropToCircle(
        image: NSImage,
        targetSize: CGSize = CGSize(width: 225, height: 225),
        circleDiameter: CGFloat = 222.0,
        zoom: Double = 1.0,
        offset: CGPoint = .zero
    ) -> NSImage? {
        guard let cgImg = cgImage(from: image) else { return nil }
        let imgW = CGFloat(cgImg.width)
        let imgH = CGFloat(cgImg.height)
        guard imgW > 0 && imgH > 0 else { return nil }
        
        // Scale image to fill the circle area with zoom
        let baseScale = max(circleDiameter / imgW, circleDiameter / imgH) * CGFloat(max(0.1, zoom))
        let scaledW = imgW * baseScale
        let scaledH = imgH * baseScale
        
        let circleX = (targetSize.width - circleDiameter) / 2.0
        let circleY = (targetSize.height - circleDiameter) / 2.0
        
        // User pan offset in SwiftUI points (multiplied by 3 for @3x canvas)
        let destX = circleX + (circleDiameter - scaledW) / 2.0 + offset.x * 3.0
        let destY = circleY + (circleDiameter - scaledH) / 2.0 + offset.y * 3.0
        let destCGY = targetSize.height - destY - scaledH
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(targetSize.width) * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        ctx.clear(CGRect(origin: .zero, size: targetSize))
        ctx.addEllipse(in: CGRect(x: circleX, y: circleY, width: circleDiameter, height: circleDiameter))
        ctx.clip()
        ctx.draw(cgImg, in: CGRect(x: destX, y: destCGY, width: scaledW, height: scaledH))
        
        guard let outCG = ctx.makeImage() else { return nil }
        return NSImage(cgImage: outCG, size: targetSize)
    }
}

// MARK: - Passcode Theme Exporter

class PasscodeThemeExporter {
    static func pngData(from image: NSImage) -> Data? {
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(image.size.width)),
            pixelsHigh: max(1, Int(image.size.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        
        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
    
    static let supportedLocales = [
        "en", "other", "ru", "uk", "es", "fr", "de", "it", "pt", "tr", "pl", "nl", "ja", "ko", "zh", "ar", "he"
    ]
    
    static func exportTheme(
        keys: [String: NSImage],
        targetURL: URL,
        language: PasscodeLanguageTarget = .all,
        boldMode: PasscodeBoldTarget = .both
    ) throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("passthm_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        let localesToExport: [String]
        if language == .all {
            localesToExport = supportedLocales
        } else {
            var setL = [language.code]
            if language.code != "other" { setL.append("other") }
            localesToExport = setL
        }
        
        let boldSuffixes: [String]
        switch boldMode {
        case .both: boldSuffixes = ["", "-bold"]
        case .boldOnly: boldSuffixes = ["-bold"]
        case .regularOnly: boldSuffixes = [""]
        }
        
        for ver in ["TelephonyUI-10", "TelephonyUI-9"] {
            let verDir = tempDir.appendingPathComponent(ver)
            try FileManager.default.createDirectory(at: verDir, withIntermediateDirectories: true)
            
            let markerFile = verDir.appendingPathComponent("_big")
            FileManager.default.createFile(atPath: markerFile.path, contents: Data())
            
            for (digit, image) in keys {
                guard let pngData = pngData(from: image) else { continue }
                let subtext = KeypadLayout.keypadSubtexts[digit] ?? ""
                
                for lang in localesToExport {
                    for boldSuffix in boldSuffixes {
                        // Blank variant: lang-digit---white[-bold].png
                        let blankFn = "\(lang)-\(digit)---white\(boldSuffix).png"
                        let blankURL = verDir.appendingPathComponent(blankFn)
                        try? pngData.write(to: blankURL)
                        
                        // Subtext variant: lang-digit-subtext--white[-bold].png
                        if !subtext.isEmpty {
                            let subFn = "\(lang)-\(digit)-\(subtext)--white\(boldSuffix).png"
                            let subURL = verDir.appendingPathComponent(subFn)
                            try? pngData.write(to: subURL)
                        }
                    }
                }
            }
        }
        
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-r", "-q", targetURL.path, "TelephonyUI-10", "TelephonyUI-9"]
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "PasscodeThemeExporter",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create .passthm zip archive (exit code \(process.terminationStatus))"]
            )
        }
    }
    
    // Themes packed from the Creator only to be sent. Every send left a whole
    // archive behind; now each replaces the last, and the folder is cleared at
    // launch.
    static var stagingFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AirCard-staged-themes", isDirectory: true)
    }

    static func clearStagedThemes() {
        try? FileManager.default.removeItem(at: stagingFolder)
    }

    static func stageTemporaryTheme(
        keys: [String: NSImage],
        language: PasscodeLanguageTarget = .all,
        boldMode: PasscodeBoldTarget = .both
    ) -> URL? {
        clearStagedThemes()
        try? FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        let tempURL = stagingFolder.appendingPathComponent("AirCard_Custom_\(UUID().uuidString).passthm")
        do {
            try exportTheme(keys: keys, targetURL: tempURL, language: language, boldMode: boldMode)
            return tempURL
        } catch {
            print("Failed to stage temporary theme: \(error)")
            return nil
        }
    }
}

// MARK: - View Model

@MainActor
class AppViewModel: ObservableObject {
    @Published var selectedTab: AppTab = .walletCards
    @Published var loadedPasscodeTheme: PasscodeThemeInfo? = nil
    @Published var isInspectingTheme = false
    @Published var targetTelephonyVersion: String = "TelephonyUI-10"
    @Published var passcodeLanguageTarget: PasscodeLanguageTarget = .all
    @Published var passcodeBoldTarget: PasscodeBoldTarget = .both
    // The phone the passcode targets were last set from.
    private var preferencesAppliedFor: String?
    
    // Theme Creator Properties
    @Published var passcodeTabMode: PasscodeTabMode = .applyTheme
    @Published var creatorSubMode: CreatorSubMode = .posterSlice
    @Published var creatorPosterImage: NSImage? = nil
    @Published var creatorPosterZoom: Double = 1.0
    @Published var creatorPosterOffset: CGPoint = .zero
    @Published var creatorMaskToCircles: Bool = false
    @Published var creatorCustomKeys: [String: NSImage] = [:]
    @Published var creatorSlicedKeys: [String: NSImage] = [:]
    @Published var creatorRawIndividualImages: [String: NSImage] = [:]
    @Published var creatorIndividualOffsets: [String: CGPoint] = [:]
    @Published var creatorIndividualZooms: [String: Double] = [:]
    @Published var selectedKeyDigit: String? = nil
    
    @Published var device: DeviceInfo?
    @Published var devices: [DeviceInfo] = []
    // Cards whose original artwork is saved on this Mac, so restore is real.
    @Published var backedUpCards: Set<String> = []
    // The card as it looked before any skin, from its saved original.
    @Published var originalPreviews: [String: NSImage] = [:]
    // The card whose face is open in the designer, if any.
    @Published var designingCardID: String?
    // True when the designer is framing one picture for every selected card.
    @Published var designingAllSelected = false
    // A picture just picked or dropped, to start a fresh design from. Without
    // one, the designer reopens the card's existing design.
    @Published var designerSeed: NSImage?
    // Pictures saved in the skin library, newest imports first.
    @Published var skinLibrary: [SkinLibraryItem] = []
    @Published var showSkinLibrary = false
    // The card a picture chosen in the library goes to. Nil means every
    // selected card.
    @Published var skinLibraryCardID: String?
    @Published var skinLibraryNote: SkinLibraryNote?
    @Published var isImportingSkins = false { didSet { updateKeepAwake() } }
    @Published var isDownloadingSkins = false { didSet { updateKeepAwake() } }
    // "Downloading... 12 MB" or "Adding...", kept apart from the outcome line so
    // the counter cannot wipe a message before anyone reads it.
    @Published var skinProgress: String?
    // Bumped when a download finishes, so the sheet can clear the link then and
    // not before: a failed download still needs the link to try in a browser.
    @Published var skinDownloadSucceeded = 0
    private var skinNoteUnseen = false
    private var pendingSkinImports: [(sources: [URL], temporary: URL?)] = []
    private var batchSkinResult = SkinImportResult()
    private var batchSkinUnreadable = 0
    private var awakeActivity: NSObjectProtocol?
    // Held until the library has closed, then handed to the designer: two
    // sheets cannot be up at once.
    private var skinChosenFromLibrary: NSImage?
    private var skinDownload: SkinDownloader?
    // Names from this session's imports, so they show first rather than
    // scattered through a library sorted by name.
    private var recentSkinImports: [String] = []
    // A phone is plugged in but has not trusted this Mac yet.
    @Published var awaitingTrust = false
    // AirCard's own device helper failed; not the same as no phone.
    @Published var helperFailed = false
    // Connected, but not something AirCard can work with as it stands.
    @Published var deviceWarning = false
    // Why device detection could not run at all, until it can. Shown on the
    // main screen: the alert that says it comes once and is easy to dismiss.
    @Published var backendFailure: BackendFailure?
    // Keeps looking for a phone while none is connected, so nobody has to
    // unplug and replug, or find the refresh button, after answering a prompt.
    private var deviceWatch: Timer?
    private var activationObserver: NSObjectProtocol?
    // What the last check concluded. Messages, logs and alerts fire only when
    // this changes, or a broken backend would raise an alert every few seconds.
    private var lastDeviceState = ""
    // True once a flash has gone quiet long enough that the user deserves to be
    // told, rather than left looking at a bar that is not moving.
    @Published var flashStalled = false
    // The reason the last passcode flash failed, from the backend's own code.
    private var passcodeFailure: String?
    // True only while a card flash process is running. Backup, restore and the
    // passcode flash share isFlashing but cannot be cancelled, so a Cancel
    // button shown for them would do nothing.
    @Published var canCancelFlash = false
    private var activeFlashProcess: Process?
    private var lastFlashActivity = Date()
    private var flashCancelled = false
    static let flashStallSeconds: TimeInterval = 45
    @Published var isCheckingDevice = false
    @Published var isScanningCards = false { didSet { updateKeepAwake() } }
    @Published var cards: [CardItem] = []
    
    @Published var isFlashing = false {
        didSet {
            if !isFlashing {
                busyJob = nil
                // A full bar left over from the last flash read as the progress
                // of the next restore or save.
                progress = 0
            }
            updateKeepAwake()
        }
    }
    // What isFlashing is busy with. The big button said "Flashing Cards..."
    // while originals were only being read, and people unplugged the phone to
    // stop what they thought was a write.
    enum BusyJob { case flashCards, flashPasscode, readingOriginals, savingOriginal, restoring }
    @Published var busyJob: BusyJob?
    // Cards AirCard has written to on this phone: their original can no longer
    // be saved, so they are not asked about before a flash.
    @Published var flashedCards: Set<String> = []
    // Cards the person chose to send without saving first, this session.
    private var sendWithoutSaving: Set<String> = []
    @Published var progress: Double = 0.0
    @Published var statusText: String = "Ready"
    @Published var logs: [String] = []
    @Published var showSuccessAlert = false
    @Published var errorMessage: String?
    
    @Published var showAddCardSheet = false
    @Published var manualHashInput = ""
    @Published var showLogs = false
    
    private var scanProcess: Process?
    private let scriptDir: String
    private let storageKey = "mak5er.aircard.savedCards"
    // Card numbers per phone. One shared list meant cards from one phone were
    // ticked, given the same picture and sent to another.
    private let perDeviceKey = "mak5er.aircard.cardsByDevice"
    private var cardsByDevice: [String: [String]] = [:]
    // The phone whose list is on screen.
    private var shownCardsFor: String?
    // Numbers saved before lists were kept per phone, or added before any
    // phone was connected. They go to the next phone that connects.
    private var unassignedCards: [String] = []
    private let legacyStorageKey1 = "mak5er.savedCards"
    private let legacyStorageKey2 = "LumiCards.savedCards"
    
    nonisolated static let cardRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: "/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,44})(?:\\.pkpass|\\.cache|\\.pkcache|/|\\s|\"|'|\\)|,|$)"),
        try! NSRegularExpression(pattern: "/([-A-Za-z0-9_+=]{20,44})\\.(?:pkpass|cache|pkcache)"),
        try! NSRegularExpression(pattern: "(?<![A-Za-z0-9+/_-])([A-Za-z0-9+/_-]{27}=)(?![A-Za-z0-9+/_-])")
    ]
    
    // The one model, for the app delegate's quit check.
    static weak var shared: AppViewModel?

    init() {
        let cwd = FileManager.default.currentDirectoryPath
        if let resPath = Bundle.main.resourcePath, FileManager.default.fileExists(atPath: resPath + "/aircard_backend.py") {
            self.scriptDir = resPath
        } else if FileManager.default.fileExists(atPath: cwd + "/aircard_backend.py") {
            self.scriptDir = cwd
        } else {
            self.scriptDir = Bundle.main.bundleURL.deletingLastPathComponent().path
        }
        
        Self.clearOldDesigns()
        PasscodeThemeExporter.clearStagedThemes()
        AppViewModel.shared = self
        loadSavedCards()
        checkDevice()
        startWatchingForDevice()
    }
    
    // Kept on disk as well, dated: messages send people to the log, and it
    // used to be undated and gone once the app quit. ~/Library/Logs is where
    // Console and people looking for a log expect it.
    nonisolated static var logFileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/AirCard/AirCard.log")
    }

    // Past 2 MB the log starts again, keeping one previous file.
    nonisolated static func appendToLogFile(_ line: String, at url: URL = logFileURL, limit: Int = 2_000_000) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil, size > limit {
            let previous = url.deletingPathExtension().appendingPathExtension("1.log")
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: url, to: previous)
        }
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        logs.append(line)
        Self.appendToLogFile(line)
    }
    
    // /usr/bin/python3 is Apple's shim onto the Command Line Tools. It counts as
    // an executable even when it cannot run, because the licence was never
    // accepted or the tools are not installed, and it sits ahead of a perfectly
    // good Homebrew python. That is why "sudo xcodebuild -license accept" became
    // the fix people passed around for a Wallet app. Running each candidate is
    // the only honest test.
    nonisolated static let pythonCandidates = [
        "/usr/bin/python3",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3"
    ]

    nonisolated static func firstWorkingPython(in candidates: [String], timeout: TimeInterval = 5) -> String? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: path)
            probe.arguments = ["-c", ""]
            probe.standardOutput = FileHandle.nullDevice
            probe.standardError = FileHandle.nullDevice
            do { try probe.run() } catch { continue }
            // The shim can sit on an install prompt instead of exiting.
            let deadline = Date().addingTimeInterval(timeout)
            while probe.isRunning && Date() < deadline { usleep(20_000) }
            if probe.isRunning { probe.terminate(); continue }
            if probe.terminationStatus == 0 { return path }
        }
        return nil
    }

    nonisolated private static let pythonExecutableURL: URL = {
        URL(fileURLWithPath: firstWorkingPython(in: pythonCandidates) ?? "/usr/bin/python3")
    }()
    
    nonisolated private static var deviceHelperExecutableURL: URL? {
        var candidates: [String] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("bin/device_helper").path)
        }
        candidates.append("/Applications/AirCard.app/Contents/Resources/bin/device_helper")
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
    
    nonisolated private static var processEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        var extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        if let res = Bundle.main.resourceURL {
            extraPaths.insert(res.appendingPathComponent("bin").path, at: 0)
        }
        extraPaths.insert("/Applications/AirCard.app/Contents/Resources/bin", at: 0)
        env["PATH"] = (extraPaths + [path]).joined(separator: ":")
        
        var libPaths = ["/Applications/AirCard.app/Contents/Resources/lib"]
        if let res = Bundle.main.resourceURL {
            libPaths.insert(res.appendingPathComponent("lib").path, at: 0)
        }
        let curDyld = env["DYLD_LIBRARY_PATH"] ?? ""
        env["DYLD_LIBRARY_PATH"] = (libPaths + (curDyld.isEmpty ? [] : [curDyld])).joined(separator: ":")

        // The backend scripts live inside the signed bundle. Left to itself
        // Python drops __pycache__ next to them on first run, which breaks the
        // app's own signature.
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        return env
    }
    
    // Runs a backend command and hands back its stdout, or nil if it never launched.
    nonisolated private static func runBackend(_ arguments: [String], scriptDir: String) -> Data? {
        let process = Process()
        process.executableURL = pythonExecutableURL
        process.environment = processEnvironment
        process.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        } catch {
            return nil
        }
    }

    // What the backend's error output says went wrong, in the user's words. The
    // three causes people actually hit all used to surface as "No iPhone found".
    enum BackendFailure: Equatable {
        case xcodeLicence
        case commandLineTools
        // xcode-select still points at an Xcode that has been deleted or moved.
        case staleDeveloperPath
        case unknown
    }

    nonisolated static func diagnoseBackendFailure(_ stderr: String) -> BackendFailure {
        let text = stderr.lowercased()
        if text.contains("agreed to the xcode") || text.contains("xcodebuild -license") {
            return .xcodeLicence
        }
        if text.contains("invalid active developer path"), text.contains("xcode.app") || text.contains("xcode-beta.app") {
            return .staleDeveloperPath
        }
        if text.contains("invalid active developer path")
            || text.contains("command line tools")
            || text.contains("xcode-select") {
            return .commandLineTools
        }
        return .unknown
    }

    static func backendFailureMessage(_ failure: BackendFailure) -> String {
        switch failure {
        case .xcodeLicence:
            return L("error.xcode_licence", "macOS is holding back a tool AirCard needs until the Xcode licence is accepted. Open Terminal, run \"sudo xcodebuild -license accept\", then click refresh.")
        case .commandLineTools:
            return L("error.command_line_tools", "AirCard needs Apple's Command Line Tools. Open Terminal, run \"xcode-select --install\", follow the installer, then click refresh.")
        case .staleDeveloperPath:
            return L("error.stale_developer_path", "This Mac is still set to use an Xcode that is no longer there. Open Terminal, run \"sudo xcode-select --reset\", then click refresh.")
        case .unknown:
            return L("error.backend_unavailable", "AirCard could not start its device tools. Reinstalling the app usually fixes this.")
        }
    }

    // Lines of JSON the backend printed, and whether it printed any at all.
    nonisolated static func jsonLines(_ data: Data?) -> [[String: Any]] {
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    // Like runBackend, but keeps what the backend printed to stderr, since that
    // is the only place the real reason for a failure is ever stated.
    nonisolated private static func runBackendDiagnosing(_ arguments: [String], scriptDir: String) -> (out: Data?, err: String) {
        final class Box: @unchecked Sendable { var data = Data() }
        let process = Process()
        process.executableURL = pythonExecutableURL
        process.environment = processEnvironment
        process.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch { return (nil, error.localizedDescription) }
        // Drain stderr alongside stdout so a chatty failure cannot fill the pipe
        // and stall the process.
        let err = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            err.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return (out, String(data: err.data, encoding: .utf8) ?? "")
    }

    nonisolated static func prepareCardImage(srcURL: URL, dstURL: URL) -> Bool {
        guard let image = NSImage(contentsOf: srcURL) else { return false }
        let targetSize = CGSize(width: 1536, height: 969)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return false }
        
        rep.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        
        let imgSize = image.size
        let scale = max(targetSize.width / imgSize.width, targetSize.height / imgSize.height)
        let scaledWidth = imgSize.width * scale
        let scaledHeight = imgSize.height * scale
        let x = (targetSize.width - scaledWidth) / 2.0
        let y = (targetSize.height - scaledHeight) / 2.0
        
        image.draw(in: CGRect(x: x, y: y, width: scaledWidth, height: scaledHeight),
                   from: CGRect(origin: .zero, size: imgSize),
                   operation: .copy,
                   fraction: 1.0)
        
        NSGraphicsContext.restoreGraphicsState()
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try pngData.write(to: dstURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
    
    // MARK: - Persistence
    
    func loadSavedCards() {
        var loaded: [String] = []
        
        if let saved = UserDefaults.standard.stringArray(forKey: storageKey), !saved.isEmpty {
            loaded.append(contentsOf: saved)
        } else if let saved = UserDefaults.standard.stringArray(forKey: legacyStorageKey1), !saved.isEmpty {
            loaded.append(contentsOf: saved)
        } else if let saved = UserDefaults.standard.stringArray(forKey: legacyStorageKey2), !saved.isEmpty {
            loaded.append(contentsOf: saved)
        }
        
        for p in ["~/.aircard_cards.json", "~/.lumicards_cards.json"] {
            let jsonPath = NSString(string: p).expandingTildeInPath
            if let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
               let jsonHashes = try? JSONDecoder().decode([String].self, from: data) {
                for h in jsonHashes where !loaded.contains(h) {
                    loaded.append(h)
                }
            }
        }
        
        let dummyHashes = [
            "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
            "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
            "hwAtAmHKYwsQrJbT5cTNDsaxVME="
        ]
        loaded.removeAll { dummyHashes.contains($0) || ($0.contains("-") && $0.count == 36) }

        // Older versions saved pasted numbers as typed, quotes and brackets
        // and all; those never matched a card. Cleaned the same way a paste is
        // now, and written back once cleaned.
        let cleaned = Self.cleanSavedHashes(loaded)
        let stored = UserDefaults.standard.dictionary(forKey: perDeviceKey) as? [String: [String]] ?? [:]
        cardsByDevice = stored.mapValues { Self.cleanSavedHashes($0) }
        // Numbers already filed under a phone are not unassigned any more; the
        // flat list is still written for older versions of AirCard.
        let filed = Set(cardsByDevice.values.flatMap { $0 })
        unassignedCards = cleaned.filter { !filed.contains($0) }
        // Until a phone is known, only the unassigned ones can be shown.
        self.cards = unassignedCards.map { CardItem(id: $0, isSelected: true) }
        log("Loaded \(unassignedCards.count) unfiled and \(filed.count) filed card(s) from storage.")
    }
    
    // The file each card is shown from: this phone's list, or the unassigned
    // list while no phone is known. Two phones share the same card only if it
    // really is on both.
    nonisolated static func cardsForDevice(_ udid: String, store: [String: [String]], unassigned: [String])
        -> (cards: [String], store: [String: [String]]) {
        var list = store[udid] ?? []
        for id in unassigned where !list.contains(id) { list.append(id) }
        var updated = store
        updated[udid] = list
        return (list, updated)
    }

    func saveCards() {
        let current = cards.map { $0.id }
        // With the phone unplugged, the list on screen is still that phone's:
        // saved as unassigned, it would be handed to the next phone plugged in.
        if let udid = device?.udid ?? shownCardsFor {
            cardsByDevice[udid] = current
        } else {
            unassignedCards = current
        }
        UserDefaults.standard.set(cardsByDevice, forKey: perDeviceKey)
        // The flat list keeps older versions of AirCard working after a downgrade.
        var hashes: [String] = []
        for id in cardsByDevice.values.flatMap({ $0 }) + unassignedCards where !hashes.contains(id) { hashes.append(id) }
        UserDefaults.standard.set(hashes, forKey: storageKey)

        let jsonPath = NSString(string: "~/.aircard_cards.json").expandingTildeInPath
        if let data = try? JSONEncoder().encode(hashes) {
            try? data.write(to: URL(fileURLWithPath: jsonPath), options: .atomic)
        }
    }
    
    nonisolated static func cleanSavedHashes(_ saved: [String]) -> [String] {
        var out: [String] = []
        for entry in saved {
            for hash in parseCardHashes(entry).valid where !out.contains(hash) {
                out.append(hash)
            }
        }
        return out
    }

    // Pulls card numbers out of whatever was pasted: bare, quoted, bracketed,
    // with a .pkpass ending, or as a full /Cards/... path. The old version kept
    // quotes and brackets as part of the number and dropped anything it did
    // not like without a word.
    nonisolated static func parseCardHashes(_ raw: String) -> (valid: [String], invalid: [String]) {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        let wrappers = CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}\u{2018}\u{2019}()[]{}<>")
        var valid: [String] = []
        var invalid: [String] = []
        for part in raw.components(separatedBy: separators) where !part.isEmpty {
            var token = part.trimmingCharacters(in: wrappers)
            if let r = token.range(of: "/Cards/") { token = String(token[r.upperBound...]) }
            for ext in [".pkpass", ".pkcache", ".cache"] {
                if let r = token.range(of: ext) { token = String(token[..<r.lowerBound]) }
            }
            token = token.trimmingCharacters(in: wrappers.union(CharacterSet(charactersIn: ".")))
            if token.range(of: "^[A-Za-z0-9+/_=-]{20,44}$", options: .regularExpression) != nil {
                if !valid.contains(token) { valid.append(token) }
            } else {
                invalid.append(part)
            }
        }
        return (valid, invalid)
    }

    // Returns what was not taken, so the sheet can keep it for correcting
    // instead of closing on it.
    @discardableResult
    func addCardHash(_ raw: String) -> [String] {
        let parsed = AppViewModel.parseCardHashes(raw)
        var added = 0
        for id in parsed.valid where !cards.contains(where: { $0.id == id }) {
            cards.append(CardItem(id: id, isSelected: true))
            added += 1
            log("Added card: \(id)")
        }
        if added > 0 {
            saveCards()
        }
        if !parsed.invalid.isEmpty {
            let shown = parsed.invalid.prefix(5).joined(separator: ", ")
            log("Not a card number, skipped: \(parsed.invalid.joined(separator: ", "))")
            errorMessage = String(format: L("error.hashes_not_recognised", "Skipped because they do not look like a card hash: %@. A card hash is 20 to 44 letters and digits, like the ones a scan finds."), shown)
        }
        return parsed.invalid
    }
    
    func deleteCard(id: String) {
        guard !isFlashing else { return }
        let old = cards.first { $0.id == id }?.customImageURL
        cards.removeAll { $0.id == id }
        removeDesignFileIfUnused(old)
        saveCards()
        log("Removed card: \(id)")
    }
    
    // Clearing the list cannot be undone from the app, so it asks first.
    // Saved originals are not touched, and cards that have one come back.
    func confirmClearAllCards() {
        guard !cards.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("clear.title", "Remove every card from the list?")
        alert.informativeText = L("clear.body", "Skins you assigned are forgotten. Saved originals stay on this Mac, and cards that have one come back to the list.")
        alert.addButton(withTitle: L("clear.confirm", "Remove All"))
        alert.addButton(withTitle: L("ui.cancel", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        clearAllCards()
        loadBackups()
    }

    func clearAllCards() {
        cards.removeAll()
        saveCards()
        log("Cleared all cards.")
    }
    
    func setCardImage(for cardId: String, url: URL) {
        if let idx = cards.firstIndex(where: { $0.id == cardId }) {
            cards[idx].customImageURL = url
            cards[idx].customImage = NSImage(contentsOf: url)
            cards[idx].design = nil
            cards[idx].isSelected = true
            log("Assigned custom skin to card: \(cardId.prefix(12))...")
        }
    }
    
    // Stops the card being written now. Cards already sent keep what they got;
    // the one in progress is left as it was before this run.
    func cancelFlash() {
        guard isFlashing else { return }
        flashCancelled = true
        activeFlashProcess?.terminate()
        log("Cancelled by the user.")
    }

    // The designer hands back a finished card face. Write it out the same way a
    // dropped image is, so the flash path treats it like any other skin.
    // Picking or dropping a picture opens the designer on it rather than
    // applying a blind centre crop, so framing is part of the normal path and
    // not something to find in a menu.
    func openDesigner(for cardId: String, image: NSImage?) {
        guard !isFlashing else { return }
        designerSeed = image
        designingAllSelected = false
        designingCardID = cardId
    }

    func openDesignerForAllSelected(image: NSImage) {
        guard !isFlashing else { return }
        designerSeed = image
        designingCardID = nil
        designingAllSelected = true
    }

    func closeDesigner() {
        designingCardID = nil
        designingAllSelected = false
        designerSeed = nil
    }

    func applyCardDesign(_ design: CardFaceDesign, for cardIds: [String]) {
        guard !isFlashing else { return }
        try? FileManager.default.createDirectory(at: Self.designsURL, withIntermediateDirectories: true)
        let url = Self.designsURL.appendingPathComponent("\(UUID().uuidString).png")
        guard let image = design.render(),
              let png = Self.pngData(image),
              (try? png.write(to: url)) != nil else {
            errorMessage = L("error.design_save_failed", "The design could not be saved. Try again, or pick a different picture.")
            return
        }
        let replaced = cards.filter { cardIds.contains($0.id) }.compactMap(\.customImageURL)
        for cardId in cardIds {
            setCardImage(for: cardId, url: url)
            // After setCardImage, which clears it for ordinary image changes.
            if let idx = cards.firstIndex(where: { $0.id == cardId }) {
                cards[idx].design = design
            }
        }
        for old in Set(replaced) { removeDesignFileIfUnused(old) }
        log("Designed a card face for \(cardIds.count) card(s).")
    }

    // MARK: - Skin Library

    // Pictures imported from packs, folders, links or files live here, so a
    // pack downloaded once can go on any card later.
    nonisolated static var skinLibraryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirCard/Skins", isDirectory: true)
    }

    nonisolated static var skinLibraryHasPictures: Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: skinLibraryURL.path)) ?? []
        return names.contains { !$0.hasPrefix(".") && skinFileExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    // What was just imported comes first, in the pack's own order; the rest
    // follows by name, the way Finder sorts it.
    nonisolated static func orderSkinNames(_ names: [String], recent: [String]) -> [String] {
        let present = Set(names)
        var first: [String] = []
        for name in recent where present.contains(name) && !first.contains(name) {
            first.append(name)
        }
        let shown = Set(first)
        let rest = names.filter { !shown.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return first + rest
    }

    // What the library lists: the kinds the importer writes, plus the common
    // ones someone might drop into the folder from Finder themselves.
    nonisolated static let skinFileExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp"]

    // Big enough for the widest grid cell on a Retina screen, and no bigger.
    nonisolated static func skinThumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 440
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // Accepts what people actually paste: a bare address, an http link, or
    // the page link a sharing site gives out instead of the file itself.
    nonisolated static func skinDownloadURL(_ text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains(where: \.isNewline) else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw, encodingInvalidCharacters: true),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parts.host?.lowercased(), host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".")
        else { return nil }
        // The app only loads secure links, and nearly every host serves both.
        parts.scheme = "https"
        var query = parts.queryItems ?? []
        if host == "github.com", parts.path.contains("/blob/") {
            // A GitHub file page is HTML; the same address with raw=true is the file.
            query.removeAll { $0.name == "raw" }
            query.append(URLQueryItem(name: "raw", value: "true"))
            parts.queryItems = query
        } else if host == "dropbox.com" || host.hasSuffix(".dropbox.com") {
            // A Dropbox share link shows a preview page unless dl=1.
            query.removeAll { $0.name == "dl" || $0.name == "raw" }
            query.append(URLQueryItem(name: "dl", value: "1"))
            parts.queryItems = query
        }
        return parts.url
    }

    // The last JSON line the importer printed. No such line means the backend
    // never ran, which is not the same as a file it could not open.
    nonisolated static func parseSkinImport(_ data: Data?) -> SkinImportResult {
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        for line in text.split(separator: "\n").reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let code = json["code"] as? String else { continue }
            return SkinImportResult(imported: json["imported"] as? [String] ?? [],
                                    skipped: json["skipped"] as? Int ?? 0,
                                    duplicates: json["duplicates"] as? Int ?? 0,
                                    encrypted: json["encrypted"] as? Int ?? 0,
                                    unsupported: json["unsupported"] as? Int ?? 0,
                                    overLimit: json["over_limit"] as? Int ?? 0,
                                    code: code)
        }
        return SkinImportResult(code: "skins.no_output")
    }

    // One line per kind of outcome. A locked zip, a pack past the limit and a
    // picture already there each need a different next step; lumping them in
    // with "not a picture, or too big" sent people converting pictures that
    // were fine. Lines, not joined fragments, so each language keeps its own
    // sentence order.
    nonisolated static func skinImportLines(_ r: SkinImportResult, unreadable: Int) -> (lines: [String], isError: Bool) {
        let added = r.imported.count
        var lines: [String] = []
        if added > 0 {
            lines.append(String(format: L("skins.added", "Added %d to the library."), added))
        }
        let otherReasons = r.skipped + r.encrypted + r.unsupported + r.overLimit + unreadable
        if r.duplicates > 0 {
            lines.append(added == 0 && otherReasons == 0
                ? L("skins.all_already_there", "Everything in it is already in the library.")
                : String(format: L("skins.some_already_there", "%d were already in the library."), r.duplicates))
        }
        if r.encrypted > 0 {
            lines.append(String(format: L("skins.skipped_locked", "%d are in a password-protected zip. Open it in Finder with its password, then add the folder it makes."), r.encrypted))
        }
        if r.unsupported > 0 {
            lines.append(String(format: L("skins.skipped_unsupported", "%d are packed in a way AirCard cannot unpack. Double-click the zip in Finder, then add the folder it makes."), r.unsupported))
        }
        if r.overLimit > 0 {
            lines.append(String(format: L("skins.skipped_over_limit", "%d more were left out, because one import takes up to 400 pictures. Add the rest separately."), r.overLimit))
        }
        if added == 0 && r.duplicates == 0 && r.encrypted == 0 && r.unsupported == 0 && r.overLimit == 0 {
            lines.append(unreadable > 0 && r.skipped == 0
                ? L("skins.unreadable", "That file could not be opened. If it is a zip, double-click it in Finder to check it is not damaged.")
                : L("skins.none_found", "No card pictures were found. They need to be PNG, JPEG, HEIC or WebP files."))
        } else if r.skipped + unreadable > 0 {
            lines.append(String(format: L("skins.skipped_other", "%d skipped: not a picture, or too big."), r.skipped + unreadable))
        }
        return (lines, added == 0 && r.duplicates == 0)
    }

    static func skinDownloadMessage(_ failure: SkinDownloader.Failure) -> String {
        switch failure {
        case .status:
            return L("skins.link_failed", "Nothing could be downloaded from that link. Check that it opens in your browser.")
        case .webPage:
            return L("skins.link_is_page", "That link opens a web page, not a file. Open it in your browser, download the zip or picture, then drop it here.")
        case .tooLarge:
            return L("skins.link_too_large", "The download was stopped at 400 MB. A card pack is far smaller than that, so check the link points to the right file.")
        case .network(let reason):
            return String(format: L("skins.download_failed", "The download did not finish: %@"), reason)
        case .needsBrowser(let reason):
            return String(format: L("skins.use_browser", "AirCard could not download this link itself. Open it in your browser, download the file, then drop it here. (%@)"), reason)
        case .cancelled:
            return L("skins.download_cancelled", "Download cancelled.")
        }
    }

    // Pictures a folder would bring in, counted the way the importer walks it:
    // no hidden files, nothing inside apps or photo libraries. Stops counting at
    // the limit, since past that the answer is "a lot".
    nonisolated static func picturesIn(folder: URL, limit: Int = 5000) -> Int {
        guard let walk = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        let kinds: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "webp"]
        var count = 0
        var seen = 0
        for case let url as URL in walk {
            seen += 1
            if seen > limit { break }
            if kinds.contains(url.pathExtension.lowercased()) { count += 1 }
        }
        return count
    }

    func openSkinLibrary(for cardId: String?) {
        guard !isFlashing else { return }
        skinLibraryCardID = cardId
        skinChosenFromLibrary = nil
        // A result that came in while the library was closed is shown once
        // more, rather than wiped before anyone saw it.
        if !isImportingSkins && !isDownloadingSkins && !skinNoteUnseen { skinLibraryNote = nil }
        skinNoteUnseen = false
        showSkinLibrary = true
        loadSkinLibrary()
    }

    func loadSkinLibrary() {
        let dir = Self.skinLibraryURL
        let recent = recentSkinImports
        Task.detached(priority: .userInitiated) {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { !$0.hasPrefix(".") && AppViewModel.skinFileExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            let items = AppViewModel.orderSkinNames(names, recent: recent).map { name -> SkinLibraryItem in
                let url = dir.appendingPathComponent(name)
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                return SkinLibraryItem(url: url, version: "\(stamp)-\(values?.fileSize ?? 0)")
            }
            await MainActor.run { self.skinLibrary = items }
        }
    }

    func chooseSkin(_ image: NSImage) {
        guard !isFlashing else { return }
        skinChosenFromLibrary = image
        showSkinLibrary = false
    }

    // Runs once the library sheet has gone, so the designer can take its place.
    func skinLibraryClosed() {
        guard let image = skinChosenFromLibrary else { return }
        skinChosenFromLibrary = nil
        if let id = skinLibraryCardID {
            if cards.contains(where: { $0.id == id }) { openDesigner(for: id, image: image) }
        } else if cards.contains(where: \.isSelected) {
            openDesignerForAllSelected(image: image)
        }
    }

    func revealSkinLibrary() {
        let dir = Self.skinLibraryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    // To the Trash, not deleted, so a slip can be undone from Finder.
    func removeSkin(_ item: SkinLibraryItem) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            skinLibrary.removeAll { $0.id == item.id }
        } catch {
            reportSkinOutcome(SkinLibraryNote(text: error.localizedDescription, isError: true))
            loadSkinLibrary()
        }
    }

    // Results land in the sheet. If it was closed meanwhile, the main status
    // line says it too, a failure also as an alert, and the sheet keeps the
    // note for the next time it opens.
    func reportSkinOutcome(_ note: SkinLibraryNote) {
        skinLibraryNote = note
        guard !showSkinLibrary else { return }
        skinNoteUnseen = true
        statusText = note.text
        if note.isError { errorMessage = note.text }
    }

    // Folders get a look before anything is copied: clicking Open one level
    // too high in the file chooser picks all of Downloads.
    func importSkinsAfterConfirming(_ sources: [URL]) {
        let folders = sources.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        let inFolders = folders.reduce(0) { $0 + Self.picturesIn(folder: $1) }
        if inFolders > Self.folderImportConfirmAbove {
            let alert = NSAlert()
            alert.messageText = String(format: L("skins.folder_confirm_title", "Add %d pictures to the library?"), inFolders)
            alert.informativeText = L("skins.folder_confirm_body", "Everything that is a picture in this folder and the folders inside it will be copied into the library.")
            alert.addButton(withTitle: L("skins.folder_confirm_add", "Add Them"))
            alert.addButton(withTitle: L("ui.cancel", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        importSkins(from: sources)
    }

    nonisolated static let folderImportConfirmAbove = 30

    // Imports run one at a time. A second request while one runs (a drop
    // during a download, say) waits its turn instead of being dropped, which
    // used to throw away the downloaded pack. Everything that runs back to back
    // is reported together at the end.
    func importSkins(from sources: [URL], cleaningUp temporary: URL? = nil) {
        guard !sources.isEmpty else {
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            return
        }
        if isImportingSkins {
            pendingSkinImports.append((sources, temporary))
            return
        }
        isImportingSkins = true
        skinProgress = L("skins.importing", "Adding to the library...")
        let scriptDir = self.scriptDir
        let library = Self.skinLibraryURL.path
        Task.detached {
            var total = SkinImportResult()
            var unreadable = 0
            var setup: AppViewModel.BackendFailure?
            var toolMissing = false
            for source in sources {
                let run = AppViewModel.runBackendDiagnosing(["aircard_backend.py", "--import-skins", source.path, library], scriptDir: scriptDir)
                let result = AppViewModel.parseSkinImport(run.out)
                if result.code == "skins.no_output" {
                    // The backend never answered: say what is missing on this
                    // Mac, not that the person's zip is damaged.
                    let failure = AppViewModel.diagnoseBackendFailure(run.err)
                    if failure == .unknown { toolMissing = true } else { setup = failure }
                    break
                }
                total.add(result)
                if result.code == "skins.unreadable" || result.code == "skins.not_found" { unreadable += 1 }
            }
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            let result = total, failed = unreadable, setupFailure = setup, noTool = toolMissing
            await MainActor.run {
                self.isImportingSkins = false
                self.finishSkinImport(result, unreadable: failed, setup: setupFailure, toolMissing: noTool)
            }
        }
    }

    private func finishSkinImport(_ result: SkinImportResult, unreadable: Int, setup: BackendFailure?, toolMissing: Bool) {
        log("Skin library: added \(result.imported.count), duplicates \(result.duplicates), skipped \(result.skipped), locked \(result.encrypted), unsupported \(result.unsupported), over limit \(result.overLimit), unreadable \(unreadable).")
        recentSkinImports = result.imported + recentSkinImports.filter { !result.imported.contains($0) }
        batchSkinResult.add(result)
        batchSkinUnreadable += unreadable
        loadSkinLibrary()

        if setup != nil || toolMissing {
            // Nothing queued can work either; clear it and say why once.
            for pending in pendingSkinImports {
                if let temporary = pending.temporary { try? FileManager.default.removeItem(at: temporary) }
            }
            pendingSkinImports.removeAll()
            batchSkinResult = SkinImportResult()
            batchSkinUnreadable = 0
            skinProgress = nil
            let text: String
            switch setup {
            case .xcodeLicence:
                text = L("error.xcode_licence", "macOS is holding back a tool AirCard needs until the Xcode licence is accepted. Open Terminal, run \"sudo xcodebuild -license accept\", then click refresh.")
            case .commandLineTools:
                text = L("error.command_line_tools", "AirCard needs Apple's Command Line Tools. Open Terminal, run \"xcode-select --install\", follow the installer, then click refresh.")
            default:
                text = L("skins.tool_failed", "AirCard could not start the part that adds pictures to the library. Reinstalling the app usually fixes this.")
            }
            reportSkinOutcome(SkinLibraryNote(text: text, isError: true))
            return
        }

        if !pendingSkinImports.isEmpty {
            let next = pendingSkinImports.removeFirst()
            importSkins(from: next.sources, cleaningUp: next.temporary)
            return
        }
        let summary = Self.skinImportLines(batchSkinResult, unreadable: batchSkinUnreadable)
        batchSkinResult = SkinImportResult()
        batchSkinUnreadable = 0
        skinProgress = nil
        reportSkinOutcome(SkinLibraryNote(text: summary.lines.joined(separator: "\n"), isError: summary.isError))
    }

    func downloadSkins(from text: String) {
        guard !isDownloadingSkins else { return }
        guard let url = Self.skinDownloadURL(text) else {
            reportSkinOutcome(SkinLibraryNote(text: L("skins.bad_link", "That does not look like a link. Paste the whole address, starting with https://"), isError: true))
            return
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aircard_download_\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            reportSkinOutcome(SkinLibraryNote(text: Self.skinDownloadMessage(.network(error.localizedDescription)), isError: true))
            return
        }
        isDownloadingSkins = true
        skinLibraryNote = nil
        showDownloadProgress(0)
        log("Downloading skins from \(url.host ?? "a link")...")
        var shown: Int64 = 0
        let download = SkinDownloader(url: url, folder: folder, onProgress: { [weak self] bytes in
            // A fast link calls this thousands of times; redraw every 256 KB.
            guard bytes - shown >= 256 * 1024 else { return }
            shown = bytes
            self?.showDownloadProgress(bytes)
        }, onFinish: { [weak self] result in
            guard let self else {
                try? FileManager.default.removeItem(at: folder)
                return
            }
            self.skinDownload = nil
            self.isDownloadingSkins = false
            switch result {
            case .success(let file):
                self.skinDownloadSucceeded += 1
                self.importSkins(from: [file], cleaningUp: folder)
            case .failure(let failure):
                try? FileManager.default.removeItem(at: folder)
                if case .status(let code) = failure { self.log("  The link answered HTTP \(code).") }
                if !self.isImportingSkins { self.skinProgress = nil }
                self.reportSkinOutcome(SkinLibraryNote(text: Self.skinDownloadMessage(failure), isError: failure != .cancelled))
            }
        })
        skinDownload = download
        download.start()
    }

    func cancelSkinDownload() {
        skinDownload?.cancel()
    }

    private func showDownloadProgress(_ bytes: Int64) {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        skinProgress = String(format: L("skins.downloading", "Downloading... %@"), size)
    }

    // A zip or folder dropped on a card goes into the library, which then
    // opens on that card: dropped there before, it was taken and nothing
    // happened.
    func importDroppedPack(_ url: URL, for cardId: String) {
        guard !isFlashing else { return }
        openSkinLibrary(for: cardId)
        importSkinsAfterConfirming([url])
    }

    // MARK: - Designs on disk

    // Rendered card faces. Kept out of the temp folder, which macOS clears of
    // files left alone for about three days: a design made on Monday in an app
    // left open failed to send on Thursday. Only card numbers are saved between
    // launches, so what is here belongs to one run and is cleared at the next.
    nonisolated static var designsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirCard/Designs", isDirectory: true)
    }

    nonisolated static func clearOldDesigns() {
        try? FileManager.default.removeItem(at: designsURL)
    }

    // A design file can be shared by every card it was applied to at once.
    private func removeDesignFileIfUnused(_ url: URL?) {
        guard let url, url.path.hasPrefix(Self.designsURL.path + "/"),
              !cards.contains(where: { $0.customImageURL == url }) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // Before sending: any card whose artwork file has gone is written out again
    // from its design, or from the picture it shows, rather than failing.
    func restoreMissingArtwork() {
        for idx in cards.indices where cards[idx].isSelected {
            guard let url = cards[idx].customImageURL, !FileManager.default.fileExists(atPath: url.path) else { continue }
            let image = cards[idx].design?.render() ?? cards[idx].customImage
            guard let image, let png = Self.pngData(image) else { continue }
            try? FileManager.default.createDirectory(at: Self.designsURL, withIntermediateDirectories: true)
            let fresh = Self.designsURL.appendingPathComponent("\(UUID().uuidString).png")
            if (try? png.write(to: fresh)) != nil {
                cards[idx].customImageURL = fresh
                log("Wrote card \(idx + 1)'s artwork again; its file had been removed.")
            }
        }
    }

    nonisolated static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // Held while anything is going on that the Mac sleeping would break: a
    // flash, a scan waiting on taps at the phone, a download. The person's
    // hands are on the iPhone, so a MacBook on battery reached its idle sleep
    // mid-flash.
    func updateKeepAwake() {
        let busy = isFlashing || isScanningCards || isDownloadingSkins || isImportingSkins
        if busy, awakeActivity == nil {
            awakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "AirCard is working with the iPhone")
        } else if !busy, let activity = awakeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            awakeActivity = nil
        }
    }

    func clearCardImage(for cardId: String) {
        guard !isFlashing else { return }
        if let idx = cards.firstIndex(where: { $0.id == cardId }) {
            let old = cards[idx].customImageURL
            cards[idx].customImageURL = nil
            cards[idx].customImage = nil
            cards[idx].design = nil
            removeDesignFileIfUnused(old)
            log("Cleared custom skin for: \(cardId.prefix(12))...")
        }
    }
    
    // MARK: - Device Connection
    
    // Looking once at launch left people replugging: the Mac holds a new
    // phone's data connection until someone clicks Allow, the phone asks for
    // Trust only after that, and by then the app had already given up.
    deinit {
        deviceWatch?.invalidate()
        if let observer = activationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func startWatchingForDevice() {
        deviceWatch?.invalidate()
        deviceWatch = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDeviceIfWaiting(fromTimer: true) }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Coming back from a Trust or Allow prompt is the moment it changed.
            Task { @MainActor in self?.checkDeviceIfWaiting(fromTimer: false) }
        }
    }

    private func checkDeviceIfWaiting(fromTimer: Bool) {
        guard AppViewModel.shouldLookForDevice(
            fromTimer: fromTimer,
            hasDevice: device != nil,
            busy: isCheckingDevice || isFlashing || isScanningCards,
            lastState: lastDeviceState,
            appActive: NSApp.isActive
        ) else { return }
        checkDevice(quiet: true)
    }

    // Listing a phone that has not paired asks it to pair, which puts the Trust
    // prompt up again. On a timer that would re-ask every few seconds after
    // someone tapped Don't Trust, so once a phone is waiting on Trust it is only
    // looked at again when the person comes back to the app.
    nonisolated static func shouldLookForDevice(fromTimer: Bool, hasDevice: Bool, busy: Bool,
                                                lastState: String, appActive: Bool) -> Bool {
        if busy { return false }
        // With a phone set, only a return to the app looks again: it may have
        // been unplugged or swapped meanwhile, and the header kept naming it.
        if hasDevice { return !fromTimer }
        // Known broken setup: running the python3 shim again only puts Apple's
        // "install developer tools" dialog back up, every few seconds and at
        // every return to the window. Only a deliberate Check Again retries.
        if lastState.hasPrefix("backend:") { return false }
        if fromTimer && (lastState == "untrusted" || !appActive) { return false }
        return true
    }

    func checkDevice(quiet: Bool = false) {
        isCheckingDevice = true
        if !quiet {
            statusText = L("status.checking_connected_devices", "Checking connected devices...")
            // A deliberate refresh should report again even if nothing changed.
            lastDeviceState = ""
        }
        let scriptDir = self.scriptDir

        Task.detached {
            let run = AppViewModel.runBackendDiagnosing(["aircard_backend.py", "--devices"], scriptDir: scriptDir)
            let response = run.out.flatMap { try? JSONDecoder().decode(DeviceListResponse.self, from: $0) }
            let failure = AppViewModel.diagnoseBackendFailure(run.err)
            let errorTail = String(run.err.suffix(400))

            await MainActor.run {
                let list = response?.devices ?? []
                self.devices = list
                self.awaitingTrust = false
                self.helperFailed = response?.error?.hasPrefix("helper_") == true

                guard !list.isEmpty else {
                    self.device = nil
                    self.backedUpCards = []
                    self.isCheckingDevice = false
                    let state: String
                    self.backendFailure = response == nil ? failure : nil
                    if response == nil { state = "backend:\(failure)" }
                    else if (response?.untrusted ?? 0) > 0 { state = "untrusted" }
                    else if response?.error == "device_helper_missing" { state = "helper-missing" }
                    else if response?.error?.hasPrefix("helper_") == true { state = "helper-failed" }
                    else { state = "none" }
                    self.awaitingTrust = (state == "untrusted")
                    // The watch repeats this every few seconds. Say something only
                    // when the answer changes, or one broken backend becomes an
                    // alert every four seconds.
                    guard state != self.lastDeviceState else { return }
                    self.lastDeviceState = state
                    if response == nil {
                        // Nothing parseable came back, so the backend did not run.
                        // Saying "no iPhone" sends people to replug a phone that
                        // was never the problem; say what is actually missing.
                        self.statusText = L("status.detection_could_not_run", "Device detection could not run. See the log.")
                        self.errorMessage = AppViewModel.backendFailureMessage(failure)
                        self.log("Device detection returned nothing usable. \(errorTail.isEmpty ? "(no error output)" : errorTail)")
                    } else if state == "untrusted" {
                        // Seen at all means the Mac already let the data through,
                        // so the Trust prompt is on the phone now.
                        self.statusText = L("status.iphone_needs_trust_check", "Your iPhone is connected but has not trusted this Mac yet. Unlock it, tap Trust, then click Check Again.")
                        self.log("An iPhone is attached but has not trusted this Mac yet.")
                    } else if response?.error == "device_helper_missing" {
                        self.statusText = L("status.device_tools_are_missing_from", "Device tools are missing from this build.")
                        self.log("Bundled device_helper not found — detection cannot run.")
                    } else if state == "helper-failed" {
                        // The helper crashed, hung or was stopped: a problem on the
                        // Mac, which a different cable would never fix.
                        self.statusText = L("status.helper_not_responding", "AirCard's device tools did not respond. Unplug the iPhone, plug it back in, then click Check Again. If this keeps happening, restart the Mac.")
                        self.log("Device helper failed (\(response?.error ?? "")). \(errorTail)")
                    } else {
                        // Not seen at all. On a Mac that asks before letting a new
                        // accessory's data through, the phone cannot show Trust
                        // until someone clicks Allow on the Mac, and nothing on
                        // the phone says so.
                        self.statusText = L("status.no_iphone_unlock_first", "No iPhone found. Unlock your iPhone and keep it unlocked while it connects: a phone locked for a while offers no data over USB. Use a cable that carries data, and if your Mac asks whether to allow the accessory, click Allow.")
                    }
                    return
                }
                self.lastDeviceState = "connected"
                self.backendFailure = nil

                // A quiet look (coming back to the window) that finds the same
                // phone still there changes nothing, and must not overwrite the
                // status line with "Connected to...".
                let keep = self.device?.udid
                if quiet, let keep, list.contains(where: { $0.udid == keep }) {
                    self.isCheckingDevice = false
                    return
                }
                // Stay on the current device if it is still attached, otherwise
                // the first iPhone (cabled ones lead). An iPad or other device is
                // never picked on its own; it can still be chosen from the menu.
                guard let target = AppViewModel.pickDevice(from: list, current: keep) else {
                    self.device = nil
                    self.backedUpCards = []
                    self.isCheckingDevice = false
                    let names = list.map { $0.name ?? $0.product ?? "?" }.joined(separator: ", ")
                    self.statusText = String(format: L("status.no_iphone_among_devices", "AirCard sees %@, but no iPhone. Connect your iPhone with a cable."), names)
                    return
                }
                if list.count > 1 {
                    let name = list.first(where: { $0.udid == target })?.name ?? "iPhone"
                    self.log("\(list.count) devices connected, using \(name). Switch from the device menu if this is the wrong one.")
                }
                self.selectDevice(target, isInitial: true)
            }
        }
    }

    // The device to use: the current one while it is still there, otherwise
    // the first iPhone in the list, which the backend orders cabled first.
    nonisolated static func pickDevice(from list: [DeviceInfo], current: String?) -> String? {
        if let current, list.contains(where: { $0.udid == current }) { return current }
        return list.first(where: { ($0.product ?? "").hasPrefix("iPhone") })?.udid
    }

    // Switches the active device and re-reads its preferences and airlift status.
    func selectDevice(_ udid: String?, isInitial: Bool = false) {
        guard let udid = udid else {
            isCheckingDevice = false
            return
        }
        if !isInitial && device?.udid == udid { return }

        // Changing phones: stop the scan and drop the old phone's hashes so they
        // cannot be flashed onto the new one. Keyed on the device actually changing,
        // so a refresh that falls back to another phone clears them too. Nothing to
        // clear on first launch, which keeps the restored saved cards.
        if let current = device?.udid, current != udid {
            if isScanningCards { stopCardScanning() }
            saveCards()
            cards.removeAll()
        }

        isCheckingDevice = true
        let scriptDir = self.scriptDir

        Task.detached {
            let data = AppViewModel.runBackend(["aircard_backend.py", "--device", udid], scriptDir: scriptDir)
            let dev = data.flatMap { try? JSONDecoder().decode(DeviceInfo.self, from: $0) }

            await MainActor.run {
                self.isCheckingDevice = false
                // Only accept the exact device we asked for. A substituted one would
                // silently point scan and flash at the wrong iPhone.
                if let dev = dev, dev.connected, dev.udid == udid {
                    let changed = self.shownCardsFor != udid
                    self.device = dev
                    if changed {
                        // This phone's own cards, plus any not yet filed anywhere.
                        let pending = self.unassignedCards + self.cards.map(\.id).filter { !self.unassignedCards.contains($0) }
                        let picked = AppViewModel.cardsForDevice(udid, store: self.cardsByDevice, unassigned: pending)
                        self.cardsByDevice = picked.store
                        self.unassignedCards = []
                        let designs = Dictionary(self.cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                        self.cards = picked.cards.map { designs[$0] ?? CardItem(id: $0, isSelected: true) }
                        self.shownCardsFor = udid
                        self.saveCards()
                    }
                    // The file-access probe was run and then ignored: a device AirCard
                    // cannot write to showed green, and everything failed later with
                    // advice about cables. Said now, in orange; nothing is blocked,
                    // in case the probe is wrong.
                    if !(dev.product ?? "").hasPrefix("iPhone") {
                        self.deviceWarning = true
                        self.statusText = L("status.not_an_iphone", "This is not an iPhone. AirCard changes Wallet cards on an iPhone; choose one from the device menu.")
                    } else if dev.airlift_compatible == false {
                        self.deviceWarning = true
                        self.statusText = L("status.files_unreachable", "Connected, but AirCard cannot reach this iPhone's files yet. Unlock it, keep it plugged in, then click refresh.")
                    } else {
                        self.deviceWarning = false
                        self.statusText = String(format: L("status.connected_to", "Connected to %@"), dev.name ?? "iPhone")
                    }
                    self.log("Device \(isInitial ? "connected" : "selected"): \(dev.name ?? "iPhone") (\(dev.product ?? ""), iOS \(dev.version ?? ""))")
                    // Only for a phone not set up yet: a refresh of the same phone
                    // must not undo a choice made by hand in the target settings.
                    if dev.udid != self.preferencesAppliedFor {
                        self.applyDevicePreferences(from: dev)
                    }
                    self.loadBackups()
                } else {
                    self.device = nil
                    self.backedUpCards = []
                    if isInitial {
                        self.statusText = L("status.no_iphone_unlock_first", "No iPhone found. Unlock your iPhone and keep it unlocked while it connects: a phone locked for a while offers no data over USB. Use a cable that carries data, and if your Mac asks whether to allow the accessory, click Allow.")
                    } else {
                        self.statusText = L("status.selected_iphone_is_no_longer", "Selected iPhone is no longer connected.")
                        self.log("Selected device is no longer available. Reconnect it and refresh.")
                    }
                }
            }
        }
    }
    
    // MARK: - Original Artwork

    // Which cards can actually be put back. Asked per device, since a backup
    // taken from one iPhone says nothing about another.
    func loadBackups() {
        guard let udid = device?.udid else {
            backedUpCards = []
            originalPreviews = [:]
            return
        }
        let scriptDir = self.scriptDir
        Task.detached {
            let data = AppViewModel.runBackend(["aircard_backend.py", "--backups", udid], scriptDir: scriptDir)
            let list = data.flatMap { try? JSONDecoder().decode(SavedCardsResponse.self, from: $0) }
            var previews: [String: NSImage] = [:]
            for (card, path) in list?.previews ?? [:] {
                if let image = NSImage(contentsOfFile: path) { previews[card] = image }
            }
            await MainActor.run {
                // The phone was switched while this was running: its answer
                // belongs to the other phone and would mix the lists.
                guard self.device?.udid == udid else { return }
                let saved = list?.cards ?? []
                self.backedUpCards = Set(saved)
                self.flashedCards = Set(list?.flashed ?? [])
                self.originalPreviews = previews
                // A card can only be restored from its row. If it was removed from
                // the list, or the list was cleared, its saved original would sit
                // on disk with no way to reach it, so put the row back.
                var added = 0
                for id in saved where !self.cards.contains(where: { $0.id == id }) {
                    self.cards.append(CardItem(id: id, isSelected: false))
                    added += 1
                }
                if added > 0 {
                    self.saveCards()
                    self.log("Put \(added) card(s) back in the list because they have a saved original.")
                }
            }
        }
    }

    // Reading artwork back off the phone moves it and writes it out again, so
    // this is something the user asks for rather than something a flash does
    // quietly on their behalf.
    // The backend's own message is English and written for the log. What the
    // person reads comes from the result code, in their language.
    static func originalArtworkMessage(code: String) -> String? {
        switch code {
        case "backup.incomplete":
            return L("error.backup_incomplete", "Only part of this card's artwork could be read, so nothing was saved. Try again with the iPhone unlocked.")
        case "backup.failed":
            return L("error.backup_failed", "The card's artwork could not be read, so nothing was saved. Try again with the iPhone unlocked.")
        case "backup.write_failed":
            return L("error.backup_write_failed", "The card's artwork was read, but this Mac could not save it. Free up some disk space and try again.")
        case "backup.already_changed":
            return L("error.backup_already_changed", "AirCard has already changed this card, so what is on it now is not the original. To get the original back, remove the card from Wallet and add it again.")
        case "restore.no_backup":
            return L("error.no_backup_for_card", "There is no saved original for this card, so it cannot be restored.")
        case "restore.failed":
            return L("error.restore_failed", "The card could not be fully restored. Try again with the iPhone unlocked.")
        case "backup.discard_failed":
            return L("error.discard_failed", "The saved original could not be removed.")
        default:
            return nil
        }
    }

    func backupCard(id: String) {
        guard !isFlashing else { return }
        guard let udid = device?.udid else {
            errorMessage = L("error.no_iphone_connected", "No iPhone connected.")
            return
        }
        // Clear last time's error, or it outlives the run that caused it.
        errorMessage = nil
        isFlashing = true
        busyJob = .savingOriginal
        showLogs = true
        statusText = L("status.backing_up", "Saving original artwork...")
        let scriptDir = self.scriptDir
        Task.detached {
            let run = AppViewModel.runBackendDiagnosing(["aircard_backend.py", "--backup", udid, id], scriptDir: scriptDir)
            let lines = AppViewModel.jsonLines(run.out)
            let failure = AppViewModel.diagnoseBackendFailure(run.err)
            await MainActor.run {
                self.isFlashing = false
                if lines.isEmpty {
                    // Python never ran; the status line must not keep saying "Saving".
                    self.errorMessage = AppViewModel.backendFailureMessage(failure)
                    self.statusText = L("status.backup_failed", "Could not save the original artwork")
                    self.log("Save Original got no answer from the backend. \(run.err.suffix(300))")
                }
                for json in lines {
                    guard let msg = json["message"] as? String else { continue }
                    self.log("  \(msg)")
                    if (json["type"] as? String) == "success" {
                        self.statusText = L("status.backup_saved", "Original artwork saved")
                    } else if (json["type"] as? String) == "error" {
                        let code = json["code"] as? String ?? ""
                        self.errorMessage = AppViewModel.originalArtworkMessage(code: code)
                            ?? L("error.backup_failed", "The card's artwork could not be read, so nothing was saved. Try again with the iPhone unlocked.")
                        self.statusText = L("status.backup_failed", "Could not save the original artwork")
                    }
                }
                self.loadBackups()
            }
        }
    }

    // Throwing away a saved original cannot be undone, so it asks first. It is
    // here for the case where what got saved was not the original after all.
    func discardBackup(id: String) {
        guard let udid = device?.udid, !isFlashing, backedUpCards.contains(id) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("discard.title", "Discard the saved original?")
        alert.informativeText = L("discard.body", "AirCard will no longer be able to restore this card. Only do this if what was saved is not the card's real design.")
        alert.addButton(withTitle: L("discard.confirm", "Discard"))
        alert.addButton(withTitle: L("ui.cancel", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        errorMessage = nil
        let scriptDir = self.scriptDir
        Task.detached {
            let run = AppViewModel.runBackendDiagnosing(["aircard_backend.py", "--discard-backup", udid, id], scriptDir: scriptDir)
            let lines = AppViewModel.jsonLines(run.out)
            let failure = AppViewModel.diagnoseBackendFailure(run.err)
            await MainActor.run {
                if lines.contains(where: { $0["code"] as? String == "backup.discarded" }) {
                    self.statusText = L("status.backup_discarded", "Saved original removed")
                    self.log("Discarded the saved original for \(id.prefix(12))...")
                } else if lines.isEmpty {
                    self.errorMessage = AppViewModel.backendFailureMessage(failure)
                } else {
                    self.errorMessage = AppViewModel.originalArtworkMessage(code: "backup.discard_failed")
                }
                self.loadBackups()
            }
        }
    }

    // Reads, saves and so shows the original of every card that has none yet.
    // It is a button rather than something a scan does on its own: reading a
    // card's artwork moves the file off the card and puts it back, and that is
    // worth doing when the person asks, not quietly for every card found.
    func readAllOriginals() {
        guard device?.udid != nil, !isFlashing, !isScanningCards else { return }
        let todo = cards.map(\.id).filter { !backedUpCards.contains($0) }
        guard !todo.isEmpty else { return }
        readOriginals(of: todo, then: nil)
    }

    // What a read of several originals says. Every count is its own: one
    // already-changed card used to make the others, which had only failed
    // while the phone locked, read as lost for good.
    nonisolated static func originalsReadMessage(read: Int, total: Int, alreadyChanged: Int, failed: Int) -> String {
        switch (alreadyChanged > 0, failed > 0) {
        case (true, true):
            return String(format: L("status.originals_read_mixed", "Originals read: %1$d of %2$d. %3$d were already changed by AirCard, so their originals are not on the phone. For the other %4$d, unlock the iPhone and try again."), read, total, alreadyChanged, failed)
        case (true, false):
            return String(format: L("status.originals_read_changed", "Originals read: %1$d of %2$d. %3$d were already changed by AirCard, so their originals are not on the phone."), read, total, alreadyChanged)
        case (false, true):
            return String(format: L("status.originals_read_some_failed", "Originals read: %1$d of %2$d. Unlock the iPhone and try again for the rest."), read, total)
        case (false, false):
            return String(format: L("status.originals_read", "Originals read: %1$d of %2$d."), read, total)
        }
    }

    // Reads and saves the originals of these cards, then runs `then` on the
    // main actor (the flash that asked for it, say). Stops at once, and says
    // why, if the backend cannot run at all.
    func readOriginals(of todo: [String], then: (() -> Void)?) {
        guard let udid = device?.udid, !isFlashing else { return }
        errorMessage = nil
        isFlashing = true
        busyJob = .readingOriginals
        showLogs = true
        progress = 0
        let scriptDir = self.scriptDir
        Task.detached {
            var read = 0, alreadyChanged = 0, failed = 0
            var broken: AppViewModel.BackendFailure?
            for (i, id) in todo.enumerated() {
                await MainActor.run {
                    self.statusText = String(format: L("status.reading_originals", "Reading original designs [%1$d/%2$d]..."), i + 1, todo.count)
                    self.progress = Double(i) / Double(todo.count)
                }
                let run = AppViewModel.runBackendDiagnosing(["aircard_backend.py", "--backup", udid, id], scriptDir: scriptDir)
                let codes = AppViewModel.jsonLines(run.out).compactMap { $0["code"] as? String }
                if codes.isEmpty {
                    broken = AppViewModel.diagnoseBackendFailure(run.err)
                    break
                }
                if codes.contains("backup.done") || codes.contains("backup.exists") { read += 1 }
                else if codes.contains("backup.already_changed") { alreadyChanged += 1 }
                else { failed += 1 }
            }
            let summary = (read, alreadyChanged, failed, broken)
            await MainActor.run {
                self.isFlashing = false
                self.progress = 0
                if let broken = summary.3 {
                    self.errorMessage = AppViewModel.backendFailureMessage(broken)
                    self.statusText = L("status.backup_failed", "Could not save the original artwork")
                } else {
                    self.statusText = AppViewModel.originalsReadMessage(read: summary.0, total: todo.count, alreadyChanged: summary.1, failed: summary.2)
                }
                self.log("Read originals: \(summary.0) read, \(summary.1) already changed, \(summary.2) failed.")
                self.loadBackups()
                if summary.3 == nil { then?() }
            }
        }
    }

    func restoreCard(id: String) {
        guard let udid = device?.udid, !isFlashing else { return }
        guard backedUpCards.contains(id) else {
            errorMessage = L("error.no_backup_for_card", "There is no saved original for this card, so it cannot be restored.")
            return
        }
        errorMessage = nil
        isFlashing = true
        busyJob = .restoring
        showLogs = true
        statusText = L("status.restoring", "Restoring original artwork...")
        let scriptDir = self.scriptDir
        Task.detached {
            let run = AppViewModel.runBackendDiagnosing(["aircard_backend.py", "--restore", udid, id], scriptDir: scriptDir)
            let lines = AppViewModel.jsonLines(run.out)
            let failure = AppViewModel.diagnoseBackendFailure(run.err)
            await MainActor.run {
                self.isFlashing = false
                var restored = false
                if lines.isEmpty {
                    self.errorMessage = AppViewModel.backendFailureMessage(failure)
                }
                for json in lines {
                    guard let msg = json["message"] as? String else { continue }
                    self.log("  \(msg)")
                    if (json["type"] as? String) == "success" { restored = true }
                    if (json["type"] as? String) == "error" {
                        let code = json["code"] as? String ?? ""
                        self.errorMessage = AppViewModel.originalArtworkMessage(code: code)
                            ?? L("error.restore_failed", "The card could not be fully restored. Try again with the iPhone unlocked.")
                    }
                }
                if restored {
                    self.statusText = L("status.restored", "Card restored. Force-close Wallet to see it.")
                    self.clearCardImage(for: id)
                } else {
                    self.statusText = L("status.restore_failed", "Could not restore the card")
                }
            }
        }
    }

    // Each phone starts from the targets that write everything, narrowed only by
    // what that phone actually reported. Starting from the last phone's choice
    // meant a second phone with a language not on the list, or no Bold Text
    // setting, kept the first phone's: its keypad never changed, and the app
    // still said the theme was applied.
    nonisolated static func passcodeTargets(language: String?, boldText: Bool?)
        -> (language: PasscodeLanguageTarget, bold: PasscodeBoldTarget) {
        var lang = PasscodeLanguageTarget.all
        if let code = language?.components(separatedBy: CharacterSet(charactersIn: "-_")).first?.lowercased(),
           let match = PasscodeLanguageTarget.allCases.first(where: { $0 != .other && $0.code == code }) {
            lang = match
        }
        let bold: PasscodeBoldTarget = boldText.map { $0 ? .boldOnly : .regularOnly } ?? .both
        return (lang, bold)
    }

    func applyDevicePreferences(from dev: DeviceInfo) {
        // 1. Auto-detect TelephonyUI version based on iOS major version
        if let verStr = dev.version, let major = Int(verStr.components(separatedBy: ".").first ?? "") {
            if major >= 18 {
                self.targetTelephonyVersion = "TelephonyUI-10"
            } else if major >= 16 {
                self.targetTelephonyVersion = "TelephonyUI-9"
            } else {
                self.targetTelephonyVersion = "TelephonyUI-8"
            }
        }
        
        // 2 and 3. Language and bold text, from this phone alone.
        let targets = AppViewModel.passcodeTargets(language: dev.language, boldText: dev.bold_text)
        self.passcodeLanguageTarget = targets.language
        self.passcodeBoldTarget = targets.bold
        self.preferencesAppliedFor = dev.udid

        self.log("  ⚡ Auto-configured passcode target: \(self.targetTelephonyVersion), language: \(self.passcodeLanguageTarget.rawValue), font: \(self.passcodeBoldTarget.rawValue)")
    }
    
    // MARK: - Live Card Scanner
    
    func toggleCardScanning() {
        if isScanningCards {
            stopCardScanning()
        } else {
            startCardScanning()
        }
    }
    
    func startCardScanning() {
        // Not while a flash or save is using the phone, and not while the app
        // is still switching phones: the scan would listen to the old one.
        guard !isScanningCards, !isFlashing, !isCheckingDevice else { return }
        guard let deviceHelper = AppViewModel.deviceHelperExecutableURL else {
            errorMessage = L("status.device_tools_are_missing_from", "Device tools are missing from this build.")
            log("Bundled device_helper not found — cannot scan.")
            return
        }
        guard let udid = device?.udid else {
            errorMessage = L("error.no_iphone_connected", "No iPhone connected.")
            return
        }
        isScanningCards = true
        statusText = L("status.double_click_side_button_pass", "Double-click Side button, pass Face ID, then tap your card...")
        log("Started scanning device logs for cards...")
        
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = deviceHelper
        proc.environment = AppViewModel.processEnvironment
        proc.arguments = ["syslog", udid]
        proc.standardOutput = pipe
        proc.standardError = pipe
        
        self.scanProcess = proc
        // Launch before yielding so Stop cannot race with a pending launch.
        do {
            try proc.run()
        } catch {
            scanProcess = nil
            isScanningCards = false
            statusText = L("status.could_not_start_card_scanning", "Could not start card scanning.")
            log("Syslog monitor failed to start: \(error.localizedDescription)")
            return
        }
        
        let dummyHashes = [
            "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
            "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
            "hwAtAmHKYwsQrJbT5cTNDsaxVME="
        ]
        
        Task.detached {
            do {
                let handle = pipe.fileHandleForReading
                var buffer = Data()
                
                // Drain the pipe through EOF, including the last buffered record
                // when the helper exits. isRunning can become false too early.
                while true {
                    let chunk = try handle.read(upToCount: 65536) ?? Data()
                    if chunk.isEmpty {
                        if buffer.isEmpty { break }
                        buffer.append(0x0A)
                    } else {
                        buffer.append(chunk)
                    }
                    
                    while let newlineRange = buffer.range(of: Data([0x0A])) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                        buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
                        
                        guard let line = String(data: lineData, encoding: .utf8) else { continue }
                        if line.hasPrefix("AirCard scanner: ") {
                            await MainActor.run {
                                guard self.scanProcess === proc else { return }
                                self.log(line)
                            }
                            continue
                        }
                        let lower = line.lowercased()
                        
                        let isWalletSubsystem = lower.contains("passd") ||
                                                lower.contains("passbook") ||
                                                lower.contains("passkit") ||
                                                lower.contains("stockholm") ||
                                                lower.contains("nanopassd") ||
                                                lower.contains("wallet") ||
                                                lower.contains("/cards/")
                        
                        guard isWalletSubsystem else { continue }
                        
                        let isWalletContext = lower.contains("card") ||
                                              lower.contains("pass") ||
                                              lower.contains("payment") ||
                                              lower.contains("pkpass") ||
                                              lower.contains("uniqueid") ||
                                              lower.contains("identifier") ||
                                              lower.contains("face") ||
                                              lower.contains("cache") ||
                                              lower.contains("stockholm") ||
                                              lower.contains("/cards/")
                        
                        guard isWalletContext else { continue }
                        
                        for regex in AppViewModel.cardRegexes {
                            let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
                            for m in matches {
                                if m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: line) {
                                    let candidate = String(line[r])
                                    if candidate.count == 36 && candidate.contains("-") { continue }
                                    if dummyHashes.contains(candidate) { continue }
                                    
                                    await MainActor.run {
                                        guard self.scanProcess === proc, self.device?.udid == udid else { return }
                                        if !self.cards.contains(where: { $0.id == candidate }) {
                                            self.cards.append(CardItem(id: candidate, isSelected: true))
                                            self.saveCards()
                                            self.log("Found card: \(candidate)")
                                            NSSound(named: "Glass")?.play()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if chunk.isEmpty { break }
                }
                proc.waitUntilExit()
                await MainActor.run {
                    guard self.scanProcess === proc else { return }
                    self.scanProcess = nil
                    self.isScanningCards = false
                    self.statusText = L("status.card_scanning_ended_check_the", "Card scanning ended. Check the log and reconnect the iPhone to retry.")
                    self.log("Syslog monitor exited (status \(proc.terminationStatus)). Total cards: \(self.cards.count).")
                    self.saveCards()
                }
            } catch {
                if proc.isRunning { proc.terminate() }
                proc.waitUntilExit()
                await MainActor.run {
                    guard self.scanProcess === proc else { return }
                    self.scanProcess = nil
                    self.log("Syslog monitor stopped: \(error.localizedDescription)")
                    self.isScanningCards = false
                    self.statusText = L("status.card_scanning_failed_check_the", "Card scanning failed. Check the log and retry.")
                }
            }
        }
    }
    
    func stopCardScanning() {
        let process = scanProcess
        scanProcess = nil
        if let process, process.isRunning { process.terminate() }
        isScanningCards = false
        // Compare against the same lookup, not the English wording, or this never
        // matches once the app is running in another language.
        if statusText == L("status.double_click_side_button_pass", "Double-click Side button, pass Face ID, then tap your card...") {
            statusText = L("status.ready", "Ready")
        }
        saveCards()
        log("Scanning stopped. Total cards: \(cards.count).")
    }
    
    // MARK: - Skin Application
    
    // Cards about to be sent whose original is not saved and still could be.
    nonisolated static func originalsWorthSaving(sending: [String], saved: Set<String>, flashed: Set<String>, declined: Set<String>) -> [String] {
        sending.filter { !saved.contains($0) && !flashed.contains($0) && !declined.contains($0) }
    }

    // Before the first write to a card, its original is the only copy there
    // is. Most people skipped Read Original Designs, and found Restore greyed
    // out when they wanted their bank's design back.
    func applySkin() {
        guard !isFlashing else { return }
        guard device?.udid != nil else {
            errorMessage = L("error.no_iphone_connected", "No iPhone connected.")
            return
        }
        let sending = cards.filter { $0.isSelected && $0.customImageURL != nil }.map(\.id)
        let unsaved = Self.originalsWorthSaving(sending: sending, saved: backedUpCards, flashed: flashedCards, declined: sendWithoutSaving)
        guard !unsaved.isEmpty else { sendSkins(); return }
        let alert = NSAlert()
        alert.messageText = L("flash.save_first_title", "Save the originals first?")
        alert.informativeText = String(format: L("flash.save_first_body", "%d of these cards have no saved original. Once the new artwork is on them, AirCard cannot put their own design back."), unsaved.count)
        alert.addButton(withTitle: L("flash.save_then_send", "Save Originals, Then Send"))
        alert.addButton(withTitle: L("flash.send_without_saving", "Send Without Saving"))
        alert.addButton(withTitle: L("ui.cancel", "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            readOriginals(of: unsaved) { [weak self] in self?.sendSkins() }
        case .alertSecondButtonReturn:
            sendWithoutSaving.formUnion(unsaved)
            sendSkins()
        default:
            return
        }
    }

    private func sendSkins() {
        guard let udid = device?.udid, !isFlashing else {
            if device?.udid == nil { errorMessage = L("error.no_iphone_connected", "No iPhone connected.") }
            return
        }
        restoreMissingArtwork()
        let selectedCardsWithSkin = cards.filter { $0.isSelected && $0.customImageURL != nil }
        guard !selectedCardsWithSkin.isEmpty else {
            errorMessage = L("error.please_assign_a_skin_image", "Please assign a skin image to at least one selected card.")
            return
        }
        
        isFlashing = true
        busyJob = .flashCards
        flashCancelled = false
        flashStalled = false
        showLogs = true
        progress = 0.0
        errorMessage = nil
        log("Starting skin application for \(selectedCardsWithSkin.count) card(s)...")
        let scriptDir = self.scriptDir
        
        // Report failures by the number people see on each card, not a hash.
        let cardNumbers = Dictionary(uniqueKeysWithValues: cards.enumerated().map { ($1.id, $0 + 1) })
        Task.detached {
            var flashFailed = false
            var notSent: [Int] = []
            let totalCards = Double(selectedCardsWithSkin.count)
            for (idx, card) in selectedCardsWithSkin.enumerated() {
                // A Cancel that lands just after a card finished stops here,
                // before the next card, instead of being lost.
                if await MainActor.run(body: { self.flashCancelled }) { break }
                guard let imgURL = card.customImageURL else { continue }
                
                // A fresh directory per run. The old fixed /tmp path was shared
                // between runs, so a card whose artwork failed to prepare would
                // be flashed with whatever the previous run had left behind.
                let prepDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("aircard-prep-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: prepDir, withIntermediateDirectories: true)
                let preparedURL = prepDir.appendingPathComponent("card.png")
                let preparedPath = preparedURL.path
                defer { try? FileManager.default.removeItem(at: prepDir) }

                await MainActor.run {
                    self.statusText = String(format: L("status.preparing_skin", "[%1$d/%2$d] Preparing skin for %3$@..."), idx + 1, selectedCardsWithSkin.count, String(card.id.prefix(10)))
                    self.progress = (Double(idx) + 0.05) / totalCards
                    self.log("Flashing card [\(idx + 1)/\(selectedCardsWithSkin.count)]: \(card.id)")
                }
                
                // 1. Prepare image natively in Swift (0 external dependencies!)
                let prepped = AppViewModel.prepareCardImage(srcURL: imgURL, dstURL: preparedURL)
                if !prepped {
                    let prepProcess = Process()
                    prepProcess.executableURL = AppViewModel.pythonExecutableURL
                    prepProcess.environment = AppViewModel.processEnvironment
                    prepProcess.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
                    prepProcess.arguments = ["aircard_backend.py", "--prepare-image", imgURL.path, preparedPath]
                    try? prepProcess.run()
                    prepProcess.waitUntilExit()
                }

                // Neither path reports back, so check the file itself. Flashing
                // without this writes stale or missing artwork and still calls it
                // a success.
                let preparedSize = (try? FileManager.default.attributesOfItem(atPath: preparedPath)[.size] as? Int) ?? nil
                guard (preparedSize ?? 0) > 0 else {
                    flashFailed = true
                    notSent.append(cardNumbers[card.id] ?? idx + 1)
                    let name = imgURL.lastPathComponent
                    await MainActor.run {
                        self.log("Could not prepare artwork from \(name); skipping this card.")
                        self.errorMessage = L("error.prepare_image_failed", "AirCard could not read the picture for one of the cards, so that card was left unchanged. Pick its picture again and send it once more.")
                    }
                    continue
                }
                
                // 2. Flash card
                let flashProcess = Process()
                flashProcess.executableURL = AppViewModel.pythonExecutableURL
                flashProcess.environment = AppViewModel.processEnvironment
                flashProcess.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
                flashProcess.arguments = ["aircard_backend.py", "--flash", udid, card.id, preparedPath]
                
                let pipe = Pipe()
                let errPipe = Pipe()
                flashProcess.standardOutput = pipe
                flashProcess.standardError = errPipe
                errPipe.fileHandleForReading.readabilityHandler = { h in
                    let data = h.availableData
                    if !data.isEmpty, let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        Task { @MainActor in
                            self.log("  [err] \(text)")
                        }
                    }
                }
                
                do {
                    try flashProcess.run()
                } catch {
                    let message = error.localizedDescription
                    flashFailed = true
                    await MainActor.run {
                        self.log("Failed to launch card flasher: \(message)")
                    }
                    break
                }
                
                let handle = pipe.fileHandleForReading
                var lineBuffer = ""
                
                let handleJSONLine: (String) async -> Void = { line in
                    guard !line.isEmpty,
                          let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let msg = json["message"] as? String else { return }
                    
                    let step = (json["step"] as? NSNumber)?.doubleValue
                    let total = (json["total"] as? NSNumber)?.doubleValue
                    
                    await MainActor.run {
                        self.lastFlashActivity = Date()
                        self.flashStalled = false
                        if let step = step, let total = total, total > 0 {
                            let subProgress = step / total
                            let currentProgress = (Double(idx) + subProgress) / totalCards
                            self.progress = min(currentProgress, 1.0)
                        }
                        // The backend's words are English and meant for the log.
                        if (json["code"] as? String) == "flash.retrying" {
                            self.statusText = L("status.flash_retrying", "The iPhone was slow to take the files. Trying them one at a time...")
                        } else if !self.flashStalled {
                            self.statusText = String(format: L("status.sending_card", "Sending card %1$d of %2$d..."), idx + 1, selectedCardsWithSkin.count)
                        }
                        self.log("  \(msg)")
                    }
                }
                
                let processChunk: (Data) async -> Void = { data in
                    guard let text = String(data: data, encoding: .utf8) else { return }
                    lineBuffer.append(text)
                    let parts = lineBuffer.components(separatedBy: .newlines)
                    if parts.count > 1 {
                        for line in parts.dropLast() {
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                await handleJSONLine(trimmed)
                            }
                        }
                        lineBuffer = parts.last ?? ""
                    }
                }
                
                await MainActor.run {
                    self.activeFlashProcess = flashProcess
                    self.canCancelFlash = true
                    self.lastFlashActivity = Date()
                }
                // The read below blocks while the helper is silent, so the stall
                // check has to run beside it. Task.sleep throws on cancel; that
                // has to end the loop, not be swallowed and carry on.
                let watchdog = Task { @MainActor in
                    while true {
                        do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                        let quiet = Date().timeIntervalSince(self.lastFlashActivity)
                        if quiet > AppViewModel.flashStallSeconds && !self.flashStalled {
                            self.flashStalled = true
                            self.statusText = L("status.flash_slow", "The iPhone is taking a long time to respond. Still trying. If it stays like this, cancel, then unplug the iPhone and plug it back in.")
                            self.log("No response from the iPhone for \(Int(quiet)) seconds, still waiting.")
                        }
                    }
                }

                while flashProcess.isRunning {
                    let data = handle.availableData
                    if data.isEmpty { usleep(50000); continue }
                    await processChunk(data)
                }
                
                let remainingData = handle.readDataToEndOfFile()
                if !remainingData.isEmpty {
                    await processChunk(remainingData)
                }
                let finalLine = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !finalLine.isEmpty {
                    await handleJSONLine(finalLine)
                }
                flashProcess.waitUntilExit()
                errPipe.fileHandleForReading.readabilityHandler = nil
                watchdog.cancel()
                await MainActor.run {
                    self.activeFlashProcess = nil
                    self.canCancelFlash = false
                }

                if flashProcess.terminationStatus != 0 {
                    let cancelled = await MainActor.run { self.flashCancelled }
                    if cancelled { break }
                    // One card failing used to end the run, and every card after
                    // it was quietly never tried. Carry on and report which.
                    flashFailed = true
                    notSent.append(cardNumbers[card.id] ?? idx + 1)
                    await MainActor.run {
                        self.log("Card update failed for \(card.id.prefix(12))..., carrying on with the rest.")
                    }
                    continue
                }
                
                await MainActor.run {
                    self.progress = Double(idx + 1) / totalCards
                }
            }
            
            let didFail = flashFailed
            let failedCards = notSent
            await MainActor.run {
                self.isFlashing = false
                self.flashStalled = false
                let total = selectedCardsWithSkin.count
                let list = AppViewModel.cardList(failedCards)
                if self.flashCancelled {
                    // Cards that had already failed before Cancel are still named.
                    self.statusText = failedCards.isEmpty
                        ? L("status.flash_cancelled", "Cancelled. Cards already sent to the iPhone are left as they are.")
                        : String(format: L("status.flash_cancelled_some_failed", "Cancelled. Cards already sent are left as they are. These had failed before that: %@."), list)
                } else if didFail {
                    if notSent.isEmpty {
                        self.statusText = L("status.failed_to_apply_card_skins", "Failed to apply card skins.")
                        self.errorMessage = L("error.one_or_more_cards_could", "One or more cards could not be updated. Check the log and try again.")
                    } else {
                        self.statusText = String(format: L("status.cards_partly_sent", "Sent %1$d of %2$d. Not sent: %3$@."), total - failedCards.count, total, list)
                        self.errorMessage = String(format: L("error.some_cards_not_sent", "These cards were not sent: %@. Check that the iPhone is still connected and unlocked, then try them again."), list)
                    }
                    self.log("Artwork sent for \(total - failedCards.count) of \(total) cards; not sent: \(failedCards).")
                } else {
                    // Nothing on the phone confirms the card actually changed; the
                    // write is sent and the phone does not report back. Say that.
                    self.statusText = L("status.cards_sent", "Sent to your iPhone. Force-close Wallet to see the new design.")
                    self.showSuccessAlert = true
                    self.log("Artwork sent for all selected cards.")
                }
                // A failure is often an unplugged or swapped phone; look again so
                // the header does not keep naming a phone that is gone.
                if didFail { self.checkDevice(quiet: true) }
            }
        }
    }

    // "Card 3, Card 5 and Card 7", in the person's language: the way each card
    // is labelled on screen, joined the way their language joins a list.
    // Joined in the language the app is shown in, which is not always the
    // system's: on a Mac set to a language AirCard does not have, the words
    // were English and the "and" was not.
    nonisolated static func cardList(_ numbers: [Int]) -> String {
        let formatter = ListFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        let labels = numbers.sorted().map { String(format: L("ui.card_number", "Card #%d"), $0) }
        return formatter.string(from: labels) ?? labels.joined(separator: ", ")
    }
    
    // MARK: - Passcode Theme (.passthm) Handlers
    
    func inspectPasscodeTheme(url: URL) {
        isInspectingTheme = true
        let scriptDir = self.scriptDir
        Task.detached {
            let proc = Process()
            proc.executableURL = AppViewModel.pythonExecutableURL
            proc.environment = AppViewModel.processEnvironment
            proc.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
            proc.arguments = ["aircard_backend.py", "--inspect-passthm", url.path]
            
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool, ok {
                let name = json["name"] as? String ?? url.deletingPathExtension().lastPathComponent
                let detectedVersion = json["detected_version"] as? String ?? "TelephonyUI-10"
                let fileCount = json["file_count"] as? Int ?? 0
                var previews: [String: NSImage] = [:]
                if let keysDict = json["keys_preview"] as? [String: String] {
                    for (digit, dataUri) in keysDict {
                        if let commaIdx = dataUri.firstIndex(of: ",") {
                            let b64 = String(dataUri[dataUri.index(after: commaIdx)...])
                            if let imgData = Data(base64Encoded: b64), let nsImg = NSImage(data: imgData) {
                                previews[digit] = nsImg
                            }
                        }
                    }
                }
                let themeInfo = PasscodeThemeInfo(
                    name: name,
                    filePath: url.path,
                    detectedVersion: detectedVersion,
                    fileCount: fileCount,
                    keysPreview: previews
                )
                await MainActor.run {
                    self.loadedPasscodeTheme = themeInfo
                    // The phone's own iOS version decides where the keypad goes. A
                    // theme only suggests one when there is no phone to ask; letting
                    // it override sent iOS 18 keypads to a folder iOS 18 ignores.
                    if self.device?.connected != true {
                        self.targetTelephonyVersion = detectedVersion
                    }
                    self.isInspectingTheme = false
                    self.statusText = String(format: L("status.loaded_theme", "Loaded passcode theme '%1$@' (%2$d assets)"), name, fileCount)
                    self.log("Loaded .passthm: \(name) [\(detectedVersion)] with \(fileCount) image assets")
                }
            } else {
                // The backend says why; without this the person saw one generic
                // line whatever the cause, and could only try the same file again.
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let code = json?["code"] as? String ?? ""
                let detail = json?["error"] as? String ?? "no output"
                await MainActor.run {
                    self.isInspectingTheme = false
                    self.log("Could not read \(url.lastPathComponent): \(detail)")
                    self.errorMessage = AppViewModel.passcodeFailureMessage(code: code)
                        ?? L("error.failed_to_inspect_passthm_file", "Failed to inspect .passthm file")
                }
            }
        }
    }
    
    static func passcodeFailureMessage(code: String) -> String? {
        switch code {
        case "passthm.missing":
            return L("error.passthm_missing", "The theme file is no longer where it was when you picked it. Choose it again.")
        case "passthm.no_images":
            return L("error.passthm_no_images", "This theme file has no keypad images in it, so there is nothing to send.")
        case "passthm.not_a_theme":
            return L("error.passthm_not_a_theme", "This file is not a keypad theme. A theme is a .passthm or .passtheme file, or a zip of keypad images.")
        case "passthm.write_failed":
            return L("error.passthm_write_failed", "Some keypad files did not reach the iPhone, so the keypad may look mixed. Keep the iPhone unlocked and connected, then send the theme again.")
        case "passthm.failed":
            return L("error.keypad_not_sent", "The keypad could not be sent. Check that the iPhone is connected and unlocked, then try again.")
        default:
            return nil
        }
    }

    func flashPasscodeTheme() {
        guard let theme = loadedPasscodeTheme else { return }
        guard let dev = device, dev.connected, let udid = dev.udid else {
            errorMessage = L("error.please_connect_and_trust_your", "Please connect and trust your iPhone first.")
            return
        }
        
        isFlashing = true
        busyJob = .flashPasscode
        showLogs = true
        progress = 0.0
        errorMessage = nil
        passcodeFailure = nil
        statusText = L("status.starting_passcode_theme_flash", "Starting passcode theme flash...")
        log("Flashing passcode theme '\(theme.name)' to device...")
        let scriptDir = self.scriptDir
        let targetVer = self.targetTelephonyVersion
        let targetLang = self.passcodeLanguageTarget.code
        let targetBold = self.passcodeBoldTarget.code
        
        Task.detached {
            let proc = Process()
            proc.executableURL = AppViewModel.pythonExecutableURL
            proc.environment = AppViewModel.processEnvironment
            proc.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
            proc.arguments = [
                "aircard_backend.py",
                "--flash-passthm",
                udid,
                theme.filePath,
                targetVer,
                targetLang,
                targetBold
            ]
            
            let pipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = errPipe
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                if !data.isEmpty, let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    Task { @MainActor in
                        self.log("  [err] \(text)")
                    }
                }
            }
            try? proc.run()
            
            let handle = pipe.fileHandleForReading
            var lineBuffer = ""
            
            let handleJSONLine: (String) async -> Void = { line in
                guard !line.isEmpty,
                      let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let msg = json["message"] as? String else { return }
                
                let step = (json["step"] as? NSNumber)?.doubleValue
                let total = (json["total"] as? NSNumber)?.doubleValue
                
                let kind = json["type"] as? String
                let code = json["code"] as? String ?? ""
                await MainActor.run {
                    if let step = step, let total = total, total > 0 {
                        self.progress = min(step / total, 1.0)
                        self.statusText = String(format: L("status.sending_keypad", "Sending keypad files [%1$d/%2$d]..."), Int(step), Int(total))
                    }
                    if kind == "error" {
                        self.passcodeFailure = AppViewModel.passcodeFailureMessage(code: code)
                    }
                    // The backend's words stay English, in the log only.
                    self.log("  \(msg)")
                }
            }
            
            let processChunk: (Data) async -> Void = { data in
                guard let chunkStr = String(data: data, encoding: .utf8) else { return }
                lineBuffer += chunkStr
                let parts = lineBuffer.components(separatedBy: .newlines)
                if parts.count > 1 {
                    for line in parts.dropLast() {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            await handleJSONLine(trimmed)
                        }
                    }
                    lineBuffer = parts.last ?? ""
                }
            }
            
            while proc.isRunning {
                let data = handle.availableData
                if data.isEmpty { usleep(50000); continue }
                await processChunk(data)
            }
            
            let remaining = handle.readDataToEndOfFile()
            if !remaining.isEmpty {
                await processChunk(remaining)
            }
            let finalLine = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalLine.isEmpty {
                await handleJSONLine(finalLine)
            }
            
            proc.waitUntilExit()
            errPipe.fileHandleForReading.readabilityHandler = nil
            let exitCode = proc.terminationStatus
            
            await MainActor.run {
                self.isFlashing = false
                if exitCode == 0 {
                    self.progress = 1.0
                    self.statusText = L("status.passcode_sent", "Sent to your iPhone. Lock it to see the new keypad.")
                    self.showSuccessAlert = true
                    self.log("Passcode theme '\(theme.name)' sent to the iPhone.")
                } else {
                    self.statusText = L("status.keypad_not_sent", "The keypad could not be sent.")
                    self.errorMessage = self.passcodeFailure
                        ?? L("error.keypad_not_sent", "The keypad could not be sent. Check that the iPhone is connected and unlocked, then try again.")
                    self.log("Passcode flash failed (exit code \(exitCode)).")
                }
            }
        }
    }
    
    // MARK: - Theme Creator Methods
    
    var effectiveCreatorKeys: [String: NSImage] {
        if creatorSubMode == .posterSlice {
            return creatorSlicedKeys
        } else {
            return creatorCustomKeys
        }
    }
    
    func updatePosterSlicing() {
        guard let img = creatorPosterImage else {
            creatorSlicedKeys = [:]
            return
        }
        creatorSlicedKeys = KeypadSlicer.slicePoster(
            image: img,
            zoom: creatorPosterZoom,
            offset: creatorPosterOffset,
            maskToCircles: creatorMaskToCircles
        )
    }
    
    func setPosterImage(_ img: NSImage) {
        creatorPosterImage = img
        creatorPosterZoom = 1.0
        creatorPosterOffset = .zero
        updatePosterSlicing()
        statusText = L("status.poster_image_loaded_ready_to", "Poster image loaded · Ready to frame and slice")
    }
    
    func setIndividualKey(digit: String, image: NSImage) {
        creatorRawIndividualImages[digit] = image
        creatorIndividualOffsets[digit] = .zero
        creatorIndividualZooms[digit] = 1.0
        selectedKeyDigit = digit
        updateIndividualKey(digit: digit)
        statusText = String(format: L("status.updated_key", "Updated key %@ · Drag on dialer to reposition or use zoom slider"), digit)
    }
    
    func updateIndividualKey(digit: String) {
        guard let raw = creatorRawIndividualImages[digit] else { return }
        let offset = creatorIndividualOffsets[digit] ?? .zero
        let zoom = creatorIndividualZooms[digit] ?? 1.0
        if let cropped = KeypadSlicer.cropToCircle(
            image: raw,
            targetSize: CGSize(width: 225, height: 225),
            circleDiameter: 222.0,
            zoom: zoom,
            offset: offset
        ) {
            creatorCustomKeys[digit] = cropped
        }
    }
    
    func clearIndividualKey(digit: String) {
        creatorCustomKeys.removeValue(forKey: digit)
        creatorRawIndividualImages.removeValue(forKey: digit)
        creatorIndividualOffsets.removeValue(forKey: digit)
        creatorIndividualZooms.removeValue(forKey: digit)
        if selectedKeyDigit == digit {
            selectedKeyDigit = nil
        }
        statusText = String(format: L("status.cleared_key", "Cleared key %@"), digit)
    }
    
    func clearAllIndividualKeys() {
        creatorCustomKeys.removeAll()
        creatorRawIndividualImages.removeAll()
        creatorIndividualOffsets.removeAll()
        creatorIndividualZooms.removeAll()
        selectedKeyDigit = nil
        statusText = L("status.cleared_all_custom_keys", "Cleared all custom keys")
    }
    
    func adoptPosterSlicesToIndividualKeys() {
        for (k, v) in creatorSlicedKeys {
            creatorCustomKeys[k] = v
            creatorRawIndividualImages[k] = v
            creatorIndividualOffsets[k] = .zero
            creatorIndividualZooms[k] = 1.0
        }
        statusText = L("status.adopted_poster_slices_to_individual", "Adopted poster slices to individual keys")
    }
    
    func editLoadedThemeInCreator() {
        guard let theme = loadedPasscodeTheme else { return }
        for (digit, img) in theme.keysPreview {
            creatorCustomKeys[digit] = img
            creatorRawIndividualImages[digit] = img
            creatorIndividualOffsets[digit] = .zero
            creatorIndividualZooms[digit] = 1.0
        }
        selectedKeyDigit = nil
        creatorSubMode = .individualKeys
        passcodeTabMode = .themeCreator
        statusText = String(format: L("status.loaded_into_creator", "Loaded '%1$@' into Theme Creator (%2$d keys ready to edit)"), theme.name, theme.keysPreview.count)
        log("Imported theme '\(theme.name)' into Creator for custom editing")
    }
    
    // Each mode clears only its own work. Removing the poster, or Clear All
    // while slicing a poster, also wiped every key built by hand in the other
    // mode, with no warning and no way back.
    func removePoster() {
        creatorPosterImage = nil
        creatorPosterZoom = 1.0
        creatorPosterOffset = .zero
        creatorSlicedKeys.removeAll()
        statusText = L("status.theme_creator_reset", "Theme Creator reset")
    }

    func clearCreatorMode() {
        if creatorSubMode == .posterSlice {
            removePoster()
        } else {
            clearAllIndividualKeys()
            statusText = L("status.theme_creator_reset", "Theme Creator reset")
        }
    }
    
    func flashCreatedTheme() {
        let keys = effectiveCreatorKeys
        guard !keys.isEmpty else {
            errorMessage = L("error.please_add_at_least_one", "Please add at least one key icon or import a poster image first.")
            return
        }
        guard let dev = device, dev.connected, dev.udid != nil else {
            errorMessage = L("error.please_connect_and_trust_your", "Please connect and trust your iPhone first.")
            return
        }
        
        guard let stagedURL = PasscodeThemeExporter.stageTemporaryTheme(
            keys: keys,
            language: passcodeLanguageTarget,
            boldMode: passcodeBoldTarget
        ) else {
            errorMessage = L("error.failed_to_package_theme_for", "Failed to package theme for flashing.")
            return
        }
        
        let themeInfo = PasscodeThemeInfo(
            name: "Created Theme",
            filePath: stagedURL.path,
            detectedVersion: targetTelephonyVersion,
            fileCount: keys.count * 4,
            keysPreview: keys
        )
        self.loadedPasscodeTheme = themeInfo
        self.flashPasscodeTheme()
    }
}

// MARK: - Card View Component (Apple Wallet Style)

struct WalletCardView: View {
    @Binding var card: CardItem
    let cardIndex: Int
    let originalImage: NSImage?
    let hasBackup: Bool
    let busy: Bool
    // Save, Restore and Discard talk to the phone; without one they did nothing.
    let connected: Bool
    let onPickImage: () -> Void
    let onDropImage: (NSImage) -> Void
    // A zip or folder dropped on the card: it goes to the Skin Library.
    let onDropPack: (URL) -> Void
    // Something dropped that is neither a picture nor a pack.
    let onDropUnreadable: () -> Void
    let onClearImage: () -> Void
    let onDesign: () -> Void
    let onChooseFromLibrary: () -> Void
    let onBackup: () -> Void
    let onRestore: () -> Void
    let onDiscardBackup: () -> Void
    let onDelete: () -> Void
    
    @State private var isHovered = false
    @State private var isTargeted = false
    @State private var copied = false
    
    var body: some View {
        VStack(spacing: 10) {
            // Card Mockup
            ZStack {
                if let img = card.customImage {
                    // Custom Skin Applied
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 290, height: 182)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        
                        // Subtle Gloss
                        LinearGradient(
                            colors: [.white.opacity(0.18), .clear, .black.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        
                        // Top Right Clear Button
                        Button(action: onClearImage) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.white.opacity(0.9))
                                .background(Circle().fill(Color.black.opacity(0.55)))
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .disabled(busy)
                        .help(L("ui.remove_skin", "Remove skin"))
                        .accessibilityLabel(L("ui.remove_skin", "Remove skin"))
                        
                        // Hover overlay: Change Skin
                        if isHovered {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Label(L("ui.adjust_skin", "Adjust"), systemImage: "crop")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(.ultraThinMaterial)
                                        .cornerRadius(20)
                                        .shadow(radius: 4)
                                    Spacer()
                                }
                                .padding(.bottom, 12)
                            }
                        }
                    }
                } else if let original = originalImage {
                    // The card as it is on the phone, from its saved original,
                    // so people can see what they are about to replace.
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: original)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 290, height: 182)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        Text(L("ui.original_badge", "Original"))
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(10)

                        if isHovered || isTargeted {
                            ZStack {
                                Color.black.opacity(0.35)
                                VStack(spacing: 6) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.system(size: 26))
                                    Text(isTargeted ? L("ui.drop_image_here", "Drop image here") : L("ui.assign_card_skin", "Assign Card Skin"))
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                                .foregroundColor(.white)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                } else {
                    // Empty / Placeholder Card Mockup
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(NSColor.controlBackgroundColor),
                                        Color(NSColor.windowBackgroundColor).opacity(0.8)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                isTargeted ? Color.accentColor : (isHovered ? Color.secondary.opacity(0.4) : Color.secondary.opacity(0.2)),
                                style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: card.customImage == nil ? [6, 4] : [])
                            )
                        
                        // Card Chip & Contactless indicator
                        VStack(alignment: .leading) {
                            HStack {
                                Image(systemName: "wave.3.right")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary.opacity(0.5))
                                Spacer()
                                Image(systemName: "creditcard")
                                    .font(.system(size: 16))
                                    .foregroundColor(.secondary.opacity(0.4))
                            }
                            .padding(14)
                            Spacer()
                        }
                        
                        // Center Action
                        VStack(spacing: 8) {
                            Image(systemName: isHovered || isTargeted ? "photo.badge.plus" : "plus.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(isTargeted ? .accentColor : (isHovered ? .accentColor : .secondary.opacity(0.7)))
                                .scaleEffect(isHovered ? 1.08 : 1.0)
                                .animation(.spring(response: 0.3), value: isHovered)
                            
                            Text(isTargeted ? L("ui.drop_image_here", "Drop image here") : L("ui.assign_card_skin", "Assign Card Skin"))
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                            
                            Text(L("ui.click_to_browse_or_drag", "Click to browse or drag image"))
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            // After a scan every card looked the same, numbered
                            // and blank: nothing said which was the bank card
                            // just tapped, or how to find out.
                            if connected && !hasBackup {
                                Text(L("ui.read_originals_to_see", "Read Original Designs to see which card this is."))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                    .frame(width: 290, height: 182)
                }
            }
            .frame(width: 290, height: 182)
            .shadow(color: .black.opacity(isHovered ? 0.22 : 0.12), radius: isHovered ? 10 : 5, y: isHovered ? 5 : 2)
            .onHover { h in isHovered = h }
            // While a flash runs, the card it is sending must not change under it:
            // the list would show artwork that never went to the phone.
            .onTapGesture { if !busy { onPickImage() } }
            .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $isTargeted) { providers in
                guard !busy else { return false }
                // Hand the picture to the model by card id. Writing it into this
                // row after an async load could land it on another card if the
                // list changed in between.
                guard let provider = providers.first else { return false }
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        var fileURL: URL?
                        if let url = item as? URL {
                            fileURL = url
                        } else if let data = item as? Data, let urlStr = String(data: data, encoding: .utf8), let url = URL(string: urlStr) {
                            fileURL = url
                        }
                        guard let url = fileURL else { return }
                        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                        if isFolder || url.pathExtension.lowercased() == "zip" {
                            Task { @MainActor in onDropPack(url) }
                        } else if let img = NSImage(contentsOf: url) {
                            Task { @MainActor in onDropImage(img) }
                        } else {
                            Task { @MainActor in onDropUnreadable() }
                        }
                    }
                    return true
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                        if let url = item as? URL, let img = NSImage(contentsOf: url) {
                            Task { @MainActor in onDropImage(img) }
                        } else if let img = item as? NSImage {
                            Task { @MainActor in onDropImage(img) }
                        }
                    }
                    return true
                }
                return false
            }
            
            // Bottom Info & Controls
            HStack(spacing: 8) {
                Toggle("", isOn: $card.isSelected)
                    .labelsHidden()
                    .help(L("ui.include_in_flash", "Include in flash"))
                    // Which card this box belongs to, said out loud; it was an
                    // unnamed checkbox, one per card.
                    .accessibilityLabel(String(format: L("ui.card_number", "Card #%d"), cardIndex + 1))
                    .accessibilityHint(L("ui.include_in_flash", "Include in flash"))
                
                Text(String(format: L("ui.card_number", "Card #%d"), cardIndex + 1))
                    .font(.system(size: 12, weight: .semibold))
                
                // Monospace Hash Pill with Copy
                HStack(spacing: 4) {
                    Text(card.id.prefix(8) + "…" + card.id.suffix(6))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(card.id, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundColor(copied ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(copied ? L("ui.copied", "Copied!") : L("ui.copy_full_hash", "Copy full hash"))
                    .accessibilityLabel(copied ? L("ui.copied", "Copied!") : L("ui.copy_full_hash", "Copy full hash"))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                
                Spacer()
                
                // Status badge
                if card.customImage != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 12))
                        .help(L("ui.skin_assigned_and_ready", "Skin assigned and ready"))
                }
                
                Menu {
                    Button(action: onDesign) {
                        Label(L("designer.menu", "Design Card Face..."),
                              systemImage: "paintbrush.pointed")
                    }
                    .disabled(busy)

                    Button(action: onChooseFromLibrary) {
                        Label(L("ui.choose_from_library", "Choose from Skin Library..."),
                              systemImage: "photo.stack")
                    }
                    .disabled(busy)

                    Divider()

                    Button(action: onBackup) {
                        Label(L("ui.save_original", "Save Original Artwork"),
                              systemImage: "square.and.arrow.down")
                    }
                    .disabled(hasBackup || busy || !connected)

                    Button(action: onRestore) {
                        Label(L("ui.restore_original", "Restore Original Artwork"),
                              systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!hasBackup || busy || !connected)

                    if hasBackup {
                        Button(role: .destructive, action: onDiscardBackup) {
                            Label(L("ui.discard_original", "Discard Saved Original..."),
                                  systemImage: "trash")
                        }
                        .disabled(busy || !connected)
                        Divider()
                        Text(L("ui.original_saved", "Original artwork is saved"))
                    }
                } label: {
                    Image(systemName: hasBackup ? "clock.arrow.circlepath" : "ellipsis.circle")
                        .font(.system(size: 11))
                        .foregroundColor(hasBackup ? .accentColor : .secondary.opacity(0.7))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(hasBackup
                      ? L("ui.original_saved", "Original artwork is saved")
                      : L("ui.save_original_help", "Save this card's original artwork so it can be put back"))

                // Delete button
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .help(L("ui.remove_from_list", "Remove from list"))
                .accessibilityLabel(L("ui.remove_from_list", "Remove from list"))
            }
            .padding(.horizontal, 4)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(card.isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - Card Face Designer

// A card face framed in the app rather than guessed at by a centre crop. Pan is
// kept as a fraction of the card's width on both axes, so the preview and the
// full-size render agree no matter how big the preview happens to be.
struct CardFaceDesign {
    var source: NSImage
    var zoom: Double = 1.0
    var offset: CGSize = .zero
    var background: Color = .black

    // Wallet's own card resolution. Rendering at exactly this size means the
    // later prepare step has nothing left to crop.
    static let pixelSize = CGSize(width: 1536, height: 969)
    static let aspect = pixelSize.width / pixelSize.height
    // Down to 0.2 so a portrait photo fits whole: at 0.5 it still lost about
    // 40% to the card's shape.
    static let zoomRange: ClosedRange<Double> = 0.2...4.0

    // The scale at which the image just covers the card. Zoom multiplies from
    // here, so 1.0 always means edge to edge with nothing showing behind it.
    static func fillScale(image: CGSize, card: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        return max(card.width / image.width, card.height / image.height)
    }

    func render() -> NSImage? {
        let size = Self.pixelSize
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(background).setFill()
        NSRect(origin: .zero, size: size).fill()

        let scale = Self.fillScale(image: source.size, card: size) * CGFloat(zoom)
        let w = source.size.width * scale
        let h = source.size.height * scale
        // AppKit draws from the bottom left while the drag is measured from the
        // top, hence the minus on y.
        let x = (size.width - w) / 2 + offset.width * size.width
        let y = (size.height - h) / 2 - offset.height * size.width
        source.draw(in: CGRect(x: x, y: y, width: w, height: h),
                    from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

struct CardFaceDesignerView: View {
    let title: String
    let onApply: (CardFaceDesign) -> Void
    let onCancel: () -> Void

    @State private var design: CardFaceDesign?
    @State private var dragStart: CGSize = .zero
    @State private var isTargeted = false

    init(title: String, initialDesign: CardFaceDesign?, fallbackImage: NSImage?,
         onApply: @escaping (CardFaceDesign) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.onApply = onApply
        self.onCancel = onCancel
        let start = initialDesign ?? fallbackImage.map { CardFaceDesign(source: $0) }
        _design = State(initialValue: start)
        // Otherwise the first drag on a reopened design jumps back to centre.
        _dragStart = State(initialValue: start?.offset ?? .zero)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(L("designer.hint", "Drag to move the picture, use the slider to size it. What you see is what goes on the card."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            canvas

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(L("ui.zoom", "Zoom"))
                        .frame(width: 96, alignment: .leading)
                    Slider(value: zoomBinding, in: CardFaceDesign.zoomRange)
                        .accessibilityLabel(L("ui.zoom", "Zoom"))
                    Text((design?.zoom ?? 1).formatted(.number.precision(.fractionLength(1))) + "×")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                HStack(spacing: 10) {
                    Text(L("designer.background", "Background"))
                        .frame(width: 96, alignment: .leading)
                    ColorPicker("", selection: backgroundBinding, supportsOpacity: false)
                        .accessibilityLabel(L("designer.background", "Background"))
                        .labelsHidden()
                    Spacer()
                    Button(L("ui.choose_image", "Choose Image...")) { chooseImage() }
                }
            }
            .disabled(design == nil)

            HStack {
                Button(L("ui.cancel", "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("designer.reset", "Reset Framing")) {
                    design?.zoom = 1
                    design?.offset = .zero
                    dragStart = .zero
                }
                .disabled(design == nil)
                Button(L("designer.apply", "Use This Design")) {
                    if let d = design { onApply(d) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(design == nil)
            }
        }
        .padding(22)
        .frame(width: 580)
    }

    private func nudge(_ press: KeyPress) -> KeyPress.Result {
        guard design != nil else { return .ignored }
        let step: CGFloat = press.modifiers.contains(.shift) ? 0.05 : 0.01
        switch press.key {
        case .leftArrow: design?.offset.width -= step
        case .rightArrow: design?.offset.width += step
        case .upArrow: design?.offset.height -= step
        case .downArrow: design?.offset.height += step
        default:
            switch press.characters {
            case "+", "=": design?.zoom = min(CardFaceDesign.zoomRange.upperBound, (design?.zoom ?? 1) * 1.1)
            case "-", "_": design?.zoom = max(CardFaceDesign.zoomRange.lowerBound, (design?.zoom ?? 1) / 1.1)
            default: return .ignored
            }
        }
        dragStart = design?.offset ?? .zero
        return .handled
    }

    private var canvas: some View {
        GeometryReader { geo in
            let card = CGSize(width: geo.size.width, height: geo.size.width / CardFaceDesign.aspect)
            let radius = card.width * 0.045
            ZStack {
                if let d = design {
                    d.background
                    let scale = CardFaceDesign.fillScale(image: d.source.size, card: card) * CGFloat(d.zoom)
                    Image(nsImage: d.source)
                        .resizable()
                        .frame(width: d.source.size.width * scale, height: d.source.size.height * scale)
                        .offset(x: d.offset.width * card.width, y: d.offset.height * card.width)
                } else {
                    Color(NSColor.controlBackgroundColor)
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 30))
                        Text(L("designer.empty", "Drop a picture here to start"))
                            .font(.callout)
                        Button(L("ui.choose_image", "Choose Image...")) { chooseImage() }
                    }
                    .foregroundColor(.secondary)
                }
            }
            .frame(width: card.width, height: card.height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                            lineWidth: isTargeted ? 2 : 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard design != nil else { return }
                        design?.offset = CGSize(
                            width: dragStart.width + value.translation.width / card.width,
                            height: dragStart.height + value.translation.height / card.width
                        )
                    }
                    .onEnded { _ in dragStart = design?.offset ?? .zero }
            )
            .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
                load(from: providers)
            }
            // Framing needed a mouse. Arrow keys move the picture (Shift for
            // bigger steps), + and - zoom.
            .focusable()
            .onKeyPress(phases: [.down, .repeat]) { press in nudge(press) }
        }
        .aspectRatio(CardFaceDesign.aspect, contentMode: .fit)
    }

    private var zoomBinding: Binding<Double> {
        Binding(get: { design?.zoom ?? 1 }, set: { design?.zoom = $0 })
    }

    private var backgroundBinding: Binding<Color> {
        Binding(get: { design?.background ?? .black }, set: { design?.background = $0 })
    }

    private func start(with image: NSImage) {
        let background = design?.background ?? .black
        design = CardFaceDesign(source: image, background: background)
        dragStart = .zero
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = L("designer.choose_message", "Choose a picture for this card")
        if panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) {
            start(with: image)
        }
    }

    private func load(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let image = NSImage(contentsOf: url) else { return }
                Task { @MainActor in start(with: image) }
            }
            return true
        }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                Task { @MainActor in start(with: image) }
            }
            return true
        }
        return false
    }
}

// MARK: - Main UI View

// Saved card pictures. A pack, folder, picture or link is imported once, and
// any picture in it can then go on any card. Choosing one opens the designer,
// the same as picking a file does, so framing is never skipped.
struct SkinLibraryView: View {
    @ObservedObject var vm: AppViewModel
    @State private var link = ""
    @State private var isDropTargeted = false
    @State private var hovered: String?

    private var targetIndex: Int? {
        guard let id = vm.skinLibraryCardID else { return nil }
        return vm.cards.firstIndex { $0.id == id }
    }

    // Opened from a card, or with cards selected. Otherwise the library can
    // still take imports, but there is nothing for a picture to go on.
    private var canChoose: Bool {
        targetIndex != nil || (vm.skinLibraryCardID == nil && vm.cards.contains(where: \.isSelected))
    }

    private var subtitle: String {
        if let index = targetIndex {
            return String(format: L("skins.for_card", "Click a picture to use it on Card #%d."), index + 1)
        }
        if canChoose {
            return L("skins.for_selected", "Click a picture to use it on every selected card.")
        }
        return L("skins.for_none", "Pictures you add stay here for next time. To use one, select cards in the list first, then open the library.")
    }

    private var busy: Bool { vm.isImportingSkins || vm.isDownloadingSkins }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("skins.title", "Skin Library"))
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text(subtitle)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button(L("skins.show_in_finder", "Show in Finder")) { vm.revealSkinLibrary() }
                        .buttonStyle(.link)
                }

                HStack(spacing: 8) {
                    // Still open while something runs: a second import waits
                    // its turn rather than being lost.
                    Button(action: pickFiles) {
                        Label(L("skins.import_file", "Import File..."), systemImage: "square.and.arrow.down")
                    }
                    .help(L("skins.import_file_help", "A zip of card pictures, a folder, or one or more pictures"))

                    if canChoose {
                        Button(action: pickOnce) {
                            Label(L("skins.use_once", "Choose a Picture..."), systemImage: "photo")
                        }
                        .help(L("skins.use_once_help", "Use a picture this once, without adding it to the library"))
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    TextField(L("skins.link_placeholder", "Or paste a link to a zip or picture"), text: $link)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(download)
                        .disabled(vm.isDownloadingSkins)
                    if vm.isDownloadingSkins {
                        Button(L("ui.cancel", "Cancel")) { vm.cancelSkinDownload() }
                    } else {
                        Button(L("skins.download", "Download"), action: download)
                            .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if let progress = vm.skinProgress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(progress)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }

                if let note = vm.skinLibraryNote {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if note.isError {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .accessibilityHidden(true)
                        }
                        Text(note.text)
                            .font(.callout)
                            .foregroundColor(note.isError ? .primary : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(20)

            Divider()

            ZStack {
                if vm.skinLibrary.isEmpty {
                    emptyState
                } else {
                    grid
                }
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        )
                        .overlay(
                            Text(L("skins.drop_here", "Drop to add to the library"))
                                .font(.headline)
                                .foregroundColor(.accentColor)
                        )
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)

            Divider()

            HStack {
                Spacer()
                // Escape rather than Return: Return in the link field downloads,
                // and must not also close the sheet.
                Button(L("ui.done", "Done")) { vm.showSkinLibrary = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 500, idealHeight: 620)
        // What happened is said out loud; a line of text at the top of the sheet
        // is easy to miss, and VoiceOver said nothing at all.
        .onChange(of: vm.skinLibraryNote) { _, note in
            guard let note else { return }
            NSAccessibility.post(element: NSApp.keyWindow as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: note.text,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        .onChange(of: vm.skinDownloadSucceeded) { _, _ in link = "" }
        // Coming back from Finder, where "Show in Finder" sends people to add,
        // remove or put back pictures.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vm.loadSkinLibrary()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            Text(L("skins.empty_title", "No pictures yet"))
                .font(.headline)
            Text(L("skins.empty_body", "Import a zip of card pictures, or paste a link to one. You can also drop files or folders here. Everything you add stays in the library, ready for any card."))
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .padding(30)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 14)], spacing: 16) {
                ForEach(vm.skinLibrary) { item in
                    Button { choose(item) } label: {
                        VStack(spacing: 6) {
                            Color.clear
                                .aspectRatio(1536.0 / 969.0, contentMode: .fit)
                                .overlay(SkinThumbnail(url: item.url, version: item.version))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(hovered == item.id && canChoose ? Color.accentColor : Color.secondary.opacity(0.25),
                                                lineWidth: hovered == item.id && canChoose ? 2 : 1)
                                )
                            Text(item.name)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
                    .help(item.name)
                    .accessibilityLabel(item.name)
                    .contextMenu {
                        Button(L("skins.show_in_finder", "Show in Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        }
                        Button(L("skins.move_to_trash", "Move to Trash"), role: .destructive) {
                            vm.removeSkin(item)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func choose(_ item: SkinLibraryItem) {
        guard canChoose else {
            vm.skinLibraryNote = SkinLibraryNote(text: L("skins.select_cards_first", "Select one or more cards in the list first, then open the library again."))
            return
        }
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            vm.skinLibraryNote = SkinLibraryNote(text: L("skins.picture_gone", "That picture is no longer in the library."), isError: true)
            vm.loadSkinLibrary()
            return
        }
        guard let image = NSImage(contentsOf: item.url) else {
            vm.skinLibraryNote = SkinLibraryNote(text: L("error.image_unreadable", "That picture could not be opened. Try a PNG or JPEG."), isError: true)
            return
        }
        vm.chooseSkin(image)
    }

    // The link stays in the field until the download succeeds: most failures
    // say to try it in a browser, and that needs the link.
    private func download() {
        let text = link
        guard !vm.isDownloadingSkins, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        vm.downloadSkins(from: text)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .image, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = L("skins.import_panel", "Choose a zip of card pictures, a folder, or pictures to add to the library.")
        if panel.runModal() == .OK {
            vm.importSkinsAfterConfirming(panel.urls)
        }
    }

    private func pickOnce() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            if let image = NSImage(contentsOf: url) {
                vm.chooseSkin(image)
            } else {
                vm.skinLibraryNote = SkinLibraryNote(text: L("error.image_unreadable", "That picture could not be opened. Try a PNG or JPEG."), isError: true)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            vm.importSkinsAfterConfirming(urls)
        }
        return true
    }
}

// Title and icon when there is room, icon alone when there is not. The title
// still names the button for VoiceOver either way.
struct AdaptiveLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            Label(configuration).labelStyle(.iconOnly)
        } else {
            Label(configuration).labelStyle(.titleAndIcon)
        }
    }
}

struct ContentView: View {
    @ObservedObject var vm: AppViewModel
    @State private var showCredits = false
    // The log was a fixed 90 pt strip, six or seven lines. Drag its top edge to
    // size it; the height is remembered between launches.
    @AppStorage("activityLogHeight") private var logHeight: Double = 180
    @State private var windowHeight: Double = 680
    static let minimumHeight: CGFloat = 540

    // The log's height as shown: what the person dragged it to, but never so
    // tall in a short window that the cards or the Flash button disappear.
    nonisolated static func shownLogHeight(wanted: Double, window: Double) -> Double {
        min(max(wanted, 80), max(80, window * 0.4))
    }
    @State private var logDragStart: Double?
    @State private var dragOffsetStart: CGPoint = .zero
    @State private var dragKeyStartOffsets: [String: CGPoint] = [:]
    @State private var isTargetedPoster = false
    @State private var isTargetedTheme = false
    
    // The keypad target in words: "TelephonyUI-10 · ALL" meant nothing to anyone.
    private var passcodeTargetSummary: String {
        let system: String
        switch vm.targetTelephonyVersion {
        case "TelephonyUI-10": system = "iOS 18+"
        case "TelephonyUI-9": system = "iOS 16–17"
        case "TelephonyUI-8": system = "iOS 14–15"
        default: system = "iOS 14+"
        }
        return [system, vm.passcodeLanguageTarget.title, vm.passcodeBoldTarget.shortTitle].joined(separator: " · ")
    }

    // Says what is really happening; reading originals is not flashing.
    private var busyLabel: String {
        switch vm.busyJob {
        case .readingOriginals: return L("ui.busy_reading_originals", "Reading Originals...")
        case .savingOriginal: return L("ui.busy_saving_original", "Saving Original...")
        case .restoring: return L("ui.busy_restoring", "Restoring...")
        case .flashPasscode: return L("ui.flashing_passcode", "Flashing Passcode...")
        case .flashCards, .none: return L("ui.flashing_cards", "Flashing Cards...")
        }
    }

    private var readyToFlashCount: Int {
        vm.cards.filter { $0.isSelected && $0.customImageURL != nil }.count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. Top Header Bar
            headerView
                .padding(.leading, 78)
                .padding(.trailing, 20)
                .frame(height: 54)
                .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // 2. Control Toolbar (Unified across tabs to prevent resizing/jumping)
            Group {
                if vm.selectedTab == .walletCards {
                    toolbarView
                } else {
                    // Changing or clearing the theme mid-send changed what the
                    // screen said was being sent.
                    passcodeToolbarView
                        .disabled(vm.isFlashing)
                }
            }
            .frame(height: 48)
            .padding(.horizontal, 20)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // 3. Live Scanner Notice Banner (if active)
            if vm.selectedTab == .walletCards && vm.isScanningCards {
                scanningNoticeBanner
                Divider()
            }
            
            // 4. Main Workspace
            if vm.selectedTab == .walletCards {
                ScrollView {
                    if vm.cards.isEmpty {
                        emptyStateView
                            .padding(.top, 40)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 310, maximum: 360), spacing: 20)],
                            spacing: 20
                        ) {
                            ForEach(Array(vm.cards.indices), id: \.self) { idx in
                                // Taken now: a dropped picture arrives after an
                                // async load, by which time the list may have
                                // changed and idx point at another card, or none.
                                let cardID = vm.cards[idx].id
                                WalletCardView(
                                    card: $vm.cards[idx],
                                    cardIndex: idx,
                                    originalImage: vm.originalPreviews[vm.cards[idx].id],
                                    hasBackup: vm.backedUpCards.contains(vm.cards[idx].id),
                                    busy: vm.isFlashing,
                                    connected: vm.device?.connected == true,
                                    onPickImage: {
                                        let id = vm.cards[idx].id
                                        // A card with a skin opens its design to adjust.
                                        // An empty one offers the library once there is
                                        // something in it, and a file picker until then,
                                        // so a first-time user is not shown an empty sheet.
                                        if vm.cards[idx].customImage != nil {
                                            vm.openDesigner(for: id, image: nil)
                                        } else if AppViewModel.skinLibraryHasPictures {
                                            vm.openSkinLibrary(for: id)
                                        } else {
                                            openCardImagePicker(for: id)
                                        }
                                    },
                                    onDropImage: { image in vm.openDesigner(for: cardID, image: image) },
                                    onDropPack: { url in vm.importDroppedPack(url, for: cardID) },
                                    onDropUnreadable: { vm.errorMessage = L("error.image_unreadable", "That picture could not be opened. Try a PNG or JPEG.") },
                                    onClearImage: { vm.clearCardImage(for: vm.cards[idx].id) },
                                    onDesign: { vm.openDesigner(for: vm.cards[idx].id, image: nil) },
                                    onChooseFromLibrary: { vm.openSkinLibrary(for: vm.cards[idx].id) },
                                    onBackup: { vm.backupCard(id: vm.cards[idx].id) },
                                    onRestore: { vm.restoreCard(id: vm.cards[idx].id) },
                                    onDiscardBackup: { vm.discardBackup(id: vm.cards[idx].id) },
                                    onDelete: { vm.deleteCard(id: vm.cards[idx].id) }
                                )
                            }
                        }
                        .padding(20)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                passcodeThemeWorkspaceView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // 5. Collapsible Activity Console (if open or flashing)
            if vm.showLogs {
                Divider()
                activityLogView
            }
            
            Divider()
            
            // 6. Bottom Action & Status Bar
            bottomBarView
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color(NSColor.controlBackgroundColor))
        }
        // 680 was taller than a 13-inch screen at "Larger Text": the Flash
        // button, Cancel and the status line ended up below the screen. Every
        // workspace scrolls instead, and the log takes at most 40%.
        .frame(minWidth: 880, minHeight: ContentView.minimumHeight)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { windowHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { _, height in windowHeight = height }
        })
        .sheet(isPresented: Binding(
            get: { vm.designingCardID != nil || vm.designingAllSelected },
            set: { if !$0 { vm.closeDesigner() } }
        )) {
            if vm.designingAllSelected {
                let targets = vm.cards.filter(\.isSelected).map(\.id)
                CardFaceDesignerView(
                    title: L("designer.title_all", "Design for All Selected Cards"),
                    initialDesign: nil,
                    fallbackImage: vm.designerSeed,
                    onApply: { design in
                        vm.applyCardDesign(design, for: targets)
                        vm.closeDesigner()
                    },
                    onCancel: { vm.closeDesigner() }
                )
            } else if let id = vm.designingCardID,
                      let index = vm.cards.firstIndex(where: { $0.id == id }) {
                CardFaceDesignerView(
                    title: String(format: L("designer.title", "Design Card #%d"), index + 1),
                    // A freshly picked picture starts a new design; otherwise pick
                    // up the card's existing one where it was left.
                    initialDesign: vm.designerSeed == nil ? vm.cards[index].design : nil,
                    fallbackImage: vm.designerSeed ?? vm.cards[index].customImage,
                    onApply: { design in
                        vm.applyCardDesign(design, for: [id])
                        vm.closeDesigner()
                    },
                    onCancel: { vm.closeDesigner() }
                )
            }
        }
        .alert(L("ui.something_went_wrong", "Something went wrong"), isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button(L("ui.ok", "OK")) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .alert(L("ui.sent", "Sent to iPhone"), isPresented: $vm.showSuccessAlert) {
            Button(L("ui.ok", "OK")) {}
        } message: {
            if vm.selectedTab == .passcodeThemes {
                Text(L("ui.passcode_sent", "The passcode theme was sent to your iPhone.\n\nLock the iPhone, or restart it, to see the new keypad."))
            } else {
                Text(L("ui.skins_sent", "The new artwork was sent to your iPhone.\n\nForce-close Wallet, or restart the iPhone, to see it. If a card still looks the same afterwards, its design comes from the card issuer and cannot be changed this way."))
            }
        }
        .sheet(isPresented: $showCredits) {
            creditsSheet
        }
        .sheet(isPresented: $vm.showAddCardSheet) {
            addCardSheet
        }
        .sheet(isPresented: $vm.showSkinLibrary, onDismiss: { vm.skinLibraryClosed() }) {
            SkinLibraryView(vm: vm)
        }
        .onChange(of: vm.selectedTab) { _, newTab in
            if newTab == .passcodeThemes && vm.isScanningCards {
                vm.stopCardScanning()
            }
            if vm.statusText == L("status.double_click_side_button_pass", "Double-click Side button, pass Face ID, then tap your card...") {
                vm.statusText = L("status.ready", "Ready")
            }
        }
    }
    
    // MARK: - Subviews
    
    // Same idea as the toolbar: in a long language at the minimum width the
    // device status was cut to "No iPhone..." while the Credits label kept its
    // full width. Status matters more, so Credits and the tagline give way.
    private var headerView: some View {
        ViewThatFits(in: .horizontal) {
            headerContent(compact: false)
            headerContent(compact: true)
            // Last resort while waiting on Trust: the Check Again button is the
            // way forward and must stay whole, and the status line below says
            // in full what the capsule's words would have said.
            headerContent(compact: true, dense: true)
        }
    }

    private func headerContent(compact: Bool, dense: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "creditcard.circle.fill")
                .font(.system(size: 30))
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("ui.aircard", "AirCard"))
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(Capsule())
                }
                if !compact {
                    Text(L("ui.wallet_cards_passcode_themes", "Wallet Cards & Passcode Themes"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Tab Switcher
            Picker("", selection: $vm.selectedTab) {
                ForEach(AppTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.regular)
            .frame(width: 290)
            
            Spacer()
            
            // Device Status Capsule
            HStack(spacing: 8) {
                Circle()
                    .fill(vm.device?.connected == true ? (vm.deviceWarning ? Color.orange : Color.green) : Color.red)
                    .frame(width: 8, height: 8)
                
                if let dev = vm.device, dev.connected {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(dev.name ?? "iPhone")
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Text(String(format: L("ui.device_subtitle", "%1$@ · iOS %2$@"), dev.product ?? "", dev.version ?? ""))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else if !(dense && vm.awaitingTrust) {
                    Text(vm.awaitingTrust
                         ? L("ui.tap_trust", "Tap Trust on iPhone")
                         : L("ui.no_iphone_usb", "No iPhone (USB)"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }

                if !vm.devices.isEmpty {
                    Menu {
                        ForEach(vm.devices, id: \.udid) { d in
                            Button {
                                if let udid = d.udid { vm.selectDevice(udid) }
                            } label: {
                                let tag = d.connection == "usb" ? "USB"
                                    : (d.connection == "network" ? "Wi-Fi" : "")
                                let label = tag.isEmpty
                                    ? (d.name ?? "iPhone")
                                    : String(format: L("ui.device_with_link", "%1$@ (%2$@)"), d.name ?? "iPhone", tag)
                                if d.udid == vm.device?.udid {
                                    Label(label, systemImage: "checkmark")
                                } else {
                                    Text(label)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                    }
                    .accessibilityLabel(String(format: L("ui.switch_device_help", "Switch device (%d connected)"), vm.devices.count))
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(vm.isCheckingDevice || vm.isScanningCards || vm.isFlashing)
                    .help(String(format: L("ui.switch_device_help", "Switch device (%d connected)"), vm.devices.count))
                }

                // While a phone waits on Trust nothing looks again on its own
                // (see shouldLookForDevice), so the way forward gets words, not
                // just an arrow.
                if vm.awaitingTrust {
                    Button(L("ui.check_again", "Check Again")) { vm.checkDevice() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(vm.isCheckingDevice)
                        .help(L("ui.tap_trust", "Tap Trust on iPhone"))
                } else {
                    Button(action: { vm.checkDevice() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isCheckingDevice)
                    .help(L("ui.refresh_device_connection", "Refresh device connection"))
                    .accessibilityLabel(L("ui.refresh_device_connection", "Refresh device connection"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(height: 32)
            .background(Color(NSColor.windowBackgroundColor))
            .cornerRadius(16)
            
            Button(action: { showCredits = true }) {
                Label(L("ui.credits", "Credits"), systemImage: "heart.fill")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: compact))
                    .foregroundColor(.pink)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help(compact ? L("ui.credits", "Credits") : "")
        }
        .controlSize(.regular)
        .frame(height: 54)
    }
    
    // In the longer languages every label does not fit at the window's minimum
    // width, and SwiftUI cut them mid-word ("Scan Ca...") and broke Select All
    // over three lines. The secondary buttons drop to their icons instead,
    // keeping their names as tooltips and for VoiceOver.
    private var toolbarView: some View {
        ViewThatFits(in: .horizontal) {
            toolbarContent(compact: false)
            toolbarContent(compact: true)
        }
    }

    private func toolbarContent(compact: Bool) -> some View {
        HStack(spacing: 12) {
            // Live Scanner Toggle
            Button(action: { vm.toggleCardScanning() }) {
                HStack(spacing: 6) {
                    if vm.isScanningCards {
                        ProgressView()
                            .scaleEffect(0.65)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "wave.3.forward.circle.fill")
                            .frame(width: 16, height: 16)
                    }
                    Text(vm.isScanningCards ? L("ui.stop_scanning", "Stop Scanning") : L("ui.scan_cards", "Scan Cards"))
                        .fontWeight(.semibold)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.isScanningCards ? .red : .blue)
            .controlSize(.regular)
            .disabled(vm.device?.connected != true || (!vm.isScanningCards && (vm.isFlashing || vm.isCheckingDevice)))
            // An empty tooltip shows nothing, so this only speaks up while greyed out.
            .help(vm.device?.connected == true ? "" : L("ui.scan_needs_iphone", "Connect your iPhone first"))
            
            Button(action: { vm.readAllOriginals() }) {
                Label(L("ui.read_originals", "Read Original Designs"), systemImage: "eye")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: compact))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(vm.device?.connected != true || vm.isFlashing || vm.isScanningCards
                      || !vm.cards.contains { !vm.backedUpCards.contains($0.id) })
            .help(compact
                  ? L("ui.read_originals", "Read Original Designs") + "\n" + L("ui.read_originals_help", "Show each card as it is now, and keep a copy so it can be put back later")
                  : L("ui.read_originals_help", "Show each card as it is now, and keep a copy so it can be put back later"))

            Button(action: { vm.showAddCardSheet = true }) {
                Label(L("ui.add_manually", "Add Manually"), systemImage: "plus")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: compact))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help(compact ? L("ui.add_manually", "Add Manually") : "")
            
            // Also where one picture goes on every selected card, which had a
            // button of its own before the library existed.
            Button(action: { vm.openSkinLibrary(for: nil) }) {
                Label(L("skins.title", "Skin Library"), systemImage: "photo.stack")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: compact))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(vm.isFlashing)
            .help(compact
                  ? L("skins.title", "Skin Library") + "\n" + L("ui.skin_library_help", "Import card pictures from a zip, a folder or a link, and use them on the selected cards")
                  : L("ui.skin_library_help", "Import card pictures from a zip, a folder or a link, and use them on the selected cards"))
            
            Spacer()
            
            if !vm.cards.isEmpty {
                HStack(spacing: 8) {
                    Button(L("ui.select_all", "Select All")) {
                        for idx in vm.cards.indices { vm.cards[idx].isSelected = true }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .lineLimit(1)
                    .fixedSize()
                    
                    Text("·").foregroundColor(.secondary)
                    
                    Button(L("ui.deselect_all", "Deselect All")) {
                        for idx in vm.cards.indices { vm.cards[idx].isSelected = false }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .lineLimit(1)
                    .fixedSize()
                    
                    Text("·").foregroundColor(.secondary)
                    
                    Button(L("ui.clear_all", "Clear All")) {
                        vm.confirmClearAllCards()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundColor(.red)
                }
            }
        }
        .controlSize(.regular)
        .frame(height: 48)
    }
    
    private var scanningNoticeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 20))
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(L("ui.live_scanner_active", "Live Scanner Active"))
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
                Text(L("ui.double_click_side_button_apple", "Double-click Side button (Apple Pay), pass Face ID, then tap your card."))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(L("ui.done", "Done")) {
                vm.stopCardScanning()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.1))
    }
    
    // The first screen a new user sees. It used to open with "click Scan
    // Cards", which is disabled until a phone is connected, and never said to
    // connect one. It now follows where the person actually is.
    private var setupStep: Int {
        if vm.device?.connected != true { return 0 }
        if !vm.isScanningCards { return 1 }
        return 2
    }

    private func setupRow(_ index: Int, _ title: Text, detail: Text? = nil) -> some View {
        let done = index < setupStep
        let current = index == setupStep
        return HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : (current ? Color.accentColor : Color.secondary.opacity(0.25)))
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text("\(index + 1)")
                        .font(.caption.bold())
                        .foregroundColor(current ? .white : .secondary)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                title
                    .foregroundColor(current ? .primary : .secondary)
                    .fontWeight(current ? .semibold : .regular)
                if current, let detail {
                    detail
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(done ? 0.6 : 1)
        // Done, current and waiting are told apart by colour and icon on screen;
        // say it in words for VoiceOver.
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? L("onboard.a11y_done", "Done")
                            : (current ? L("onboard.a11y_current", "Next step") : L("onboard.a11y_waiting", "Not yet")))
    }

    // The one command that fixes this Mac's setup, where it can be copied.
    private func setupProblem(_ failure: AppViewModel.BackendFailure) -> some View {
        let command: String? = {
            switch failure {
            case .xcodeLicence: return "sudo xcodebuild -license accept"
            case .commandLineTools: return "xcode-select --install"
            case .staleDeveloperPath: return "sudo xcode-select --reset"
            case .unknown: return nil
            }
        }()
        return VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(AppViewModel.backendFailureMessage(failure))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            }
            if let command {
                HStack(spacing: 8) {
                    Text(command)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                    Button(L("ui.copy_command", "Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
        }
        .font(.subheadline)
        .frame(maxWidth: 480, alignment: .leading)
        .padding(16)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(12)
    }

    private var emptyStateView: some View {
        VStack(spacing: 18) {
            Image(systemName: "creditcard.viewfinder")
                .font(.system(size: 54))
                .foregroundColor(.accentColor.opacity(0.8))

            Text(L("ui.no_cards_detected_yet", "No Cards Detected Yet"))
                .font(.title3)
                .fontWeight(.bold)

            if let failure = vm.backendFailure {
                setupProblem(failure)
            }

            VStack(alignment: .leading, spacing: 12) {
                setupRow(0, Text(L("onboard.connect", "Connect your iPhone with a cable")),
                         detail: Text(vm.awaitingTrust
                            ? L("onboard.connect_trust_check", "Unlock the iPhone and tap Trust, then click Check Again below.")
                            : L("onboard.connect_detail_unlock", "Unlock your iPhone, and use a cable that carries data. If your Mac asks whether to allow the accessory, click Allow.")))
                setupRow(1, Text(LM("onboard.scan", "Click **Start Scanning** below.")))
                setupRow(2, Text(LM("ui.on_your_iphone_double_click", "On your iPhone, **double-click the Side button** (Apple Pay), authenticate with **Face ID**, and **tap your card**.")))
                setupRow(3, Text(L("ui.your_card_will_be_detected", "Your card will be detected immediately!")))
            }
            .font(.subheadline)
            .frame(maxWidth: 480)
            .padding(20)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)

            HStack(spacing: 12) {
                if vm.device?.connected != true && (vm.awaitingTrust || vm.backendFailure != nil || vm.helperFailed) {
                    // Not looked at again on its own while waiting on Trust (see
                    // shouldLookForDevice), so a spinner here would be a promise
                    // the app is not keeping. Tapping Trust changes nothing on the
                    // Mac's side; this is how the app finds out.
                    Button(action: { vm.checkDevice() }) {
                        HStack(spacing: 6) {
                            if vm.isCheckingDevice {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(L("ui.check_again", "Check Again"))
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(vm.isCheckingDevice)
                } else if vm.device?.connected != true {
                    // The app keeps looking on its own, so there is nothing to
                    // press here; say that it is looking.
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("onboard.looking", "Looking for your iPhone..."))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Button(action: { vm.toggleCardScanning() }) {
                        Label(vm.isScanningCards ? L("ui.stop_scanning", "Stop Scanning") : L("ui.start_scanning", "Start Scanning"),
                              systemImage: vm.isScanningCards ? "stop.circle.fill" : "wave.3.forward.circle.fill")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(vm.isScanningCards ? .red : .accentColor)
                    .controlSize(.regular)
                }

                Button(L("ui.add_hashes_manually", "Add Hashes Manually")) {
                    vm.showAddCardSheet = true
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(40)
    }
    
    // MARK: - Passcode Views
    
    private var passcodeToolbarView: some View {
        HStack(spacing: 12) {
            // Mode Switcher: [Apply .passthm] | [Theme Creator]
            Picker("", selection: $vm.passcodeTabMode) {
                ForEach(PasscodeTabMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.regular)
            .frame(width: 250)
            
            if vm.passcodeTabMode == .applyTheme {
                Button(action: { openPasscodeThemePicker() }) {
                    Label(L("ui.choose_passthm_file", "Choose .passthm File..."), systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.regular)
            } else {
                Button(action: { openPosterPicker() }) {
                    Label(vm.creatorPosterImage == nil ? L("ui.choose_poster", "Choose Poster...") : L("ui.change_poster", "Change Poster..."), systemImage: "photo")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.regular)
                
                Button(action: { openSavePasscodeThemePanel() }) {
                    Label(L("ui.export_passthm", "Export .passthm..."), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(vm.effectiveCreatorKeys.isEmpty)
            }
            
            Spacer()
            
            // Target Version Picker
            HStack(spacing: 6) {
                Text(L("ui.target", "Target:"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $vm.targetTelephonyVersion) {
                    Text(L("ui.telephonyui_10_ios_18", "TelephonyUI-10 (iOS 18+)")).tag("TelephonyUI-10")
                    Text(L("ui.telephonyui_9_ios_16_17", "TelephonyUI-9 (iOS 16–17)")).tag("TelephonyUI-9")
                    Text(L("ui.telephonyui_8_ios_14_15", "TelephonyUI-8 (iOS 14–15)")).tag("TelephonyUI-8")
                    Text(L("ui.universal_all_8_9_10", "Universal (All 8, 9, 10)")).tag("all")
                }
                .pickerStyle(.menu)
                .controlSize(.regular)
                .frame(width: 205)
            }
            
            Text("·")
                .foregroundColor(.secondary)
            
            if vm.passcodeTabMode == .applyTheme {
                Button(L("ui.clear_theme", "Clear Theme")) {
                    vm.loadedPasscodeTheme = nil
                }
                .buttonStyle(.link)
                .font(.caption)
                .foregroundColor(.red)
                .disabled(vm.loadedPasscodeTheme == nil)
            } else {
                Button(L("ui.clear_all", "Clear All")) {
                    vm.clearCreatorMode()
                }
                .buttonStyle(.link)
                .font(.caption)
                .foregroundColor(.red)
                .disabled(vm.effectiveCreatorKeys.isEmpty && vm.creatorPosterImage == nil)
            }
        }
        .controlSize(.regular)
        .frame(height: 48)
    }
    
    // Scrolls, so a short window cuts nothing off the keypad preview.
    private var passcodeThemeWorkspaceView: some View {
        ScrollView(.vertical) {
            Group {
                if vm.passcodeTabMode == .applyTheme {
                    passcodeApplyThemeWorkspaceView
                } else {
                    passcodeThemeCreatorWorkspaceView
                }
            }
        }
    }
    
    // MARK: - Apply Theme Mode
    
    private var passcodeApplyThemeWorkspaceView: some View {
        HStack(alignment: .top, spacing: 20) {
            // Left Column: Controls & Actions (width: 320)
            VStack(alignment: .leading, spacing: 14) {
                applyThemeControlsCard
                targetSettingsCard
                    .disabled(vm.isFlashing)
                Spacer()
            }
            .frame(width: 320)
            
            // Right Column: Authentic iPhone Lock Screen Mockup
            VStack(spacing: 8) {
                HStack {
                    Text(L("ui.lock_screen_keypad_preview", "Lock Screen Keypad Preview"))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Spacer()
                    if vm.loadedPasscodeTheme != nil {
                        Text(L("ui.custom_theme_loaded", "Custom Theme Loaded"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.green)
                    }
                }
                .padding(.horizontal, 6)
                
                phoneMockupContainer {
                    applyThemeDialerCanvas
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .onDrop(of: [UTType.fileURL, UTType.data], isTargeted: nil) { providers in
            if let provider = providers.first {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        Task { @MainActor in
                            vm.inspectPasscodeTheme(url: url)
                        }
                    } else if let url = item as? URL {
                        Task { @MainActor in
                            vm.inspectPasscodeTheme(url: url)
                        }
                    }
                }
                return true
            }
            return false
        }
    }
    
    private var applyThemeControlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("ui.passcode_theme_file", "Passcode Theme File"))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            
            if let theme = vm.loadedPasscodeTheme {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.square.stack.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.purple)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(theme.name)
                                .font(.headline)
                                .fontWeight(.bold)
                            
                            Text(theme.detectedVersion)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.15))
                                .foregroundColor(.purple)
                                .cornerRadius(4)
                        }
                    }
                    
                    Text(String(format: L("ui.theme_assets_ready", "%d artwork assets loaded · Ready to flash to iPhone"), theme.fileCount))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 8) {
                        Button(action: { vm.editLoadedThemeInCreator() }) {
                            Label(L("ui.edit_in_creator", "Edit in Creator"), systemImage: "pencil.and.outline")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .controlSize(.regular)
                        
                        Button(L("ui.change", "Change...")) {
                            openPasscodeThemePicker()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        
                        Button(L("ui.clear", "Clear")) {
                            vm.loadedPasscodeTheme = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.purple)
                    
                    Text(L("ui.drop_passthm_file_here", "Drop .passthm file here"))
                        .font(.caption)
                        .fontWeight(.semibold)
                    
                    Text(L("ui.supports_passthm_passtheme_or_zip", "Supports .passthm, .passtheme, or .zip packages from Cowabunga or Nugget"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                    
                    Button(L("ui.choose_file", "Choose File...")) {
                        openPasscodeThemePicker()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.regular)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isTargetedTheme ? Color.purple : Color.purple.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.4).cornerRadius(12))
                )
                .onDrop(of: [UTType.fileURL, UTType.data], isTargeted: $isTargetedTheme) { providers in
                    if let provider = providers.first {
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                                Task { @MainActor in
                                    vm.inspectPasscodeTheme(url: url)
                                }
                            } else if let url = item as? URL {
                                Task { @MainActor in
                                    vm.inspectPasscodeTheme(url: url)
                                }
                            }
                        }
                        return true
                    }
                    return false
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 1)
        )
    }
    
    private var applyThemeDialerCanvas: some View {
        ZStack {
            ForEach(KeypadLayout.allButtons) { btn in
                let cellX = CGFloat(btn.col) * KeypadLayout.colWidth
                let cellY = CGFloat(btn.row) * KeypadLayout.rowHeight
                let centerX = cellX + KeypadLayout.colWidth / 2.0
                let centerY = cellY + KeypadLayout.rowHeight / 2.0
                
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                    
                    if let img = vm.loadedPasscodeTheme?.keysPreview[btn.digit] {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                            .clipShape(Circle())
                    }
                    
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
                        .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                    
                    VStack(spacing: 1) {
                        Text(btn.digit)
                            .font(.system(size: 28, weight: .light))
                            .foregroundColor(.white)
                        if !btn.letters.isEmpty {
                            Text(btn.letters)
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(1)
                                .foregroundColor(.white.opacity(0.9))
                        }
                    }
                }
                .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                .position(x: centerX, y: centerY)
            }
        }
        .frame(width: KeypadLayout.gridWidth, height: KeypadLayout.gridHeight)
    }
    
    // MARK: - Theme Creator Mode
    
    private var passcodeThemeCreatorWorkspaceView: some View {
        HStack(alignment: .top, spacing: 20) {
            // Left Column: Controls & Actions (width: 320)
            VStack(alignment: .leading, spacing: 14) {
                creatorControlsCard
                targetSettingsCard
                    .disabled(vm.isFlashing)
                Spacer()
            }
            .frame(width: 320)
            
            // Right Column: Authentic iPhone Lock Screen Mockup
            VStack(spacing: 8) {
                HStack {
                    Text(L("ui.interactive_iphone_lock_screen_preview", "Interactive iPhone Lock Screen Preview"))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Spacer()
                    if vm.creatorSubMode == .posterSlice && vm.creatorPosterImage != nil {
                        Text(L("ui.drag_dialer_to_pan_use", "Drag dialer to pan · Use slider to zoom"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                
                phoneMockupContainer {
                    creatorDialerCanvas
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
    
    private var creatorControlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Mode Selector: Poster Slice vs Individual Keys
            Picker("", selection: $vm.creatorSubMode) {
                ForEach(CreatorSubMode.allCases) { subMode in
                    Text(subMode.title).tag(subMode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.regular)
            
            Divider()
            
            if vm.creatorSubMode == .posterSlice {
                // 1. Poster Source Section
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("ui.poster_artwork", "Poster Artwork"))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    if let poster = vm.creatorPosterImage {
                        HStack(spacing: 12) {
                            Image(nsImage: poster)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 50, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.purple.opacity(0.4), lineWidth: 1)
                                )
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L("ui.artwork_loaded", "Artwork Loaded"))
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                HStack(spacing: 8) {
                                    Button(L("ui.change", "Change...")) {
                                        openPosterPicker()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    
                                    Button(L("ui.remove", "Remove")) {
                                        vm.removePoster()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 26))
                                .foregroundColor(.purple)
                            
                            Text(L("ui.drop_poster_or_wallpaper_here", "Drop poster or wallpaper here"))
                                .font(.caption)
                                .fontWeight(.medium)
                            
                            Button(L("ui.choose_image", "Choose Image...")) {
                                openPosterPicker()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .controlSize(.regular)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(isTargetedPoster ? Color.purple : Color.purple.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                                .background(Color(NSColor.controlBackgroundColor).opacity(0.4).cornerRadius(10))
                        )
                        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $isTargetedPoster) { providers in
                            handlePosterDrop(providers: providers)
                        }
                    }
                }
                
                Divider()
                
                // 2. Style Section
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("ui.slicing_style", "Slicing Style"))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    Picker("", selection: $vm.creatorMaskToCircles) {
                        Text(L("ui.seamless_poster", "Seamless Poster")).tag(false)
                        Text(L("ui.circle_buttons", "Circle Buttons")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: vm.creatorMaskToCircles) { _, _ in
                        vm.updatePosterSlicing()
                    }
                    
                    Text(vm.creatorMaskToCircles ? L("ui.slice_circle_desc", "Artwork is clipped into individual circular button icons.") : L("ui.slice_seamless_desc", "Seamless artwork spans across dialer keys without circular cuts (Adobe Dog style)."))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Divider()
                
                // 3. Framing & Zoom Section
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L("ui.zoom_framing", "Zoom & Framing"))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Button(L("ui.reset_position", "Reset Position")) {
                            withAnimation(.spring()) {
                                vm.creatorPosterZoom = 1.0
                                vm.creatorPosterOffset = .zero
                                dragOffsetStart = .zero
                                vm.updatePosterSlicing()
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption2)
                        .disabled(vm.creatorPosterImage == nil)
                    }
                    
                    HStack(spacing: 8) {
                        Image(systemName: "minus.magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        
                        Slider(value: $vm.creatorPosterZoom, in: 0.5...3.0, step: 0.05) {
                            Text(L("ui.zoom", "Zoom"))
                        }
                        .onChange(of: vm.creatorPosterZoom) { _, _ in
                            vm.updatePosterSlicing()
                        }
                        .disabled(vm.creatorPosterImage == nil)
                        
                        Image(systemName: "plus.magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        
                        Text(vm.creatorPosterZoom.formatted(.number.precision(.fractionLength(1))) + "×")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .frame(width: 32, alignment: .trailing)
                    }
                    
                    HStack(spacing: 6) {
                        Image(systemName: "hand.draw")
                            .foregroundColor(.secondary)
                            .font(.caption2)
                        Text(L("ui.drag_anywhere_on_the_dialer", "Drag anywhere on the dialer preview to reposition"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                // Individual Keys Mode Controls
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L("ui.individual_keys", "Individual Keys"))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                        if let sel = vm.selectedKeyDigit {
                            Button(String(format: L("ui.deselect_key", "Deselect Key %@"), sel)) {
                                vm.selectedKeyDigit = nil
                            }
                            .buttonStyle(.link)
                            .font(.caption2)
                        }
                    }
                    
                    if let selDigit = vm.selectedKeyDigit, vm.creatorRawIndividualImages[selDigit] != nil || vm.creatorCustomKeys[selDigit] != nil {
                        // Per-key framing controls
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(String(format: L("ui.key_framing", "Key %@ Framing"), selDigit), systemImage: "crop")
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                    .foregroundColor(.purple)
                                Spacer()
                                Button(L("ui.reset", "Reset")) {
                                    withAnimation(.spring()) {
                                        vm.creatorIndividualOffsets[selDigit] = .zero
                                        vm.creatorIndividualZooms[selDigit] = 1.0
                                        dragKeyStartOffsets[selDigit] = .zero
                                        vm.updateIndividualKey(digit: selDigit)
                                    }
                                }
                                .buttonStyle(.link)
                                .font(.caption2)
                            }
                            
                            // Zoom Slider for the selected key
                            let zoomVal = vm.creatorIndividualZooms[selDigit] ?? 1.0
                            HStack(spacing: 8) {
                                Image(systemName: "minus.magnifyingglass")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                
                                Slider(
                                    value: Binding(
                                        get: { vm.creatorIndividualZooms[selDigit] ?? 1.0 },
                                        set: { newVal in
                                            vm.creatorIndividualZooms[selDigit] = newVal
                                            vm.updateIndividualKey(digit: selDigit)
                                        }
                                    ),
                                    in: 0.5...3.0,
                                    step: 0.05
                                )
                                
                                Image(systemName: "plus.magnifyingglass")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                
                                Text(zoomVal.formatted(.number.precision(.fractionLength(1))) + "×")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .frame(width: 32, alignment: .trailing)
                            }
                            
                            HStack(spacing: 6) {
                                Image(systemName: "hand.draw")
                                    .foregroundColor(.secondary)
                                    .font(.caption2)
                                Text(String(format: L("ui.drag_key_hint", "Drag Key %@ on dialer preview to reposition"), selDigit))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            HStack(spacing: 8) {
                                Button(L("ui.change_image", "Change Image...")) {
                                    openIndividualKeyPicker(for: selDigit)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                
                                Button(L("ui.remove", "Remove")) {
                                    vm.clearIndividualKey(digit: selDigit)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.top, 2)
                        }
                        .padding(10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.purple.opacity(0.35), lineWidth: 1)
                        )
                        
                        Divider()
                    }
                    
                    Text(L("ui.click_any_key_on_the", "Click any key on the dialer to select it, pan the image, adjust zoom, or drop files."))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                        Text(String(format: L("ui.keys_configured", "%d of 10 keys configured"), vm.creatorCustomKeys.count))
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    
                    HStack(spacing: 8) {
                        if !vm.creatorSlicedKeys.isEmpty {
                            Button(L("ui.fill_from_poster", "Fill from Poster")) {
                                vm.adoptPosterSlicesToIndividualKeys()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        }
                        
                        Button(L("ui.clear_all_keys", "Clear All Keys")) {
                            vm.clearAllIndividualKeys()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(vm.creatorCustomKeys.isEmpty)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 1)
        )
    }
    
    private func scaledPosterDimensions(for poster: NSImage) -> (width: CGFloat, height: CGFloat) {
        let imgAspect = poster.size.width / poster.size.height
        let gridAspect = KeypadLayout.gridWidth / KeypadLayout.gridHeight
        let zoom = CGFloat(max(0.1, vm.creatorPosterZoom))
        if imgAspect > gridAspect {
            let h = KeypadLayout.gridHeight * zoom
            return (width: h * imgAspect, height: h)
        } else {
            let w = KeypadLayout.gridWidth * zoom
            return (width: w, height: w / imgAspect)
        }
    }
    
    private var creatorDialerCanvas: some View {
        ZStack {
            // Layer 1: Background Poster Image (Seamless Poster Mode)
            if vm.creatorSubMode == .posterSlice, let poster = vm.creatorPosterImage, !vm.creatorMaskToCircles {
                let dims = scaledPosterDimensions(for: poster)
                Image(nsImage: poster)
                    .resizable()
                    .frame(width: dims.width, height: dims.height)
                    .position(
                        x: KeypadLayout.gridWidth / 2.0 + vm.creatorPosterOffset.x,
                        y: KeypadLayout.gridHeight / 2.0 + vm.creatorPosterOffset.y
                    )
            }
            
            // Layer 2: 10 Buttons laid out in exact cell frames
            ForEach(KeypadLayout.allButtons) { btn in
                let cellX = CGFloat(btn.col) * KeypadLayout.colWidth
                let cellY = CGFloat(btn.row) * KeypadLayout.rowHeight
                let centerX = cellX + KeypadLayout.colWidth / 2.0
                let centerY = cellY + KeypadLayout.rowHeight / 2.0
                
                creatorButtonView(for: btn)
                    .position(x: centerX, y: centerY)
            }
        }
        .frame(width: KeypadLayout.gridWidth, height: KeypadLayout.gridHeight)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if vm.creatorSubMode == .posterSlice && vm.creatorPosterImage != nil {
                        vm.creatorPosterOffset = CGPoint(
                            x: dragOffsetStart.x + value.translation.width,
                            y: dragOffsetStart.y + value.translation.height
                        )
                        vm.updatePosterSlicing()
                    }
                }
                .onEnded { _ in
                    dragOffsetStart = vm.creatorPosterOffset
                }
        )
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: nil) { providers in
            handlePosterDrop(providers: providers)
        }
    }
    
    private func creatorButtonView(for btn: KeypadButtonGeometry) -> some View {
        let customIndividualImage = vm.creatorCustomKeys[btn.digit]
        let slicedImage = vm.creatorSlicedKeys[btn.digit]
        
        return ZStack {
            if vm.creatorSubMode == .posterSlice {
                if vm.creatorMaskToCircles {
                    // Circular Cutouts mode: display sliced circular preview
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                    
                    if let img = slicedImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                            .clipShape(Circle())
                    }
                    
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
                        .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                } else {
                    // Seamless Poster mode: frosted translucent circle indicator
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                    
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                        .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                }
            } else {
                // Individual Keys mode
                let isSelected = (vm.selectedKeyDigit == btn.digit)
                Circle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                
                if let img = customIndividualImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                }
                
                Circle()
                    .stroke(isSelected ? Color.purple : Color.white.opacity(0.3), lineWidth: isSelected ? 2.5 : 1)
                    .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
                    .shadow(color: isSelected ? Color.purple.opacity(0.8) : Color.clear, radius: 4)
            }
            
            // Authentic Digits & Letters Typography
            VStack(spacing: 1) {
                Text(btn.digit)
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.white)
                if !btn.letters.isEmpty {
                    Text(btn.letters)
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1)
                        .foregroundColor(.white.opacity(0.9))
                }
            }
        }
        .frame(width: KeypadLayout.buttonDiameter, height: KeypadLayout.buttonDiameter)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if vm.creatorSubMode == .individualKeys && (vm.creatorRawIndividualImages[btn.digit] != nil || vm.creatorCustomKeys[btn.digit] != nil) {
                        if vm.selectedKeyDigit != btn.digit {
                            vm.selectedKeyDigit = btn.digit
                        }
                        let start = dragKeyStartOffsets[btn.digit] ?? (vm.creatorIndividualOffsets[btn.digit] ?? .zero)
                        vm.creatorIndividualOffsets[btn.digit] = CGPoint(
                            x: start.x + value.translation.width,
                            y: start.y + value.translation.height
                        )
                        vm.updateIndividualKey(digit: btn.digit)
                    }
                }
                .onEnded { _ in
                    if let cur = vm.creatorIndividualOffsets[btn.digit] {
                        dragKeyStartOffsets[btn.digit] = cur
                    }
                }
        )
        .onTapGesture {
            if vm.creatorSubMode == .individualKeys {
                if customIndividualImage == nil && vm.creatorRawIndividualImages[btn.digit] == nil {
                    openIndividualKeyPicker(for: btn.digit)
                } else {
                    vm.selectedKeyDigit = (vm.selectedKeyDigit == btn.digit ? nil : btn.digit)
                }
            }
        }
        .contextMenu {
            if vm.creatorSubMode == .individualKeys {
                Button(String(format: L("ui.change_key", "Change Key %@..."), btn.digit)) {
                    openIndividualKeyPicker(for: btn.digit)
                }
                if customIndividualImage != nil {
                    Button(L("ui.reset_position_zoom", "Reset Position & Zoom")) {
                        vm.creatorIndividualOffsets[btn.digit] = .zero
                        vm.creatorIndividualZooms[btn.digit] = 1.0
                        dragKeyStartOffsets[btn.digit] = .zero
                        vm.updateIndividualKey(digit: btn.digit)
                    }
                    Button(String(format: L("ui.clear_key", "Clear Key %@"), btn.digit)) {
                        vm.clearIndividualKey(digit: btn.digit)
                    }
                }
            }
        }
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: nil) { providers in
            if vm.creatorSubMode == .individualKeys {
                return handleIndividualKeyDrop(digit: btn.digit, providers: providers)
            }
            return false
        }
    }
    
    // MARK: - Authentic Phone Lock Screen Mockup Container
    
    private func phoneMockupContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // Read as one picture: VoiceOver used to read a fake Cancel, Emergency
        // and twenty digits and letters as if they were controls.
        ZStack {
            // Phone Background (Deep Lock Screen Slate / Black)
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.10))
            
            // Subtle frosted gradient
            LinearGradient(
                colors: [Color.white.opacity(0.04), Color.clear, Color.black.opacity(0.3)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
            
            VStack(spacing: 0) {
                // Lock Screen Header (Height ~64)
                VStack(spacing: 4) {
                    Capsule()
                        .fill(Color.black.opacity(0.6))
                        .frame(width: 60, height: 18)
                        .overlay(
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
                        )
                    
                    Text(L("ui.enter_passcode", "Enter Passcode"))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.white.opacity(0.95))
                        .padding(.top, 2)
                    
                    // 6-Dot Indicator
                    HStack(spacing: 10) {
                        ForEach(0..<6, id: \.self) { _ in
                            Circle()
                                .stroke(Color.white.opacity(0.7), lineWidth: 1.5)
                                .frame(width: 9, height: 9)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.top, 12)
                
                Spacer(minLength: 2)
                
                // The Dialer Grid (Exact 305 x 382.67 pt Canvas)
                content()
                    .frame(width: KeypadLayout.gridWidth, height: KeypadLayout.gridHeight)
                
                Spacer(minLength: 2)
                
                // Lock Screen Footer (Height ~28)
                HStack {
                    Text(L("ui.emergency", "Emergency"))
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white.opacity(0.9))
                    Spacer()
                    Text(L("ui.cancel", "Cancel"))
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white.opacity(0.9))
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 326, height: 512)
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 16, x: 0, y: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("ui.lock_screen_keypad_preview", "Lock Screen Keypad Preview"))
    }
    
    // MARK: - Passcode Target Configuration Box
    
    private var targetSettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(.purple)
                    .font(.system(size: 13, weight: .semibold))
                Text(L("ui.flash_language_target", "Flash & Language Target"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Spacer()
                if let dev = vm.device, dev.connected {
                    Button(action: { vm.applyDevicePreferences(from: dev) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                            Text(L("ui.auto_detect", "Auto-detect"))
                        }
                        .font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .help(L("ui.reset_to_iphone_s_detected", "Reset to iPhone's detected language and font style"))
                }
            }
            
            // 1. Language Target Selector
            VStack(alignment: .leading, spacing: 4) {
                Text(L("ui.system_language", "System Language:"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                
                Picker("", selection: $vm.passcodeLanguageTarget) {
                    ForEach(PasscodeLanguageTarget.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            
            // 2. Bold / Font Weight Selector
            VStack(alignment: .leading, spacing: 4) {
                Text(L("ui.font_weight_style", "Font Weight / Style:"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                
                Picker("", selection: $vm.passcodeBoldTarget) {
                    ForEach(PasscodeBoldTarget.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            
            // Helpful Speed / Info Hint
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: vm.passcodeLanguageTarget == .all && vm.passcodeBoldTarget == .both ? "globe" : "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundColor(vm.passcodeLanguageTarget == .all && vm.passcodeBoldTarget == .both ? .secondary : .orange)
                    .padding(.top, 1)
                
                if vm.passcodeLanguageTarget == .all && vm.passcodeBoldTarget == .both {
                    Text(L("ui.universal_mode_flashes_600_files", "Universal mode flashes ~600 files for all languages & Bold text. Selecting a specific language (e.g. Ukrainian) speeds up flashing dramatically."))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(String(format: L("ui.fast_mode_selected", "Fast mode selected: only targets %1$@ with %2$@."), vm.passcodeLanguageTarget.title, vm.passcodeBoldTarget.title))
                        .font(.system(size: 9))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.purple.opacity(0.3), lineWidth: 1))
    }
    
    private var activityLogView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Grab strip along the top edge. Dragging up makes the log taller.
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 36, height: 4)
                .clipShape(Capsule())
                .frame(maxWidth: .infinity)
                .frame(height: 10)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let start = logDragStart ?? logHeight
                            if logDragStart == nil { logDragStart = start }
                            logHeight = min(max(start - value.translation.height, 80), 520)
                        }
                        .onEnded { _ in logDragStart = nil }
                )
                .help(L("ui.log_resize_help", "Drag to resize the log"))

            HStack {
                Text(L("ui.activity_log", "Activity Log"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                // The log stays in English so it can be pasted into an issue;
                // that only helps if it can be copied out in one go.
                Button(L("ui.copy_log", "Copy All")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(vm.logs.joined(separator: "\n"), forType: .string)
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(vm.logs.isEmpty)
                Button(L("ui.clear", "Clear")) {
                    vm.logs.removeAll()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            .padding(.horizontal, 16)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(vm.logs.enumerated()), id: \.offset) { idx, log in
                            Text(log)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
                .frame(height: ContentView.shownLogHeight(wanted: logHeight, window: windowHeight))
                .onChange(of: vm.logs.count) { _, _ in
                    if let last = vm.logs.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }
    
    private var bottomBarView: some View {
        VStack(spacing: 8) {
            if vm.isFlashing || vm.progress > 0 {
                ProgressView(value: vm.progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .animation(.easeInOut(duration: 0.2), value: vm.progress)
            }
            
            HStack(spacing: 16) {
                // Left Status Text
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(vm.statusText)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        if vm.isFlashing || vm.progress > 0 {
                            Text(String(format: L("ui.percent", "%d%%"), Int(min(max(vm.progress, 0.0), 1.0) * 100)))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                    
                    if vm.selectedTab == .passcodeThemes {
                        if vm.passcodeTabMode == .themeCreator {
                            let count = vm.effectiveCreatorKeys.count
                            let targetInfo = passcodeTargetSummary
                            if count > 0 {
                                Text(String(format: L("ui.creator_status", "Theme Creator · %1$d of 10 keys configured · Target: %2$@"), count, targetInfo))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            } else {
                                Text(L("ui.theme_creator_import_a_poster", "Theme Creator · Import a poster or drop icons onto keys"))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        } else if let theme = vm.loadedPasscodeTheme {
                            let targetInfo = passcodeTargetSummary
                            Text(String(format: L("ui.theme_status", "%1$d source assets loaded · Target: %2$@"), theme.fileCount, targetInfo))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        } else {
                            Text(L("ui.no_passthm_loaded_select_a", "No .passthm loaded · Select a theme package to flash"))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    } else if !vm.cards.isEmpty {
                        Text(String(format: L("ui.cards_selected_status", "%1$d of %2$d cards selected · %3$d ready to flash"), vm.cards.filter { $0.isSelected }.count, vm.cards.count, readyToFlashCount))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Toggle Log Drawer
                Button(action: { withAnimation { vm.showLogs.toggle() } }) {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal")
                            .frame(width: 14, height: 14)
                        Text(L("ui.log", "Log"))
                        Image(systemName: vm.showLogs ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                
                // Apply / Flash Button
                if vm.selectedTab == .passcodeThemes {
                    if vm.passcodeTabMode == .themeCreator {
                        Button(action: { vm.flashCreatedTheme() }) {
                            HStack(spacing: 6) {
                                if vm.isFlashing {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "lock.shield.fill")
                                        .frame(width: 16, height: 16)
                                }
                                Text(vm.isFlashing ? busyLabel : L("ui.flash_to_iphone", "Flash to iPhone"))
                                    .fontWeight(.semibold)
                            }
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .controlSize(.regular)
                        .disabled(vm.effectiveCreatorKeys.isEmpty || vm.isFlashing || vm.device?.connected != true)
                    } else {
                        Button(action: { vm.flashPasscodeTheme() }) {
                            HStack(spacing: 6) {
                                if vm.isFlashing {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "lock.shield.fill")
                                        .frame(width: 16, height: 16)
                                }
                                Text(vm.isFlashing ? busyLabel : L("ui.flash_passcode_theme", "Flash Passcode Theme"))
                                    .fontWeight(.semibold)
                            }
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .controlSize(.regular)
                        .disabled(vm.loadedPasscodeTheme == nil || vm.isFlashing || vm.isInspectingTheme || vm.device?.connected != true)
                    }
                } else {
                    Button(action: { vm.applySkin() }) {
                        HStack(spacing: 6) {
                            if vm.isFlashing {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "sparkles")
                                    .frame(width: 16, height: 16)
                            }
                            Text(vm.isFlashing ? busyLabel : (readyToFlashCount > 0 ? String(format: L("ui.flash_skins_count", "Flash Skins (%d)"), readyToFlashCount) : L("ui.flash_skins", "Flash Skins")))
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    // A darker green, so the white label is readable (4.5:1 or
                    // better); system green gave about 2.2:1.
                    .tint(Color(red: 0.10, green: 0.46, blue: 0.20))
                    .controlSize(.regular)
                    .disabled(readyToFlashCount == 0 || vm.isFlashing || vm.device?.connected != true)

                    // A way out, which people did not have: they waited at 10% or
                    // 25% and then quit the app to escape.
                    if vm.isFlashing && vm.canCancelFlash {
                        Button(L("ui.cancel", "Cancel")) { vm.cancelFlash() }
                            .buttonStyle(.bordered)
                            .tint(vm.flashStalled ? .orange : nil)
                            .controlSize(.regular)
                            .help(L("ui.cancel_flash_help", "Stop sending to the iPhone"))
                    }
                }
            }
            
            // Subtle Footer Credits
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Text(L("ui.by", "By"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Link("@mak5er", destination: URL(string: "https://github.com/mak5er")!)
                        .font(.system(size: 10))
                    Text("&")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Link("@Lumid-Off", destination: URL(string: "https://github.com/Lumid-Off")!)
                        .font(.system(size: 10))
                }
            }
        }
    }
    
    // MARK: - Sheets & Pickers
    
    private var creditsSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "creditcard.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
            
            Text(L("ui.aircard", "AirCard"))
                .font(.title2)
                .fontWeight(.bold)
            
            Text(L("ui.apple_wallet_skins_passcode_themes", "Apple Wallet Skins & Passcode Themes for iOS 18+"))
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundColor(.blue)
                    Text(L("ui.developer", "Developer:"))
                        .fontWeight(.medium)
                    Link("@mak5er", destination: URL(string: "https://github.com/mak5er")!)
                    Text("·")
                        .foregroundColor(.secondary)
                    Link(L("ui.twitter_x", "Twitter / X"), destination: URL(string: "https://x.com/mak5er")!)
                }
                
                HStack {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundColor(.blue)
                    Text(L("ui.developer", "Developer:"))
                        .fontWeight(.medium)
                    Link("@Lumid-Off", destination: URL(string: "https://github.com/Lumid-Off")!)
                    Text("·")
                        .foregroundColor(.secondary)
                    Link("Twitter / X", destination: URL(string: "https://x.com/LumidOff")!)
                }
                
                HStack {
                    Image(systemName: "bolt.shield.fill")
                        .foregroundColor(.orange)
                    Text(L("ui.core_exploit", "Core Exploit:"))
                        .fontWeight(.medium)
                    Text(L("ui.airlift_airtraffic_sync_escape", "airlift (AirTraffic sync escape)"))
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(.purple)
                    Text(L("ui.passcode_themes", "Passcode Themes:"))
                        .fontWeight(.medium)
                    Text(L("ui.passthm_standard_cowabunga_nugget", ".passthm standard (Cowabunga / Nugget)"))
                        .foregroundColor(.secondary)
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            
            Divider()
            
            Button(L("ui.close", "Close")) {
                showCredits = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(24)
        .frame(width: 420)
    }
    
    private var addCardSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("ui.add_card_hashes_manually", "Add Card Hashes Manually"))
                .font(.headline)
            Text(L("ui.paste_one_or_more_card", "Paste one or more card hashes (separated by spaces, commas, or newlines):"))
                .font(.caption)
                .foregroundColor(.secondary)
            
            TextEditor(text: $vm.manualHashInput)
                .font(.system(.body, design: .monospaced))
                .frame(height: 120)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            
            HStack {
                Button(L("ui.cancel", "Cancel")) {
                    vm.showAddCardSheet = false
                    vm.manualHashInput = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                
                Spacer()
                
                Button(L("ui.add_to_list", "Add to List")) {
                    // Anything not taken stays in the field to fix, and the
                    // sheet stays open for it; it used to close and wipe it all.
                    let rejected = vm.addCardHash(vm.manualHashInput)
                    vm.manualHashInput = rejected.joined(separator: "\n")
                    if rejected.isEmpty { vm.showAddCardSheet = false }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(vm.manualHashInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 440)
    }
    
    private func openCardImagePicker(for cardId: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(format: L("panel.choose_skin_for_card", "Choose a custom skin for card %@..."), String(cardId.prefix(12)))
        if panel.runModal() == .OK, let url = panel.url {
            if let image = NSImage(contentsOf: url) {
                vm.openDesigner(for: cardId, image: image)
            } else {
                vm.errorMessage = L("error.image_unreadable", "That picture could not be opened. Try a PNG or JPEG.")
            }
        }
    }
    
    private func openPasscodeThemePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "passthm") ?? .data,
            UTType(filenameExtension: "passtheme") ?? .data,
            .zip
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L("panel.choose_passthm", "Choose a .passthm passcode theme package...")
        if panel.runModal() == .OK, let url = panel.url {
            vm.inspectPasscodeTheme(url: url)
        }
    }
    
    private func openPosterPicker() {
        let panel = NSOpenPanel()
        panel.title = L("panel.choose_poster_title", "Choose Poster Image")
        panel.message = L("panel.choose_poster_msg", "Select a wallpaper or photo to slice for the passcode keypad...")
        panel.allowedContentTypes = [
            UTType.png,
            UTType.jpeg,
            UTType(filenameExtension: "heic") ?? .image,
            UTType(filenameExtension: "webp") ?? .image,
            .image
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            vm.setPosterImage(img)
        }
    }
    
    private func openIndividualKeyPicker(for digit: String) {
        let panel = NSOpenPanel()
        panel.title = String(format: L("panel.choose_key_icon_title", "Choose Icon for Key %@"), digit)
        panel.message = String(format: L("panel.choose_key_icon_msg", "Select an icon or image for key %@..."), digit)
        panel.allowedContentTypes = [
            UTType.png,
            UTType.jpeg,
            UTType(filenameExtension: "heic") ?? .image,
            UTType(filenameExtension: "webp") ?? .image,
            .image
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            vm.setIndividualKey(digit: digit, image: img)
        }
    }
    
    private func openSavePasscodeThemePanel() {
        let keys = vm.effectiveCreatorKeys
        guard !keys.isEmpty else {
            vm.errorMessage = L("error.please_configure_at_least_one", "Please configure at least one key before exporting.")
            return
        }
        
        let panel = NSSavePanel()
        panel.title = L("panel.save_theme_title", "Save Passcode Theme")
        panel.prompt = L("panel.export_prompt", "Export")
        panel.nameFieldStringValue = "CustomTheme.passthm"
        panel.allowedContentTypes = [UTType(filenameExtension: "passthm") ?? .data]
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try PasscodeThemeExporter.exportTheme(keys: keys, targetURL: url)
                vm.statusText = String(format: L("status.theme_exported", "Theme exported successfully to %@"), url.lastPathComponent)
                vm.log("Exported .passthm to \(url.path)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                vm.errorMessage = String(format: L("error.theme_export_failed", "Failed to export theme: %@"), error.localizedDescription)
            }
        }
    }
    
    private func handlePosterDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        loadImage(from: provider) { img in
            if let img = img {
                vm.setPosterImage(img)
            }
        }
        return true
    }
    
    private func handleIndividualKeyDrop(digit: String, providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        loadImage(from: provider) { img in
            if let img = img {
                vm.setIndividualKey(digit: digit, image: img)
            }
        }
        return true
    }
    
    private func loadImage(from provider: NSItemProvider, completion: @escaping (NSImage?) -> Void) {
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url, let img = NSImage(contentsOf: url) {
                    DispatchQueue.main.async { completion(img) }
                    return
                }
                if provider.canLoadObject(ofClass: NSImage.self) {
                    _ = provider.loadObject(ofClass: NSImage.self) { img, _ in
                        DispatchQueue.main.async { completion(img as? NSImage) }
                    }
                } else {
                    DispatchQueue.main.async { completion(nil) }
                }
            }
        } else if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { img, _ in
                DispatchQueue.main.async { completion(img as? NSImage) }
            }
        } else {
            completion(nil)
        }
    }
}

// MARK: - App Entry Point

@main
struct AirCardApp: App {
    // One model for the life of the app. Held by each window, as it was, every
    // Cmd+N opened a second copy with its own device watch and its own flash,
    // and closing the window mid-flash threw the progress away.
    @StateObject private var vm = AppViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("AirCard", id: "main") {
            ContentView(vm: vm)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
