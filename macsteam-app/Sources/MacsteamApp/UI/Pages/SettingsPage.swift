// Settings page: Lua source, LuaTools sign-in, Steam UI toggles and updates.
// Logic ported from the Settings section of ConfigViewController.
import AppKit
import Combine
import GlassUI
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    let store: ConfigStore

    @Published private(set) var provider = LuaProvider.current
    @Published private(set) var hideWhatsNew = false
    @Published private(set) var hideCloudErrors = false
    @Published private(set) var autoCheckForUpdates = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var accountText = "Not signed in"
    @Published private(set) var isSignedIn = false
    @Published private(set) var isAuthBusy = false

    private var subscriptions: Set<AnyCancellable> = []

    init(store: ConfigStore) {
        self.store = store
        NotificationCenter.default.publisher(for: LuaProvider.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.provider = LuaProvider.current }
            .store(in: &subscriptions)
        UpdaterManager.shared.$canCheckForUpdates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] can in self?.canCheckForUpdates = can }
            .store(in: &subscriptions)
        reload()
    }

    /// Re-reads everything; also called when another page changes config.yaml.
    func reload() {
        provider = LuaProvider.current
        hideWhatsNew = store.config.hideWhatsNew
        hideCloudErrors = store.config.hideCloudErrors
        autoCheckForUpdates = UpdaterManager.shared.automaticallyChecksForUpdates
        refreshLuaToolsAuth()
    }

    // MARK: Lua source

    func setProvider(_ provider: LuaProvider) {
        LuaProvider.current = provider   // posts didChange, which updates `provider`
    }

    func toggleLuaToolsSignIn() {
        guard !isAuthBusy else { return }
        isAuthBusy = true
        Task { [weak self] in
            defer {
                self?.isAuthBusy = false
                self?.refreshLuaToolsAuth()
            }
            if await LuaToolsAuth.shared.isSignedIn() {
                await LuaToolsAuth.shared.signOut()
                return
            }
            do {
                _ = try await LuaToolsAuth.shared.signIn()
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                presentAlert("Couldn’t sign in with Discord", error.localizedDescription, style: .warning)
            }
        }
    }

    private func refreshLuaToolsAuth() {
        Task { [weak self] in
            let signedIn = await LuaToolsAuth.shared.isSignedIn()
            let label = await LuaToolsAuth.shared.accountLabel()
            self?.isSignedIn = signedIn
            self?.accountText = label.map { "Signed in as \($0)" } ?? "Not signed in"
        }
    }

    // MARK: Toggles

    func setHideWhatsNew(_ on: Bool) {
        persisting { try store.setHideWhatsNew(on) }
        hideWhatsNew = store.config.hideWhatsNew
    }

    func setHideCloudErrors(_ on: Bool) {
        persisting { try store.setHideCloudErrors(on) }
        hideCloudErrors = store.config.hideCloudErrors
    }

    func setAutoCheckForUpdates(_ on: Bool) {
        UpdaterManager.shared.automaticallyChecksForUpdates = on
        autoCheckForUpdates = UpdaterManager.shared.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        UpdaterManager.shared.checkForUpdates()
    }

    private func persisting(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            NSSound.beep()
            presentAlert("Couldn’t save config", error.localizedDescription, style: .warning)
        }
    }
}

struct SettingsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        PageScroll(maxWidth: 680) {
            PageHeader(title: "Settings")

            GlassSection(title: "Lua Source") {
                GlassRow(
                    title: "Lua source",
                    subtitle: "Where the Steam store button gets Lua and manifests. Applies immediately. Hubcap uses the API key from the Hubcap tab."
                ) {
                    Picker("Lua source", selection: Binding(get: { model.provider },
                                                            set: { model.setProvider($0) })) {
                        ForEach(LuaProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                RowDivider()
                GlassRow(title: "LuaTools / Discord", subtitle: "Required when LuaTools is the Lua source.") {
                    HStack(spacing: 10) {
                        Text(model.accountText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 170, alignment: .trailing)
                        Group {
                            if model.isAuthBusy {
                                Button("Waiting for Discord…") {}
                                    .buttonStyle(.glass)
                                    .disabled(true)
                            } else if model.isSignedIn {
                                Button("Sign Out") { model.toggleLuaToolsSignIn() }
                                    .buttonStyle(.glass)
                            } else {
                                Button("Sign in with Discord") { model.toggleLuaToolsSignIn() }
                                    .buttonStyle(.glassProminent)
                            }
                        }
                        .transition(.blurReplace)
                    }
                    .animation(.snappy, value: model.isSignedIn)
                    .animation(.snappy, value: model.isAuthBusy)
                }
            }

            GlassSection(title: "General") {
                GlassRow(title: "Hide What's New shelf") {
                    Toggle("Hide What's New shelf", isOn: Binding(get: { model.hideWhatsNew },
                                                                  set: { model.setHideWhatsNew($0) }))
                        .labelsHidden()
                }
                RowDivider()
                GlassRow(
                    title: "Hide Steam Cloud errors",
                    subtitle: "Hide error indicators and notifications; skip launch warnings. Cloud sync stays on. Restart Steam to apply."
                ) {
                    Toggle("Hide Steam Cloud errors", isOn: Binding(get: { model.hideCloudErrors },
                                                                    set: { model.setHideCloudErrors($0) }))
                        .labelsHidden()
                }
            }

            GlassSection(title: "Updates") {
                GlassRow(title: "Automatically check for updates") {
                    Toggle("Automatically check for updates",
                           isOn: Binding(get: { model.autoCheckForUpdates },
                                         set: { model.setAutoCheckForUpdates($0) }))
                        .labelsHidden()
                }
                RowDivider()
                GlassRow(title: "Check for Updates") {
                    Button("Check for Updates…") { model.checkForUpdates() }
                        .buttonStyle(.glass)
                        .disabled(!model.canCheckForUpdates)
                }
            }
        }
        .toggleStyle(.switch)
        .onAppear { model.reload() }
    }
}
