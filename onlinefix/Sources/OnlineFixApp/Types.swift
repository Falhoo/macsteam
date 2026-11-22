import Foundation

// MARK: - Game model (same on-disk schema as the original manager)

struct PatchFlags: Codable, Equatable {
    var inputAppID: Bool = false
    var overlayAppID: Bool = false
    var startupAppID: Bool = false
    var statsAppID: Bool = false
    var terrariaServerEnvironment: Bool = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case inputAppID, overlayAppID, startupAppID, statsAppID, terrariaServerEnvironment
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputAppID = try c.decodeIfPresent(Bool.self, forKey: .inputAppID) ?? false
        overlayAppID = try c.decodeIfPresent(Bool.self, forKey: .overlayAppID) ?? false
        startupAppID = try c.decodeIfPresent(Bool.self, forKey: .startupAppID) ?? false
        statsAppID = try c.decodeIfPresent(Bool.self, forKey: .statsAppID) ?? false
        terrariaServerEnvironment = try c.decodeIfPresent(Bool.self, forKey: .terrariaServerEnvironment) ?? false
    }

    var anyEnabled: Bool {
        inputAppID || overlayAppID || startupAppID || statsAppID || terrariaServerEnvironment
    }
}

struct RepoPhoton: Codable, Equatable {
    var realtime: String = ""
    var voice: String = ""

    init() {}
    init(realtime: String, voice: String) { self.realtime = realtime; self.voice = voice }

    enum CodingKeys: String, CodingKey { case realtime, voice }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        realtime = try c.decodeIfPresent(String.self, forKey: .realtime) ?? ""
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
    }
}

struct ManagedGame: Codable, Identifiable, Equatable {
    var id: Int
    var name: String
    var imageURL: String?
    var keepRealAppID: Bool = false
    var patches: PatchFlags = PatchFlags()
    var phasmophobiaPhotonAppID: String = ""
    var picoPark2Photon: Bool = false
    var repoPhoton: RepoPhoton = RepoPhoton()

    enum CodingKeys: String, CodingKey {
        case id, name, imageURL, keepRealAppID, patches
        case phasmophobiaPhotonAppID, picoPark2Photon, repoPhoton
    }

    init(id: Int, name: String, imageURL: String? = nil) {
        self.id = id
        self.name = name
        self.imageURL = imageURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "App \(id)"
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL)
        keepRealAppID = try c.decodeIfPresent(Bool.self, forKey: .keepRealAppID) ?? false
        patches = try c.decodeIfPresent(PatchFlags.self, forKey: .patches) ?? PatchFlags()
        phasmophobiaPhotonAppID = try c.decodeIfPresent(String.self, forKey: .phasmophobiaPhotonAppID) ?? ""
        picoPark2Photon = try c.decodeIfPresent(Bool.self, forKey: .picoPark2Photon) ?? false
        repoPhoton = try c.decodeIfPresent(RepoPhoton.self, forKey: .repoPhoton) ?? RepoPhoton()
    }
}

/// A game-files fix that this app installed (DLLs placed into the game folder).
struct FixRecord: Codable, Identifiable, Equatable {
    var id: Int
    var gameName: String
    var installedAt: Date
    var files: [String]
    /// Size of each written file at install time. A path alone does not prove the
    /// fix is still in place: a Steam verify downloads the game's own file over it.
    var sizes: [String: Int64] = [:]

    enum CodingKeys: String, CodingKey { case id, gameName, installedAt, files, sizes }

    init(id: Int, gameName: String, installedAt: Date = Date(), files: [String],
         sizes: [String: Int64] = [:]) {
        self.id = id
        self.gameName = gameName
        self.installedAt = installedAt
        self.files = files
        self.sizes = sizes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        gameName = try c.decodeIfPresent(String.self, forKey: .gameName) ?? "App \(id)"
        installedAt = try c.decodeIfPresent(Date.self, forKey: .installedAt) ?? Date()
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        // An older record has no sizes; its files are still checked for existence.
        sizes = try c.decodeIfPresent([String: Int64].self, forKey: .sizes) ?? [:]
    }
}

struct GamesFile: Codable {
    var games: [ManagedGame] = []
    var fixes: [FixRecord] = []
    /// Last game added, so the Fix screen can preselect it. Extra key for older
    /// versions of the app, which ignore what they don't decode.
    var lastAddedID: Int?

    enum CodingKeys: String, CodingKey { case games, fixes, lastAddedID }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        games = try c.decodeIfPresent([ManagedGame].self, forKey: .games) ?? []
        fixes = try c.decodeIfPresent([FixRecord].self, forKey: .fixes) ?? []
        lastAddedID = try c.decodeIfPresent(Int.self, forKey: .lastAddedID)
    }
}

/// What the manager wrote when it deployed the dylib into Steam.
struct InstallRecord: Codable {
    var appPath: String
    var originalHash: String
    var installedHash: String
    var installedAt: Date

    enum CodingKeys: String, CodingKey { case appPath, originalHash, installedHash, installedAt }

    init(appPath: String, originalHash: String, installedHash: String, installedAt: Date = Date()) {
        self.appPath = appPath
        self.originalHash = originalHash
        self.installedHash = installedHash
        self.installedAt = installedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appPath = try c.decodeIfPresent(String.self, forKey: .appPath) ?? "/Applications/Steam.app"
        originalHash = try c.decodeIfPresent(String.self, forKey: .originalHash) ?? ""
        installedHash = try c.decodeIfPresent(String.self, forKey: .installedHash) ?? ""
        installedAt = try c.decodeIfPresent(Date.self, forKey: .installedAt) ?? Date()
    }
}

// MARK: - Steam library entry

struct LibraryApp: Identifiable, Hashable {
    let id: Int
    let name: String
    let installDir: String
    var folder: URL?
}

// MARK: - UI state helpers

enum InstallPhase: Equatable {
    case unknown
    case notInstalled
    case installed
    /// The dylib is in place but Steam isn't configured to load it.
    case incomplete(String)
    case broken(String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    var needsRepair: Bool {
        switch self {
        case .incomplete, .broken: return true
        default: return false
        }
    }
}

struct ProfileStatus: Equatable {
    var detectedBuild: String?
    var bundledProfiles: [String]
    var runtimeProfile: Bool
    var note: String
}

/// Identifies the game whose patch sheet is open.
struct PatchTarget: Identifiable, Hashable {
    let id: Int
}
