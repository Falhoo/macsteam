// Import Apps page: drop or choose unlock zips, folders and .lua files, review the games
// they hold, then import them into macSteam's config.
// Logic ported from the old ImportViewController / ImportDropViews / GameReviewCell. The
// reading, copying and merging is still ZipImporter's; this file only drives it.
import AppKit
import GlassUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Plan display

fileprivate extension ImportPlan {
    var title: String { luaTitle ?? sourceZip.deletingPathExtension().lastPathComponent }
    var isImportable: Bool { mainAppID != nil }

    var summary: String {
        guard let app = mainAppID else {
            return "No app id in the file, can't import"
        }
        var parts = ["App \(app)"]
        if dlcAppIDs.count == 1 { parts.append("1 DLC") }
        else if dlcAppIDs.count > 1 { parts.append("\(dlcAppIDs.count) DLC") }
        let keys = depotKeys.count
        if keys > 0 { parts.append("\(keys) depot key\(keys == 1 ? "" : "s")") }
        return parts.joined(separator: "  ·  ")
    }
}

enum ImportPane: Equatable {
    case empty, review, success
}

// MARK: - Model

@MainActor
final class ImportModel: ObservableObject {
    let store: ConfigStore
    let onConfigChanged: @MainActor () -> Void

    /// Undo/redo for removals from the review list. The window hands this out for
    /// Edit > Undo while the Import page is showing.
    let reviewUndoManager = UndoManager()

    @Published private(set) var items: [ImportPlan] = []
    @Published private(set) var pane: ImportPane = .empty
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""
    /// Prominent (label colour) for the "ready to import" summary, secondary otherwise.
    @Published private(set) var statusIsProminent = false
    @Published private(set) var successTitle = ""
    @Published private(set) var successDetail = ""
    @Published var selection: UUID?

    // Review row size (the old size slider under the list).
    static let minRowHeight: CGFloat = 48
    static let maxRowHeight: CGFloat = 160
    static let defaultRowHeight: CGFloat = 104
    private static let snapDistance: CGFloat = 3
    private static let rowHeightDefaultsKey = "ImportRowHeight"
    @Published private(set) var rowHeight: CGFloat = ImportModel.loadRowHeight()

    // Store names and header art, filled in as StoreArtLoader resolves them.
    @Published private(set) var storeNames: [Int: String] = [:]
    @Published private(set) var storeArt: [Int: NSImage] = [:]
    private let art = StoreArtLoader()

    private var batchGeneration = 0

    static let artInset: CGFloat = 8
    static let artAspect: CGFloat = 460.0 / 215.0

    /// Decode art at 2x the largest tile so resizing up never blurs.
    private var tileArtWidth: CGFloat {
        ((Self.maxRowHeight - 2 * Self.artInset) * Self.artAspect * 2).rounded()
    }

    init(store: ConfigStore, onConfigChanged: @escaping @MainActor () -> Void) {
        self.store = store
        self.onConfigChanged = onConfigChanged
    }

    var canImport: Bool { !isBusy && items.contains { $0.isImportable } }
    var canClear: Bool { !isBusy && !items.isEmpty }
    var itemIDs: [UUID] { items.map(\.planID) }

    // MARK: Accepted sources

    /// Zips, .lua files and folders: the same set the old drop views and open panel took.
    nonisolated static func isImportSource(_ url: URL) -> Bool {
        ["zip", "lua"].contains(url.pathExtension.lowercased()) || url.hasDirectoryPath
    }

    /// File URLs on the drag pasteboard that the page would import.
    static func draggedImportURLs() -> [URL] {
        let urls = NSPasteboard(name: .drag).readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.filter(isImportSource) ?? []
    }

    // MARK: Choosing and reading files

