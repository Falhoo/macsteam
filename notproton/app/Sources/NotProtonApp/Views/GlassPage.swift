// macSteam + NotProton: Liquid Glass pieces shared by NotProton's pages.

import GlassUI
import SwiftUI

extension EnvironmentValues {
    // True when the page is hosted somewhere that does not bridge SwiftUI toolbar items into the
    // window toolbar (NotProtonEmbed.viewController(for:)). The page's toolbar buttons are then
    // shown in a glass bar at the top of the page instead.
    @Entry var notProtonInlineToolbar = false
}

extension View {
    // A page's primary toolbar: the page's own action buttons, a gap, then Refresh.
    func pageToolbar<Actions: View, Refresh: View>(
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder refresh: () -> Refresh
    ) -> some View {
        modifier(PageToolbar(actions: actions(), refresh: refresh()))
    }

    func pageToolbar<Refresh: View>(@ViewBuilder refresh: () -> Refresh) -> some View {
        pageToolbar(actions: { EmptyView() }, refresh: refresh)
    }
}

private struct PageToolbar<Actions: View, Refresh: View>: ViewModifier {
    @Environment(\.notProtonInlineToolbar) private var inline

    let actions: Actions
    let refresh: Refresh

    private var hasActions: Bool { Actions.self != EmptyView.self }

    @ViewBuilder
    func body(content: Content) -> some View {
        if inline {
            content.safeAreaInset(edge: .top, spacing: 0) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        actions
                        if hasActions { Spacer().frame(width: 6) }
                        refresh
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .menuStyle(.button)
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
        } else {
            content.toolbar {
                if #available(macOS 26.1, *) {
                    PrimaryItems(hasActions: hasActions, actions: actions, refresh: refresh)
                        .visibilityPriority(.high)
                } else {
                    PrimaryItems(hasActions: hasActions, actions: actions, refresh: refresh)
                }
            }
        }
    }
}

private struct PrimaryItems<Actions: View, Refresh: View>: ToolbarContent {
    let hasActions: Bool
    let actions: Actions
    let refresh: Refresh

    var body: some ToolbarContent {
        if hasActions {
            ToolbarItemGroup(placement: .primaryAction) { actions }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) { refresh }
    }
}

// A table on a single glass panel, with an optional caption above it.
struct GlassTablePanel<Content: View>: View {
    private let caption: String?
    private let content: Content

    init(caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .padding(.leading, 8)
                    .transition(.opacity)
            }
            content
                .tableStyle(.inset)
                .scrollContentBackground(.hidden)
                .padding(6)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
        .padding(24)
        .animation(.smooth, value: caption)
    }
}

// The Done / Failed line pinned to the bottom of the Prefixes and Prefix Backups pages.
struct ReportBanner: View {
    let row: StatusRow

    var body: some View {
        row
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// Inserts a row divider between each of the rows it is given.
struct DividedRows<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Group(subviews: content) { rows in
            ForEach(rows) { row in
                if row.id != rows.first?.id { RowDivider() }
                row
            }
        }
    }
}

// The status card at the top of the Status page (Failed, Done, a running task).
struct StatusBanner<Accessory: View>: View {
    enum Icon {
        case symbol(String, Color?)
        case progress
    }

    let icon: Icon
    let title: String
    var message: String?
    let accessory: Accessory

    init(icon: Icon, title: String, message: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.icon = icon
        self.title = title
        self.message = message
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 16) {
            switch icon {
            case .symbol(let symbol, let tint):
                GlassIcon(symbol: symbol, size: 48, tint: tint)
                    .accessibilityHidden(true)
            case .progress:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 48, height: 48)
                    .glassEffect(.regular, in: .circle)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.interpolate)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
        .accessibilityElement(children: .contain)
    }
}

extension StatusBanner where Accessory == EmptyView {
    init(icon: Icon, title: String, message: String? = nil) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}
