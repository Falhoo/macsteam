// Cloud Saves pane: CloudRedirect's runtime inside Steam, and where it syncs.
//
// This is macSteam's own page. CloudRedirect's app (providers, sign-in, games,
// backups, migration) opens in a window of its own from here, because the OAuth
// and credential forms live there.

import AppKit
import CloudRedirectSupport

final class CloudSavesViewController: NSViewController {

    private enum Provider: String, CaseIterable {
        case local
        case folder
        case gdrive
        case oneDrive = "onedrive"
        case r2
        case s3

        var title: String {
            switch self {
            case .local: return "Local storage"
            case .folder: return "Custom folder"
            case .gdrive: return "Google Drive"
            case .oneDrive: return "OneDrive"
            case .r2: return "Cloudflare R2"
            case .s3: return "S3-compatible"
            }
        }

        var detail: String {
            switch self {
            case .local: return "Saves stay on this Mac; Steam Cloud requests are answered locally."
            case .folder: return "Saves sync to a folder you choose, such as a network share."
            case .gdrive: return "Saves sync to your Google Drive account."
            case .oneDrive: return "Saves sync to your OneDrive account."
            case .r2: return "Saves sync to a Cloudflare R2 bucket."
            case .s3: return "Saves sync to an S3-compatible bucket."
            }
        }

        var needsSetup: Bool { [.gdrive, .oneDrive, .r2, .s3].contains(self) }
    }

    private let runtimeLabel = NSTextField(labelWithString: "")
    private let providerPopup = NSPopUpButton()
    private let providerDetail = NSTextField(labelWithString: "")
    private let folderField = NSTextField(string: "")
    private var folderCard: SettingsCard!
    private var setupButton: NSButton!
    private var installButton: NSButton!
    private var removeButton: NSButton!

    override func loadView() {
        let root = makeScrollView()
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        root.documentView = content

        let title = NSTextField(labelWithString: "Cloud Saves")
        title.font = Typography.largeTitle
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString:
            "CloudRedirect makes Steam Cloud work for games macSteam unlocks: the client "
            + "sees normal cloud saves, and the bytes live in the account or folder you "
            + "choose. macSteam installs its runtime into Steam and keeps its own older "
            + "save snapshots switched off.")
        subtitle.font = Typography.caption
        subtitle.textColor = Colors.secondaryText
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 0
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        // Runtime
        runtimeLabel.font = Typography.body
        runtimeLabel.textColor = Colors.secondaryText
        runtimeLabel.lineBreakMode = .byTruncatingTail
        runtimeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        runtimeLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true

