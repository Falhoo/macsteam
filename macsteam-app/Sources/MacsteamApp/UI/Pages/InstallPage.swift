// Install page: macSteam's install state and the Install / Uninstall / update-block actions.
// Logic ported from the old InstallViewController.
import AppKit
import NotProtonApp
import GlassUI
import SwiftUI

@MainActor
final class InstallModel: ObservableObject {
    @Published private(set) var symbol = "questionmark"
    @Published private(set) var tint: Color?
    @Published private(set) var headline = ""
    @Published private(set) var detail = ""
    @Published private(set) var installTitle = "Install"
    @Published private(set) var blockTitle = "Block Updates"
    @Published private(set) var canInstall = false
    @Published private(set) var canUninstall = false
    @Published private(set) var canToggleBlock = false
    @Published private(set) var canOpenSteam = false
    @Published private(set) var isBusy = false

    private var bundledDylib: URL? {
        Bundle.main.url(forResource: "macsteam", withExtension: "dylib")
    }

    // MARK: Status

    func refresh() {
        guard !isBusy else { return }
        let status = SteamInstaller.status()
        let blockOn = SteamInstaller.updateBlockEnabled()

        let summary = summarize(status: status, blockOn: blockOn)
        symbol = summary.tone.glassSymbol
        tint = summary.tone.glassTint
        headline = summary.headline
        detail = summary.detail

        switch status {
        case .installed:
            installTitle = "Reinstall"
            canUninstall = true
            canOpenSteam = true
        case .outdated:
            installTitle = "Update"
            canUninstall = true
            canOpenSteam = true
        case .needsOnlineFix:
            installTitle = "Install OnlineFix"
            canUninstall = true
            canOpenSteam = true
        case .notInstalled:
            installTitle = "Install"
            canUninstall = false
            canOpenSteam = true
        case .foreign:
            installTitle = "Install"
            canUninstall = true
            canOpenSteam = true
        case .steamMissing:
            installTitle = "Install"
            canUninstall = false
            canOpenSteam = false
        }

        blockTitle = blockOn ? "Allow Updates" : "Block Updates"
        switch status {
        case .installed, .outdated, .needsOnlineFix: canToggleBlock = true
        default: canToggleBlock = false
        }

        canInstall = bundledDylib != nil && status != .steamMissing
    }

    private func summarize(status: SteamInstaller.Status, blockOn: Bool)
        -> (tone: StatusTone, headline: String, detail: String) {
        switch status {
        case .steamMissing:
            return (.bad, "Steam not found",
                    "Steam isn't in your Applications folder. Install it from Valve, then come back.")
        case .installed:
            return blockOn
                ? (.ok, "Installed", "")
                : (.warn, "Installed, updates allowed",
                   "Steam can update its client. A future update will break macSteam until macSteam is updated to match.")
        case .outdated(let bundled, let deployed):
            return (.warn, "Update available",
                    "A newer dylib is bundled (v\(bundled)). The installed version is v\(deployed). Click Update to apply it.")
        case .needsOnlineFix:
            return (.warn, "OnlineFix needs installing",
                    "macSteam is installed, but this build ships OnlineFix as its own dylib and Steam isn't loading it yet. Click Install OnlineFix.")
        case .notInstalled, .foreign:
            return (.ok, "Ready to install", "Steam is present. Click Install to patch it.")
        }
    }

    // MARK: Actions

    func install() {
        guard let dylib = bundledDylib else { return }
        switch MacCrab.status() {
        case .unsupported(let version):
            promptVersionFix(currentBuild: version, dylib: dylib)
        default:
            // Only OnlineFix is missing: install it without reinstalling NotProton.
            if SteamInstaller.status() == .needsOnlineFix {
                runBusy(verb: "Installing OnlineFix") { _ in
                    try SteamInstaller.install(sourceDylib: dylib)
                }
                return
            }
            runInstall(dylib: dylib, pinFirst: false)
        }
    }

