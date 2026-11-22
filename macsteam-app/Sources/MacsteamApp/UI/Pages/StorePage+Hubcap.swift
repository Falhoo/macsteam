// Store › Hubcap: connection/access key, library browsing 100 games at a time, catalog
// search and installs. Logic ported from the old HubcapViewController; all Hubcap API
// behaviour stays in HubcapClient / HubcapStoreInstaller.
import AppKit
import GlassUI
import SwiftUI

@MainActor
final class HubcapStoreModel: ObservableObject {
    private let store: ConfigStore
    private let onConfigChanged: @MainActor () -> Void
    private let client = HubcapClient()
    private lazy var storeInstaller = HubcapStoreInstaller(client: client, store: store)

    @Published private(set) var query = ""
    @Published private(set) var games: [HubcapGame] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isSearching = false
    @Published private(set) var resultCountText = "Ready to load"
    @Published private(set) var statusText = "Enter your Hubcap API key to load the library."
    @Published private(set) var statusTone: StatusTone = .neutral
    @Published private(set) var empty = StoreEmptyInfo(
        symbol: "books.vertical",
        title: "Browse the Hubcap library",
        message: "Load a page to start browsing.")
    @Published private(set) var installedCount = 0
    @Published private(set) var configuredApps: Set<Int> = []
    @Published private(set) var isConnected = false
    @Published private(set) var connectionTitle = "Not connected"
    @Published private(set) var connectionDetail = "Add an access key to use Hubcap."
    @Published private(set) var totalCount = 0
    @Published private(set) var loadedOffset = 0

    private var allGames: [HubcapGame] = []
    private var searchGeneration = 0
    private var searchTask: Task<Void, Never>?
    private var usageTask: Task<Void, Never>?

    init(store: ConfigStore, onConfigChanged: @escaping @MainActor () -> Void) {
        self.store = store
        self.onConfigChanged = onConfigChanged
    }

    var showsActivity: Bool { isBusy || isSearching }

    var canLoadMore: Bool {
        !isBusy && trimmedQuery.isEmpty && loadedOffset < totalCount
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Lifecycle

    /// The old viewDidAppear (loadView's first status pass included).
    func appear() {
        updateInstalledMetric()
        updateAPIStatus()
        if !isBusy && allGames.isEmpty {
            loadLibrary(reset: true)
        }
    }

    // MARK: Hubcap settings

    func openSettings() {
        guard !isBusy else { return }
        let dialog = HubcapKeyDialog(
            apiKey: HubcapCredentialStore.apiKey,
            openAPIKeys: { [weak self] in self?.openAPIKeys() }
        )

        switch dialog.run() {
        case .connect(let key):
            connectHubcap(rawKey: key)

        case .disconnect:
            do {
                searchTask?.cancel()
                searchGeneration += 1
                isSearching = false
                query = ""
                try HubcapCredentialStore.remove()
                updateAPIStatus()
                allGames.removeAll()
                games.removeAll()
                totalCount = 0
                loadedOffset = 0
                empty = StoreEmptyInfo(
                    symbol: "key",
                    title: "Connect to Hubcap",
                    message: "Add an API key in Hubcap Settings to search the catalog.")
                resultCountText = "Ready to connect"
                setStatus("Hubcap disconnected.", tone: .neutral)
            } catch {
                setStatus("Could not remove the Hubcap API key: \(error.localizedDescription)", tone: .bad)
            }

        case .cancel:
            break
        }
    }

    func openAPIKeys() {
        NSWorkspace.shared.open(HubcapClient.apiKeysURL)
    }

    private func validateHubcapKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(of: #"^smm_[0-9a-f]{96}$"#, options: .regularExpression) != nil else {
            throw HubcapClientError.invalidAPIKey
        }
        return key
    }

