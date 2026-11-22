// Apps page: the games macSteam unlocks (config.yaml `apps`), as glass cards with their
// DLC nested under them. Logic ported from the Apps section of ConfigViewController and
// from AppCardListView: selection, Delete / File > Remove (⌘⌫), context menus,
// double-click for Properties, the OnlineFix hand-off and the art size slider.
import AppKit
import Combine
import OnlineFixApp
import GlassUI
import SwiftUI

@MainActor
final class AppsModel: ObservableObject {
    /// A listed game, with the DLC that nest under it. A DLC whose parent is not listed
    /// is a game of its own here, so it stays visible and removable.
    struct Game: Identifiable, Equatable {
        let appID: Int
        var dlc: [Int]
        var id: Int { appID }
    }

    // Row size. Same units, defaults key and notification as AppCardListView, so the
    // Import page's "use this size in Apps" keeps working.
    static let rowHeightDefaultsKey = "AppsRowHeight"
    static let rowHeightChanged = Notification.Name("AppsRowHeightChanged")
    static let minRowHeight: CGFloat = 48
    static let maxRowHeight: CGFloat = 160
    static let rowHeightStep: CGFloat = 14   // 9 stops, 48...160
    // 90 lands on the 4th of 9 stops, the "return to default" (Option-click the slider).
    static let defaultRowHeight: CGFloat = 90
    static let artInset: CGFloat = 8
    static let artAspect: CGFloat = 460.0 / 215.0
    private static let snapDistance: CGFloat = 3
    // Decode at 2x the largest art so resizing up never blurs.
    private static var decodeWidth: CGFloat {
        ((maxRowHeight - 2 * artInset) * artAspect * 2).rounded()
    }

    let store: ConfigStore

    @Published private(set) var games: [Game] = []
    @Published private(set) var expanded: Set<Int> = []
    @Published private(set) var selection: Set<Int> = []
    @Published private(set) var rowHeight: CGFloat
    @Published private(set) var resolvedNames: [Int: String] = [:]
    @Published private(set) var images: [Int: NSImage] = [:]

    /// Receives File > Remove (⌘⌫, `removeApps:` with a nil target) while the page is
    /// on screen; see AppsResponderBridge.
    let commandResponder = AppsCommandResponder()

    private var selectionAnchor: Int?
    private let art = StoreArtLoader()
    private var propertiesWindows: [Int: AppsPropertiesWindowController] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    private var appIDs: [Int] { store.config.apps }

    init(store: ConfigStore) {
        self.store = store
        self.rowHeight = Self.loadRowHeight()

        commandResponder.onRemove = { [weak self] in self?.removeSelection() }
        commandResponder.canRemove = { [weak self] in !(self?.selection.isEmpty ?? true) }
        commandResponder.onSelectAll = { [weak self] in self?.selectAll() }

        // Import already wrote the new size to defaults, so adopt it (no persist).
        NotificationCenter.default.publisher(for: Self.rowHeightChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.externalRowHeightChanged() }
            .store(in: &subscriptions)

        reloadFromStore()
    }

    /// Rebuilds the list from config.yaml; also called when another page changes it.
    func reloadFromStore() {
        rebuildTree()
        resolveAll()
    }

    // MARK: Tree

    // A DLC nests only when its parent is also listed; an orphan stays top-level and
    // removable. List order preserved so the main app stays first.
    private func rebuildTree() {
        var index: [Int: Int] = [:]
        var order: [Game] = []
        for id in appIDs where !isNestableDLC(id) {
            index[id] = order.count
            order.append(Game(appID: id, dlc: []))
        }
        for id in appIDs where isNestableDLC(id) {
            if let parent = store.config.appParents[id], let i = index[parent] {
                order[i].dlc.append(id)
            } else {
                index[id] = order.count
                order.append(Game(appID: id, dlc: []))
            }
        }
        games = order

        let gameIDs = Set(order.map(\.appID))
        expanded.formIntersection(gameIDs)
        let visible = Set(visibleIDs)
        selection.formIntersection(visible)
        if let anchor = selectionAnchor, !visible.contains(anchor) { selectionAnchor = nil }
    }

    private func isNestableDLC(_ id: Int) -> Bool {
        guard let parent = store.config.appParents[id] else { return false }
        return appIDs.contains(parent)
    }

    private func game(_ appID: Int) -> Game? { games.first { $0.appID == appID } }

    /// Rows on screen, top to bottom: each game, then its DLC when it is expanded.
    private var visibleIDs: [Int] {
        games.flatMap { game in
            [game.appID] + (expanded.contains(game.appID) ? game.dlc : [])
        }
    }

