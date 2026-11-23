import AppKit
import GlassUI
import SwiftUI

// MARK: - Sidebar model

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case myGames, addGames, installation, logs

    var id: Self { self }

    var title: String {
        switch self {
        case .myGames: return "My Games"
        case .addGames: return "Add Games"
        case .installation: return "Installation"
        case .logs: return "Logs"
        }
    }

    var icon: String {
        switch self {
        case .myGames: return "gamecontroller"
        case .addGames: return "plus.square.on.square"
        case .installation: return "square.and.arrow.down"
        case .logs: return "list.bullet"
        }
    }

    static let library: [SidebarItem] = [.myGames, .addGames]
    static let manage: [SidebarItem] = [.installation, .logs]

    /// Lets the page be chosen at launch (handy for checking layout):
    /// `OFM_SECTION=installation ./OnlineFixManager`
    static var initial: SidebarItem {
        if let raw = ProcessInfo.processInfo.environment["OFM_SECTION"],
           let item = SidebarItem(rawValue: raw) {
            return item
        }
        return .myGames
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $model.section)
                .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            detail(for: model.section ?? .myGames)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh")
                    }
                }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $model.patchTarget) { target in
            PatchSheetView(gameID: target.id)
                .environmentObject(model)
        }
        .onAppear {
            // Debug hook so the sheet can be inspected without clicking:
            // `open --env OFM_PATCH=1 ...`
            guard ProcessInfo.processInfo.environment["OFM_PATCH"] != nil,
                  let id = model.fixGameID ?? model.games.first?.id else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                model.openPatch(id)
            }
        }
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .myGames: MyGamesView()
        case .addGames: AddGamesView()
        case .installation: InstallationView()
        case .logs: LogView()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                HStack(spacing: 7) {
                    Image(systemName: "globe")
                        .font(.system(size: 13, weight: .medium))
                    Text("OnlineFix")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
                .listRowSeparator(.hidden)
                .selectionDisabled()

                Section("Library") {
                    ForEach(SidebarItem.library) { item in
                        Label(item.title, systemImage: item.icon)
                            .tag(item)
                    }
                }
                Section("Manage") {
                    ForEach(SidebarItem.manage) { item in
                        Label(item.title, systemImage: item.icon)
                            .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)

            StatusFooter()
        }
        .safeAreaPadding(.top)
    }
}

struct StatusFooter: View {
    @EnvironmentObject private var model: AppModel

    private var installed: Bool { model.phase.isInstalled }

    private var label: String {
        switch model.phase {
        case .installed: return "Installed"
        case .notInstalled: return "Not installed"
        case .incomplete: return "Needs repair"
        case .broken: return "Needs attention"
        case .unknown: return "Unknown"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider().opacity(0.4)
            HStack(spacing: 6) {
                Circle()
                    .strokeBorder(installed ? Color.green : Color.secondary, lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
            Text("Session AppID 480")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shared bits

/// The large glass search field on Add Games. Like GlassUI's `GlassSearchField`, plus
/// a spinner while Steam is searched, a clear button that resets the search, and
/// focus on appear.
struct SearchField: View {
    @Binding var text: String
    var placeholder: String
    var busy: Bool = false
    var onSubmit: () -> Void = {}
    var onClear: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(focused ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: focused)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(onSubmit)
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            }
            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .glassEffect(.regular.tint(focused ? Color.accentColor.opacity(0.12) : nil).interactive(),
                     in: .capsule)
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(focused ? 0.45 : 0), lineWidth: 1))
        .scaleEffect(focused ? 1.005 : 1)
        .animation(.smooth(duration: 0.25), value: focused)
        .animation(.snappy(duration: 0.2), value: text.isEmpty)
        .animation(.snappy(duration: 0.2), value: busy)
        .onAppear { focused = true }
    }
}

/// GlassUI's `InsetField` look for a password, for use inside a glass card.
struct InsetSecureField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        SecureField(prompt, text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.primary.opacity(focused ? 0.09 : 0.06), in: .capsule)
            .overlay(
                Capsule().strokeBorder(
                    focused ? AnyShapeStyle(Color.accentColor.opacity(0.6)) : AnyShapeStyle(.primary.opacity(0.08)),
                    lineWidth: focused ? 1.2 : 1
                )
            )
            .animation(.smooth(duration: 0.2), value: focused)
    }
}