    private func connectHubcap(rawKey: String) {
        guard !isBusy else { return }

        let key: String
        do {
            key = try validateHubcapKey(rawKey)
        } catch {
            setStatus(error.localizedDescription, tone: .bad)
            return
        }

        setBusy(true, status: "Validating Hubcap API key…")

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.client.userStats(apiKey: key)
                try HubcapCredentialStore.save(key)

                self.updateAPIStatus()
                self.query = ""
                self.allGames.removeAll()
                self.games.removeAll()
                self.totalCount = 0
                self.loadedOffset = 0

                self.setBusy(false)
                self.loadLibrary(reset: true)
            } catch {
                self.setBusy(false)
                self.setStatus(error.localizedDescription, tone: .bad)
            }
        }
    }

    // MARK: Search

    func updateQuery(_ text: String) {
        guard text != query else { return }
        query = text
        scheduleSearch()
    }

    /// Return in the search field.
    func submitSearch() {
        scheduleSearch()
    }

    func refreshLibrary() {
        guard !isBusy else { return }
        if trimmedQuery.isEmpty {
            searchTask?.cancel()
            searchGeneration += 1
            isSearching = false
            loadLibrary(reset: true)
        } else {
            scheduleSearch(immediate: true)
        }
    }

    func loadMoreLibrary() {
        guard !isBusy, trimmedQuery.isEmpty else { return }
        loadLibrary(reset: false)
    }

    private func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = false

        let query = trimmedQuery

        if query.isEmpty {
            games = deduplicateAndSort(allGames)
            resultCountText = games.isEmpty ? "No games" : "\(games.count) shown"
            empty = StoreEmptyInfo(
                symbol: "books.vertical",
                title: "Browse the Hubcap library",
                message: "Search the full Hubcap catalog by title or App ID.")
            updateCatalogStatus()
            return
        }

        guard query.count >= 3 else {
            games.removeAll()
            resultCountText = "Keep typing…"
            empty = StoreEmptyInfo(
                symbol: "text.magnifyingglass",
                title: "Search needs 3 characters",
                message: "Enter at least 3 characters to search Hubcap by title or App ID.")
            setStatus("Enter at least 3 characters to search Hubcap.", tone: .neutral)
            return
        }

        guard let key = currentKey() else {
            games.removeAll()
            resultCountText = "Hubcap not connected"
            empty = StoreEmptyInfo(
                symbol: "key",
                title: "Connect to Hubcap to search",
                message: "Add a valid API key in Hubcap Settings.")
            return
        }

        resultCountText = "Searching…"
        empty = StoreEmptyInfo(
            symbol: "magnifyingglass",
            title: "Searching Hubcap…",
            message: "Looking across the Hubcap catalog.")
        setStatus("Searching Hubcap for “\(query)”…", tone: .neutral)

        searchTask = Task { [weak self] in
            do {
                if !immediate {
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard let self, !Task.isCancelled else { return }
                await self.performHubcapSearch(query: query, apiKey: key, generation: generation)
            } catch {
                // Cancellation during the debounce interval is expected.
            }
        }
    }

    private func performHubcapSearch(query: String, apiKey: String, generation: Int) async {
        guard generation == searchGeneration, !Task.isCancelled else { return }
        isSearching = true

        do {
            let results = try await client.searchGames(
                query: query,
                apiKey: apiKey,
                appID: query.allSatisfy { $0.isNumber }
            )

            guard !Task.isCancelled,
                  generation == searchGeneration,
                  query == trimmedQuery,
                  HubcapCredentialStore.apiKey == apiKey
            else { return }

            isSearching = false
            games = deduplicateAndSort(results)
            resultCountText = games.isEmpty
                ? "No matches"
                : "\(games.count) result\(games.count == 1 ? "" : "s")"
            empty = StoreEmptyInfo(
                symbol: "magnifyingglass",
                title: "No games found",
                message: "Try another title or App ID.")
            setStatus(
                games.isEmpty
                    ? "No Hubcap games matched “\(query)”."
                    : "Found \(games.count) Hubcap result(s) for “\(query)”.",
                tone: games.isEmpty ? .neutral : .ok
            )
        } catch {
            guard !Task.isCancelled,
                  generation == searchGeneration,
                  query == trimmedQuery,
                  HubcapCredentialStore.apiKey == apiKey
            else { return }

            isSearching = false
            games.removeAll()
            resultCountText = "Search failed"
            empty = StoreEmptyInfo(
                symbol: "exclamationmark.triangle",
                title: "Hubcap search failed",
                message: error.localizedDescription)
            setStatus(error.localizedDescription, tone: .bad)
        }
    }

    // MARK: Library paging

    private func applyLibraryRows() {
        games = deduplicateAndSort(allGames)
        resultCountText = games.isEmpty ? "No games" : "\(games.count) shown"
        empty = StoreEmptyInfo(
            symbol: "books.vertical",
            title: "Browse the Hubcap library",
            message: "Search for a game or scroll through the catalog.")
    }

    private func loadLibrary(reset: Bool) {
        guard !isBusy, let key = currentKey() else { return }

        let offset = reset ? 0 : loadedOffset
        setBusy(true, status: reset ? "Loading first 100 games…" : "Loading 100 more games…")

        Task { [weak self] in
            guard let self else { return }
            do {
                // Keep foreground pagination at 100 items so the first screen stays responsive.
                let page = try await self.client.libraryPage(apiKey: key, limit: 100, offset: offset)

                let merged: [HubcapGame] = reset ? page.games : (self.allGames + page.games)
                self.allGames = self.deduplicateAndSort(merged)
                self.loadedOffset = offset + page.games.count
                self.totalCount = page.totalCount

                self.updateInstalledMetric()
                self.applyLibraryRows()
                self.updateCatalogStatus()
                self.setBusy(false)
            } catch {
                self.setBusy(false)
                self.setStatus(error.localizedDescription, tone: .bad)
            }
        }
    }

    private func updateCatalogStatus() {
        if allGames.isEmpty {
            setStatus("Hubcap returned no games.", tone: .neutral)
            resultCountText = "No games"
        } else if loadedOffset < totalCount {
            setStatus("Showing \(allGames.count) of \(totalCount) games. Load 100 more to continue.",
                      tone: .ok)
            resultCountText = "\(games.count) shown"
        } else {
            setStatus("Showing all \(allGames.count) Hubcap games.", tone: .ok)
            resultCountText = "\(games.count) shown"
        }
    }

    private func deduplicateAndSort(_ input: [HubcapGame]) -> [HubcapGame] {
        var seen = Set<String>()
        return input
            .filter { seen.insert($0.id).inserted }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                if order == .orderedSame {
                    return $0.id.localizedStandardCompare($1.id) == .orderedAscending
                }
                return order == .orderedAscending
            }
    }

    // MARK: Install

    func isInstalled(_ game: HubcapGame) -> Bool {
        guard let appID = game.appID else { return false }
        return configuredApps.contains(appID)
    }

    func canInstall(_ game: HubcapGame) -> Bool {
        !isBusy && game.appID != nil && game.manifestAvailable
    }

    func install(_ game: HubcapGame) {
        guard !isBusy, let appID = game.appID, currentKey() != nil else { return }
        setBusy(true, status: "Adding \(game.name) to Steam…")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.storeInstaller.install(appID: appID)
                self.refreshInstalledState()
                self.onConfigChanged()
                self.setBusy(false)
                self.setStatus("Added \(game.name) to the Steam library. Ready to install.", tone: .ok)
            } catch {
                self.setBusy(false)
                self.setStatus(error.localizedDescription, tone: .bad)
            }
        }
    }

    func refreshInstalledState() {
        updateInstalledMetric()
    }

    private func updateInstalledMetric() {
        configuredApps = Set(store.config.apps)
        installedCount = configuredApps.count
    }

    // MARK: Connection

    private func currentKey() -> String? {
        guard let key = HubcapCredentialStore.apiKey else {
            setStatus("Open Hubcap Settings to add your access key.", tone: .neutral)
            return nil
        }
        do {
            return try validateHubcapKey(key)
        } catch {
            if !isBusy {
                setStatus(error.localizedDescription, tone: .bad)
            }
            return nil
        }
    }

    private func updateAPIStatus() {
        usageTask?.cancel()

        guard let key = HubcapCredentialStore.apiKey else {
            isConnected = false
            connectionTitle = "Not connected"
            connectionDetail = "Add an access key in Settings."
            return
        }

        isConnected = true
        connectionTitle = "Connected"
        connectionDetail = "Hubcap access is ready."

        let hubcapClient = client
        usageTask = Task { [weak self, hubcapClient] in
            do {
                let stats = try await hubcapClient.userStats(apiKey: key)
                guard !Task.isCancelled else { return }
                guard HubcapCredentialStore.apiKey == key else { return }
                self?.connectionTitle = "Connected • \(stats.dailyUsage)/\(stats.dailyLimit)"
            } catch {
                // Keep the connected state visible if daily usage statistics are unavailable.
            }
        }
    }

    // MARK: Status

    func copyStatus() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(statusText, forType: .string)
    }

    private func setBusy(_ busy: Bool, status: String? = nil) {
        if busy {
            searchTask?.cancel()
            searchGeneration += 1
            isSearching = false
        }
        isBusy = busy
        if let status {
            setStatus(status, tone: .neutral)
        }
    }

    private func setStatus(_ text: String, tone: StatusTone) {
        statusText = text
        statusTone = tone
    }
}

