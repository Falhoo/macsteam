// Cloud Saves page: CloudRedirect's runtime inside Steam, and where it syncs.
// Logic ported from the old CloudSavesViewController. CloudRedirect's own app (providers,
// sign-in, games, backups, migration) still opens in a window of its own from here.
import AppKit
import CloudRedirectSupport
import GlassUI
import SwiftUI

enum CloudProviderChoice: String, CaseIterable, Identifiable {
    case local
    case folder
    case gdrive
    case oneDrive = "onedrive"
    case r2
    case s3

    var id: Self { self }

    var title: String {
        switch self {
        case .local: "Local storage"
        case .folder: "Custom folder"
        case .gdrive: "Google Drive"
        case .oneDrive: "OneDrive"
        case .r2: "Cloudflare R2"
        case .s3: "S3-compatible"
        }
    }

    var detail: String {
        switch self {
        case .local: "Saves stay on this Mac; Steam Cloud requests are answered locally."
        case .folder: "Saves sync to a folder you choose, such as a network share."
        case .gdrive: "Saves sync to your Google Drive account."
        case .oneDrive: "Saves sync to your OneDrive account."
        case .r2: "Saves sync to a Cloudflare R2 bucket."
        case .s3: "Saves sync to an S3-compatible bucket."
        }
    }

    var needsSetup: Bool { [.gdrive, .oneDrive, .r2, .s3].contains(self) }
    var isOnThisMac: Bool { self == .local || self == .folder }
}

@MainActor
final class CloudSavesModel: ObservableObject {
    @Published private(set) var isInstalled = false
    @Published private(set) var provider: CloudProviderChoice = .local
    @Published var folder = ""

    func refresh() {
        isInstalled = (try? RuntimeContent.current()) == true
        provider = CloudProviderChoice(rawValue: CloudRedirect.provider()) ?? .local
        folder = CloudRedirect.syncFolder()
    }

    func setProvider(_ choice: CloudProviderChoice) {
        CloudRedirect.setProvider(choice.rawValue)
        if choice == .folder, CloudRedirect.syncFolder().isEmpty {
            let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/macSteam Saves").path
            CloudRedirect.setSyncFolder(defaultFolder)
        }
        refresh()
    }

    func commitFolder() {
        let path = (folder as NSString).expandingTildeInPath
        guard !path.isEmpty else { return }
        CloudRedirect.setSyncFolder(path)
        refresh()
    }

    func chooseFolder() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.prompt = "Use Folder"
        if !folder.isEmpty {
            picker.directoryURL = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        }
        guard picker.runModal() == .OK, let url = picker.url else { return }
        CloudRedirect.setSyncFolder(url.path)
        refresh()
    }

    func installRuntime() {
        do {
            try CloudRedirectRuntime.install()
        } catch {
            presentAlert("CloudRedirect couldn't be installed", error.localizedDescription, style: .warning)
        }
        refresh()
    }

    func removeRuntime() {
        guard confirm("Remove CloudRedirect from Steam?",
                      "The runtime and credential helper are taken out of Steam and its injection list. "
                          + "macSteam, NotProton and OnlineFix stay installed, and your CloudRedirect "
                          + "settings and cloud data are kept.",
                      confirmTitle: "Remove") else { return }
        do {
            try CloudRedirectRuntime.remove()
        } catch {
            presentAlert("CloudRedirect couldn't be removed", error.localizedDescription, style: .warning)
        }
        refresh()
    }

    func openCloudRedirect() {
        CloudRedirectEmbed.openWindow()
    }

    func revealConfig() {
        let folder = CloudRedirect.configFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

struct CloudSavesPage: View {
    @ObservedObject var model: CloudSavesModel

    var body: some View {
        PageScroll(maxWidth: 720) {
            PageHeader(
                title: "Cloud Saves",
                subtitle: "CloudRedirect makes Steam Cloud work for games macSteam unlocks: the client sees normal cloud saves, and the bytes live in the account or folder you choose. macSteam installs its runtime into Steam and keeps its own older save snapshots switched off."
            )

            GlassSection(title: "Runtime") {
                GlassRow(
                    title: "CloudRedirect runtime",
                    subtitle: "The dylib and credential helper Steam loads. Install adds them beside macSteam's own dylib and restarts nothing."
                ) {
                    Button(model.isInstalled ? "Update" : "Install in Steam") { model.installRuntime() }
                        .buttonStyle(model.isInstalled ? AnyPrimitiveButtonStyle(.glass) : AnyPrimitiveButtonStyle(.glassProminent))
                        .contentTransition(.interpolate)
                }
                RowDivider()
                GlassRow(title: "Status", status: model.isInstalled ? .ok : .inactive) {
                    Text(model.isInstalled ? "Installed in Steam" : "Not installed in Steam")
                        .foregroundStyle(model.isInstalled ? .primary : .secondary)
                        .contentTransition(.interpolate)
                }
                RowDivider()
                GlassRow(title: "Remove it from Steam") {
                    Button("Remove from Steam", role: .destructive) { model.removeRuntime() }
                        .buttonStyle(.glass)
                        .disabled(!model.isInstalled)
                }
            }

            GlassSection(title: "Cloud Provider", footer: model.provider.detail) {
                GlassRow(title: "Cloud service") {
                    Picker("Cloud service", selection: Binding(get: { model.provider },
                                                               set: { model.setProvider($0) })) {
                        ForEach(CloudProviderChoice.allCases.filter(\.isOnThisMac)) { Text($0.title).tag($0) }
                        Divider()
                        ForEach(CloudProviderChoice.allCases.filter { !$0.isOnThisMac }) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if model.provider == .folder {
                    RowDivider()
                    GlassRow(title: "Sync folder") {
                        HStack(spacing: 8) {
                            InsetField(prompt: "~/Documents/macSteam Saves", text: $model.folder)
                                .frame(minWidth: 220)
                                .onSubmit { model.commitFolder() }
                            Button("Choose…") { model.chooseFolder() }
                                .buttonStyle(.glass)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                RowDivider()
                GlassRow(
                    title: "Provider setup",
                    subtitle: "Sign in to Google Drive or OneDrive, or enter R2/S3 credentials, in CloudRedirect's own window. Games, backups and migration live there too."
                ) {
                    Button(model.provider.needsSetup ? "Set Up \(model.provider.title)…" : "Open Cloud Redirect…") {
                        model.openCloudRedirect()
                    }
                    .buttonStyle(.glassProminent)
                    .contentTransition(.interpolate)
                }
            }

            GlassSection(
                title: "Configuration",
                footer: "Install requires Steam to be quit for the removal step; macSteam re-signs Steam afterwards. Sign-ins are kept in your login keychain by the credential helper."
            ) {
                GlassRow(title: "Configuration", subtitle: "Provider settings and cloud data are kept in this folder.") {
                    Button("Show in Finder", systemImage: "folder") { model.revealConfig() }
                        .buttonStyle(.glass)
                }
            }
        }
        .animation(.snappy, value: model.provider)
        .animation(.snappy, value: model.isInstalled)
        .onAppear { model.refresh() }
    }
}

/// Lets a button switch between the glass and prominent glass styles.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
