import Sparkle
import SwiftUI

/// Sparkle wrapper. Debug builds never check (no signed feed for them).
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?

    private init() {
        #if DEBUG
        controller = nil
        #else
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }

    var isAvailable: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

struct UpdaterCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Güncellemeleri Denetle…") { Updater.shared.checkForUpdates() }
                .disabled(!Updater.shared.isAvailable)
        }
    }
}
