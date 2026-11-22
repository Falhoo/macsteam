// Store page: one tab for every Lua source. The toolbar picker mirrors Settings → Lua
// source and swaps the content between the LuaTools Steam search and the Hubcap catalog.
// Logic ported from the old StoreViewController; the two sources live in
// StorePage+LuaTools.swift and StorePage+Hubcap.swift.
import AppKit
import Combine
import GlassUI
import SwiftUI

@MainActor
final class StoreModel: ObservableObject {
    let luaTools: LuaToolsStoreModel
    let hubcap: HubcapStoreModel

    @Published private(set) var provider = LuaProvider.current

    private var subscriptions: Set<AnyCancellable> = []

    init(store: ConfigStore, onConfigChanged: @escaping @MainActor () -> Void) {
        luaTools = LuaToolsStoreModel(store: store, onConfigChanged: onConfigChanged)
        hubcap = HubcapStoreModel(store: store, onConfigChanged: onConfigChanged)
        // Settings changes the source too, so follow the shared notification.
        NotificationCenter.default.publisher(for: LuaProvider.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.providerDidChange() }
            .store(in: &subscriptions)
    }

    /// Re-reads config.yaml after another page (or an add here) changed it.
    func reloadFromStore() {
        luaTools.reloadFromStore()
        hubcap.refreshInstalledState()
    }

    func setProvider(_ provider: LuaProvider) {
        // The setter posts didChange, which swaps the content.
        LuaProvider.current = provider
    }

    private func providerDidChange() {
        provider = LuaProvider.current
        luaTools.providerDidChange()
    }
}

struct StorePage: View {
    @ObservedObject var model: StoreModel

    var body: some View {
        Group {
            switch model.provider {
            case .luaTools:
                LuaToolsStoreView(model: model.luaTools).transition(.blurReplace)
            case .hubcap:
                HubcapStoreView(model: model.hubcap).transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.35), value: model.provider)
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Lua source", selection: Binding(get: { model.provider },
                                                        set: { model.setProvider($0) })) {
                    ForEach(LuaProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Lua source")
            }
        }
    }
}

// MARK: - Shared pieces

/// What a list shows while it has no rows.
struct StoreEmptyInfo: Equatable {
    var symbol: String
    var title: String
    var message: String?
}

/// Small glass capsule for a count or quota.
struct StoreCountPill: View {
    let symbol: String
    let text: String
    var tint: Color? = nil

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.snappy, value: text)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .fixedSize()
    }
}

/// Status icon + text (+ spinner), toned like the AppKit pages' status labels.
struct StoreStatusLine: View {
    let text: String
    let tone: StatusTone
    var isBusy = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tone.symbol)
                .foregroundStyle(tone.glassTint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(tone == .bad ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .font(.callout)
        .animation(.smooth(duration: 0.25), value: text)
        .animation(.smooth(duration: 0.25), value: tone)
        .animation(.smooth(duration: 0.25), value: isBusy)
    }
}

/// Where a row's header art comes from.
enum StoreArtSource: Hashable {
    /// A Steam CDN URL, loaded through SteamStoreClient's disk cache.
    case steam(String)
    /// Any URL (Hubcap's header art), fetched directly and kept in memory.
    case remote(URL)
}

@MainActor
private enum StoreArtCache {
    static let remoteImages = NSCache<NSURL, NSImage>()
}

/// Steam header-style artwork (460×215) with a placeholder until the image arrives.
struct StoreArtwork: View {
    var source: StoreArtSource?
    var width: CGFloat = 120
    var cornerRadius: CGFloat = 14

    @State private var image: NSImage?
    @State private var loadedFor: StoreArtSource?

    var body: some View {
        ZStack {
            Rectangle().fill(.primary.opacity(0.07))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "gamecontroller")
                    .font(.system(size: width * 0.16))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: width, height: width * 215 / 460)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.08)))
        .animation(.smooth(duration: 0.25), value: image != nil)
        .accessibilityHidden(true)
        .task(id: source) { await load() }
    }

    private func load() async {
        guard loadedFor != source || image == nil else { return }
        if loadedFor != source { image = nil }
        loadedFor = source
        switch source {
        case nil:
            return
        case .steam(let url):
            let data = await SteamStoreClient.shared.imageData(for: url)
            guard !Task.isCancelled, let data else { return }
            image = StoreArtLoader.decode(data, targetWidth: width * 2)
        case .remote(let url):
            // Never block first paint on remote art: memory cache first, then fetch shortly
            // after the row has rendered (as the old Hubcap rows did).
            if let cached = StoreArtCache.remoteImages.object(forKey: url as NSURL) {
                image = cached
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled,
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled,
                  let fetched = NSImage(data: data) else { return }
            StoreArtCache.remoteImages.setObject(fetched, forKey: url as NSURL)
            image = fetched
        }
    }
}

/// One game in a result list: art, name, ID line and trailing actions on a glass row.
struct StoreGameRow<Trailing: View>: View {
    let title: String
    let subtitle: String
    var art: StoreArtSource?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 16) {
            StoreArtwork(source: art, width: 120)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .hoverLift()
        .accessibilityElement(children: .contain)
    }
}