    // MARK: Names & art

    private func resolveAll() {
        art.load(appIDs, artWidth: Self.decodeWidth,
                 onName: { [weak self] id, name in self?.resolvedNames[id] = name },
                 onArt: { [weak self] id, image in self?.images[id] = image })
    }

    // Store name, then persisted lua name, then bare id, so unresolved ids still read.
    func displayName(for appID: Int) -> String {
        if let n = resolvedNames[appID], !n.isEmpty { return n }
        if let n = art.name(for: appID) { return n }
        if let n = store.config.appNames[appID], !n.isEmpty { return n }
        return "App \(appID)"
    }

    func image(for appID: Int) -> NSImage? { images[appID] ?? art.image(for: appID) }

    // DLC count nested under a base game, for the removal confirmation copy.
    func dlcCount(for appID: Int) -> Int { game(appID)?.dlc.count ?? 0 }

    // MARK: Disclosure

    func isExpanded(_ appID: Int) -> Bool { expanded.contains(appID) }

    func setExpanded(_ appID: Int, _ open: Bool) {
        if open {
            expanded.insert(appID)
        } else {
            expanded.remove(appID)
            // Hidden DLC rows leave the selection, as they did in the outline view.
            let hidden = Set(game(appID)?.dlc ?? [])
            selection.subtract(hidden)
            if let anchor = selectionAnchor, hidden.contains(anchor) { selectionAnchor = appID }
        }
    }

    // MARK: Selection

    func isSelected(_ appID: Int) -> Bool { selection.contains(appID) }

    /// A click on a row: plain click selects it, ⌘ toggles it, ⇧ extends from the anchor.
    func click(_ appID: Int, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchor = selectionAnchor {
            let rows = visibleIDs
            if let a = rows.firstIndex(of: anchor), let b = rows.firstIndex(of: appID) {
                let range = Set(rows[min(a, b)...max(a, b)])
                selection = modifiers.contains(.command) ? selection.union(range) : range
                return
            }
        }
        if modifiers.contains(.command) {
            if selection.contains(appID) { selection.remove(appID) } else { selection.insert(appID) }
        } else {
            selection = [appID]
        }
        selectionAnchor = appID
    }

    func clearSelection() {
        selection = []
        selectionAnchor = nil
    }

    func selectAll() {
        selection = Set(visibleIDs)
    }

    /// Arrow keys: move the selection one row, or extend it with ⇧.
    func moveSelection(by delta: Int, extend: Bool) {
        let rows = visibleIDs
        guard !rows.isEmpty else { return }
        let current = selectionAnchor.flatMap { rows.firstIndex(of: $0) }
            ?? (delta > 0 ? rows.lastIndex(where: selection.contains) : rows.firstIndex(where: selection.contains))
        let next: Int
        if let current {
            next = min(max(current + delta, 0), rows.count - 1)
        } else {
            next = delta > 0 ? 0 : rows.count - 1
        }
        if extend {
            selection.insert(rows[next])
            selectionAnchor = rows[next]
        } else {
            selection = [rows[next]]
            selectionAnchor = rows[next]
        }
    }

    /// Left / right arrows collapse or expand the selected games, like the outline view.
    func setSelectionExpanded(_ open: Bool) {
        for game in games where selection.contains(game.appID) {
            setExpanded(game.appID, open)
        }
    }

    /// What a context menu acts on: the clicked row when it is outside the selection,
    /// else the whole selection (Finder behavior).
    func contextTargets(for appID: Int) -> [Int] {
        guard selection.contains(appID) else { return [appID] }
        return visibleIDs.filter { selection.contains($0) }
    }

    // MARK: Remove

    func removeSelection() {
        remove(visibleIDs.filter { selection.contains($0) })
    }

    // A base game takes its nested DLC with it; a DLC row goes alone. Selection can mix
    // both. The store owns the change (removeApps drops each app's depot-key group).
    func remove(_ targets: [Int]) {
        guard !targets.isEmpty else { NSSound.beep(); return }
        var removed = Set<Int>()
        for id in targets {
            if let game = game(id) {
                removed.insert(id)
                removed.formUnion(game.dlc)
            } else if appIDs.contains(id) {
                removed.insert(id)
            }
        }
        guard !removed.isEmpty else { NSSound.beep(); return }

        let removedList = appIDs.filter { removed.contains($0) }
        guard confirmRemoval(removedList) else { return }
        guard performRemoval(removedList) else { return }
        rebuildTree()
    }

