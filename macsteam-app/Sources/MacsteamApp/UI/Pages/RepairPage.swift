// Repair Steam page: replaces Steam with a clean Valve copy.
// Logic ported from the old RepairViewController.
import AppKit
import GlassUI
import SwiftUI

@MainActor
final class RepairModel: ObservableObject {
    @Published private(set) var symbol = "wrench.and.screwdriver"
    @Published private(set) var tint: Color?
    @Published private(set) var headline = "Repair Steam"
    @Published private(set) var detail = ""
    @Published private(set) var buildLine = ""
    @Published private(set) var steamPresent = false
    @Published private(set) var isBusy = false

    func refresh() {
        guard !isBusy else { return }
        steamPresent = MacCrab.status() != .steamMissing
        if steamPresent {
            symbol = "wrench.and.screwdriver"
            tint = nil
            headline = "Repair Steam"
            detail = ""
            buildLine = currentBuildLine()
        } else {
            symbol = StatusTone.bad.glassSymbol
            tint = StatusTone.bad.glassTint
            headline = "Steam not found"
            detail = "Steam isn't in your Applications folder. Install it from Valve, then come back to repair it."
            buildLine = ""
        }
    }

    private func currentBuildLine() -> String {
        switch MacCrab.status() {
        case .supported, .unsupported:
            if let version = MacCrab.detectedVersion() { return "Current Steam Build: \(version)" }
            return "Current Steam Build: unknown"
        case .unknown:
            return "Current Steam Build: unreadable"
        case .steamMissing:
            return ""
        }
    }

    func repair() {
        guard confirm("Reinstall Steam at the latest build?",
                      "This will remove macSteam and download a clean copy of Steam. This can take a few minutes.",
                      confirmTitle: "Repair", style: .informational) else { return }
        isBusy = true
        setRepairing("Getting ready to repair Steam")
        runInBackground(failureTitle: "Couldn't repair", { [weak self] in
            try MacCrab.repairToStock(progress: { step in
                Task { @MainActor in self?.setRepairing(step) }
            })
        }, completion: { [weak self] succeeded in
            guard let self else { return }
            isBusy = false
            if succeeded { setSucceeded() } else { refresh() }
        })
    }

    func openSteam() {
        NSWorkspace.shared.open(Paths.steamApp)
    }

    private func setRepairing(_ step: String) {
        symbol = "wrench.and.screwdriver"
        tint = nil
        headline = step
        detail = ""
        buildLine = ""
    }

    private func setSucceeded() {
        symbol = StatusTone.ok.glassSymbol
        tint = StatusTone.ok.glassTint
        headline = "Steam repaired"
        detail = "Steam has been restored to an unmodified client. Run Install to patch Steam with macSteam."
        buildLine = ""
        steamPresent = true
    }
}

struct RepairPage: View {
    @ObservedObject var model: RepairModel

    var body: some View {
        HeroPage(symbol: model.symbol, tint: model.tint, title: model.headline,
                 subtitle: model.detail, footnote: model.buildLine, isBusy: model.isBusy) {
            Button("Open Steam") { model.openSteam() }
                .buttonStyle(.glass)
                .disabled(model.isBusy || !model.steamPresent)
            Button("Repair") { model.repair() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || !model.steamPresent)
        }
        .onAppear { model.refresh() }
    }
}