        installButton = makeButton(title: "Install in Steam", target: self, action: #selector(installRuntime))
        removeButton = makeButton(title: "Remove from Steam", target: self, action: #selector(removeRuntime))

        let runtimeCard = SettingsCard(rows: [
            SettingRow(title: "CloudRedirect runtime",
                       subtitle: "The dylib and credential helper Steam loads. Install adds them "
                           + "beside macSteam's own dylib and restarts nothing.",
                       control: installButton),
            SettingRow(title: "Status", control: runtimeLabel),
            SettingRow(title: "Remove it from Steam", control: removeButton),
        ])

        // Provider
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        for provider in Provider.allCases {
            providerPopup.addItem(withTitle: provider.title)
            providerPopup.lastItem?.representedObject = provider.rawValue
        }

        let providerCard = SettingsCard(rows: [
            SettingRow(title: "Cloud service", control: providerPopup),
        ])

        providerDetail.font = Typography.caption
        providerDetail.textColor = Colors.secondaryText
        providerDetail.lineBreakMode = .byWordWrapping
        providerDetail.maximumNumberOfLines = 0
        providerDetail.translatesAutoresizingMaskIntoConstraints = false

        folderField.placeholderString = "~/Documents/macSteam Saves"
        folderField.action = #selector(folderChanged)
        folderField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let chooseFolder = makeButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        let folderControls = NSStackView(views: [folderField, chooseFolder])
        folderControls.orientation = .horizontal
        folderControls.alignment = .centerY
        folderControls.spacing = 8
        folderCard = SettingsCard(rows: [
            SettingRow(title: "Sync folder", control: folderControls),
        ])

        setupButton = makeButton(title: "Open Cloud Redirect…", target: self, action: #selector(openCloudRedirect))
        let setupCard = SettingsCard(rows: [
            SettingRow(title: "Provider setup",
                       subtitle: "Sign in to Google Drive or OneDrive, or enter R2/S3 credentials, "
                           + "in CloudRedirect's own window. Games, backups and migration live there too.",
                       control: setupButton),
        ])

        let revealButton = makeButton(title: "Show in Finder", target: self, action: #selector(revealConfig))
        let configCard = SettingsCard(rows: [
            SettingRow(title: "Configuration",
                       subtitle: "Provider settings and cloud data are kept in this folder.",
                       control: revealButton),
        ])

        let note = NSTextField(labelWithString:
            "Install requires Steam to be quit for the removal step; macSteam re-signs Steam "
            + "afterwards. Sign-ins are kept in your login keychain by the credential helper.")
        note.font = Typography.caption
        note.textColor = Colors.quiet
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.translatesAutoresizingMaskIntoConstraints = false

        let cards: [NSView] = [
            title, subtitle,
            settingsGroupLabel("Runtime"), runtimeCard,
            settingsGroupLabel("Cloud provider"), providerCard, providerDetail, folderCard, setupCard,
            settingsGroupLabel("Configuration"), configCard,
            note,
        ]

        let stack = NSStackView(views: cards)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(16, after: runtimeCard)
        stack.setCustomSpacing(4, after: providerCard)
        stack.setCustomSpacing(16, after: setupCard)
        stack.setCustomSpacing(16, after: configCard)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for card in [runtimeCard, providerCard, folderCard!, setupCard, configCard] {
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        providerDetail.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        content.addSubview(stack)

        let margin = Metrics.paneMargin
        let maxWidth = stack.widthAnchor.constraint(lessThanOrEqualToConstant: 540)
        let wantWidth = stack.widthAnchor.constraint(equalToConstant: 540)
        wantWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: root.widthAnchor),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -margin),
            maxWidth,
            wantWidth,
        ])

        view = root
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    // MARK: - Rendering

    private func refresh() {
        let installed = (try? RuntimeContent.current()) == true
        runtimeLabel.stringValue = installed ? "Installed in Steam" : "Not installed in Steam"
        runtimeLabel.textColor = installed ? .labelColor : Colors.secondaryText
        installButton.title = installed ? "Update" : "Install in Steam"
        removeButton.isEnabled = installed

        let provider = Provider(rawValue: CloudRedirect.provider()) ?? .local
        if let index = Provider.allCases.firstIndex(of: provider) {
            providerPopup.selectItem(at: index)
        }
        providerDetail.stringValue = provider.detail
        folderCard.isHidden = provider != .folder
        setupButton.title = provider.needsSetup ? "Set Up \(provider.title)…" : "Open Cloud Redirect…"
        folderField.stringValue = CloudRedirect.syncFolder()
    }

    // MARK: - Actions

    @objc private func providerChanged() {
        let index = providerPopup.indexOfSelectedItem
        guard index >= 0, index < Provider.allCases.count else { return }
        let provider = Provider.allCases[index]
        CloudRedirect.setProvider(provider.rawValue)
        if provider == .folder, CloudRedirect.syncFolder().isEmpty {
            let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/macSteam Saves").path
            CloudRedirect.setSyncFolder(defaultFolder)
        }
        refresh()
    }

    @objc private func folderChanged() {
        let path = (folderField.stringValue as NSString).expandingTildeInPath
        guard !path.isEmpty else { return }
        CloudRedirect.setSyncFolder(path)
        refresh()
    }

    @objc private func chooseFolder() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.prompt = "Use Folder"
        if let current = folderField.stringValue as String?, !current.isEmpty {
            picker.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
        }
        guard picker.runModal() == .OK, let url = picker.url else { return }
        CloudRedirect.setSyncFolder(url.path)
        refresh()
    }

    @objc private func installRuntime() {
        do {
            try CloudRedirectRuntime.install()
            refresh()
        } catch {
            presentAlert("CloudRedirect couldn't be installed", error.localizedDescription, style: .warning)
        }
    }

    @objc private func removeRuntime() {
        let alert = NSAlert()
        alert.messageText = "Remove CloudRedirect from Steam?"
        alert.informativeText = "The runtime and credential helper are taken out of Steam and "
            + "its injection list. macSteam, NotProton and OnlineFix stay installed, and your "
            + "CloudRedirect settings and cloud data are kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try CloudRedirectRuntime.remove()
            refresh()
        } catch {
            presentAlert("CloudRedirect couldn't be removed", error.localizedDescription, style: .warning)
        }
    }

    @objc private func openCloudRedirect() {
        CloudRedirectEmbed.openWindow()
    }

    @objc private func revealConfig() {
        let folder = CloudRedirect.configFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