    private func promptVersionFix(currentBuild: String, dylib: URL) {
        let tooOld = Int(currentBuild).flatMap { current in
            Int(MacCrab.supportedVersion).map { current < $0 }
        } ?? false
        let alert = NSAlert()
        alert.alertStyle = .warning
        if tooOld {
            alert.messageText = "Steam version is older than the supported version"
            alert.informativeText = "Your Steam client is on a build of Steam that is older "
                + "than the build that macSteam supports. This installer can upgrade you to the "
                + "latest supported version of Steam, or you can install on your current "
                + "build\u{2026}at your own risk."
            alert.addButton(withTitle: "Update and Install")
        } else {
            alert.messageText = "Steam version is newer than the supported version!"
            alert.informativeText = "Your Steam client is on a build of Steam that is newer "
                + "than the build that macSteam supports! This installer can downgrade you to "
                + "the latest supported version of Steam, or you can install anyway on your "
                + "current build\u{2026}at your own risk."
            alert.addButton(withTitle: "Downgrade and Install")
        }
        alert.addButton(withTitle: "Install Anyway")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn: runInstall(dylib: dylib, pinFirst: true)
        case .alertSecondButtonReturn: runInstall(dylib: dylib, pinFirst: false)
        default: return
        }
    }

    // Combined install: NotProton goes in first (it sets up Steam and the CrossOver tool), then
    // macSteam is added alongside it. Both dylibs end up in Steam's injection list.
    private func runInstall(dylib: URL, pinFirst: Bool) {
        setWorking("Installing NotProton…",
                   detail: "This can take a few minutes. Progress also shows on the NotProton Status page.")
        Task { @MainActor in
            let result = await NotProtonEmbed.installIntoSteam()
            isBusy = false
            guard result.succeeded else {
                refresh()
                if confirm("NotProton couldn't be installed",
                           result.message + "\n\nYou can fix this on the NotProton > Status page and try again, or install macSteam on its own.",
                           confirmTitle: "Install macSteam Only") {
                    installMacSteam(dylib: dylib, pinFirst: pinFirst)
                }
                return
            }
            installMacSteam(dylib: dylib, pinFirst: pinFirst)
        }
    }

    private func installMacSteam(dylib: URL, pinFirst: Bool) {
        runBusy(verb: "Installing macSteam, OnlineFix and CloudRedirect") { progress in
            switch SteamInstaller.status() {
            case .installed, .outdated, .needsOnlineFix:
                try SteamInstaller.install(sourceDylib: dylib)
            default:
                try MacCrab.ensurePristineBundle(progress: progress)
                if pinFirst { try MacCrab.pinToSupported(progress: progress) }
                try SteamInstaller.install(sourceDylib: dylib)
            }
        }
    }

    func uninstall() {
        guard confirm("Uninstall macSteam and NotProton from Steam?",
                      "This downloads a clean, Valve-signed Steam and replaces the installed one, "
                          + "removing macSteam and the NotProton injection completely. Your NotProton "
                          + "prefixes and CrossOver tool stay on disk. Takes a few minutes.",
                      confirmTitle: "Uninstall") else { return }
        runBusy(verb: "Uninstalling") { progress in try MacCrab.uninstallToStock(progress: progress) }
    }

    func toggleUpdateBlock() {
        guard SteamInstaller.updateBlockEnabled() else {
            runBusy { _ in try SteamInstaller.enableUpdateBlock() }
            return
        }
        guard confirm("Allow Steam to update?",
                      "macSteam blocks the Steam client from updating the client itself. If you "
                          + "disable this behavior, a future Steam update will break macSteam until "
                          + "macSteam is updated to match. You have been warned.",
                      confirmTitle: "Continue") else { return }
        runBusy { _ in try SteamInstaller.disableUpdateBlock() }
    }

    func openSteam() {
        NSWorkspace.shared.open(Paths.steamApp)
    }

    // MARK: Busy state

    private func setWorking(_ headline: String, detail: String = "") {
        isBusy = true
        symbol = "arrow.triangle.2.circlepath"
        tint = nil
        self.headline = headline
        self.detail = detail
    }

    private func runBusy(verb: String = "Working",
                         _ work: @escaping @Sendable (@escaping @Sendable (String) -> Void) throws -> Void) {
        setWorking("\(verb)…")
        runInBackground({ [weak self] in
            try work { message in
                Task { @MainActor in self?.detail = message }
            }
        }, completion: { [weak self] _ in
            self?.isBusy = false
            self?.refresh()
        })
    }
}

struct InstallPage: View {
    @ObservedObject var model: InstallModel

    var body: some View {
        HeroPage(symbol: model.symbol, tint: model.tint, title: model.headline,
                 subtitle: model.detail, isBusy: model.isBusy) {
            Button("Open Steam") { model.openSteam() }
                .buttonStyle(.glass)
                .disabled(model.isBusy || !model.canOpenSteam)
            Button(model.blockTitle) { model.toggleUpdateBlock() }
                .buttonStyle(.glass)
                .disabled(model.isBusy || !model.canToggleBlock)
            Button("Uninstall", role: .destructive) { model.uninstall() }
                .buttonStyle(.glass)
                .disabled(model.isBusy || !model.canUninstall)
            Button(model.installTitle) { model.install() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || !model.canInstall)
        }
        .onAppear { model.refresh() }
    }
}