    private func confirmRemoval(_ removed: [Int]) -> Bool {
        let baseGames = removed.filter { dlcCount(for: $0) > 0 }
        if let game = baseGames.first, removed.count > 1 {
            let n = dlcCount(for: game)
            return confirm(
                "Remove \(displayName(for: game)) and its \(n) DLC?",
                "This removes the game and its DLC from the macSteam "
                    + "configuration. macSteam will no longer unlock the title.",
                confirmTitle: "Remove")
        }
        let names = ListFormatter.localizedString(byJoining: removed.map { displayName(for: $0) })
        let titleNoun = removed.count > 1 ? "these titles" : "the title"
        return confirm(
            "Remove \(names)?",
            "This removes \(names) from the macSteam configuration. "
                + "macSteam will no longer unlock \(titleNoun).",
            confirmTitle: "Remove")
    }

    private func performRemoval(_ ids: [Int]) -> Bool {
        var ok = true
        persisting {
            do { try store.removeApps(ids) } catch { ok = false; throw error }
        }
        return ok
    }

    private func persisting(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            NSSound.beep()
            presentAlert("Couldn’t save config", error.localizedDescription, style: .warning)
        }
    }

    /// Title of the Remove item for these rows (context menu and the card's button).
    func removeTitle(for targets: [Int]) -> String {
        if targets.count == 1 {
            let id = targets[0]
            let name = displayName(for: id)
            if let game = game(id), !game.dlc.isEmpty { return "Remove \(name) and \(game.dlc.count) DLC" }
            return "Remove \(name)"
        }
        return "Remove \(targets.count) Items"
    }

    // MARK: Properties & OnlineFix

    func openProperties(appID: Int) {
        if let existing = propertiesWindows[appID] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = AppsPropertiesWindowController(appID: appID, gameName: displayName(for: appID))
        controller.onClose = { [weak self] in self?.propertiesWindows[appID] = nil }
        propertiesWindows[appID] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// OnlineFix… is offered for a listed game (not a nested DLC), and never for
    /// Spacewar (480) itself.
    func canOpenOnlineFix(_ appID: Int) -> Bool {
        game(appID) != nil && (1...0xffffff).contains(appID) && appID != 480
    }

    /// Opens the game in the merged OnlineFix Manager, which owns the list, the
    /// game-file fixes and the per-game routing settings.
    func openInOnlineFixManager(appID: Int) {
        OnlineFixEmbed.prepareGame(appID: appID, name: displayName(for: appID))
        NotificationCenter.default.post(
            name: OnlineFixHandoff.notification, object: nil,
            userInfo: [OnlineFixHandoff.appIDKey: appID])
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Row size

    func setRowHeight(_ value: CGFloat) {
        var h = min(max(value.rounded(), Self.minRowHeight), Self.maxRowHeight)
        if abs(h - Self.defaultRowHeight) <= Self.snapDistance { h = Self.defaultRowHeight }
        guard h != rowHeight else { return }
        rowHeight = h
        UserDefaults.standard.set(Double(h), forKey: Self.rowHeightDefaultsKey)
    }

    func resetRowHeight() { setRowHeight(Self.defaultRowHeight) }

    private func externalRowHeightChanged() {
        let h = Self.loadRowHeight()
        guard h != rowHeight else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { rowHeight = h }
    }

    private static func loadRowHeight() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: rowHeightDefaultsKey)
        guard stored > 0 else { return defaultRowHeight }
        return min(max(CGFloat(stored), minRowHeight), maxRowHeight)
    }
}

// MARK: - Page

struct AppsPage: View {
    @ObservedObject var model: AppsModel
    @FocusState private var listFocused: Bool

    private var artHeight: CGFloat { model.rowHeight - 2 * AppsModel.artInset }

