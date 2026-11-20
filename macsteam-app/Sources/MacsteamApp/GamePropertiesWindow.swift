// Per-game Properties window: OnlineFix and the LuaTools game fixes in two tabs,
// each with install and uninstall. Opened from the Apps list.
import AppKit
import OnlineFixApp

final class PropertyActionButton: NSButton {
    private var handler: (() -> Void)?

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(fire)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler?() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class GamePropertiesWindowController: NSWindowController {

    private let appID: Int
    private let gameName: String
    private let store: ConfigStore
    private let luaFixes = HubcapStoreFixes()

    // OnlineFix tab
    private let onlineState = NSTextField(labelWithString: "")
    private let onlineMessage = NSTextField(wrappingLabelWithString: "")
    private let onlineRecommend = NSTextField(wrappingLabelWithString: "")
    private let onlineSpinner = NSProgressIndicator()
    private let onlineInstall = PropertyActionButton(title: "Install OnlineFix") {}
    private let onlineUninstall = PropertyActionButton(title: "Uninstall") {}
    private var onlineBusy = false

    // LuaTools tab
    private let luaState = NSTextField(labelWithString: "")
    private let luaMessage = NSTextField(wrappingLabelWithString: "")
    private let luaList = NSStackView()
    private weak var luaRefreshButton: NSButton?
    private var luaBusy = false

    init(appID: Int, gameName: String, store: ConfigStore) {
        self.appID = appID
        self.gameName = gameName
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Properties — \(gameName)"
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 560, height: 440)
        super.init(window: window)
        window.contentViewController = makeTabs()
        window.center()
        refreshOnlineFix()
        refreshLuaFixes()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Tabs

    private func makeTabs() -> NSTabViewController {
        let tabs = NSTabViewController()
        tabs.tabStyle = .segmentedControlOnTop
        // LuaTools fixes first, OnlineFix second.
        tabs.addTabViewItem(NSTabViewItem(viewController: makeLuaTab()))
        tabs.addTabViewItem(NSTabViewItem(viewController: makeOnlineTab()))
        tabs.tabViewItems[0].label = "LuaTools Fixes"
        tabs.tabViewItems[1].label = "OnlineFix"
        tabs.selectedTabViewItemIndex = 0
        return tabs
    }

    private func makeOnlineTab() -> NSViewController {
        let vc = NSViewController()
        let root = NSView()
        vc.view = root

        let title = makeLabel(gameName, size: 15, weight: .semibold)
        onlineState.font = .systemFont(ofSize: 12, weight: .medium)
        onlineMessage.font = .systemFont(ofSize: 11)
        onlineMessage.textColor = .secondaryLabelColor

        onlineSpinner.style = .spinning
        onlineSpinner.controlSize = .small
        onlineSpinner.isDisplayedWhenStopped = false

        onlineInstall.target = self
        onlineInstall.action = #selector(installOnlineFix)
        onlineUninstall.target = self
        onlineUninstall.action = #selector(uninstallOnlineFix)
        let manager = PropertyActionButton(title: "Open in OnlineFix Manager…") { [weak self] in
            self?.openInManager()
        }
        let buttons = NSStackView(views: [onlineInstall, onlineUninstall, onlineSpinner, NSView(), manager])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(wrappingLabelWithString:
            "Install downloads the game's fix from online-fix.me and installs it. "
            + "Uninstall restores the files the fix replaced and deletes the ones it added. "
            + "Routing through AppID 480 is set up automatically.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        onlineMessage.translatesAutoresizingMaskIntoConstraints = false

        onlineRecommend.font = .systemFont(ofSize: 11)
        onlineRecommend.textColor = .systemGreen
        onlineRecommend.isHidden = true
        onlineRecommend.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, onlineState, buttons, onlineMessage,
                                        onlineRecommend, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            onlineMessage.widthAnchor.constraint(equalTo: stack.widthAnchor),
            onlineRecommend.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return vc
    }

    private func makeLuaTab() -> NSViewController {
        let vc = NSViewController()
        let root = NSView()
        vc.view = root

        let title = makeLabel("LuaTools fixes for \(gameName)", size: 15, weight: .semibold)
        luaState.font = .systemFont(ofSize: 12, weight: .medium)
        luaMessage.font = .systemFont(ofSize: 11)
        luaMessage.textColor = .secondaryLabelColor
        luaMessage.translatesAutoresizingMaskIntoConstraints = false

        let refresh = PropertyActionButton(title: "Refresh") { [weak self] in
            self?.refreshLuaFixes()
        }
        luaRefreshButton = refresh
        let header = NSStackView(views: [title, NSView(), refresh])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        luaList.orientation = .vertical
        luaList.alignment = .leading
        luaList.spacing = 10
        luaList.translatesAutoresizingMaskIntoConstraints = false
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(luaList)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content

        let stack = NSStackView(views: [header, luaState, scroll, luaMessage])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            luaMessage.widthAnchor.constraint(equalTo: stack.widthAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            luaList.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            luaList.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            luaList.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            luaList.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -4),
        ])
        return vc
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        return label
    }

