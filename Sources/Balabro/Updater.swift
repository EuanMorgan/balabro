import AppKit
import BalabroCore
import BalabroEngine
import Observation
import os

/// Offers a newer release from `UpdateCheck` and swaps the running app for it.
///
/// Restarting mid-run is safe: a run's conversation only moves on a completed turn, so at worst
/// the coach repeats the answer it was writing.
@MainActor
@Observable
final class Updater {
    enum Status: Equatable {
        case none
        case available(AppRelease)
        case installing(AppRelease)
        case failed(AppRelease)
    }

    private(set) var status = Status.none
    @ObservationIgnored private let updates: UpdateCheck
    @ObservationIgnored private let logger = Logger(subsystem: "com.euanmorgan.balabro", category: "update")

    /// nil outside a packaged app, such as under `swift run`, where there's nothing to replace.
    init?() {
        guard Bundle.main.bundleURL.pathExtension == "app", let updates = UpdateCheck.thisApp else { return nil }
        self.updates = updates
    }

    func watch() async {
        await updates.watch(offer)
    }

    func check() async {
        if let release = await updates.newest() { offer(release) }
    }

    private func offer(_ release: AppRelease) {
        if case .installing = status { return }
        status = .available(release)
    }

    /// True when the new version is in place and will open once this process exits.
    func install() async -> Bool {
        guard case .available(let release) = status else { return false }
        status = .installing(release)
        do {
            try await replaceApp(with: release)
            try relaunch()
            return true
        } catch {
            logger.error("Update to \(release.version) failed: \(error)")
            status = .failed(release)
            return false
        }
    }

    private func replaceApp(with release: AppRelease) async throws {
        let (zip, _) = try await URLSession.shared.download(from: release.download)
        let folder = FileManager.default.temporaryDirectory.appending(path: "balabro-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: zip)
        }
        guard await Command.run(URL(filePath: "/usr/bin/ditto"), ["-x", "-k", zip.path, folder.path], timeout: .seconds(60))?.status == 0 else {
            throw UpdateError.unreadableDownload
        }
        let app = folder.appending(path: "Balabro.app")
        guard await isIntact(app, release: release) else { throw UpdateError.unreadableDownload }
        _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: app, options: .usingNewMetadataOnly)
    }

    /// Ad-hoc signing shows the bundle arrived whole, not who built it. That part rests on HTTPS from GitHub.
    private func isIntact(_ app: URL, release: AppRelease) async -> Bool {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version.description else { return false }
        return await Command.run(URL(filePath: "/usr/bin/codesign"), ["--verify", "--strict", app.path], timeout: .seconds(60))?.status == 0
    }

    /// Opening before this process exits would run two coaches at once, so a shell waits for the exit.
    private func relaunch() throws {
        let arguments = CommandLine.arguments.dropFirst().filter { $0 != BalabroApp.updateFlag }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", #"pid="$1"; shift; while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open "$@""#, "sh",
                             String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
            + (arguments.isEmpty ? [] : ["--args"] + arguments)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

private enum UpdateError: Error {
    case unreadableDownload
}