    var body: some View {
        Group {
            if model.games.isEmpty {
                GlassEmptyState(symbol: "square.stack.3d.up", title: "No games yet",
                                message: "Import a game to add it.")
                    .transition(.opacity)
            } else {
                list
            }
        }
        .animation(.smooth, value: model.games.isEmpty)
        .safeAreaInset(edge: .bottom, spacing: 0) { sizeBar }
        .background { AppsResponderBridge(responder: model.commandResponder) }
        .onAppear { model.reloadFromStore() }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "Apps",
                    subtitle: "The games macSteam unlocks. Double-click a game for its properties; select games and press Delete to remove them."
                )
                LazyVStack(spacing: 10) {
                    ForEach(model.games) { game in
                        AppCardRow(model: model, game: game, artHeight: artHeight,
                                   focusList: { listFocused = true })
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            // A click on empty space clears the selection.
            .background {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture {
                        model.clearSelection()
                        listFocused = true
                    }
            }
        }
        .scrollContentBackground(.hidden)
        .focusable(interactions: .edit)
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(keys: [.delete, .deleteForward], phases: .down) { _ in
            model.removeSelection()
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            model.moveSelection(by: press.key == .upArrow ? -1 : 1,
                                extend: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            model.setSelectionExpanded(press.key == .rightArrow)
            return .handled
        }
        .onKeyPress(.escape) {
            model.clearSelection()
            return .handled
        }
        .animation(.snappy, value: model.expanded)
    }

    /// Floating glass capsule with the art size slider (Option-click resets it).
    private var sizeBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo")
                .font(.system(size: 12))
                .accessibilityHidden(true)
            Slider(
                value: Binding(get: { Double(model.rowHeight) },
                               set: { model.setRowHeight(CGFloat($0)) })
                    .animation(.spring(duration: 0.35, bounce: 0.2)),
                in: Double(AppsModel.minRowHeight)...Double(AppsModel.maxRowHeight),
                step: Double(AppsModel.rowHeightStep),
                onEditingChanged: { editing in
                    if !editing, NSEvent.modifierFlags.contains(.option) {
                        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { model.resetRowHeight() }
                    }
                }
            )
            .frame(width: 180)
            .accessibilityLabel("Game row size")
            Image(systemName: "photo")
                .font(.system(size: 18))
                .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.bottom, 20)
    }
}

// MARK: - Rows

/// One game: header art and name, a disclosure chevron, and when expanded its DLC and
/// actions.
private struct AppCardRow: View {
    @ObservedObject var model: AppsModel
    let game: AppsModel.Game
    let artHeight: CGFloat
    let focusList: () -> Void

    private var isExpanded: Bool { model.isExpanded(game.appID) }
    private var isSelected: Bool { model.isSelected(game.appID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                detail
                    .transition(.opacity.combined(with: .offset(y: -8)))
            }
        }
        .clipShape(.rect(cornerRadius: 26))
        .glassEffect(isSelected ? .regular.tint(Color.accentColor.opacity(0.22)) : .regular,
                     in: .rect(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .strokeBorder(Color.accentColor.opacity(isSelected ? 0.55 : 0), lineWidth: 1.5)
        }
        .animation(.smooth(duration: 0.2), value: isSelected)
        .hoverLift()
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                withAnimation(.snappy) { model.setExpanded(game.appID, !isExpanded) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse" : "Expand")

            AppCardArt(image: model.image(for: game.appID), height: artHeight)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName(for: game.appID))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !game.dlc.isEmpty {
                    Text(game.dlc.count == 1 ? "1 DLC" : "\(game.dlc.count) DLC")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
        }
        .padding(.vertical, AppsModel.artInset)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .contentShape(.rect)
        .appCardSelectable(model: model, appID: game.appID, focusList: focusList)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowDivider()
            ForEach(game.dlc, id: \.self) { dlc in
                AppCardDLCRow(model: model, appID: dlc, artHeight: max(28, artHeight * 0.6),
                              focusList: focusList)
            }
            if !game.dlc.isEmpty { RowDivider() }
            HStack(spacing: 10) {
                Text("App \(String(game.appID))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Properties…", systemImage: "info.circle") {
                    model.openProperties(appID: game.appID)
                }
                .buttonStyle(.glass)
                if model.canOpenOnlineFix(game.appID) {
                    Button("OnlineFix…", systemImage: "network") {
                        model.openInOnlineFixManager(appID: game.appID)
                    }
                    .buttonStyle(.glass)
                }
                Button("Remove", systemImage: "trash", role: .destructive) {
                    model.remove([game.appID])
                }
                .buttonStyle(.glass)
                .help(model.removeTitle(for: [game.appID]))
                .accessibilityLabel(model.removeTitle(for: [game.appID]))
            }
            .padding(14)
        }
    }
}

/// A DLC nested under its game, inside the expanded card.
private struct AppCardDLCRow: View {
    @ObservedObject var model: AppsModel
    let appID: Int
    let artHeight: CGFloat
    let focusList: () -> Void

    private var isSelected: Bool { model.isSelected(appID) }