    /// Opens the file picker. Also used by File > Import Zip… (⌘I).
    func pickZip() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        let types = ["zip", "lua"].compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            loadPlans(from: panel.urls)
        }
    }

    func loadPlans(from urls: [URL]) {
        guard !isBusy, !urls.isEmpty else { return }
        let sources = urls.filter(Self.isImportSource)
        guard !sources.isEmpty else { return }

        if items.isEmpty { ZipImporter.sweepStaleExtractDirs() }
        // Reading from the success screen: go back to the drop well so progress shows.
        if pane == .success { pane = .empty }

        let noun = sources.count == 1 ? "file" : "\(sources.count) files"
        setBusy(true, status: "Reading \(noun)…")

        let generation = batchGeneration

        Task {
            var loaded: [ImportPlan] = []
            var failures: [String] = []
            for src in sources {
                do {
                    let ext = src.pathExtension.lowercased()
                    let plans = try await Task.detached {
                        if ext == "lua" {
                            return [try ZipImporter.buildPlan(fromLua: src)]
                        } else if src.hasDirectoryPath {
                            return try ZipImporter.buildPlans(fromFolder: src)
                        } else {
                            return try ZipImporter.buildPlans(from: src)
                        }
                    }.value
                    loaded.append(contentsOf: plans)
                } catch {
                    failures.append("\(src.lastPathComponent): \(error.localizedDescription)")
                }
            }
            self.setBusy(false, status: nil)
            if self.batchGeneration != generation {
                for plan in loaded { ZipImporter.cleanup(plan.extractDir) }
                return
            }
            self.appendLoadedPlans(loaded, failures: failures)
        }
    }

    private func appendLoadedPlans(_ plans: [ImportPlan], failures: [String]) {
        // One row per app: a plan for an app already in the review is dropped.
        var existingApps = Set(items.compactMap(\.mainAppID))
        for plan in plans {
            if let app = plan.mainAppID, !existingApps.insert(app).inserted {
                continue
            }
            items.append(plan)
        }
        pane = items.isEmpty ? .empty : .review
        resolveArt(for: plans)

        let importable = items.filter { $0.isImportable }.count
        let skipped = items.count - importable
        var text = importable == 1 ? "1 game ready to import" : "\(importable) games ready to import"
        if skipped > 0 { text += "  ·  \(skipped) skipped (no app id)" }
        setStatus(text, prominent: true)
        announce(text)

        if !failures.isEmpty {
            presentAlert("Couldn’t read some files",
                         failures.joined(separator: "\n"), style: .warning)
        }
    }

    private func resolveArt(for plans: [ImportPlan]) {
        let ids = plans.compactMap { $0.mainAppID }.filter { $0 > 0 }
        guard !ids.isEmpty else { return }
        art.load(ids, artWidth: tileArtWidth,
                 onName: { [weak self] id, name in self?.storeNames[id] = name },
                 onArt: { [weak self] id, image in self?.storeArt[id] = image })
    }

    /// The store's name for the app when known, else the lua/zip title.
    func displayTitle(for plan: ImportPlan) -> String {
        if let id = plan.mainAppID, let name = storeNames[id], !name.isEmpty { return name }
        return plan.title
    }

    func artwork(for plan: ImportPlan) -> NSImage? {
        plan.mainAppID.flatMap { storeArt[$0] }
    }

    func summary(for plan: ImportPlan) -> String { plan.summary }
    func isImportable(_ plan: ImportPlan) -> Bool { plan.isImportable }

    // MARK: Status

    private func setBusy(_ busy: Bool, status text: String?) {
        isBusy = busy
        if let text { setStatus(text, prominent: false); announce(text) }
    }

    private func setStatus(_ text: String, prominent: Bool) {
        status = text
        statusIsProminent = prominent
    }

    private func announce(_ text: String) {
        let element: Any = NSApplication.shared.mainWindow ?? NSApplication.shared
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Clear (Escape) and Import

    /// Empties the review. Escape did this in the old pane; the Clear button does too.
    func clear() {
        guard !isBusy, !items.isEmpty else { return }
        batchGeneration += 1
        for item in items { ZipImporter.cleanup(item.extractDir) }
        items.removeAll()
        selection = nil
        reviewUndoManager.removeAllActions()
        pane = .empty
        setStatus("Cleared.", prominent: false)
        announce("Cleared")
    }

    func applyImport() {
        guard !isBusy else { return }
        let selected = items.filter { $0.isImportable }
        guard !selected.isEmpty else { return }

        setBusy(true, status: "Applying import…")

        let allManifests = selected.flatMap(\.manifestFiles)
        let plans = selected
        Task {
            let copyResult: Result<Int, Error>
            do {
                copyResult = .success(
                    try await Task.detached { try ZipImporter.copyManifests(allManifests) }.value)
            } catch {
                copyResult = .failure(error)
            }

            self.setBusy(false, status: nil)

            switch copyResult {
            case .failure(let error):
                presentAlert("Import failed", error.localizedDescription, style: .warning)
            case .success:
                do {
                    var dlcTotal = 0
                    try self.store.mutate { cfg in
                        for plan in plans {
                            _ = ZipImporter.merge(plan, into: &cfg)
                            dlcTotal += plan.dlcAppIDs.count
                        }
                    }
                    self.onConfigChanged()

                    let games = plans.count
                    self.batchGeneration += 1
                    for item in self.items { ZipImporter.cleanup(item.extractDir) }
                    self.items.removeAll()
                    self.selection = nil
                    self.reviewUndoManager.removeAllActions()
                    self.showSuccess(games: games, dlc: dlcTotal)
                } catch {
                    Task.detached { ZipImporter.removeCopiedManifests(allManifests) }
                    presentAlert("Import failed", error.localizedDescription, style: .warning)
                }
            }
        }
    }

    private func showSuccess(games: Int, dlc: Int) {
        let headline = "Imported \(games) game\(games == 1 ? "" : "s")"
        successTitle = headline
        successDetail = dlc > 0 ? "\(dlc) DLC added" : ""
        setStatus("", prominent: false)
        pane = .success
        announce(dlc > 0 ? "\(headline), \(dlc) DLC added" : headline)
    }

    func importMore() {
        pane = .empty
    }

    // MARK: Removing rows (undoable)

    func remove(planID: UUID) {
        guard let index = items.firstIndex(where: { $0.planID == planID }) else { return }
        remove(at: index)
    }

    func removeSelected() {
        guard let selection else { return }
        remove(planID: selection)
    }

    private func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        let removed = items.remove(at: index)

        reviewUndoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.insert(removed, at: min(index, target.items.count))
            }
        }
        reviewUndoManager.setActionName("Remove Game")

        // Like the table did, keep a selection on the row that slid into place.
        if selection == removed.planID {
            selection = items.isEmpty ? nil : items[min(index, items.count - 1)].planID
        }
        pane = items.isEmpty ? .empty : .review
        if items.isEmpty { setStatus("", prominent: false) }
    }

    private func insert(_ item: ImportPlan, at index: Int) {
        items.insert(item, at: index)

        // Redo removes it again (and is itself undoable).
        reviewUndoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.remove(planID: item.planID)
            }
        }
        reviewUndoManager.setActionName("Remove Game")

        pane = .review
        resolveArt(for: [item])
    }

    // MARK: Keyboard selection

    func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let current = selection.flatMap { id in items.firstIndex { $0.planID == id } }
        let next: Int
        if let current {
            next = min(max(current + offset, 0), items.count - 1)
        } else {
            next = offset > 0 ? 0 : items.count - 1
        }
        selection = items[next].planID
    }

    // MARK: Row size

    private static func loadRowHeight() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: rowHeightDefaultsKey)
        guard stored > 0 else { return defaultRowHeight }
        return min(max(CGFloat(stored), minRowHeight), maxRowHeight)
    }

    /// Slider moved: round, clamp, and snap to the default when close to it.
    func setRowHeight(fromSlider value: Double) {
        var h = min(max(CGFloat(value).rounded(), Self.minRowHeight), Self.maxRowHeight)
        if abs(h - Self.defaultRowHeight) <= Self.snapDistance { h = Self.defaultRowHeight }
        applyRowHeight(h)
    }

    /// Option-click on the slider: back to the default size.
    func resetRowHeight() {
        applyRowHeight(Self.defaultRowHeight)
    }

    private func applyRowHeight(_ h: CGFloat) {
        guard h != rowHeight else { return }
        rowHeight = h
        UserDefaults.standard.set(Double(rowHeight), forKey: Self.rowHeightDefaultsKey)
    }

    /// Context menu: push this row size to the Apps list too.
    func useSizeInApps() {
        UserDefaults.standard.set(Double(rowHeight), forKey: AppsModel.rowHeightDefaultsKey)
        NotificationCenter.default.post(name: AppsModel.rowHeightChanged, object: nil)
    }
}

