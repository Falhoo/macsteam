// The Liquid Glass window shell: frosted background, sidebar, light/dark toggle and
// animated page changes. Each page is still macSteam's own view controller, hosted
// inside the shell (see PageControllers in MainViewController.swift).

import AppKit
import GlassUI
import SwiftUI

// MARK: - Pages

enum Page: String, CaseIterable, Identifiable, Hashable {
    case store, fixes, importApps, apps
    case myGames, addGames
    case install, repairSteam, settings, cloudSaves
    case status, prefixes, prefixBackups

    var id: Self { self }

    var title: String {
        switch self {
        case .store: "Store"
        case .fixes: "Fixes"
        case .importApps: "Import Apps"
        case .apps: "Apps"
        case .myGames: "My Games"
        case .addGames: "Add Games"
        case .install: "Install"
        case .repairSteam: "Repair Steam"
        case .settings: "Settings"
        case .cloudSaves: "Cloud Saves"
        case .status: "Status"
        case .prefixes: "Prefixes"
        case .prefixBackups: "Prefix Backups"
        }
    }

    var tint: Color {
        switch self {
        case .store: .blue
        case .fixes: .red
        case .importApps: .green
        case .apps: .indigo
        case .myGames: .orange
        case .addGames: .yellow
        case .install: .blue
        case .repairSteam: .gray
        case .settings: .gray
        case .cloudSaves: .cyan
        case .status: .green
        case .prefixes: .purple
        case .prefixBackups: .pink
        }
    }

    var symbol: String {
        switch self {
        case .store: "cart"
        case .fixes: "cross.case"
        case .importApps: "square.and.arrow.down"
        case .apps: "square.grid.2x2"
        case .myGames: "gamecontroller"
        case .addGames: "plus.square.on.square"
        case .install: "shield.lefthalf.filled"
        case .repairSteam: "wrench.and.screwdriver"
        case .settings: "gearshape"
        case .cloudSaves: "icloud"
        case .status: "checklist"
        case .prefixes: "externaldrive"
        case .prefixBackups: "externaldrive.badge.timemachine"
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case library = "Library"
    case onlineFix = "OnlineFix"
    case macSteam = "macSteam"
    case notProton = "NotProton"

    var id: Self { self }

    var pages: [Page] {
        switch self {
        case .library: [.store, .fixes, .importApps, .apps]
        case .onlineFix: [.myGames, .addGames]
        case .macSteam: [.install, .repairSteam, .settings, .cloudSaves]
        case .notProton: [.status, .prefixes, .prefixBackups]
        }
    }
}

// MARK: - Appearance

enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark

    static let storageKey = "glassUIAppearance"

    /// The choice saved by the sidebar toggle (dark until the user picks).
    static var stored: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .dark
    }

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String { self == .light ? "sun.max.fill" : "moon.fill" }
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
    var nsAppearance: NSAppearance? { NSAppearance(named: self == .dark ? .darkAqua : .aqua) }
}

// MARK: - Shell

@MainActor
final class ShellModel: ObservableObject {
    @Published private(set) var selection: Page = .store
    let pages: PageControllers

    init(pages: PageControllers) {
        self.pages = pages
        pages.willShow(selection, leaving: nil)
    }

    func select(_ page: Page) {
        guard page != selection else { return }
        pages.willShow(page, leaving: selection)
        selection = page
    }
}

struct GlassShell: View {
    @ObservedObject var model: ShellModel
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .dark

    var body: some View {
        // Visibility is pinned to .all so the sidebar can never be collapsed.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            Sidebar(selection: selection)
                // Inside an AppKit window the split view ignores the ideal width, so pin it.
                .frame(minWidth: 220, idealWidth: 236, maxWidth: 290)
                .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 290)
                .toolbar(removing: .sidebarToggle)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    AppearanceToggle(appearance: $appearance)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                        .padding(.top, 4)
                }
        } detail: {
            let page = model.selection
            ZStack {
                pageView(page)
                    .id(page)
                    .transition(PageTransition())
            }
            .animation(.smooth(duration: 0.38), value: page)
            .navigationTitle(page.title)
            .background { FrostedBackground() }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .preferredColorScheme(appearance.colorScheme)
    }

    @ViewBuilder
    private func pageView(_ page: Page) -> some View {
        switch model.pages.content(for: page) {
        case .native(let view): view
        case .hosted(let controller): HostedPage(controller: controller)
        }
    }

    private var selection: Binding<Page?> {
        Binding(
            get: { model.selection },
            set: { if let page = $0 { model.select(page) } }
        )
    }
}

// MARK: - Hosting macSteam's view controllers

/// Shows one of macSteam's existing view controllers inside the SwiftUI shell.
struct HostedPage: NSViewControllerRepresentable {
    let controller: NSViewController

    func makeNSViewController(context: Context) -> PageContainer {
        PageContainer(hosting: controller)
    }

    func updateNSViewController(_ container: PageContainer, context: Context) {}

    static func dismantleNSViewController(_ container: PageContainer, coordinator: ()) {
        container.release()
    }
}

/// A fresh container per appearance, so the long-lived page controller can move from the
/// outgoing container to the incoming one even while a transition is running.
final class PageContainer: NSViewController {
    private let page: NSViewController

    init(hosting page: NSViewController) {
        self.page = page
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        attach()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        attach()
    }

    private func attach() {
        guard page.parent !== self else { return }
        page.view.removeFromSuperview()
        page.removeFromParent()
        addChild(page)
        let pageView = page.view
        pageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.topAnchor.constraint(equalTo: view.topAnchor),
            pageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Gives the page back, unless a newer container has already taken it.
    func release() {
        guard page.parent === self else { return }
        page.view.removeFromSuperview()
        page.removeFromParent()
    }
}

// MARK: - Light / dark toggle

/// Light / dark switch pinned to the bottom of the sidebar.
struct AppearanceToggle: View {
    @Binding var appearance: AppAppearance

    private let options = AppAppearance.allCases
    private var selectedIndex: Int { options.firstIndex(of: appearance) ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isSelected = appearance == option
                Button {
                    select(option)
                } label: {
                    Label(option.title, systemImage: option.symbol)
                        .font(.callout.weight(.medium))
                        .symbolEffect(.bounce, value: isSelected)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        // Sliding selection pill.
        .background(alignment: .leading) {
            GeometryReader { proxy in
                let segment = proxy.size.width / CGFloat(options.count)
                Capsule()
                    .fill(.primary.opacity(0.12))
                    .frame(width: segment)
                    .offset(x: segment * CGFloat(selectedIndex))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.25), value: appearance)
        .padding(4)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func select(_ option: AppAppearance) {
        guard option != appearance else { return }
        AppearanceTransition.crossfade(to: option)
        appearance = option
    }
}

/// Cross-fades the whole window (title bar included) between light and dark.
@MainActor
enum AppearanceTransition {
    static func crossfade(to option: AppAppearance, duration: CFTimeInterval = 0.45) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        // The theme frame is the content view's superview; fading it covers the toolbar too.
        if let layer = (window.contentView?.superview ?? window.contentView)?.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "appearanceCrossfade")
        }
        // Switch now, in the same transaction as the fade. Set app-wide so every window
        // (Properties, Cloud Redirect) follows, not just the main one.
        NSApp.appearance = option.nsAppearance
    }
}