    var body: some View {
        HStack(spacing: 14) {
            AppCardArt(image: model.image(for: appID), height: artHeight)
            Text(model.displayName(for: appID))
                .font(.system(size: 14, weight: .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.accentColor.opacity(isSelected ? 0.2 : 0), in: .rect(cornerRadius: 14))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .padding(.leading, 30)   // indented under the game, past the chevron
        .contentShape(.rect)
        .appCardSelectable(model: model, appID: appID, focusList: focusList)
        .animation(.smooth(duration: 0.2), value: isSelected)
    }
}

/// Steam header art (460×215) from StoreArtLoader, with a placeholder until it loads.
private struct AppCardArt: View {
    let image: NSImage?
    let height: CGFloat

    var body: some View {
        let width = (height * AppsModel.artAspect).rounded()
        let radius = min(16, max(6, height * 0.16))
        ZStack {
            Rectangle().fill(.primary.opacity(0.07))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: min(22, height * 0.35)))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.primary.opacity(0.08)))
        .animation(.smooth(duration: 0.3), value: image != nil)
        .accessibilityHidden(true)
    }
}

// MARK: - Selection, double-click and context menu

private struct AppCardSelectable: ViewModifier {
    @ObservedObject var model: AppsModel
    let appID: Int
    let focusList: () -> Void

    func body(content: Content) -> some View {
        content
            // Double-click opens Properties; the single click selects straight away.
            .gesture(TapGesture(count: 2).onEnded { model.openProperties(appID: appID) })
            .simultaneousGesture(TapGesture().onEnded {
                model.click(appID, modifiers: NSEvent.modifierFlags)
                focusList()
            })
            .contextMenu { AppCardMenu(model: model, clickedID: appID) }
            .accessibilityAddTraits(model.isSelected(appID) ? [.isSelected] : [])
            .accessibilityAction(named: "Properties") { model.openProperties(appID: appID) }
    }
}

private extension View {
    func appCardSelectable(model: AppsModel, appID: Int, focusList: @escaping () -> Void) -> some View {
        modifier(AppCardSelectable(model: model, appID: appID, focusList: focusList))
    }
}

/// The row context menu: Properties…, OnlineFix…, Remove (for one row or the selection).
private struct AppCardMenu: View {
    @ObservedObject var model: AppsModel
    let clickedID: Int

    var body: some View {
        let targets = model.contextTargets(for: clickedID)
        if targets.count == 1 {
            Button("Properties…") { model.openProperties(appID: targets[0]) }
            Divider()
        }
        if targets.count == 1, model.canOpenOnlineFix(targets[0]) {
            Button("OnlineFix…") { model.openInOnlineFixManager(appID: targets[0]) }
            Divider()
        }
        Button(model.removeTitle(for: targets)) { model.remove(targets) }
    }
}

// MARK: - File > Remove (⌘⌫) bridge

/// File > Remove sends `removeApps:` with a nil target. This responder sits in the main
/// window's responder chain (right after the window) while the Apps page is on screen,
/// so the menu item finds it whatever view has focus, and greys out with no selection.
/// It also answers Edit > Select All when nothing earlier in the chain does.
@MainActor
final class AppsCommandResponder: NSResponder, NSMenuItemValidation {
    var onRemove: () -> Void = {}
    var canRemove: () -> Bool = { false }
    var onSelectAll: () -> Void = {}

    private weak var installedWindow: NSWindow?
    private var hostCount = 0

    @objc func removeApps(_ sender: Any?) {
        onRemove()
    }

    override func selectAll(_ sender: Any?) {
        onSelectAll()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(removeApps(_:)) { return canRemove() }
        return true
    }

    /// Counted, so a page fading out during a page transition can't pull the responder
    /// out from under the page fading in.
    func attach(to window: NSWindow) {
        hostCount += 1
        guard installedWindow == nil else { return }
        nextResponder = window.nextResponder
        window.nextResponder = self
        installedWindow = window
    }

    func detach() {
        hostCount = max(0, hostCount - 1)
        guard hostCount == 0, let window = installedWindow else { return }
        var link: NSResponder? = window
        while let current = link {
            if current.nextResponder === self {
                current.nextResponder = nextResponder
                break
            }
            link = current.nextResponder
        }
        nextResponder = nil
        installedWindow = nil
    }
}

/// Invisible view that puts the page's AppsCommandResponder into its window's responder
/// chain for as long as the page is in the window.
private struct AppsResponderBridge: NSViewRepresentable {
    let responder: AppsCommandResponder

    func makeNSView(context: Context) -> AppsResponderHostView {
        AppsResponderHostView(responder: responder)
    }

    func updateNSView(_ view: AppsResponderHostView, context: Context) {}
}

private final class AppsResponderHostView: NSView {
    private let responder: AppsCommandResponder
    private var attached = false

    init(responder: AppsCommandResponder) {
        self.responder = responder
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if attached, newWindow !== window {
            responder.detach()
            attached = false
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !attached, let window {
            responder.attach(to: window)
            attached = true
        }
    }
}
