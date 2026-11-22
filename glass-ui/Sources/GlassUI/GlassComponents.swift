// Liquid Glass building blocks shared by macSteam, NotProton's pages and OnlineFix's pages.
import AppKit
import SwiftUI

// MARK: - Background

/// Frosted, see-through window background: the desktop and windows behind the app are
/// Gaussian-blurred, with a translucent wash on top — white in light mode, black in dark mode.
public struct FrostedBackground: View {
    @Environment(\.colorScheme) private var scheme

    /// How strong the wash over the blur is. Raise for a more solid frost, lower to see more through it.
    public var lightWash: Double
    public var darkWash: Double

    public init(lightWash: Double = 0.24, darkWash: Double = 0.0) {
        self.lightWash = lightWash
        self.darkWash = darkWash
    }

    public var body: some View {
        BehindWindowBlur()
            .overlay(scheme == .dark ? Color.black.opacity(darkWash) : Color.white.opacity(lightWash))
            .ignoresSafeArea()
    }
}

/// Wraps `NSVisualEffectView` in behind-window mode, which blurs whatever is behind the window.
public struct BehindWindowBlur: NSViewRepresentable {
    public var material: NSVisualEffectView.Material

    public init(material: NSVisualEffectView.Material = .underWindowBackground) {
        self.material = material
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

// MARK: - Layout

/// Scrollable page body with a readable max width.
public struct PageScroll<Content: View>: View {
    public var maxWidth: CGFloat
    public var content: Content

    public init(maxWidth: CGFloat = 760, @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                content
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}

public struct PageHeader<Trailing: View>: View {
    public let title: String
    public var subtitle: String?
    public var trailing: Trailing

    public init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    public init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Cards & rows

/// A titled group of rows on a single glass panel.
public struct GlassSection<Content: View>: View {
    public var title: String?
    public var footer: String?
    public var content: Content

    public init(title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            GlassCard { content }
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

public struct GlassCard<Content: View>: View {
    public var cornerRadius: CGFloat
    public var content: Content

    public init(cornerRadius: CGFloat = 28, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

public struct GlassRow<Accessory: View>: View {
    public let title: String
    public var subtitle: String?
    public var status: StatusKind?
    public var accessory: Accessory

    public init(title: String, subtitle: String? = nil, status: StatusKind? = nil,
                @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: 12) {
            if let status { StatusDot(kind: status) }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(1.5)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 16)
            accessory
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }
}

extension GlassRow where Accessory == EmptyView {
    public init(title: String, subtitle: String? = nil, status: StatusKind? = nil) {
        self.init(title: title, subtitle: subtitle, status: status) { EmptyView() }
    }
}

public struct RowDivider: View {
    public init() {}

    public var body: some View {
        Divider().padding(.leading, 20).opacity(0.5)
    }
}

// MARK: - Status

public enum StatusKind: Sendable {
    case ok, warning, error, inactive

    public var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        case .inactive: .secondary
        }
    }
}

public struct StatusDot: View {
    public let kind: StatusKind

    public init(kind: StatusKind) {
        self.kind = kind
    }

    public var body: some View {
        Circle()
            .fill(kind.color)
            .frame(width: 8, height: 8)
            .shadow(color: kind.color.opacity(0.7), radius: 4)
            .background {
                if kind == .ok {
                    Circle()
                        .fill(kind.color.opacity(0.5))
                        .phaseAnimator([false, true]) { halo, expanded in
                            halo.scaleEffect(expanded ? 2.6 : 1).opacity(expanded ? 0 : 0.8)
                        } animation: { expanded in
                            expanded ? .easeOut(duration: 1.8) : nil
                        }
                }
            }
            .animation(.smooth, value: kind)
    }
}

/// Shows a value, or a dimmed dash when the value hasn't been filled in yet.
public struct ValueText: View {
    public let value: String?

    public init(value: String?) {
        self.value = value
    }

    public var body: some View {
        if let value, !value.isEmpty {
            Text(value).foregroundStyle(.secondary)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Inputs

public struct GlassSearchField: View {
    public let prompt: String
    @Binding public var text: String
    public var large: Bool
    public var onSubmit: () -> Void

    @FocusState private var isFocused: Bool

    public init(prompt: String, text: Binding<String>, large: Bool = false,
                onSubmit: @escaping () -> Void = {}) {
        self.prompt = prompt
        self._text = text
        self.large = large
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: isFocused)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .font(large ? .title3 : .body)
        .padding(.horizontal, large ? 20 : 16)
        .padding(.vertical, large ? 14 : 10)
        .glassEffect(.regular.tint(isFocused ? Color.accentColor.opacity(0.12) : nil).interactive(), in: .capsule)
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(isFocused ? 0.45 : 0), lineWidth: 1))
        .scaleEffect(isFocused ? 1.005 : 1)
        .animation(.smooth(duration: 0.25), value: isFocused)
        .animation(.snappy(duration: 0.2), value: text.isEmpty)
    }
}

/// Text field for use inside a glass card (avoids glass-on-glass).
public struct InsetField: View {
    public let prompt: String
    @Binding public var text: String

    @FocusState private var isFocused: Bool

    public init(prompt: String, text: Binding<String>) {
        self.prompt = prompt
        self._text = text
    }

    public var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.primary.opacity(isFocused ? 0.09 : 0.06), in: .capsule)
            .overlay(
                Capsule().strokeBorder(
                    isFocused ? AnyShapeStyle(Color.accentColor.opacity(0.6)) : AnyShapeStyle(.primary.opacity(0.08)),
                    lineWidth: isFocused ? 1.2 : 1
                )
            )
            .animation(.smooth(duration: 0.2), value: isFocused)
    }
}

// MARK: - Empty states & heroes

public struct GlassEmptyState<Actions: View>: View {
    public let symbol: String
    public let title: String
    public var message: String?
    public var actions: Actions

    @State private var appeared = false

    public init(symbol: String, title: String, message: String? = nil,
                @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 16) {
            GlassIcon(symbol: symbol, size: 76)
                .scaleEffect(appeared ? 1 : 0.8)
                .opacity(appeared ? 1 : 0)
            VStack(spacing: 6) {
                Text(title).font(.title3.weight(.semibold))
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
            }
            actions
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(duration: 0.5, bounce: 0.35).delay(0.08)) { appeared = true }
        }
    }
}

extension GlassEmptyState where Actions == EmptyView {
    public init(symbol: String, title: String, message: String? = nil) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

public struct GlassIcon: View {
    public let symbol: String
    public var size: CGFloat
    public var tint: Color?