// MARK: - Page

struct ImportPage: View {
    @ObservedObject var model: ImportModel

    @State private var isTargeted = false
    @FocusState private var listFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motion: Animation? { reduceMotion ? nil : .smooth(duration: 0.32) }

    var body: some View {
        ZStack {
            switch model.pane {
            case .empty:
                emptyState
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .review:
                reviewState
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            case .success:
                successState
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .onDrop(of: [.fileURL], delegate: ImportDropDelegate(model: model, isTargeted: $isTargeted))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.pane != .success {
                GlassActionBar {
                    Button("Clear") { model.clear() }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                        .disabled(!model.canClear)
                        .help("Empty the review list (Esc)")
                    Button("Import") { model.applyImport() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canImport)
                }
                .transition(.opacity)
            }
        }
        .animation(motion, value: model.pane)
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: isTargeted)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: model.itemIDs)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.isBusy)
    }

    // MARK: Empty: the big drop well

    private var emptyState: some View {
        ImportDropWell(isTargeted: isTargeted, isEnabled: !model.isBusy, cornerRadius: 34,
                       onActivate: { model.pickZip() }) {
            VStack(spacing: 18) {
                VStack(spacing: 18) {
                    GlassIcon(symbol: "arrow.down.doc", size: 84,
                              tint: isTargeted ? .accentColor : nil)
                        .symbolEffect(.bounce, value: isTargeted)
                    VStack(spacing: 6) {
                        Text("Drop Zips, Folders, or .lua Files")
                            .font(.title3.weight(.semibold))
                        Text("or choose them from disk")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("Choose Files…") { model.pickZip() }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .disabled(model.isBusy)
                }
                .opacity(model.isBusy ? 0.5 : 1)

                ImportStatusLine(text: model.status, prominent: model.statusIsProminent,
                                 isBusy: model.isBusy)
                    .frame(minHeight: 20)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 8)
        .frame(maxWidth: 980)
    }

    // MARK: Review: compact well, status, list

    private var reviewState: some View {
        VStack(alignment: .leading, spacing: 14) {
            ImportDropWell(isTargeted: isTargeted, isEnabled: !model.isBusy, cornerRadius: 26,
                           onActivate: { model.pickZip() }) {
                HStack(spacing: 14) {
                    GlassIcon(symbol: "arrow.down.doc", size: 44,
                              tint: isTargeted ? .accentColor : nil)
                        .symbolEffect(.bounce, value: isTargeted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drop more zips, folders, or .lua files")
                            .font(.headline)
                        Text("They’re added to the review below.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button("Add Zips…") { model.pickZip() }
                        .buttonStyle(.glass)
                        .disabled(model.isBusy)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .opacity(model.isBusy ? 0.5 : 1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Review")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                ImportStatusLine(text: model.status, prominent: model.statusIsProminent,
                                 isBusy: model.isBusy)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .frame(minHeight: 20)

            reviewList
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: 980)
    }

    private var reviewList: some View {
        GlassCard {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.items, id: \.planID) { plan in
                            let id = plan.planID
                            ImportReviewRow(
                                title: model.displayTitle(for: plan),
                                summary: model.summary(for: plan),
                                importable: model.isImportable(plan),
                                artwork: model.artwork(for: plan),
                                rowHeight: model.rowHeight,
                                isSelected: model.selection == id,
                                listFocused: listFocused,
                                onSelect: {
                                    model.selection = id
                                    listFocused = true
                                },
                                onRemove: { model.remove(planID: id) },
                                onUseSizeInApps: { model.useSizeInApps() }
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.selection) { _, id in
                    // Keep the keyboard selection on screen, as the table did.
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { proxy.scrollTo(id) }
                }
                .frame(maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .contentShape(.rect)
                .onTapGesture {
                    // Clicking empty space clears the selection, as the table allowed.
                    model.selection = nil
                    listFocused = true
                }
                .contextMenu {
                    Button("Use This Size in the Apps List") { model.useSizeInApps() }
                }
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                    guard model.selection != nil else { return .ignored }
                    model.removeSelected()
                    return .handled
                }
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    model.moveSelection(by: press.key == .upArrow ? -1 : 1)
                    return .handled
                }
                .accessibilityLabel("Review")
            }

            Divider().opacity(0.5)

            ImportSizeSlider(model: model)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .contextMenu {
                    Button("Use This Size in the Apps List") { model.useSizeInApps() }
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .fill(Color.accentColor.opacity(isTargeted ? 0.08 : 0))
                .strokeBorder(Color.accentColor.opacity(isTargeted ? 0.6 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
    }

    // MARK: Success

    private var successState: some View {
        VStack(spacing: 18) {
            GlassIcon(symbol: "checkmark", size: 112, tint: .green)
            VStack(spacing: 8) {
                Text(model.successTitle)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .accessibilityLabel(model.successTitle)
                if !model.successDetail.isEmpty {
                    Text(model.successDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Import More") { model.importMore() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Drop handling

/// Takes file drags anywhere on the page. Only zips, .lua files and folders light the page
/// up or get accepted, and nothing is accepted while a batch is being read or imported.
private struct ImportDropDelegate: DropDelegate {
    let model: ImportModel
    @Binding var isTargeted: Bool

    private var accepts: Bool {
        !model.isBusy && !ImportModel.draggedImportURLs().isEmpty
    }

    func validateDrop(info: DropInfo) -> Bool { accepts }

    func dropEntered(info: DropInfo) { isTargeted = accepts }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        accepts ? DropProposal(operation: .copy) : DropProposal(operation: .forbidden)
    }

    func dropExited(info: DropInfo) { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let sources = ImportModel.draggedImportURLs()
        guard !model.isBusy, !sources.isEmpty else { return false }
        model.loadPlans(from: sources)
        return true
    }
}

/// The dashed glass well. Clicking it (or Space/Return while it has keyboard focus, or
/// VoiceOver's press) opens the file picker, like the old DropZoneView.
private struct ImportDropWell<Content: View>: View {
    let isTargeted: Bool
    let isEnabled: Bool
    let cornerRadius: CGFloat
    let onActivate: () -> Void
    @ViewBuilder var content: Content

    @FocusState private var isFocused: Bool

    var body: some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.18)),
                        style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [8, 6])
                    )
            }
            .glassEffect(.regular.tint(isTargeted ? Color.accentColor.opacity(0.14) : nil),
                         in: .rect(cornerRadius: cornerRadius))
            .scaleEffect(isTargeted ? 1.01 : 1)
            .contentShape(.rect(cornerRadius: cornerRadius))
            .contentShape(.focusEffect, .rect(cornerRadius: cornerRadius))
            .onTapGesture { if isEnabled { activate() } }
            .focusable(isEnabled)
            .focused($isFocused)
            .onKeyPress(keys: [.space, .return]) { _ in
                guard isEnabled else { return .ignored }
                activate()
                return .handled
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Choose files to import")
            .accessibilityHint("Drop unlock zips or lua files here, or activate to browse.")
            .accessibilityAction { if isEnabled { activate() } }
    }

    private func activate() {
        isFocused = true
        onActivate()
    }
}

// MARK: - Pieces

private struct ImportStatusLine: View {
    let text: String
    let prominent: Bool
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
                    .transition(.opacity)
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(prominent ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: text)
    }
}

/// One game in the review: header art, name, what it adds, and a remove button that shows
/// on hover (the old GameReviewCell).
private struct ImportReviewRow: View {
    let title: String
    let summary: String
    let importable: Bool
    let artwork: NSImage?
    let rowHeight: CGFloat
    let isSelected: Bool
    let listFocused: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    let onUseSizeInApps: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tileHeight: CGFloat { rowHeight - 2 * ImportModel.artInset }

    var body: some View {
        HStack(spacing: 14) {
            ImportArtTile(image: artwork, height: tileHeight, importable: importable)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(importable ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            if !importable {
                Text("Can’t import")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.14), in: .capsule)
                    .fixedSize()
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .help("Remove game from the review")
            .accessibilityLabel("Remove game")
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .frame(height: rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(isSelected
                      ? (listFocused ? AnyShapeStyle(Color.accentColor.opacity(0.24))
                                     : AnyShapeStyle(.primary.opacity(0.10)))
                      : AnyShapeStyle(.primary.opacity(isHovering ? 0.05 : 0)))
        }
        .contentShape(.rect(cornerRadius: 18))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Remove", action: onRemove)
            Divider()
            Button("Use This Size in the Apps List", action: onUseSizeInApps)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(importable ? "\(title). \(summary)." : "\(title). \(summary). Can’t import.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Remove", onRemove)
    }
}

/// Steam header art (460×215) at the row's size, with a box glyph until the art loads.
private struct ImportArtTile: View {
    let image: NSImage?
    let height: CGFloat
    let importable: Bool

    private var width: CGFloat { (height * ImportModel.artAspect).rounded() }
    private var radius: CGFloat { min(12, max(6, height * 0.14)) }

    var body: some View {
        ZStack {
            Rectangle().fill(.primary.opacity(0.07))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "shippingbox")
                    .font(.system(size: 18))
                    .foregroundStyle(importable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
            }
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.primary.opacity(0.08)))
        .animation(.smooth(duration: 0.25), value: image != nil)
        .accessibilityHidden(true)
    }
}

/// Row-size slider under the list. Option-click puts it back to the default size, and it
/// snaps to the default when dragged close, like the old ResettableSlider.
private struct ImportSizeSlider: View {
    @ObservedObject var model: ImportModel
    @State private var resettingWithOption = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.system(size: 11))
            Slider(
                value: Binding(
                    get: { Double(model.rowHeight) },
                    set: { value in
                        guard !resettingWithOption else { return }
                        model.setRowHeight(fromSlider: value)
                    }),
                in: Double(ImportModel.minRowHeight)...Double(ImportModel.maxRowHeight),
                onEditingChanged: { editing in
                    if editing {
                        resettingWithOption = NSEvent.modifierFlags.contains(.option)
                        if resettingWithOption { model.resetRowHeight() }
                    } else if resettingWithOption {
                        resettingWithOption = false
                        model.resetRowHeight()
                    }
                }
            )
            .frame(width: 140)
            .accessibilityLabel("Review row size")
            Image(systemName: "photo")
                .font(.system(size: 17))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .disabled(model.isBusy)
    }
}