// MARK: - View

struct HubcapStoreView: View {
    @ObservedObject var model: HubcapStoreModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                GlassIcon(symbol: "shippingbox.fill", size: 56, tint: .blue)
                    .accessibilityHidden(true)
                PageHeader(
                    title: "Find games in Hubcap",
                    subtitle: "Browse 100 games at a time and install Lua manifests directly into macSteam."
                ) {
                    StoreCountPill(symbol: "checkmark.circle", text: "\(model.installedCount) installed")
                }
            }

            GlassSection(title: "Connection") {
                GlassRow(
                    title: model.connectionTitle,
                    subtitle: model.connectionDetail,
                    status: model.isConnected ? .ok : .inactive
                ) {
                    Button("Settings", systemImage: "gearshape") { model.openSettings() }
                        .buttonStyle(.glass)
                        .disabled(model.isBusy)
                }
                .animation(.smooth, value: model.connectionTitle)
            }

            library

            listPanel

            footer
        }
        .onAppear { model.appear() }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Library")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.resultCountText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.resultCountText)
            }
            .padding(.horizontal, 6)
            HStack(spacing: 10) {
                GlassSearchField(prompt: "Search Hubcap by title or App ID",
                                 text: Binding(get: { model.query }, set: { model.updateQuery($0) }),
                                 onSubmit: { model.submitSearch() })
                    .accessibilityLabel("Search Hubcap games by title or App ID")
                    .disabled(model.isBusy)
                Button("Reload", systemImage: "arrow.clockwise") { model.refreshLibrary() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .help("Reload the first 100 games")
                    .accessibilityLabel("Reload first 100 Hubcap games")
                    .disabled(model.isBusy)
            }
        }
    }

    private var listPanel: some View {
        Group {
            if model.games.isEmpty {
                GlassEmptyState(symbol: model.empty.symbol, title: model.empty.title,
                                message: model.empty.message)
                    .animation(.smooth(duration: 0.25), value: model.empty)
                    .transition(.blurReplace)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.games) { game in
                            row(for: game)
                        }
                    }
                    .padding(12)
                    .animation(.snappy, value: model.games.map(\.id))
                }
                .scrollContentBackground(.hidden)
                .transition(.blurReplace)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 34))
        .animation(.smooth(duration: 0.3), value: model.games.isEmpty)
    }

    private func row(for game: HubcapGame) -> some View {
        StoreGameRow(
            title: game.name,
            subtitle: "App ID \(game.id)  •  \(game.appType?.capitalized ?? "App")",
            art: game.headerImageURL.map(StoreArtSource.remote)
        ) {
            VStack(alignment: .trailing, spacing: 6) {
                Text(game.manifestAvailable ? "Manifest available" : "No manifest")
                    .font(.caption)
                    .foregroundStyle(game.manifestAvailable ? AnyShapeStyle(.secondary)
                                                            : AnyShapeStyle(.tertiary))
                Group {
                    if model.isInstalled(game) {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.green)
                    } else {
                        Button("Install") { model.install(game) }
                            .buttonStyle(.glassProminent)
                            .disabled(!model.canInstall(game))
                            .accessibilityLabel("Install game")
                    }
                }
                .transition(.blurReplace)
            }
            .animation(.snappy, value: model.isInstalled(game))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.showsActivity {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity.combined(with: .scale))
            }
            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(model.statusTone.glassTint.map { AnyShapeStyle($0) }
                                 ?? AnyShapeStyle(.secondary))
                .textSelection(.enabled)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            Button("Copy status", systemImage: "doc.on.doc") { model.copyStatus() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Copy status")
            Spacer(minLength: 12)
            Button("Load 100 More") { model.loadMoreLibrary() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!model.canLoadMore)
        }
        .animation(.smooth(duration: 0.25), value: model.showsActivity)
        .animation(.smooth(duration: 0.25), value: model.statusText)
        .padding(.bottom, 20)
    }
}