/// Caption above a group of glass rows, styled like a `GlassSection` title.
private struct GroupTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.7)
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func headerArtURL(for game: ManagedGame) -> URL? {
    if let raw = game.imageURL, let url = URL(string: raw) { return url }
    return SteamCatalog.headerImageURL(for: game.id)
}

// MARK: - Add Games

struct AddGamesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchTask: Task<Void, Never>?

    private var libraryMatches: [LibraryApp] {
        let query = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        return model.library.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let matches = libraryMatches
        let showsEmptyState = model.searchResults.isEmpty && matches.isEmpty && !model.searching

        PageScroll(maxWidth: 820) {
            PageHeader(
                title: "Find your game",
                subtitle: "Search Steam or enter an AppID. The game doesn't need to be installed."
            )

            VStack(alignment: .leading, spacing: 10) {
                SearchField(
                    text: $model.searchQuery,
                    placeholder: "Game name or AppID",
                    busy: model.searching,
                    onSubmit: { model.searchStore() },
                    onClear: { model.clearSearch() }
                )

                if let message = model.searchMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .transition(.blurReplace)
                }
            }
            .animation(.smooth(duration: 0.25), value: model.searchMessage)

            Group {
                if showsEmptyState {
                    GlassEmptyState(
                        symbol: "magnifyingglass",
                        title: "Search for a game",
                        message: "Find a game by name, or add it using its Steam AppID."
                    )
                    .frame(height: 260)
                    .transition(.blurReplace)
                } else {
                    results(matches)
                        .transition(.blurReplace)
                }
            }
            .animation(.smooth(duration: 0.3), value: showsEmptyState)

            GlassSection(
                title: "Add by AppID",
                footer: "If the search does not find it, enter the Steam AppID directly (the name is optional)."
            ) {
                HStack(spacing: 10) {
                    InsetField(prompt: "AppID", text: $model.newAppID)
                        .frame(width: 140)
                    InsetField(prompt: "Name (optional)", text: $model.newName)
                    Button("Add Game") { model.addManualGame() }
                        .buttonStyle(.glassProminent)
                        .disabled(model.busy
                            || model.newAppID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(16)
            }
        }
        .onChange(of: model.searchQuery) { _, newValue in
            scheduleSearch(for: newValue)
        }
        .onDisappear { searchTask?.cancel() }
    }

    private func results(_ matches: [LibraryApp]) -> some View {
        LazyVStack(spacing: 10) {
            if !matches.isEmpty {
                GroupTitle(text: "In your Steam library")
                ForEach(matches.prefix(25)) { app in
                    resultRow(
                        name: app.name,
                        appID: app.id,
                        art: SteamCatalog.headerImageURL(for: app.id),
                        added: model.alreadyAdded(app.id),
                        action: { model.addLibraryGame(app) }
                    )
                    .transition(.blurReplace)
                }
            }
            if !model.searchResults.isEmpty {
                if !matches.isEmpty {
                    GroupTitle(text: "Steam store")
                }
                ForEach(model.searchResults) { result in
                    resultRow(
                        name: result.name,
                        appID: result.id,
                        art: result.imageURL ?? SteamCatalog.headerImageURL(for: result.id),
                        added: model.alreadyAdded(result.id),
                        action: { model.add(result) }
                    )
                    .transition(.blurReplace)
                }
            }
        }
        .animation(.snappy, value: model.searchResults.map(\.id))
        .animation(.snappy, value: matches.map(\.id))
    }

    private func resultRow(name: String, appID: Int, art: URL?, added: Bool,
                           action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            Artwork(url: art, width: 120)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                Text("AppID \(appID)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Group {
                if added {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                } else {
                    Button("Add Game", action: action)
                        .buttonStyle(.glassProminent)
                }
            }
            .transition(.blurReplace)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .hoverLift()
        .animation(.snappy, value: added)
    }

    private func scheduleSearch(for raw: String) {
        searchTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            model.searchResults = []
            model.searchMessage = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            model.searchStore()
        }
    }
}

// MARK: - My Games

