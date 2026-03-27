import AppKit
import os

private let logger = Logger(subsystem: "dev.finite", category: "UpdateManager")

/// Watches for a Ghostty update marker file and notifies when an update is available.
final class UpdateManager {
    static let shared = UpdateManager()

    var onUpdateAvailable: ((String) -> Void)?
    var onUpdateDismissed: (() -> Void)?

    private var timer: DispatchSourceTimer?
    private let markerPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/finite/update-available.json").path

    /// Once dismissed, updates are suppressed for the rest of this session.
    private var dismissed = false

    struct UpdateMarker: Codable {
        var sha: String
        var oldSha: String
        var date: String

        private enum CodingKeys: String, CodingKey {
            case sha
            case oldSha = "old_sha"
            case date
        }
    }

    func startWatching() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 60)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    func stopWatching() {
        timer?.cancel()
        timer = nil
    }

    private func check() {
        guard !dismissed else { return }
        guard FileManager.default.fileExists(atPath: markerPath),
              let data = FileManager.default.contents(atPath: markerPath),
              let marker = try? JSONDecoder().decode(UpdateMarker.self, from: data) else {
            return
        }
        onUpdateAvailable?(String(marker.sha.prefix(8)))
    }

    func dismiss() {
        dismissed = true
        onUpdateDismissed?()
    }

    func installUpdate() {
        let scriptPath = projectDir().appendingPathComponent("scripts/install-update.sh").path
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
            logger.error("Update script not found at \(scriptPath)")
            return
        }

        // Launch the install script detached, then quit so the app can be replaced
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
        // Ensure PATH includes homebrew for zig/xcodebuild
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + existingPath
        process.environment = env

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch update script: \(error.localizedDescription)")
            return
        }

        // Give the script a moment to start, then quit
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func projectDir() -> URL {
        // Derive from the app bundle by default (works when installed to /Applications).
        // Override with FINITE_PROJECT_DIR env var for development builds.
        if let override = ProcessInfo.processInfo.environment["FINITE_PROJECT_DIR"] {
            return URL(fileURLWithPath: override)
        }
        // App bundle is at <project>/Finite.app, scripts are at <project>/scripts/
        return URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent()
    }
}