// MARK: - Settings dialog

/// The Hubcap "Settings" dialog: an NSAlert with the API key field, a link to get a key,
/// and Connect / Disconnect / Cancel. Ported unchanged from the old view controller.
@MainActor
private final class HubcapKeyDialog: NSObject {
    enum Result {
        case connect(String)
        case disconnect
        case cancel
    }

    private let openAPIKeys: () -> Void
    private let keyField = NSSecureTextField()
    private let alert = NSAlert()
    private var connectButton: NSButton!
    private var disconnectButton: NSButton!
    private var cancelButton: NSButton!
    private var accessoryView: NSView!

    init(apiKey: String?, openAPIKeys: @escaping () -> Void) {
        self.openAPIKeys = openAPIKeys
        super.init()

        alert.alertStyle = .informational
        alert.messageText = "Connect to Hubcap"
        alert.informativeText = "Enter your Hubcap API key to browse and install manifests."

        keyField.stringValue = apiKey ?? ""
        keyField.placeholderString = "Hubcap API key"
        keyField.font = .systemFont(ofSize: 13)
        keyField.controlSize = .large
        keyField.usesSingleLineMode = false
        keyField.maximumNumberOfLines = 0
        keyField.lineBreakMode = .byWordWrapping
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.setAccessibilityLabel("Hubcap API key")

        let getKeyButton = NSButton(title: "Get API key", target: self,
                                    action: #selector(openAPIKeysPressed))
        getKeyButton.translatesAutoresizingMaskIntoConstraints = false

        let helper = NSTextField(labelWithString: "Stored locally by macSteam.")
        helper.font = .systemFont(ofSize: 11)
        helper.textColor = .secondaryLabelColor
        helper.translatesAutoresizingMaskIntoConstraints = false

        accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 128))
        accessoryView.addSubview(keyField)
        accessoryView.addSubview(helper)
        accessoryView.addSubview(getKeyButton)

