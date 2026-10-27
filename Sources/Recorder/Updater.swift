import AppKit
import Sparkle

/// Sparkle, with one rule on top: an update installs only while Kagu has nothing to lose (no recording,
/// save, recovery, starting recording or transcript in progress). A background update also waits until
/// Kagu is not the app in front, so it never relaunches under the owner's hands.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static var shared: Updater?

    private unowned let model: Recorder
    private var controller: SPUStandardUpdaterController?
    /// Sparkle's go-ahead for an update that waits, and whether it waits for Kagu to leave the front too.
    private var pending: (install: () -> Void, quietly: Bool)?
    private var timer: Timer?
    /// Test aid: `--feed <url>` reads updates from another appcast.
    private let feed = CommandLine.arguments.firstIndex(of: "--feed").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }

    var updater: SPUUpdater? { controller?.updater }

    init(model: Recorder) {
        self.model = model
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    func check() { controller?.checkForUpdates(nil) }

    private var busy: Bool {
        model.state != .idle || model.isRecovering || model.starting || model.transcriber.isBusy
    }

    private func hold(_ install: @escaping () -> Void, quietly: Bool) {
        pending = (install, quietly)
        log("update: waiting until Kagu is free\(quietly ? " and in the background" : "")")
        if timer == nil {
            let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tryInstall() } }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        tryInstall()
    }

    /// Reads every condition at once, right before installing; then refuses new recordings until Kagu quits
    /// (quitting also waits for a transcript that started meanwhile, see `applicationShouldTerminate`).
    private func tryInstall() {
        guard let pending else { return }
        if pending.quietly, updater?.automaticallyDownloadsUpdates == false {  // turned off meanwhile: it installs at quit only
            drop()
            return
        }
        guard !busy, !(pending.quietly && NSApp.isActive) else { return }
        drop()
        lock()
        pending.install()
    }

    private func drop() {
        pending = nil
        timer?.invalidate()
        timer = nil
    }

    private func lock() {
        model.updating = true
        log("update: installing")
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { feed }
    }

    /// Install and Relaunch, clicked: goes now unless something is in progress.
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        nonisolated(unsafe) let installHandler = installHandler
        return MainActor.assumeIsolated {
            guard busy else {
                lock()
                return false
            }
            hold(installHandler, quietly: false)
            return true
        }
    }

    /// A downloaded background update: Kagu installs it itself once free and not in front, instead of only at quit.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        nonisolated(unsafe) let immediateInstallHandler = immediateInstallHandler
        return MainActor.assumeIsolated {
            hold(immediateInstallHandler, quietly: true)
            return true
        }
    }

    /// The cycle ended in an error (a failed or canceled install), so Kagu stays: recordings may start again.
    /// Without an error the install is under way (a cycle may end before it quits Kagu), so the lock stays.
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let text = error?.localizedDescription
        MainActor.assumeIsolated {
            guard let text, model.updating else { return }
            model.updating = false
            log("update: did not install: \(text)")
        }
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
