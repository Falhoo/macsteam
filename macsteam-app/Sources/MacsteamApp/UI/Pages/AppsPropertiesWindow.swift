// Per-game Properties window, opened from the Apps page: the LuaTools game fixes and
// OnlineFix in two tabs, each with install and uninstall. Logic ported from the old
// GamePropertiesWindow.swift; still a window of its own, now with SwiftUI content.
import AppKit
import OnlineFixApp
import GlassUI
import SwiftUI

// MARK: - Window

@MainActor
final class AppsPropertiesWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(appID: Int, gameName: String) {
        let model = AppsPropertiesModel(appID: appID, gameName: gameName)
        let hosting = NSHostingController(rootView: AppsPropertiesView(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Properties — \(gameName)"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 640, height: 540))
        window.contentMinSize = NSSize(width: 560, height: 440)
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - Model

/// Text colour the old window used for status lines.
enum AppsPropertiesTone {
    case secondary, good, warning

    var style: AnyShapeStyle {
        switch self {
        case .secondary: AnyShapeStyle(.secondary)
        case .good: AnyShapeStyle(.green)
        case .warning: AnyShapeStyle(.orange)
        }
    }
}

/// One LuaTools fix as HubcapStoreFixes reports it.
struct AppsLuaFix: Identifiable {
    let id: String
    let title: String
    let description: String
    let includesOnlineFix: Bool
    let drifted: Bool
    let hasManifest: Bool
    let hasFix: Bool
    let applied: Bool

    init(_ fix: [String: Any], index: Int) {
        let fixID = fix["id"] as? String ?? ""
        id = fixID.isEmpty ? "#\(index)" : fixID
        title = fix["title"] as? String ?? "Fix"
        description = fix["description"] as? String ?? ""
        includesOnlineFix = fix["onlineFix"] as? Bool == true
        drifted = fix["drifted"] as? Bool ?? false
        hasManifest = fix["hasManifest"] as? Bool ?? false
        hasFix = fix["hasFix"] as? Bool ?? false
        applied = fix["applied"] as? Bool ?? false
        fixIDForActions = fixID
    }

    /// The id sent back to HubcapStoreFixes (may be empty, as before).
    let fixIDForActions: String
}

@MainActor
final class AppsPropertiesModel: ObservableObject {
    enum Tab: Hashable { case luaTools, onlineFix }

    let appID: Int
    let gameName: String
    private let luaFixes = HubcapStoreFixes()

    // LuaTools fixes first, OnlineFix second.
    @Published var tab: Tab = .luaTools

    // OnlineFix tab
    @Published private(set) var onlineState = ""
    @Published private(set) var onlineStateTone: AppsPropertiesTone = .secondary
    @Published private(set) var onlineMessage = ""
    @Published private(set) var onlineMessageTone: AppsPropertiesTone = .secondary
    @Published private(set) var onlineRecommendation: String?
    @Published private(set) var onlineInstallTitle = "Install OnlineFix"
    @Published private(set) var canInstallOnlineFix = false
    @Published private(set) var canUninstallOnlineFix = false
    @Published private(set) var onlineBusy = false

    // LuaTools tab
    @Published private(set) var luaState = ""
    @Published private(set) var luaStateTone: AppsPropertiesTone = .secondary
    @Published private(set) var luaMessage = ""
    @Published private(set) var luaMessageTone: AppsPropertiesTone = .secondary
    @Published private(set) var fixes: [AppsLuaFix] = []
    @Published private(set) var gameInstalled = false
    @Published private(set) var manifestInstalled = false
    @Published private(set) var luaBusy = false

    init(appID: Int, gameName: String) {
        self.appID = appID
        self.gameName = gameName
        refreshOnlineFix()
        refreshLuaFixes()
    }

    // MARK: OnlineFix

    func refreshOnlineFix() {
        let status = OnlineFixEmbed.storeStatus(appID: appID)
        var text: String
        if status.fixInstalled {
            text = "OnlineFix is installed."
        } else if status.inList {
            text = "In My Games, but its fix is not installed."
        } else {
            text = "Not in My Games yet. Installing adds it."
        }
        if !status.gameInstalled {
            text += " The game folder was not found — install the game in Steam first."
        }
        if let issue = status.photonIssue {
            text += " " + issue
        }
        onlineState = text
        onlineStateTone = status.fixInstalled ? .good : (status.gameInstalled ? .secondary : .warning)
        // A fix whose Photon chain never loads still counts as installed, but the game
        // fails with CustomAuthenticationError, so say it here rather than in game.
        if status.photonIssue != nil {
            onlineStateTone = .warning
        }
        onlineInstallTitle = status.fixInstalled ? "Reinstall OnlineFix" : "Install OnlineFix"
        canInstallOnlineFix = status.gameInstalled
        canUninstallOnlineFix = status.fixInstalled
    }

    func installOnlineFix() {
        startOnlineFixInstall(confirmed: false)
    }

    private func startOnlineFixInstall(confirmed: Bool) {
        guard !onlineBusy else { return }
        onlineBusy = true
        onlineMessageTone = .secondary
        onlineMessage = "Starting…"
        refreshOnlineFix()
        let name = gameName
        let appID = appID
        Task { @MainActor [weak self] in
            let outcome = await OnlineFixEmbed.storeInstall(
                appID: appID, name: name, confirmed: confirmed) { [weak self] text in
                Task { @MainActor in self?.onlineMessage = text }
            }
            guard let self else { return }
            self.onlineBusy = false
            // The fix may not work: ask before downloading it.
            if let confirmation = outcome.confirmation {
                self.askToInstallAnyway(confirmation: confirmation, name: name)
                return
            }
            self.onlineMessageTone = outcome.error == nil ? .good : .warning
            self.onlineMessage = outcome.message ?? outcome.error ?? ""
            self.refreshOnlineFix()
        }
    }

    /// Says what may go wrong and installs only if the player still wants it.
    private func askToInstallAnyway(confirmation: String, name: String) {
        if confirm("OnlineFix may not work for \(name)", confirmation, confirmTitle: "Install anyway") {
            startOnlineFixInstall(confirmed: true)
        } else {
            refreshOnlineFix()
        }
    }

    func uninstallOnlineFix() {
        let outcome = OnlineFixEmbed.storeUninstall(appID: appID)
        onlineMessageTone = outcome.error == nil ? .good : .warning
        onlineMessage = outcome.message ?? outcome.error ?? ""
        refreshOnlineFix()
    }

    func openInManager() {
        OnlineFixEmbed.prepareGame(appID: appID, name: gameName)
        NotificationCenter.default.post(
            name: OnlineFixHandoff.notification, object: nil,
            userInfo: [OnlineFixHandoff.appIDKey: appID])
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: LuaTools fixes

    func refreshLuaFixes() {
        guard !luaBusy else { return }
        luaBusy = true
        luaStateTone = .secondary
        luaState = "Loading…"
        let appID = appID
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reply = await self.luaFixes.list(appID: appID)
            self.luaBusy = false
            self.renderLua(reply)
        }
    }

    private func renderLua(_ reply: [String: Any]) {
        fixes = []
        if let error = reply["error"] as? String {
            luaStateTone = .warning
            luaState = error
            return
        }
        // A LuaTools fix patches the game's Windows DLLs; Steam runs the native Mac
        // build when it has one, so the fix has nothing to patch.
        if reply["nativeMac"] as? Bool == true {
            luaStateTone = .secondary
            luaState = "No LuaTools fixes: Steam has a native macOS build of this "
                + "game, so LuaTools' Windows fixes do not apply."
            updateOnlineRecommendation([])
            return
        }
        gameInstalled = reply["gameInstalled"] as? Bool ?? false
        manifestInstalled = reply["manifestInstalled"] as? Bool ?? false
        let raw = reply["fixes"] as? [[String: Any]] ?? []
        updateOnlineRecommendation(raw)
        luaStateTone = .secondary
        if raw.isEmpty {
            luaState = "No LuaTools fixes for this game."
            return
        }
        luaState = gameInstalled
            ? "\(raw.count) available"
            : "\(raw.count) available — install the game in Steam first"
        luaStateTone = gameInstalled ? .secondary : .warning
        fixes = raw.enumerated().map { AppsLuaFix($0.element, index: $0.offset) }
    }

    /// LuaTools' own OnlineFix is the same fix, installed and tracked by LuaTools, so
    /// the OnlineFix tab recommends it instead of installing a second copy.
    private func updateOnlineRecommendation(_ fixes: [[String: Any]]) {
        guard let online = fixes.first(where: { $0["onlineFix"] as? Bool == true }) else {
            onlineRecommendation = nil
            return
        }
        let applied = online["applied"] as? Bool ?? false
        onlineRecommendation = "LuaTools has a version of OnlineFix for this game"
            + (applied ? " (installed)" : "") + ". we recommend using that one instead of this "
            + "OnlineFix. It is the same fix, but our OnlineFix isn't always stable/working."
    }

    func installManifest(_ fix: AppsLuaFix) { runLua("fix-manifest", fixID: fix.fixIDForActions) }
    func installFix(_ fix: AppsLuaFix) { runLua("fix-install", fixID: fix.fixIDForActions) }
    func uninstallFix(_ fix: AppsLuaFix) { runLua("fix-undo", fixID: fix.fixIDForActions) }

    private func runLua(_ action: String, fixID: String) {
        guard !luaBusy else { return }
        luaBusy = true
        luaMessageTone = .secondary
        luaMessage = "Working…"
        let appID = appID
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reply = await self.luaFixes.perform(action, appID: appID, fixID: fixID)
            self.luaBusy = false
            if let error = reply["error"] as? String {
                self.luaMessageTone = .warning
                self.luaMessage = error
                return
            }
            self.renderLua(reply)
            self.luaMessageTone = .good
            self.luaMessage = reply["message"] as? String ?? ""
        }
    }
}

// MARK: - View

struct AppsPropertiesView: View {
    @ObservedObject var model: AppsPropertiesModel

    var body: some View {
        VStack(spacing: 16) {
            Picker("Section", selection: $model.tab) {
                Text("LuaTools Fixes").tag(AppsPropertiesModel.Tab.luaTools)
                Text("OnlineFix").tag(AppsPropertiesModel.Tab.onlineFix)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Group {
                switch model.tab {
                case .luaTools: luaTab
                case .onlineFix: onlineTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 440)
        .animation(.snappy, value: model.tab)
    }

    // MARK: LuaTools tab

    private var luaTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("LuaTools fixes for \(model.gameName)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { model.refreshLuaFixes() }
                    .buttonStyle(.glass)
                    .disabled(model.luaBusy)
            }
            HStack(spacing: 8) {
                if model.luaBusy {
                    ProgressView().controlSize(.small)
                }
                Text(model.luaState)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.luaStateTone.style)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                if !model.fixes.isEmpty {
                    GlassCard(cornerRadius: 22) {
                        ForEach(Array(model.fixes.enumerated()), id: \.element.id) { index, fix in
                            if index > 0 { RowDivider() }
                            luaRow(fix)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .scrollContentBackground(.hidden)
            .frame(minHeight: 280)

            if !model.luaMessage.isEmpty {
                Text(model.luaMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(model.luaMessageTone.style)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func luaRow(_ fix: AppsLuaFix) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fix.title).font(.system(size: 12.5, weight: .semibold))
                if !fix.description.isEmpty {
                    Text(fix.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if fix.includesOnlineFix {
                    Text("Includes the OnlineFix — we recommend this one over the OnlineFix tab.")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if fix.drifted {
                    Text("Some files changed since it was installed (a game update?).")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            HStack(spacing: 6) {
                if fix.hasManifest {
                    Button(model.manifestInstalled ? "Manifest installed" : "Install manifest") {
                        model.installManifest(fix)
                    }
                    .buttonStyle(.glass)
                    .disabled(model.manifestInstalled || model.luaBusy)
                }
                if fix.hasFix && (!fix.applied || fix.drifted) {
                    Button(fix.drifted ? "Reinstall fix" : "Install fix") { model.installFix(fix) }
                        .buttonStyle(.glassProminent)
                        .disabled(!model.gameInstalled || model.luaBusy)
                }
                if fix.applied {
                    Button("Uninstall", role: .destructive) { model.uninstallFix(fix) }
                        .buttonStyle(.glass)
                        .disabled(model.luaBusy)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: OnlineFix tab

    private var onlineTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.gameName)
                .font(.system(size: 15, weight: .semibold))
            Text(model.onlineState)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.onlineStateTone.style)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(model.onlineInstallTitle) { model.installOnlineFix() }
                    .buttonStyle(.glassProminent)
                    .disabled(!model.canInstallOnlineFix || model.onlineBusy)
                Button("Uninstall", role: .destructive) { model.uninstallOnlineFix() }
                    .buttonStyle(.glass)
                    .disabled(!model.canUninstallOnlineFix || model.onlineBusy)
                if model.onlineBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Open in OnlineFix Manager…") { model.openInManager() }
                    .buttonStyle(.glass)
            }

            if !model.onlineMessage.isEmpty {
                Text(model.onlineMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(model.onlineMessageTone.style)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let recommendation = model.onlineRecommendation {
                Text(recommendation)
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Install downloads the game's fix from online-fix.me and installs it. "
                + "Uninstall restores the files the fix replaced and deletes the ones it added. "
                + "Routing through AppID 480 is set up automatically.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
