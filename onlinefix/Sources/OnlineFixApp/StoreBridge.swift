import Foundation

/// What the Steam store card knows about a game's OnlineFix state.
public struct OnlineFixStoreStatus: Codable, Sendable {
    public let inList: Bool
    public let fixInstalled: Bool
    public let gameInstalled: Bool
    /// The game's online play runs on Steam's relay network (SDR), which only
    /// exists for the game's own AppID: as Spacewar it never connects.
    public let usesSteamNetworking: Bool
    /// The game is set to start as itself instead of Spacewar.
    public let keepRealAppID: Bool
    /// Set when the game's OnlineFix ships a Photon patch that cannot load, so the
    /// store card can say which piece is missing instead of leaving the player with
    /// "CustomAuthenticationError" in game.
    public let photonIssue: String?
    /// The game ships the Microsoft Store (GDK) runtime, which no OnlineFix or
    /// LuaTools patch can satisfy under Wine. The card warns and hides the install
    /// behind a "show me anyway" tick.
    public let gdkRestricted: Bool
    /// Steam installed the native macOS build, which runs as a Mach-O process with
    /// `libsteam_api.dylib`. No OnlineFix file can load into it, so the fix has to be
    /// written into the bundle's own files or into the identity Steam starts it with.
    public let nativeMacBuild: Bool
    /// The Mac build carries something the fix can write into it (a Photon app id it
    /// connects to, or a code change a profile names), so installing is more than the
    /// AppID routing. A Windows build beside it means Steam launches the `.exe`, so
    /// this is false there.
    public let macPatchable: Bool
    /// The NotProton compatibility tool Steam has installed, which the card hands to
    /// `SteamClient.Apps.SpecifyCompatTool` for a native build.
    public let compatTool: String?
    /// The folder now holds the Windows build (no `.app`, an executable), so the fix
    /// can be installed for real. This is what the card waits for after the switch.
    public let windowsBuildInstalled: Bool
    /// Which build of the game Steam actually starts. A game can ship both, and the
    /// folder alone cannot say which one runs: a Windows fix copies its files beside
    /// the `.exe`, a Mac fix writes into the `.app`. The card follows this instead of
    /// the folder, so it stops offering the Mac build to a game running as Windows.
    public let buildInUse: GameBuildInUse
    /// The Mac bundle is still in the folder. Steam sometimes leaves it there when it
    /// installs the Windows build beside it, so the card can say both are present
    /// instead of pretending only one is.
    public let macBuildInstalled: Bool
    /// The game's fix ships Steam's overlay stub, so the overlay is on the critical
    /// path at startup. The OnlineFix card's copy disables it; a LuaTools copy does
    /// not, which is what crashes some games (Buckshot Roulette).
    public let overlayStub: Bool
    /// What the last launch test proved, if one has run. The card shows this next
    /// to the install button, so it does not disappear with the install message.
    public var lastOnlineCheck: String? = nil

}

/// Which build of a game is the one in use.
public enum GameBuildInUse: String, Codable, Sendable {
    case mac
    case windows
    case none

    /// Read from what the fix did, then from the folder. A fix's record outranks the
    /// folder, because the folder keeps the other build beside the one in use.
    static func resolve(appID: Int, folder: URL?) -> GameBuildInUse {
        // A pinned compatibility tool is Steam's own answer to "run the Windows build",
        // and it is what makes the `.exe` the thing that starts. It outranks everything.
        if Steam.forcedCompatTool(appID: appID) != nil { return .windows }
        guard let folder else { return .none }
        let mac = FixInstaller.nativeMacBundle(in: folder) != nil
        let windows = FixInstaller.hasAnyWindowsBuild(in: folder)
        // The folder is what Steam launches from, so it speaks first. A fix's record
        // only breaks the tie, and only while it still describes the folder: a Mac
        // record left behind after Steam swapped in the Windows build used to keep the
        // card on the Mac wording forever.
        switch (mac, windows) {
        case (true, false): return .mac
        case (false, true): return .windows
        case (false, false): return .none
        case (true, true):
            // Both builds are on disk. Steam left the Windows one there on purpose
            // (a forced install, or a verify after the switch), and a fix only has
            // something to do there, so that is the one the card talks about. The
            // Mac bundle is reported beside it, not instead of it.
            return .windows
        }
    }
}

/// How an OnlineFix install started from the Steam store page ended.
public struct OnlineFixStoreOutcome: Codable, Sendable {
    public let message: String?
    public let error: String?
    public let needsGame: Bool
    public let installed: Bool
    /// Similar uploads folders the store page should offer when the game's own
    /// name had no folder. Picking one re-runs the install with `folder`.
    public var choices: [OnlineFixStoreChoice]? = nil
    /// Set when the fix may not work and the player has to confirm before it is
    /// downloaded. Nothing is installed until the install is retried with
    /// `confirmed`.
    public var confirmation: String? = nil
    /// Set for a native macOS build: the store page should switch the game to
    /// NotProton (with `compatTool`) and start Steam's install, so the Windows build
    /// is what gets downloaded.
    public var windowsBuild: Bool? = nil
    public var compatTool: String? = nil
}

/// One folder that could be the game's fix, as offered on the store page.
public struct OnlineFixStoreChoice: Codable, Sendable {
    public let name: String
    public let percent: Int
}
