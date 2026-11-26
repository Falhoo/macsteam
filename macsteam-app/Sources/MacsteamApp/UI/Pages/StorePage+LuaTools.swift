// Store › LuaTools: Steam search plus LuaTools Discord-authenticated Lua/manifest installs.
// Logic ported from the old GamesViewController.
import AppKit
import GlassUI
import SwiftUI

@MainActor
final class LuaToolsStoreModel: ObservableObject {
    private static let defaultEmpty = StoreEmptyInfo(
        symbol: "magnifyingglass",
        title: "Find a game",
        message: "Search Steam for a game, or enter its App ID.")

    private let store: ConfigStore
    private let onConfigChanged: @MainActor () -> Void
    private let client = LuaToolsGamesClient.shared
    private lazy var hubcapInstaller = HubcapStoreInstaller(store: store)

    @Published private(set) var query = ""
    @Published private(set) var games: [LuaToolsSteamGame] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isInstalling = false
    @Published private(set) var installingAppID: Int?
    @Published private(set) var usageRemaining: Int?
    @Published private(set) var usageText = ""
    @Published private(set) var usageIsWarning = false
    @Published private(set) var statusText = "Search Steam to add a game"
    @Published private(set) var statusTone: StatusTone = .neutral
    @Published private(set) var empty = LuaToolsStoreModel.defaultEmpty
    @Published private(set) var configuredApps: Set<Int> = []

    private var searchTask: Task<Void, Never>?
    private var usageTask: Task<Void, Never>?
    private var searchGeneration = 0
    /// Stands in for the old `isViewLoaded` checks.
    private var hasAppeared = false

    init(store: ConfigStore, onConfigChanged: @escaping @MainActor () -> Void) {
        self.store = store
        self.onConfigChanged = onConfigChanged
    }

    var showsActivity: Bool { isLoading || isInstalling }

    // MARK: Lifecycle

    /// The old viewDidAppear.
    func appear() {
        hasAppeared = true
        store.load()
        refreshConfigured()
        if games.isEmpty {
            empty = Self.defaultEmpty
        }
        refreshUsage()
    }

    func reloadFromStore() {
        guard hasAppeared else { return }
        store.load()
        refreshConfigured()
    }

    /// LuaProvider.didChange (the old GamesViewController observer).
    func providerDidChange() {
        guard hasAppeared else { return }
        refreshUsage()
    }

    private func refreshConfigured() {
        configuredApps = Set(store.config.apps)
    }

    // MARK: Rows

    func isConfigured(_ game: LuaToolsSteamGame) -> Bool {
        configuredApps.contains(game.id)
    }

    func isAdding(_ game: LuaToolsSteamGame) -> Bool {
        installingAppID == game.id
    }

    func canAdd(_ game: LuaToolsSteamGame) -> Bool {
        !isConfigured(game) && !isAdding(game) && !isInstalling && (usageRemaining ?? 1) > 0
    }

    // MARK: Search