struct MyGamesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.games.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.horizontal, 32)
                        .padding(.top, 28)
                    GlassEmptyState(
                        symbol: "gamecontroller",
                        title: "No games yet",
                        message: "Add a game from the Add Games page — search it by name."
                    )
                }
                .transition(.blurReplace)
            } else {
                PageScroll(maxWidth: 860) {
                    header
                    LazyVStack(spacing: 12) {
                        ForEach(model.games) { game in
                            gameRow(game)
                                .transition(.blurReplace)
                        }
                    }
                }
                .transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.3), value: model.games.isEmpty)
        .animation(.snappy, value: model.games.map(\.id))
    }

    private var header: some View {
        PageHeader(
            title: "My Games",
            subtitle: "Games OnlineFix routes on launch. Patches apply per game."
        ) {
            if !model.games.isEmpty {
                Text(model.games.count == 1 ? "1 game" : "\(model.games.count) games")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(model.games.count)))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity)
            }
        }
    }

    private func gameRow(_ game: ManagedGame) -> some View {
        HStack(spacing: 18) {
            Button {
                model.openPatch(game.id)
            } label: {
                HStack(spacing: 18) {
                    Artwork(url: headerArtURL(for: game), width: 160, cornerRadius: 16)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(game.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text("AppID \(game.id)")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(patchSummary(game.patches))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                        fixWarning(game)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Game settings")

            Spacer(minLength: 12)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button("Game settings", systemImage: "slider.horizontal.3") {
                        model.openPatch(game.id)
                    }
                    .help("Game settings")

                    Button("Remove", systemImage: "trash", role: .destructive) {
                        model.removeGame(id: game.id)
                    }
                    .help("Remove")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .hoverLift()
        .contextMenu {
            Button("Game settings…") { model.openPatch(game.id) }
            if model.fixes.contains(where: { $0.id == game.id }) {
                Button("Uninstall OnlineFix", role: .destructive) {
                    model.uninstallFix(appID: game.id)
                }
            }
            Button("Remove from My Games", role: .destructive) {
                model.removeGame(id: game.id)
            }
        }
    }

    @ViewBuilder
    private func fixWarning(_ game: ManagedGame) -> some View {
        if let state = model.fixState(game.id), case .missing = state {
            Label("Fix files are missing or were replaced, reinstall it",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .padding(.top, 2)
        } else if let issue = model.fixIssue(game.id) {
            Label(issue, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .lineLimit(2)
                .padding(.top, 2)
        }
    }

    private func patchSummary(_ p: PatchFlags) -> String {
        var parts: [String] = []
        if p.startupAppID { parts.append("startup") }
        if p.overlayAppID { parts.append("overlay") }
        if p.inputAppID { parts.append("input") }
        if p.statsAppID { parts.append("stats") }
        if p.terrariaServerEnvironment { parts.append("server") }
        return parts.isEmpty ? "No patches" : "Patches: " + parts.joined(separator: ", ")
    }
}

// MARK: - Patch sheet (shown after adding a game, and from My Games)

struct PatchSheetView: View {
    let gameID: Int
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// The Photon app id typed in, and the one found in the game it replaces.
    @State private var photonReplacement = ""
    @State private var photonSource = ""

    private var index: Int? { model.games.firstIndex { $0.id == gameID } }
    private var game: ManagedGame? { index.map { model.games[$0] } }

    private var installedFix: FixRecord? { model.fixes.first { $0.id == gameID } }

    private var showsStatus: Bool { !model.fixMessage.isEmpty || model.busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let game {
                    VStack(alignment: .leading, spacing: 0) {
                        header(game)
                        Divider().opacity(0.4)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                patchesSection(game)
                                fixSource
                                if showsStatus {
                                    statusLine
                                        .transition(.blurReplace)
                                }
                                if let installedFix {
                                    installedSection(installedFix)
                                        .transition(.blurReplace)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 18)
                            .animation(.smooth(duration: 0.3), value: showsStatus)
                            .animation(.smooth(duration: 0.3), value: installedFix)
                        }
                        .scrollContentBackground(.hidden)
                    }
                    .transition(.opacity)
                } else {
                    missingGame
                        .transition(.blurReplace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.smooth(duration: 0.3), value: game == nil)

            Divider().opacity(0.4)
            HStack {
                Button("Remove from my games", role: .destructive) {
                    model.removeGame(id: gameID)
                    dismiss()
                }
                .buttonStyle(.glass)
                .disabled(game == nil)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .sheet(isPresented: $model.showFolderChoice) {
            FolderChoiceView()
                .environmentObject(model)
        }
        .alert(item: $model.fixCompatibilityPrompt) { prompt in
            Alert(title: Text(prompt.title),
                  message: Text(prompt.reason),
                  primaryButton: .default(Text("Install anyway")) {
                      Task { @MainActor in prompt.proceed() }
                  },
                  secondaryButton: .cancel())
        }
        .onAppear {
            model.fixGameID = gameID
            // Read the game's files for the Photon app id they carry. A fix install has
            // done this already; the scan is skipped when the folder was read before.
            model.scanPhotonIDs(appID: gameID, name: game?.name ?? "")
        }

    }

    private var missingGame: some View {
        VStack(spacing: 14) {
            GlassIcon(symbol: "gamecontroller", size: 64)
            Text("That game is no longer in your list.")
                .foregroundStyle(.secondary)
            // Uninstalling takes the game out of the list, so its result is
            // reported here rather than in the sheet's status line.
            if !model.fixMessage.isEmpty {
                Text(model.fixMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private func header(_ game: ManagedGame) -> some View {
        HStack(spacing: 16) {
            Artwork(url: headerArtURL(for: game), width: 150, cornerRadius: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(game.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text("AppID \(game.id)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("Added to My Games — choose what to patch below.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
        }
        .padding(20)
    }

    // MARK: Patches

    @ViewBuilder
    private func patchesSection(_ game: ManagedGame) -> some View {
        if let index {
            let binding = $model.games[index]
            GlassSection(title: "What to patch") {
                HStack(spacing: 0) {
                    patchCell("Startup AppID", binding.patches.startupAppID)
                    patchCell("Overlay AppID", binding.patches.overlayAppID)
                }
                RowDivider()
                HStack(spacing: 0) {
                    patchCell("Input AppID", binding.patches.inputAppID)
                    patchCell("Stats AppID", binding.patches.statsAppID)
                }
                RowDivider()
                keepRealAppIDRow(game, binding)
                // A Mac build takes no fix files at all; the routing above is the
                // whole fix for it, so say so where the choice is.
                if let mac = model.macAppStatus(game.id) {
                    RowDivider()
                    macBuildRow(mac)
                }
                if game.id == 3241660 {
                    RowDivider()
                    repoPhotonRow(game, binding)
                }
                if game.id == 2644470 {
                    RowDivider()
                    picoPark2Row(game, binding)
                }
                if showsPhotonRow(game) {
                    RowDivider()
                    photonRow(game)
                }
            }
        }
    }

    private func patchCell(_ title: String, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.body.weight(.medium))
            Spacer(minLength: 8)
            persistToggle(title, binding)
                .labelsHidden()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity)
    }

    private func keepRealAppIDRow(_ game: ManagedGame, _ binding: Binding<ManagedGame>) -> some View {
        let relay = usesSteamRelayNetwork(game)
        let needsReal = needsRealAppID(game, usesSteamRelay: relay)
        let keepReal = binding.keepRealAppID.wrappedValue

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keep real AppID")
                        .font(.body.weight(.medium))
                    Text("Starts Steam as the game itself instead of Spacewar (480). "
                         + "The game still matches players as Spacewar, so this only "
                         + "changes what Steam's client reports: its playtime, its store "
                         + "data, and whether it can hand the game a Steam relay.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                persistToggle("Keep real AppID", binding.keepRealAppID)
                    .labelsHidden()
            }
            if relay {
                note(needsReal && !keepReal
                     ? "This game plays over Steam's relay servers, and Steam only gives "
                       + "a relay to the game's own AppID. Turn Keep real AppID on, or "
                       + "multiplayer waits on the relay and never joins."
                     : "This game plays over Steam's relay servers. Keep real AppID is "
                       + "what lets Steam hand it a relay, so leave it on.",
                     warning: !keepReal)
                    .transition(.blurReplace)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .animation(.smooth(duration: 0.25), value: keepReal)
    }

    /// A Mac build takes no fix files at all: the routing is the whole fix for it.
    private func macBuildRow(_ mac: MacAppFix.Status) -> some View {
        note(mac.summary, warning: !mac.hasSteamAPI)
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// PICO PARK 2's online play runs on Photon, so the AppID routing above does nothing
    /// for it. The fix for a Mac build is made to the game's own files instead, which is
    /// what this switch does.
    private func picoPark2Row(_ game: ManagedGame, _ binding: Binding<ManagedGame>) -> some View {
        let state = PicoPark2Patch.state(in: Store.gameFolder(for: game.id, name: game.name))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PICO PARK 2 Photon fix")
                        .font(.body.weight(.medium))
                    Text("This game's online play runs on Photon, not Steam, so AppID routing "
                         + "cannot make it connect. The fix belongs in the game's own files: its "
                         + "Photon app id is swapped for OnlineFix's, and the session limit that "
                         + "holds it to one player is lifted. macSteam applies it as soon as the "
                         + "fix is installed, and again after a game update. Only the Mac build "
                         + "can be patched this way; a Windows build needs the fix's own DLLs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("PICO PARK 2 Photon fix", isOn: Binding(
                    get: { binding.wrappedValue.picoPark2Photon || state.isPatched },
                    set: { model.setPicoPark2Photon($0, game: game) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!state.canPatch)
            }
            if let message = state.message {
                note(message, warning: true)
                    .transition(.blurReplace)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .animation(.smooth(duration: 0.25), value: state.isPatched)
    }

    /// A Photon game's own app id, read out of its files when the fix was installed.
    /// Most Photon games need that id swapped for the one the players are on, and this
    /// is where the patch for a game no fix covers yet comes from: the id is found in
    /// the game's own files and replaced in place, the untouched file kept beside it.
    private func photonRow(_ game: ManagedGame) -> some View {
        let found = model.photonScans[game.id] ?? []
        let chosen = found.first { $0.id == photonSource } ?? found.first
        let scanning = model.photonScanning.contains(game.id)
        let typed = photonReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let fits = chosen.map { PhotonPatch.kind(of: typed) == $0.kind } ?? false

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Photon app id")
                        .font(.body.weight(.medium))
                    Text("This game's online play runs on Photon, and the app it joins is "
                         + "written in its own files, so no AppID setting changes who it "
                         + "meets. Paste the id the players are on and it is swapped for "
                         + "the one the game carries.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                if scanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if found.count > 1 {
                Picker("App id to replace", selection: Binding(
                    get: { chosen?.id ?? "" },
                    set: { photonSource = $0 }
                )) {
                    ForEach(found, id: \.self) { candidate in
                        Text("\(candidate.id) — \(relativePath(of: candidate))").tag(candidate.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            if let chosen {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chosen.id)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text("Found in \(relativePath(of: chosen))"
                         + (chosen.isOnlineFixShared ? ", OnlineFix's own app" : ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            InsetField(prompt: "New app id "
                       + (chosen?.kind == .quantum ? "(64 base64 characters)" : "(36-character GUID)"),
                       text: $photonReplacement)
                .font(.system(.callout, design: .monospaced))
            HStack(spacing: 8) {
                Button("Apply to game files") {
                    if let chosen { model.applyPhotonID(typed, replacing: chosen.id, for: game) }
                }
                .buttonStyle(.glassProminent)
                .disabled(!fits || scanning)
                Button("Restore the game's own id") { model.restorePhotonIDs(for: game) }
                    .buttonStyle(.glass)
                    .disabled(scanning)
            }
            .controlSize(.small)
            if !typed.isEmpty, !fits {
                note("The new id has to be the same kind and the same length as the one above.",
                     warning: true)
                    .transition(.blurReplace)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .animation(.smooth(duration: 0.25), value: fits)
        .animation(.smooth(duration: 0.25), value: chosen)
    }

    /// The row is for a game whose files a scan has already found an app id in.
    /// R.E.P.O. and PICO PARK 2 have a row of their own above.
    private func showsPhotonRow(_ game: ManagedGame) -> Bool {
        guard game.id != 3241660, game.id != 2644470 else { return false }
        return model.photonScans[game.id]?.isEmpty == false
    }

    /// A file's place inside the game folder, which is all the row has room for.
    private func relativePath(of candidate: PhotonPatch.Candidate) -> String {
        candidate.file.pathComponents.suffix(3).joined(separator: "/")
    }

    private func repoPhotonRow(_ game: ManagedGame, _ binding: Binding<ManagedGame>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("R.E.P.O. Photon app IDs")
                .font(.body.weight(.medium))
            InsetField(prompt: "Realtime app ID", text: binding.repoPhoton.realtime)
                .font(.system(.callout, design: .monospaced))
            InsetField(prompt: "Voice app ID (optional)", text: binding.repoPhoton.voice)
                .font(.system(.callout, design: .monospaced))
            HStack(spacing: 8) {
                Button("Apply to game files") { model.applyRepoPhotonIDs(game) }
                    .buttonStyle(.glassProminent)
                Button("Restore defaults") { model.clearRepoPhotonIDs(game) }
                    .buttonStyle(.glass)
            }
            .controlSize(.small)
            Text("Replaces the Photon app R.E.P.O. connects to, as the original "
                 + "OnlineFix Manager does. The untouched file is kept beside it "
                 + "for Restore defaults.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }

    /// A note under a setting: orange with a warning sign, or secondary with an info sign.
    private func note(_ text: String, warning: Bool) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle")
        }
        .font(.callout)
        .foregroundStyle(warning ? Color.orange : Color.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((warning ? Color.orange : Color.primary).opacity(0.08), in: .rect(cornerRadius: 12))
    }

    private func usesSteamRelayNetwork(_ game: ManagedGame) -> Bool {
        SteamNetworking.uses(appID: game.id,
                             gameFolder: Store.gameFolder(for: game.id, name: game.name))
    }

    /// A fixed game matches players as Spacewar, whatever its own code uses.
    private func needsRealAppID(_ game: ManagedGame, usesSteamRelay: Bool) -> Bool {
        SteamNetworking.needsRealAppID(usesSteamNetworking: usesSteamRelay,
                                       fixInstalled: model.fixIsInstalled(game.id))
    }

    private func persistToggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { binding.wrappedValue },
            set: { binding.wrappedValue = $0; model.persist() }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    // MARK: Fix source

    private var fixSource: some View {
        GlassSection(title: "Fix source") {
            HStack(spacing: 10) {
                Button("Fetch fix automatically") { model.fetchFix() }
                    .buttonStyle(.glassProminent)
                    .disabled(model.busy)
                Button("Open online-fix.me") { model.openFixSite() }
                    .buttonStyle(.glass)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)

            RowDivider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button("Choose archive…") { model.chooseArchive() }
                        .buttonStyle(.glass)
                    Text(model.archiveURL?.lastPathComponent ?? "No archive selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.opacity)
                    Spacer(minLength: 0)
                }
                .animation(.smooth(duration: 0.25), value: model.archiveURL)
                InsetSecureField(prompt: "Archive password (default: online-fix.me)",
                                 text: $model.archivePassword)
                Button("Install from archive") { model.importFix() }
                    .buttonStyle(.glass)
                    .disabled(model.busy || model.archiveURL == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            if model.busy {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            }
            Text(model.fixMessage.isEmpty ? "Working…" : model.fixMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .animation(.smooth(duration: 0.25), value: model.busy)
        .animation(.smooth(duration: 0.25), value: model.fixMessage)
    }

    // MARK: Installed

    private func installedSection(_ fix: FixRecord) -> some View {
        var missing: [String] = []
        if case .missing(let files) = FixInstaller.state(of: fix) { missing = files }
        let names = missing.map { ($0 as NSString).lastPathComponent }
        return GlassCard {
            HStack(alignment: .top, spacing: 12) {
                StatusDot(kind: missing.isEmpty ? .ok : .warning)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(missing.isEmpty ? "Fix installed" : "Fix files are missing or were replaced")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(missing.isEmpty ? Color.primary : Color.orange)
                    if missing.isEmpty {
                        Text("\(fix.files.count) file(s) written into the game folder.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(fix.files.count)))
                        if let issue = model.fixIssue(fix.id) {
                            Label(issue, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(removedFixDetail(names))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Button("Repair") {
                        model.repairFix(appID: fix.id)
                    }
                    .help("Copy the fix's files where the game loads them, so its loader starts. "
                          + "Run this when the game crashes after the fix was installed.")
                    Button("Own Steam API") {
                        model.routingOnlyFix(appID: fix.id)
                    }
                    .help("Put the game's own Steam API back and leave OnlineFix's loader out. "
                          + "Run this when the game starts as Spacewar and no window ever "
                          + "appears: macSteam's routing still starts it as 480.")
                    Button("Uninstall", role: .destructive) {
                        model.removeFix(id: fix.id)
                    }
                    .help("Delete the files this fix added and take the game out of My Games "
                          + "so it stops running as AppID 480")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
        }
    }

    /// Which files went away, and why that leaves the game without a fix.
    private func removedFixDetail(_ names: [String]) -> String {
        let sample = names.prefix(3).joined(separator: ", ")
        let more = names.count > 3 ? " and \(names.count - 3) more" : ""
        return "Steam put the game's own files back (an update, a verify or a repair), "
            + "which removed the fix: \(sample)\(more). Reinstall OnlineFix below to "
            + "play online again."
    }
}

// MARK: - Similar folder choice

/// Shown when online-fix.me has no folder under the game's own name but does have
/// folders that look like it. Installing another game's files is worse than a
/// question, so the player picks.
struct FolderChoiceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var gameName: String {
        guard let id = model.pendingFolderGameID else { return "this game" }
        return model.games.first { $0.id == id }?.name ?? "this game"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                GlassIcon(symbol: "folder.badge.questionmark", size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Which one is \(gameName)?")
                        .font(.title3.weight(.semibold))
                    Text("online-fix.me has no folder under that exact name. "
                         + "These look similar — pick the one for this game.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.folderChoices) { match in
                        Button {
                            model.chooseFolder(match)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(match.name)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text("\(match.percent)% name match")
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
                        }
                        .buttonStyle(.plain)
                        .hoverLift()
                    }
                }
                .padding(4)
            }
            .scrollContentBackground(.hidden)

            HStack(spacing: 12) {
                Text("None of these? Download the fix from online-fix.me "
                     + "and use “Choose archive…”.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("None of these") {
                    model.cancelFolderChoice()
                    dismiss()
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
        .padding(20)
        .frame(width: 520, height: 400)
    }
}

// MARK: - Installation

struct InstallationView: View {
    @EnvironmentObject private var model: AppModel

    private var phaseText: String {
        switch model.phase {
        case .unknown: return "Unknown"
        case .notInstalled: return "Not installed"
        case .installed: return "Installed"
        case .incomplete(let why): return "Needs repair — \(why)"
        case .broken(let why): return "Needs attention — \(why)"
        }
    }

    private var phaseColor: Color {
        switch model.phase {
        case .installed: return .green
        case .notInstalled: return .secondary
        case .unknown, .incomplete: return .orange
        case .broken: return .red
        }
    }

    var body: some View {
        PageScroll {
            PageHeader(
                title: "Installation",
                subtitle: "Set up the Steam patch for \(model.steamBuild ?? "your Steam build")."
            )

            GlassSection(title: "Steam") {
                row("Location", Paths.steamApp.path)
                RowDivider()
                row("Build", model.steamBuild ?? "not detected")
                RowDivider()
                row("Manifest", model.manifestPath?.path ?? "—")
                RowDivider()
                GlassRow(title: model.steamRunning
                         ? "Steam is running — quit it before installing"
                         : "Steam is not running",
                         status: model.steamRunning ? .warning : .ok)
            }

            GlassSection(title: "OnlineFix") {
                GlassRow(title: "State") {
                    Text(phaseText)
                        .foregroundStyle(phaseColor)
                        .fontWeight(.semibold)
                        .contentTransition(.opacity)
                }
                RowDivider()
                row("Runtime", Paths.runtimeDir.path)
                RowDivider()
                row("Log", Paths.logFile.path)
                RowDivider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.profile.note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !model.profile.bundledProfiles.isEmpty {
                        Text("Bundled profiles: " + model.profile.bundledProfiles.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 15)
            }

            HStack(spacing: 10) {
                Button(model.phase.needsRepair ? "Repair install" : "Install") {
                    model.install()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || Steam.isRunning() || !model.steamPresent)
                Button("Remove OnlineFix") { model.uninstall() }
                    .disabled(model.busy)
                Button("Deploy profiles") { model.deployProfiles() }
                    .disabled(model.busy)
                Spacer()
                Button("Open Steam") { model.openSteam() }
                Button("Support folder") { model.openSupportFolder() }
            }
            .buttonStyle(.glass)

            Group {
                if model.busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.status.isEmpty ? "Working…" : model.status)
                            .foregroundStyle(.secondary)
                    }
                } else if !model.status.isEmpty {
                    Text(model.status)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .transition(.opacity)
            .animation(.smooth(duration: 0.25), value: model.busy)
        }
        .navigationTitle("Installation")
    }

    private func row(_ label: String, _ value: String) -> some View {
        GlassRow(title: label) {
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Logs

struct LogView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                title: "Logs",
                subtitle: "What the injected dylib reports at Steam launch."
            )
            ScrollView {
                Text(model.logText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .scrollContentBackground(.hidden)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .navigationTitle("Logs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refreshLog()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.openLog()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
            }
        }
    }
}
