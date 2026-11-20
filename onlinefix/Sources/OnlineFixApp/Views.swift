import AppKit
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

struct ArtworkView: View {
    let url: URL?
    var width: CGFloat = 157
    var height: CGFloat = 74
    var corner: CGFloat = 6

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    Rectangle().fill(Color.white.opacity(0.06))
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(
            RoundedRectangle(cornerRadius: corner)
                .stroke(Color.white.opacity(0.06))
        )
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder: String
    var busy: Bool = false
    var onSubmit: () -> Void = {}
    var onClear: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(onSubmit)
            if busy {
                ProgressView().controlSize(.small)
            }
            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08))
        )
        .onAppear { focused = true }
    }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(
                    title: "Find your game",
                    subtitle: "Search Steam or enter an AppID. The game doesn't need to be installed."
                )

                SearchField(
                    text: $model.searchQuery,
                    placeholder: "Game name or AppID",
                    busy: model.searching,
                    onSubmit: { model.searchStore() },
                    onClear: { model.clearSearch() }
                )

                if let message = model.searchMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if model.searchResults.isEmpty && libraryMatches.isEmpty && !model.searching {
                    ContentUnavailableView {
                        Label("Search for a game", systemImage: "magnifyingglass")
                    } description: {
                        Text("Find a game by name, or add it using its Steam AppID.")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 90)
                } else {
                    LazyVStack(spacing: 8) {
                        if !libraryMatches.isEmpty {
                            sectionTitle("In your Steam library")
                            ForEach(libraryMatches.prefix(25)) { app in
                                resultRow(
                                    name: app.name,
                                    appID: app.id,
                                    art: SteamCatalog.headerImageURL(for: app.id),
                                    added: model.alreadyAdded(app.id),
                                    action: { model.addLibraryGame(app) }
                                )
                            }
                        }
                        if !model.searchResults.isEmpty {
                            if !libraryMatches.isEmpty {
                                sectionTitle("Steam store")
                            }
                            ForEach(model.searchResults) { result in
                                resultRow(
                                    name: result.name,
                                    appID: result.id,
                                    art: result.imageURL ?? SteamCatalog.headerImageURL(for: result.id),
                                    added: model.alreadyAdded(result.id),
                                    action: { model.add(result) }
                                )
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                Divider().padding(.vertical, 6)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Add by AppID")
                        .font(.system(size: 12, weight: .semibold))
                    Text("If the search does not find it, enter the Steam AppID directly (the name is optional).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("AppID", text: $model.newAppID)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        TextField("Name (optional)", text: $model.newName)
                            .textFieldStyle(.roundedBorder)
                        Button("Add Game") { model.addManualGame() }
                            .disabled(model.busy
                                || model.newAppID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.white.opacity(0.045))
                )
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Add Games")
        .onChange(of: model.searchQuery) { _, newValue in
            scheduleSearch(for: newValue)
        }
        .onDisappear { searchTask?.cancel() }
    }

    private func sectionTitle(_ text: String) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func resultRow(name: String, appID: Int, art: URL?, added: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            ArtworkView(url: art)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text("AppID \(appID)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if added {
                Text("Added")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Button("Add Game", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.045))
        )
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

    private func artURL(for game: ManagedGame) -> URL? {
        if let raw = game.imageURL, let url = URL(string: raw) { return url }
        return SteamCatalog.headerImageURL(for: game.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(
                    title: "My Games",
                    subtitle: "Games OnlineFix routes on launch. Patches apply per game."
                )

                if model.games.isEmpty {
                    ContentUnavailableView {
                        Label("No games yet", systemImage: "gamecontroller")
                    } description: {
                        Text("Add a game from the Add Games page — search it by name.")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 90)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach($model.games) { $game in
                            gameCard($game)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("My Games")
    }

    private func gameCard(_ game: Binding<ManagedGame>) -> some View {
        let value = game.wrappedValue

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Button {
                    model.openPatch(value.id)
                } label: {
                    HStack(spacing: 14) {
                        ArtworkView(url: artURL(for: value))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(value.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                            Text("AppID \(value.id)")
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(patchSummary(value.patches))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            if let state = model.fixState(value.id), case .missing = state {
                                Text("Fix files are missing, reinstall in settings")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Game settings")

                Spacer(minLength: 8)

                Button {
                    model.openPatch(value.id)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help("Game settings")

                Button(role: .destructive) {
                    model.removeGame(id: value.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }

        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.045))
        )
        .contextMenu {
            Button("Game settings…") { model.openPatch(value.id) }
            if model.fixes.contains(where: { $0.id == value.id }) {
                Button("Uninstall OnlineFix", role: .destructive) {
                    model.uninstallFix(appID: value.id)
                }
            }
            Button("Remove from My Games", role: .destructive) {
                model.removeGame(id: value.id)
            }
        }
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { binding.wrappedValue },
            set: { binding.wrappedValue = $0; model.persist() }
        ))
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
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

// MARK: - Fix

// MARK: - Patch sheet (shown after adding a game, and from My Games)

struct PatchSheetView: View {
    let gameID: Int
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var index: Int? { model.games.firstIndex { $0.id == gameID } }
    private var game: ManagedGame? { index.map { model.games[$0] } }

    private var installedFix: FixRecord? { model.fixes.first { $0.id == gameID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let game {
                header(game)
                Divider().opacity(0.4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        patchesSection(game)
                        fixSource
                        if !model.fixMessage.isEmpty || model.busy {
                            statusLine
                        }
                        if let installedFix {
                            installedSection(installedFix)
                        }
                    }
                    .padding(18)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("That game is no longer in your list.")
                        .foregroundStyle(.secondary)
                    // Uninstalling takes the game out of the list, so its result is
                    // reported here rather than in the sheet's status line.
                    if !model.fixMessage.isEmpty {
                        Text(model.fixMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(30)
            }

            Divider().opacity(0.4)
            HStack {
                Button("Remove from my games", role: .destructive) {
                    model.removeGame(id: gameID)
                    dismiss()
                }
                .disabled(game == nil)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560, height: 620)
        .sheet(isPresented: $model.showFolderChoice) {
            FolderChoiceView()
                .environmentObject(model)
        }
        .onAppear { model.fixGameID = gameID }
    }

    // MARK: Header

    private func header(_ game: ManagedGame) -> some View {
        HStack(spacing: 14) {
            ArtworkView(url: artURL(game))
            VStack(alignment: .leading, spacing: 3) {
                Text(game.name)
                    .font(.system(size: 14, weight: .semibold))
                Text("AppID \(game.id)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("Added to My Games — choose what to patch below.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
        }
        .padding(16)
    }

    private func artURL(_ game: ManagedGame) -> URL? {
        if let raw = game.imageURL, let url = URL(string: raw) { return url }
        return SteamCatalog.headerImageURL(for: game.id)
    }

    // MARK: Patches

    private func patchesSection(_ game: ManagedGame) -> some View {
        GroupBox {
            if let index {
                let binding = $model.games[index]
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                        persistToggle("Startup AppID", binding.patches.startupAppID)
                        persistToggle("Overlay AppID", binding.patches.overlayAppID)
                        persistToggle("Input AppID", binding.patches.inputAppID)
                        persistToggle("Stats AppID", binding.patches.statsAppID)
                    }
                    Divider().opacity(0.3)
                    persistToggle("Keep real AppID", binding.keepRealAppID)
                    if usesSteamRelayNetwork(game) {
                        Text("In order to use OnlineFix for this game, we recommend you use "
                             + "Keep real AppID, because the game uses the Steam relay servers, "
                             + "which aren't compatible with Spacewar (AppID 480).")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 18)
                    }
                    Text("Starts the game as its own AppID instead of Spacewar (480). "
                         + "Turn this on for games whose online play uses Steam's relay "
                         + "servers: remapped, they never get a relay and multiplayer waits forever.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 18)
                }
                .padding(4)
            }
        } label: {
            Label("What to patch", systemImage: "slider.horizontal.3")
        }
    }

    private func usesSteamRelayNetwork(_ game: ManagedGame) -> Bool {
        SteamNetworking.uses(appID: game.id,
                             gameFolder: Store.gameFolder(for: game.id, name: game.name))
    }

    private func persistToggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { binding.wrappedValue },
            set: { binding.wrappedValue = $0; model.persist() }
        ))
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
    }

    // MARK: Fix source

    private var fixSource: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Fetch fix automatically") { model.fetchFix() }
                        .disabled(model.busy)
                    Button("Open online-fix.me") { model.openFixSite() }
                    Spacer()
                }
                Divider().opacity(0.4)
                HStack {
                    Button("Choose archive…") { model.chooseArchive() }
                    Text(model.archiveURL?.lastPathComponent ?? "No archive selected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                SecureField("Archive password (default: online-fix.me)", text: $model.archivePassword)
                    .textFieldStyle(.roundedBorder)
                Button("Install from archive") { model.importFix() }
                    .disabled(model.busy || model.archiveURL == nil)
            }
            .padding(4)
        } label: {
            Label("Fix source", systemImage: "shippingbox")
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.fixMessage.isEmpty ? "Working…" : model.fixMessage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: Installed

    private func installedSection(_ fix: FixRecord) -> some View {
        var missing: [String] = []
        if case .missing(let files) = FixInstaller.state(of: fix) { missing = files }
        let names = missing.map { ($0 as NSString).lastPathComponent }
        return GroupBox {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(missing.isEmpty ? "Fix installed" : "Fix files are missing")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(missing.isEmpty ? Color.primary : Color.orange)
                    if missing.isEmpty {
                        Text("\(fix.files.count) file(s) written into the game folder.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(removedFixDetail(names))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button("Uninstall", role: .destructive) {
                    model.removeFix(id: fix.id)
                }
                .controlSize(.small)
                .help("Delete the files this fix added and take the game out of My Games "
                      + "so it stops running as AppID 480")
            }
            .padding(4)
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
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Which one is \(gameName)?")
                    .font(.system(size: 14, weight: .semibold))
                Text("online-fix.me has no folder under that exact name. "
                     + "These look similar — pick the one for this game.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.folderChoices) { match in
                        Button {
                            model.chooseFolder(match)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(match.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text("\(match.percent)% name match")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.15)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            HStack {
                Text("None of these? Download the fix from online-fix.me "
                     + "and use “Choose archive…”.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("None of these") {
                    model.cancelFolderChoice()
                    dismiss()
                }
            }
        }
        .padding(18)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "Installation",
                    subtitle: "Set up the Steam patch for \(model.steamBuild ?? "your Steam build")."
                )

                GroupBox("Steam") {
                    VStack(alignment: .leading, spacing: 8) {
                        row("Location", Paths.steamApp.path)
                        row("Build", model.steamBuild ?? "not detected")
                        row("Manifest", model.manifestPath?.path ?? "—")
                        HStack(spacing: 8) {
                            Circle()
                                .fill(model.steamRunning ? Color.orange : Color.green)
                                .frame(width: 8, height: 8)
                            Text(model.steamRunning ? "Steam is running — quit it before installing" : "Steam is not running")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("OnlineFix") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("State").foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                            Text(phaseText).foregroundStyle(phaseColor).fontWeight(.semibold)
                        }
                        row("Runtime", Paths.runtimeDir.path)
                        row("Log", Paths.logFile.path)
                        Text(model.profile.note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if !model.profile.bundledProfiles.isEmpty {
                            Text("Bundled profiles: " + model.profile.bundledProfiles.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                HStack(spacing: 10) {
                    Button(model.phase.needsRepair ? "Repair install" : "Install") {
                        model.install()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || Steam.isRunning() || !model.steamPresent)
                    Button("Uninstall") { model.uninstall() }
                        .disabled(model.busy || Steam.isRunning())
                    Button("Deploy profiles") { model.deployProfiles() }
                        .disabled(model.busy)
                    Spacer()
                    Button("Open Steam") { model.openSteam() }
                    Button("Support folder") { model.openSupportFolder() }
                }

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
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .navigationTitle("Installation")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: - Logs

struct LogView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(
                title: "Logs",
                subtitle: "What the injected dylib reports at Steam launch."
            )
            ScrollView {
                Text(model.logText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.035))
                    )
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
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