    func updateQuery(_ text: String) {
        guard text != query else { return }
        query = text
        scheduleSearch(text)
    }

    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            games = []
            empty = Self.defaultEmpty
            // Clearing the field cancels any search in flight; stop its spinner too.
            setBusy(false)
            return
        }
        setBusy(true)
        empty = StoreEmptyInfo(symbol: "magnifyingglass", title: "Searching Steam…", message: nil)
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                let results = try await self.client.search(trimmed)
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                self.games = results
                self.setBusy(false)
                if results.isEmpty {
                    self.empty = StoreEmptyInfo(symbol: "magnifyingglass", title: "No results",
                                                message: "No Steam games matched that search.")
                }
                self.updateStatus()
            } catch {
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                self.setBusy(false)
                self.games = []
                self.empty = StoreEmptyInfo(symbol: "exclamationmark.triangle", title: "Search failed",
                                            message: error.localizedDescription)
                self.updateStatus(error: error.localizedDescription)
            }
        }
    }

    // MARK: Add flow

    func add(_ game: LuaToolsSteamGame) {
        guard !isInstalling else { return }
        if store.config.apps.contains(game.id) { return }
        isInstalling = true
        installingAppID = game.id
        let provider = LuaProvider.current
        setStatus("Checking \(provider.title) sources for \(game.name)…", tone: .neutral)

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isInstalling = false
                self.installingAppID = nil
                self.refreshConfigured()
                self.refreshUsage()
            }
            if provider == .hubcap {
                await self.addViaHubcap(game)
                return
            }
            do {
                let sources = try await self.client.sources(appID: game.id)
                guard let source = self.chooseSource(sources, for: game) else { return }

                if !(await LuaToolsAuth.shared.isSignedIn()) {
                    self.setStatus("Complete Discord sign-in in your browser…", tone: .neutral)
                    _ = try await LuaToolsAuth.shared.signIn()
                    NSApp.activate()
                }

                self.setStatus("Downloading Lua + manifests for \(game.name)…", tone: .neutral)
                let data = try await self.client.downloadManifest(
                    appID: game.id, source: source, gameName: game.name)
                self.setStatus("Installing Lua + manifests for \(game.name)…", tone: .neutral)
                let result = try LuaToolsManifestInstaller.installManifest(
                    data: data, appID: game.id, store: self.store)
                self.onConfigChanged()
                try? await SteamLibraryActivation.refresh(appID: game.id)
                self.setStatus("Added \(result.title)", tone: .ok)
                self.refreshConfigured()
                let manifestText = result.manifestCount == 0
                    ? "The Lua was installed. This source did not include separate depot manifests."
                    : "The Lua and \(result.manifestCount) depot manifest"
                        + (result.manifestCount == 1 ? "" : "s") + " were installed."
                presentAlert(
                    "Added \(result.title)",
                    manifestText + " Open the game's Steam store page and click Install with Steam.",
                    style: .informational)
            } catch {
                self.setStatus(error.localizedDescription, tone: .bad)
                presentAlert("Couldn’t add \(game.name)", error.localizedDescription,
                             style: .warning)
            }
        }
    }

    private func addViaHubcap(_ game: LuaToolsSteamGame) async {
        do {
            setStatus("Downloading Lua + manifests for \(game.name) from Hubcap…", tone: .neutral)
            try await hubcapInstaller.install(appID: game.id, name: game.name)
            onConfigChanged()
            let title = game.name
            setStatus("Added \(title)", tone: .ok)
            refreshConfigured()
            presentAlert("Added \(title)",
                         "Open the game's Steam store page and click Install with Steam.",
                         style: .informational)
        } catch {
            setStatus(error.localizedDescription, tone: .bad)
            presentAlert("Couldn’t add \(game.name)", error.localizedDescription,
                         style: .warning)
        }
    }

    private func chooseSource(_ sources: [String], for game: LuaToolsSteamGame) -> String? {
        guard let first = sources.first else { return nil }
        guard sources.count > 1 else { return first }
        let alert = NSAlert()
        alert.messageText = "Choose a LuaTools source"
        alert.informativeText = "Both sources have manifests for \(game.name)."
        alert.alertStyle = .informational
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26),
                                  pullsDown: false)
        popup.addItems(withTitles: sources)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return popup.titleOfSelectedItem ?? first
    }

    // MARK: Status

    private func setBusy(_ busy: Bool) {
        isLoading = busy
        updateStatus()
    }

    private func updateStatus(error: String? = nil) {
        if let error {
            setStatus(error, tone: .bad)
            return
        }
        if isLoading || isInstalling { return }
        if games.isEmpty {
            setStatus("Search Steam to add a game", tone: .neutral)
        } else {
            setStatus("\(games.count) game\(games.count == 1 ? "" : "s") found", tone: .ok)
        }
    }

    private func setStatus(_ text: String, tone: StatusTone) {
        statusText = text
        statusTone = tone
    }

    private func refreshUsage() {
        usageTask?.cancel()
        if LuaProvider.current == .hubcap {
            usageRemaining = nil
            usageText = "Source: Hubcap"
            usageIsWarning = false
            return
        }
        usageTask = Task { [weak self] in
            guard let self else { return }
            guard await LuaToolsAuth.shared.isSignedIn() else {
                self.usageRemaining = nil
                self.usageText = "Sign in to see limit"
                self.usageIsWarning = false
                return
            }
            self.usageText = "Checking limit…"
            self.usageIsWarning = false
            guard let usage = await self.client.usage() else {
                if !Task.isCancelled {
                    self.usageRemaining = nil
                    self.usageText = "Limit unavailable"
                }
                return
            }
            guard !Task.isCancelled else { return }
            self.usageRemaining = usage.remaining
            if usage.remaining > 0 {
                self.usageText = "\(usage.remaining) game\(usage.remaining == 1 ? "" : "s") left today"
                self.usageIsWarning = false
            } else {
                self.usageText = "Daily limit reached"
                self.usageIsWarning = true
            }
        }
    }
}

struct LuaToolsStoreView: View {
    @ObservedObject var model: LuaToolsStoreModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            GlassSearchField(prompt: "Search Steam by game name or App ID",
                             text: Binding(get: { model.query }, set: { model.updateQuery($0) }),
                             large: true)
                .accessibilityLabel("Search Steam games")

            if model.games.isEmpty {
                GlassEmptyState(symbol: model.empty.symbol, title: model.empty.title,
                                message: model.empty.message)
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.25), value: model.empty)
                    .transition(.blurReplace)
            } else {
                results.transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.3), value: model.games.isEmpty)
        .onAppear { model.appear() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Store")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                StoreStatusLine(text: model.statusText, tone: model.statusTone,
                                isBusy: model.showsActivity)
            }
            Spacer(minLength: 0)
            if !model.usageText.isEmpty {
                StoreCountPill(symbol: "gauge.with.dots.needle.33percent", text: model.usageText,
                               tint: model.usageIsWarning ? .orange : nil)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("LuaTools daily download limit")
                    .accessibilityValue(model.usageText)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.smooth, value: model.usageText.isEmpty)
    }

    private var results: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(model.games) { game in
                    StoreGameRow(title: game.name, subtitle: "App \(String(game.id))",
                                 art: game.image.map(StoreArtSource.steam)) {
                        addControl(for: game)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .animation(.snappy, value: model.games.map(\.id))
        }
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 20, for: .scrollContent)
    }

    @ViewBuilder
    private func addControl(for game: LuaToolsSteamGame) -> some View {
        Group {
            if model.isConfigured(game) {
                Label("Added", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
            } else if model.isAdding(game) {
                Button {} label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Adding…")
                    }
                }
                .buttonStyle(.glass)
                .disabled(true)
            } else {
                Button("Add") { model.add(game) }
                    .buttonStyle(.glassProminent)
                    .disabled(!model.canAdd(game))
                    .accessibilityLabel("Add \(game.name)")
            }
        }
        .transition(.blurReplace)
        .animation(.snappy, value: model.isConfigured(game))
        .animation(.snappy, value: model.isAdding(game))
    }
}