    public init(symbol: String, size: CGFloat = 76, tint: Color? = nil) {
        self.symbol = symbol
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .symbolRenderingMode(.hierarchical)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: size, height: size)
            .glassEffect(.regular.tint(tint?.opacity(0.25)), in: .circle)
            .animation(.smooth(duration: 0.35), value: symbol)
    }
}

/// Floating row of glass buttons pinned to the bottom of a page.
public struct GlassActionBar<Content: View>: View {
    public var content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Spacer()
                content
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }
}

/// Centered status hero with a floating action bar (Install, Repair Steam).
public struct HeroPage<Actions: View>: View {
    public let symbol: String
    public let tint: Color?
    public let title: String
    public var subtitle: String
    public var footnote: String
    public var isBusy: Bool
    public var actions: Actions

    public init(symbol: String, tint: Color?, title: String, subtitle: String = "",
                footnote: String = "", isBusy: Bool = false,
                @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.footnote = footnote
        self.isBusy = isBusy
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 18) {
            GlassIcon(symbol: symbol, size: 112, tint: tint)
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isBusy)
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .contentTransition(.interpolate)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .transition(.opacity)
                }
                if !footnote.isEmpty {
                    Text(footnote)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .contentTransition(.numericText())
                        .transition(.opacity)
                }
            }
        }
        .padding(32)
        .animation(.smooth(duration: 0.4), value: title)
        .animation(.smooth(duration: 0.4), value: subtitle)
        .animation(.smooth(duration: 0.4), value: footnote)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GlassActionBar {
                if isBusy {
                    ProgressView().controlSize(.small).transition(.opacity)
                }
                actions
            }
            .animation(.smooth, value: isBusy)
        }
    }
}

// MARK: - Artwork

/// Steam header-style artwork (460×215) with a placeholder until an image URL is supplied.
public struct Artwork: View {
    public var url: URL?
    public var width: CGFloat
    public var cornerRadius: CGFloat
    public var placeholderSymbol: String

    public init(url: URL? = nil, width: CGFloat = 150, cornerRadius: CGFloat = 14,
                placeholderSymbol: String = "gamecontroller") {
        self.url = url
        self.width = width
        self.cornerRadius = cornerRadius
        self.placeholderSymbol = placeholderSymbol
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(.primary.opacity(0.07))
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: width * 215 / 460)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.08)))
    }

    private var placeholder: some View {
        Image(systemName: placeholderSymbol)
            .font(.system(size: width * 0.16))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Motion

/// Page change: the new page rises in from a soft blur while the old one dissolves.
public struct PageTransition: Transition {
    public init() {}

    public func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .blur(radius: phase.isIdentity ? 0 : 10)
            .scaleEffect(phase == .willAppear ? 0.985 : (phase == .didDisappear ? 1.01 : 1))
            .offset(y: phase == .willAppear ? 12 : 0)
    }
}

/// Subtle lift on hover for clickable cards and list rows.
public struct HoverLift: ViewModifier {
    @State private var isHovering = false

    public init() {}

    public func body(content: Content) -> some View {
        content
            .scaleEffect(isHovering ? 1.008 : 1)
            .shadow(color: .black.opacity(isHovering ? 0.16 : 0), radius: isHovering ? 14 : 0, y: isHovering ? 6 : 0)
            .animation(.smooth(duration: 0.22), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// Subtle lift on hover for clickable cards and list rows.
    @MainActor public func hoverLift() -> some View { modifier(HoverLift()) }
}