    // MARK: - OnlineFix

    private func refreshOnlineFix() {
        let status = OnlineFixEmbed.storeStatus(appID: appID)
        var text: String
        if status.fixInstalled {
            text = "OnlineFix is installed."
        } else if status.inList {
            text = "In My Games, but its fix is not installed."
        } else {
            text = "Not in My Games yet. Installing adds it."
        }
        if !status.gameInstalled {
            text += " The game folder was not found — install the game in Steam first."
        }
        onlineState.stringValue = text
        onlineState.textColor = status.fixInstalled ? .systemGreen
            : (status.gameInstalled ? .secondaryLabelColor : .systemOrange)
        onlineInstall.title = status.fixInstalled ? "Reinstall OnlineFix" : "Install OnlineFix"
        onlineInstall.isEnabled = status.gameInstalled && !onlineBusy
        onlineUninstall.isEnabled = status.fixInstalled && !onlineBusy
    }

    @objc private func installOnlineFix() {
        guard !onlineBusy else { return }
        onlineBusy = true
        onlineSpinner.startAnimation(nil)
        onlineMessage.textColor = .secondaryLabelColor
        onlineMessage.stringValue = "Starting…"
        refreshOnlineFix()
        let name = gameName
        Task { @MainActor in
            let outcome = await OnlineFixEmbed.storeInstall(appID: self.appID, name: name) { [weak self] text in
                Task { @MainActor in self?.onlineMessage.stringValue = text }
            }
            self.onlineBusy = false
            self.onlineSpinner.stopAnimation(nil)
            self.onlineMessage.textColor = outcome.error == nil ? .systemGreen : .systemOrange
            self.onlineMessage.stringValue = outcome.message ?? outcome.error ?? ""
            self.refreshOnlineFix()
        }
    }

    @objc private func uninstallOnlineFix() {
        let outcome = OnlineFixEmbed.storeUninstall(appID: appID)
        onlineMessage.textColor = outcome.error == nil ? .systemGreen : .systemOrange
        onlineMessage.stringValue = outcome.message ?? outcome.error ?? ""
        refreshOnlineFix()
    }