        NSLayoutConstraint.activate([
            keyField.topAnchor.constraint(equalTo: accessoryView.topAnchor),
            keyField.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
            keyField.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor),
            keyField.heightAnchor.constraint(equalToConstant: 72),

            helper.topAnchor.constraint(equalTo: keyField.bottomAnchor, constant: 8),
            helper.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
            helper.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor),

            getKeyButton.topAnchor.constraint(equalTo: helper.bottomAnchor, constant: 8),
            getKeyButton.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
            getKeyButton.bottomAnchor.constraint(equalTo: accessoryView.bottomAnchor),
        ])

        alert.accessoryView = accessoryView

        // NSAlert places the first-added native button on the trailing edge.
        // Add in reverse visual order to get: Connect | Disconnect | Cancel.
        cancelButton = alert.addButton(withTitle: "Cancel")
        disconnectButton = alert.addButton(withTitle: "Disconnect")
        connectButton = alert.addButton(withTitle: "Connect")

        disconnectButton.isEnabled = apiKey != nil && !(apiKey?.isEmpty ?? true)
        connectButton.keyEquivalent = "\r"
    }

    func run() -> Result {
        alert.window.initialFirstResponder = keyField
        alert.layout()

        // Keep the native NSAlert response buttons exactly as AppKit creates them.
        // Match the multiline API input to the width of their response container.
        var responseContainer: NSView? = connectButton
        while let parent = responseContainer?.superview {
            if parent is NSStackView {
                responseContainer = parent
                break
            }
            responseContainer = parent
        }

        let responseWidth = responseContainer?.bounds.width
            ?? max(connectButton.frame.width,
                   max(disconnectButton.frame.width, cancelButton.frame.width))

        if responseWidth > 0 {
            var frame = accessoryView.frame
            frame.size.width = responseWidth
            accessoryView.frame = frame
            alert.layout()
        }

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .cancel
        case .alertSecondButtonReturn: return .disconnect
        case .alertThirdButtonReturn: return .connect(keyField.stringValue)
        default: return .cancel
        }
    }

    @objc private func openAPIKeysPressed() {
        openAPIKeys()
    }
}
