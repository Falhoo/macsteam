import GlassUI
import SwiftUI

// MARK: - Sidebar

struct Sidebar: View {
    @Binding var selection: Page?
    @Namespace private var selectionNamespace
    @State private var hovered: Page?

    private let allPages = SidebarSection.allCases.flatMap(\.pages)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                brand
                ForEach(SidebarSection.allCases) { section in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.rawValue)
                            .font(.caption2.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(0.8)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 3)
                        ForEach(section.pages) { row(for: $0) }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(.downArrow) { step(1); return .handled }
    }

    private var brand: some View {
        BrandHeader()
    }

    private func row(for page: Page) -> some View {
        let isSelected = selection == page
        let isHovered = hovered == page && !isSelected

        return Button {
            select(page)
        } label: {
            HStack(spacing: 10) {
                SidebarIconTile(symbol: page.symbol, tint: page.tint, size: 22)
                    .symbolEffect(.bounce, value: isSelected)
                Text(page.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(.rect(cornerRadius: 12))
            .background {
                if isSelected {
                    // One shared glass pill that slides between rows.
                    Color.clear
                        .glassEffect(.regular.tint(page.tint.opacity(0.18)).interactive(), in: .rect(cornerRadius: 12))
                        .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.primary.opacity(0.06))
                        .transition(.opacity)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) {
                if inside { hovered = page } else if hovered == page { hovered = nil }
            }
        }
    }

    private func select(_ page: Page) {
        withAnimation(.spring(duration: 0.4, bounce: 0.22)) { selection = page }
    }

    private func step(_ delta: Int) {
        let current = allPages.firstIndex(of: selection ?? .store) ?? 0
        let next = min(max(current + delta, 0), allPages.count - 1)
        select(allPages[next])
    }
}

/// "macSteam" title. Clicking it shows the fork credits in a popover.
struct BrandHeader: View {
    @State private var showingCredits = false
    @State private var isHovering = false

    var body: some View {
        Button {
            showingCredits.toggle()
        } label: {
            HStack(spacing: 10) {
                SidebarIconTile(symbol: "smoke.fill", tint: .teal, size: 28)
                    .symbolEffect(.bounce, value: showingCredits)
                Text("macSteam")
                    .font(.system(.headline, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(.rect(cornerRadius: 12))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.primary.opacity(isHovering ? 0.06 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = inside }
        }
        .popover(isPresented: $showingCredits, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("macSteam")
                    .font(.system(.headline, design: .rounded))
                Text("Forked version by @Falhoo and @SkillzNoLogic")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(16)
        }
    }
}

/// Coloured rounded-square icon, in the style of System Settings.
struct SidebarIconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: symbol)
            .symbolVariant(.fill)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [tint, tint.opacity(0.72)], startPoint: .top, endPoint: .bottom),
                in: .rect(cornerRadius: size * 0.3, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            )
            .shadow(color: tint.opacity(0.3), radius: 3, y: 1)
    }
}