    private func openInManager() {
        OnlineFixEmbed.prepareGame(appID: appID, name: gameName)
        NotificationCenter.default.post(
            name: OnlineFixHandoff.notification, object: nil,
            userInfo: [OnlineFixHandoff.appIDKey: appID])
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - LuaTools fixes

    private func refreshLuaFixes() {
        guard !luaBusy else { return }
        luaBusy = true
        luaRefreshButton?.isEnabled = false
        luaState.textColor = .secondaryLabelColor
        luaState.stringValue = "Loading…"
        Task { @MainActor in
            let reply = await self.luaFixes.list(appID: self.appID)
            self.luaBusy = false
            self.luaRefreshButton?.isEnabled = true
            self.renderLua(reply)
        }
    }

    private func renderLua(_ reply: [String: Any]) {
        for view in luaList.arrangedSubviews {
            luaList.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let error = reply["error"] as? String {
            luaState.textColor = .systemOrange
            luaState.stringValue = error
            return
        }
        // A LuaTools fix patches the game's Windows DLLs; Steam runs the native Mac
        // build when it has one, so the fix has nothing to patch.
        if reply["nativeMac"] as? Bool == true {
            luaState.textColor = .secondaryLabelColor
            luaState.stringValue = "No LuaTools fixes: Steam has a native macOS build of this "
                + "game, so LuaTools' Windows fixes do not apply."
            updateOnlineRecommendation([])
            return
        }
        let gameInstalled = reply["gameInstalled"] as? Bool ?? false
        let manifestInstalled = reply["manifestInstalled"] as? Bool ?? false
        let fixes = reply["fixes"] as? [[String: Any]] ?? []
        updateOnlineRecommendation(fixes)
        luaState.textColor = .secondaryLabelColor
        if fixes.isEmpty {
            luaState.stringValue = "No LuaTools fixes for this game."
            return
        }
        luaState.stringValue = gameInstalled
            ? "\(fixes.count) available"
            : "\(fixes.count) available — install the game in Steam first"
        luaState.textColor = gameInstalled ? .secondaryLabelColor : .systemOrange
        for fix in fixes {
            luaList.addArrangedSubview(luaRow(fix, gameInstalled: gameInstalled,
                                              manifestInstalled: manifestInstalled))
        }
    }

    /// LuaTools' own OnlineFix is the same fix, installed and tracked by LuaTools, so
    /// the OnlineFix tab recommends it instead of installing a second copy.
    private func updateOnlineRecommendation(_ fixes: [[String: Any]]) {
        guard let online = fixes.first(where: { $0["onlineFix"] as? Bool == true }) else {
            onlineRecommend.isHidden = true
            onlineRecommend.stringValue = ""
            return
        }
        let applied = online["applied"] as? Bool ?? false
        onlineRecommend.isHidden = false
        onlineRecommend.stringValue = "LuaTools has a version of OnlineFix for this game"
            + (applied ? " (installed)" : "") + ". we recommend using that one instead of this "
            + "OnlineFix. It is the same fix, but our OnlineFix isn't always stable/working."
    }

    private func luaRow(_ fix: [String: Any], gameInstalled: Bool,
                        manifestInstalled: Bool) -> NSView {
        let title = makeLabel(fix["title"] as? String ?? "Fix", size: 12.5, weight: .semibold)
        let text = NSStackView(views: [title])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        if let description = fix["description"] as? String, !description.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: description)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            text.addArrangedSubview(detail)
        }
        if (fix["onlineFix"] as? Bool) == true {
            let note = NSTextField(wrappingLabelWithString:
                "Includes the OnlineFix — we recommend this one over the OnlineFix tab.")
            note.font = .systemFont(ofSize: 10)
            note.textColor = .systemGreen
            text.addArrangedSubview(note)
        }
        if (fix["drifted"] as? Bool) == true {
            let note = NSTextField(wrappingLabelWithString:
                "Some files changed since it was installed (a game update?).")
            note.font = .systemFont(ofSize: 10)
            note.textColor = .systemOrange
            text.addArrangedSubview(note)
        }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 6

        let fixID = fix["id"] as? String ?? ""
        let hasManifest = fix["hasManifest"] as? Bool ?? false
        let hasFix = fix["hasFix"] as? Bool ?? false
        let applied = fix["applied"] as? Bool ?? false
        let drifted = fix["drifted"] as? Bool ?? false

        if hasManifest {
            let install = PropertyActionButton(title: manifestInstalled ? "Manifest installed" : "Install manifest") { [weak self] in
                self?.runLua("fix-manifest", fixID: fixID)
            }
            install.isEnabled = !manifestInstalled && !luaBusy
            buttons.addArrangedSubview(install)
        }
        if hasFix && (!applied || drifted) {
            let install = PropertyActionButton(title: drifted ? "Reinstall fix" : "Install fix") { [weak self] in
                self?.runLua("fix-install", fixID: fixID)
            }
            install.isEnabled = gameInstalled && !luaBusy
            buttons.addArrangedSubview(install)
        }
        if applied {
            let remove = PropertyActionButton(title: "Uninstall") { [weak self] in
                self?.runLua("fix-undo", fixID: fixID)
            }
            remove.isEnabled = !luaBusy
            buttons.addArrangedSubview(remove)
        }

        let row = NSStackView(views: [text, NSView(), buttons])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func runLua(_ action: String, fixID: String) {
        guard !luaBusy else { return }
        luaBusy = true
        luaRefreshButton?.isEnabled = false
        luaMessage.textColor = .secondaryLabelColor
        luaMessage.stringValue = "Working…"
        Task { @MainActor in
            let reply = await self.luaFixes.perform(action, appID: self.appID, fixID: fixID)
            self.luaBusy = false
            self.luaRefreshButton?.isEnabled = true
            if let error = reply["error"] as? String {
                self.luaMessage.textColor = .systemOrange
                self.luaMessage.stringValue = error
                return
            }
            self.renderLua(reply)
            self.luaMessage.textColor = .systemGreen
            self.luaMessage.stringValue = reply["message"] as? String ?? ""
        }
    }
}
