# macsteam 

"Steam unlock client" for macOS. ARM macOS, specifically. **This does not support Intel Macs!**

## Huh?


## How?

1. The config app deploys a dylib 'into' the Steam app bundle. 
2. A dylib (`macsteam.dylib`) is injected into Steam on launch, which does the unlock work.

Pretty boring. 

On Steam startup, macsteam also hides the “From the library of…” row (including
the lender avatar/status) and the legacy library-sharing retirement notice.
The patch preserves the JavaScript file's byte length to avoid triggering Steam's
startup size repair, and reapplies when macsteam loads after an update. It only
changes the UI; sharing permissions are unaffected. The rows are found by their
stable CSS-module names, so Steam's per-build identifier renaming doesn't matter;
if a bundle no longer contains them, it is left unchanged.

## macSteam Config

The companion app can handle all the basics. It can deploy the macSteam dylib, it can import games, you can use it to remove games from your unlock list, you can toggle the features that support being toggled (with more to come). You can also edit the config by hand by going to ```~/Library/Application Support/macSteam``` and editing the config file.

In macSteam Settings, **Hide Steam Cloud errors** optionally hides library Cloud
error indicators and Cloud failure/conflict notifications without disabling syncing.
Error-only Cloud columns collapse completely, and sidebar titles retain their
normal installed/uninstalled colors. It continues past game-launch Cloud warnings
using Steam’s “play anyway” action, without choosing local or remote saves. It defaults to off. Restart Steam
after changing it; turning it off restores the original UI. The config key is
`HideCloudErrors: yes` (or `no`).

The Cloud patch discovers render functions and callbacks from semantic UI names;
it does not depend on minified variable names or CSS hashes. It reapplies to new
bundles at startup and preserves file size. Recovery copies are keyed to the
patched bundle’s SHA-256, so restoring the toggle cannot overwrite a Steam update
with an old bundle. If a future structure is unrecognized, the bundle stays
untouched and the reason is logged.

Regression check against an unmodified Steam bundle:
```bash
python3 scripts/tests/cloud_errors.py /path/to/steamui/sp.js
```

## Usage

Download the latest release from the [Releases page](https://github.com/crghofficial/macsteam/releases).

Unzip it. Move macSteam Config to Applications. 

Go to Install, hit Install, let macSteam deploy. You will get a TCC prompt to allow macSteam to modify other applications, allow it.

## Building from source

One script builds the whole app (macSteam, NotProton and OnlineFix together):

```bash
./build.sh
```

NotProton's prebuilt parts come from NotProton 1.2.6 in `/Applications` or `~/Downloads`;
point it elsewhere (or at the release zip) with `./build.sh --notproton-app PATH`.
The result is `dist/macSteam.app`.

There is also a science experiment in the repo, a macSteam launcher that does not modify the Steam app bundle in any way. It is included for the enjoyment of others, but is not intended to be used. 

## OnlineFix

OnlineFix routing from [SomeAppOnlineFix](https://github.com/ElfariaKensington/SomeAppOnlineFix)
(AGPL-3.0) ships as its own `onlinefix.dylib`, not as part of `macsteam.dylib`. macSteam's
**Install** copies it into `Steam.app/Contents/MacOS/`, adds it to Steam's injection list the
same way NotProton's dylib is added, and sets `ONLINEFIX_SIG`, `ONLINEFIX_CONFIG` and
`ONLINEFIX_LOG` in `LSEnvironment` so the dylib finds its per-Steam-build profiles, the game
list and its log. The merged **OnlineFix Manager** pages own those settings. Add a game in
**Add Games** (or install its fix from the patch sheet) and the game is put in the Apps list
and in the manager's `games.json`. The injected dylib reads that list at Steam's launch, so the
session runs as **AppID 480** (Spacewar) with the optional App ID restores; restart Steam for
a change to the list to take effect. Right-click a game in Apps and choose **OnlineFix…** to
open it in the manager. A valid original game license is still required; this routing does not
itself grant ownership.

**From Steam's store page:** with macSteam Config running, a game's page shows a
**Use OnlineFix** card. **Install** adds the game to My Games, downloads its fix
from online-fix.me into the game folder, and sets up its AppID 480 routing. The
game has to be installed first; if the server does not have the fix under the
game's name, install it from the manager with **Choose archive…**. Unpacking runs
off the window's own thread and shows the archive's progress, with a 15-minute
limit, so a large archive no longer looks like a hang.

If LuaTools carries an **Online Fix** for the game (its “Online Fix” tag), the
card says so and recommends that one instead: it is the same fix, installed and
tracked by LuaTools, so the card's own button becomes **Install anyway**. Its
OnlineFix is only needed for macSteam's AppID 480 routing. The game's
**Properties** window says the same on its OnlineFix tab.

The macSteam card's own button adds the game (or opens Steam's install dialog
once it is in the library). A **Restart** button of the same size appears beside
it only on the card that just added the game: a game that was already in the
library when the page opened shows no Restart, since nothing about it is waiting
for a restart. Restart quits Steam, starts it again and then opens that game's
library page (`steam://nav/games/details/<appid>`, the link Steam itself uses),
because a game added while Steam runs only gets its achievement list the next
time the client starts. Steam ignores a polite quit, so the button gives it a few
seconds and then stops it outright before relaunching. The restart is done by the
Store bridge helper (`macsteam-app/Sources/MacsteamApp/SteamRestarter.swift`),
which stays up while Steam is gone and reattaches to the new pages afterwards;
the newest app also takes the bridge over from a helper left by an earlier launch.

A **Remove from Steam** button sits under the card whenever macSteam has the game
in its configuration (so on the "Ready to install with macSteam" and "In your
library, added with macSteam" states alike). It is the store page's version of the
macSteam app's Remove: the bridge drops the app, its DLC, its depot-key group, its
name and any OnlineFix routing from config.yaml, and deletes the Lua receipt so a
re-add downloads the manifest again. Once the removal succeeds the card offers a
**Restart Steam** button, which is a plain quit-and-start (`SteamRestarter.restartOnly`)
that makes Steam drop the title from the library; it does not load a page or wait
for achievements.

**One restart is enough for the achievements.** A game's list reaches the library
cache only once Steam has fetched its achievements, and a library page draws only
the list its cache held when the page was opened — which is why the game used to
need two restarts. Restart now opens that game's library page in the client that
is running, waits three seconds for Steam to fetch its achievements, then quits the
client through its own `steam://exit` — the way the menu does, so it writes its
library cache on the way out instead of being killed — and starts it again, coming
back to the same page: the first start after the restart already has the list. The
Store bridge also writes the entry as part of the add (`AchievCache` loads the
client dylib's `sx_achiev_cache_sync_app` in the helper process). Each step it
takes is logged with a `[restart]` prefix in `macsteam.log`.

**Uninstalling a fix:** the patch sheet, the store card and the game's Properties
window all have **Uninstall**. It restores the files the fix replaced from their
`*.onlinefix-backup` copies, deletes the files it added, takes the game out of
**My Games** and drops its AppID 480 routing from `config.yaml`, so Steam starts it
with its own AppID again — with the account's own licence, when it has one.

A game the account already owns routes the same way as any other **once it has an
OnlineFix installed**: the session then runs as AppID 480, so you can join friends
who use OnlineFix. macSteam does not replace the ownership Steam reports for it, so
Steam keeps using your own licence and does not time the session out with “this game
will close in 2 minutes because of family sharing”.

A game in **My Games** with no fix installed is not routed at all: it launches as
itself, so online play that depends on its real Steam identity (Photon, Steam
lobbies) keeps working. Routing is written only for games that have a fix on disk —
`AppModel.routingEntries` carries `hasFix`, and only those reach config.yaml's
`OnlineFix:` section.

**Per-game Properties:** double-click a game in **Apps** (or right-click it and
choose **Properties…**) for two tabs: **LuaTools Fixes** first (the same fixes and
manifest actions the store page offers, with Uninstall) and **OnlineFix** second
(install/reinstall/uninstall, open in the manager).

Alternatively, add `-onlinefix` to a game's launch options; `-realappid` keeps its
original AppID visible after networking starts. Without either per-game configuration
or `-onlinefix`, macsteam leaves the game's OnlineFix identity alone.

The existing `config.yaml` stores per-game options separately from the unlock list:

```yaml
OnlineFix:
  105600:
    KeepRealAppID: no
    StartupAppID: yes
    OverlayAppID: yes
    InputAppID: yes
    StatsAppID: yes
```

The session uses AppID 480 for networking, while the optional patches restore the
original startup, overlay, controller and stats identities. All four patches default
to enabled. Only one routed game per Steam process is supported. The seven required
hooks must all resolve and install before routing activates. Profiles are included
for Steam builds 1791918634 and 1792618285; older profiles leave routing inactive.
`MACSTEAM_DISABLE=onlinefix` disables installation. The separate OnlineFix Manager
app and its `onlinefix.dylib` are not needed: the merged pages feed macSteam's
routing and install the game-file fixes. Game-file and Wine/Photon patches are not
part of the Steam routing runtime itself.

Run `make test-onlinefix` for the runtime and C/Swift config integration checks.

## Achievements

Two separate things have to happen for a game that Steam does not own to show an
achievement list, and only one of them involves the network.

**The list itself.** The library does not build the achievements card from the
stats reply. `steamui` asks the native side for the app's cached details
(`Apps.GetCachedAppDetails`), which is a plain read of

    <steam>/userdata/<account>/config/librarycache/<appid>.json

and renders the card from the `achievements` entry in that file. For a game Steam
does not own the entry is `nTotal: 0`, and every achievements component returns
`null` on `nTotal: 0`, so nothing appears however good the network reply was.

The schema is already on disk — the client writes
`appcache/stats/UserGameStatsSchema_<appid>.bin` for every app it has seen one
for — so macsteam turns it into the entry the library reads
(`src/feats/achiev_cache.c`): name, description and icon for each achievement,
with the unlock state taken from the local stats blob. A game that has never been
played therefore starts at 0/N, and progress the client recorded shows up on the
next launch. Files that already hold a list of the right size are rewritten from
the schema; a list Steam wrote that disagrees with the schema, or that is further
along than the local stats, is left alone.

The store also had to be asked for that entry. `AppDetailsStore` loads the cache
only when the details arrive with `vecHighlight === void 0`, which never happens
for an unowned game — the arrays are there and empty. `src/hooks/hook_achievui.c`
rewrites that guard, and the one in `RequestAchievements`, to fire on
`nTotal === 0` instead. The edit is a fixed-size in-place patch of `sp.js`, so the
bundle keeps the byte length Steam checks at startup.

**The schema on disk.** Steam only writes the schema after a stats request for the
app succeeds, and for an unowned game it fails. macsteam points that one request
at an account that does own the game (`CAPIJob::sendAndRecv`) and keeps the schema
from the reply, clearing the owner's stats and achievement blocks so nothing is
inherited. Owners are found through `IUserReviewsService/GetAppReviews` and cached
per game; ones with no stats to share are blacklisted. The older
`store.steampowered.com/appreviews?json=1` endpoint now redirects to the store
home page, which is why the owner lookup never used to succeed.

There is nothing to set up by hand and nothing in the config app to open: a game
picks up its list the first time the library asks about it, and whatever you earn
is recorded by Steam as usual.

**Adding a game takes effect while Steam runs.** Saving a config whose app list,
packages or depot keys changed tells Steam to reload through the same live
activation the store card uses. Only the games that are new to the list are
synced, on a worker thread, and the library refresh is armed once their caches
are written — a whole-list sync took long enough that Steam rebuilt the library
first and kept an empty card. A list written later in the session, when a page's
stats request brings a schema that did not exist yet, asks for the library to
read that app's details again, so the card appears without a restart. An app whose
schema was not on disk yet when its sync ran — true of every game added
mid-session, because the library fetches its achievements a moment later — is
queued by the live add and retried every couple of seconds for about a minute,
which is how long that fetch usually takes. Changing a setting alone does not
trigger any of it.

**The game page's "View all achievements".** That page asks the client for the
signed-in account's achievements (`Apps.GetMyAchievementsForApp`), which the
client only answers for a game the account owns; for anything else it returns
`Failed to retrieve user stats` and the page shows "Failed to load achievement
data". `src/hooks/hook_achievui.c` points that page at the same cached list the
library card uses (the uncapped `vecAll` written by `src/feats/achiev_cache.c`)
when the call fails, so the list still opens. Progress is whatever Steam has
recorded locally; global percentages are 0 for a game nobody here owns.

**The library grid's badge.** The grid does not read the library cache: it reads
`config/librarycache/achievement_progress.json`, which the CM service fills in only
for apps the account owns — for the rest it answers `total: 0`, and every tile
says "No achievements" even though the game's page has the list.
`src/feats/achiev_cache.c` now writes the same numbers for the apps on the unlock
list from their local schema. The unlock state comes from the account's own stats
blob, so a game played here keeps the achievements it earned (Garry's Mod with one
of 29 shows 3%), and an entry that already carries a real total keeps it. The tile
then shows a percentage like any other game.

## Steam Cloud

A game Steam does not own gets no Cloud sync: the client's cloud calls for that
app fail, so nothing follows you to another Mac. The saves themselves are not
lost. The game writes them to

    ~/Library/Application Support/Steam/userdata/<account>/<appid>/remote

and Steam leaves them there; what is missing is only the copy it would have kept
on Valve's servers.

macSteam keeps a second copy of that folder in

    ~/Library/Application Support/macSteam/cloud/<appid>/files

and copies a file there exactly once, the first time it is seen. A later save
that overwrites, corrupts or deletes a file does not touch the stored copy, so an
early save is still there afterwards. The store is a plain folder: point it at a
synced drive, or copy it between Macs, and the saves follow.

Two kinds of folder are kept, both under
`~/Library/Application Support/macSteam/cloud/<appid>`:

- `files/` — `userdata/<account>/<appid>/remote`, the games that use Steam's own
  RemoteStorage. Steam does not sync it for an app it does not own, but the game
  still writes there.
- `game/` — the save folder of a game that keeps its saves somewhere else
  entirely, which is most of them.

Settings live in `~/Library/Application Support/macSteam/cloud.yaml`, not in
`config.yaml`: the config app rewrites `config.yaml` from the fixed set of keys
it knows, so anything it does not know about belongs in a file of its own.

```yaml
Enabled: yes                 # the whole feature, default off
AutoDetect: yes              # look for new save folders after each session
RestoreAll: yes              # put back saved files a folder is missing
Destination: ~/Dropbox/macSteam Saves   # where backups are kept
Provider: dropbox            # which folder Destination came from
Folders:
  413150: ~/.config/StardewValley
```

The snapshot system above is now a fallback: this app's **Cloud Saves** page sets up
CloudRedirect (built from the vendored
[cloudredirect-macos](https://github.com/ElfariaKensington/cloudredirect-macos)
source in `vendor/cloudredirect`), and installing its runtime turns macSteam's own
snapshots off so the two never write the same save files. Providers that need a
sign-in or credentials open CloudRedirect's own app in a window.

Nothing has to be filled in by hand. Steam writes `: Game process added` and
`: Game process removed` lines to `logs/console_log.txt` with the app id, so a
session's start and end are both known. When a game exits, macSteam looks one
level into `~/.config`, `~/Library/Application Support`, `~/Library/Containers`
and `~/.local/share` for a folder that was written to while that game ran — named
like the game, or created during the session — and adds it under `Folders` by
itself. The saves are copied then, and again after every later session.

### An online account (macSteam's own snapshots, the fallback)

Two settings sit side by side, and both can be on at once when Cloud Redirect is
not installed:

- **Local backup folder** — where the backups are kept on this Mac: the macSteam
  folder, iCloud Drive, OneDrive, Google Drive or Dropbox (the folders their
  desktop apps keep in sync), or any folder you choose.
- **Cloud service** — an optional second copy online: none, a WebDAV account,
  Google Drive, or OneDrive. Only the chosen service's settings are shown, and
  only it is contacted.

So a local OneDrive folder plus the OneDrive cloud service means the saves are in
the folder *and* in the account, fetched by macSteam itself without the desktop app
being installed. With a cloud service on, macSteam keeps a copy of the local
backup folder in the account and fetches it back on another Mac.
macSteam runs the config app headless (`--cloud-sync push|pull`) when Steam starts
— pulling before the restore pass, so the files are in place before a game
launches — and again after a round that copied new saves. Each service's Test,
Upload and Download buttons do the same by hand.

**WebDAV** is the one that needs no app registration: an address, a user name and
a password, and it works with Nextcloud, ownCloud, Box, pCloud, a NAS, or a server
of your own.

**Google Drive** signs in through the browser and keeps the backups in a `macSteam`
folder it creates. The scope is `drive.file`, so it only ever sees files it made
itself. It needs a Google OAuth client ID (Cloud console → enable the Drive API →
consent screen → Credentials → OAuth client ID → Desktop app); a build can ship
one in `GoogleDrive.builtInClientID`, otherwise the pane takes one.

**OneDrive** works the same way against Microsoft Graph, with Microsoft's app
folder (`Files.ReadWrite.AppFolder`): macSteam gets one folder of its own in the
account and can see nothing else. It needs an Azure app registration — App
registrations → New, account type "any organizational directory and personal
Microsoft accounts", Authentication → Add a platform → Mobile and desktop
applications → redirect `http://localhost`, then the Application (client) ID goes
in the pane, or in `OneDrive.builtInClientID` for a release.

Sign-ins land in the login keychain, so the headless helper can pull and push
without the window being open. Only the first sign-in needs it.

`Restore` is the only part that writes outside macSteam's own folder. It puts
back every stored file the game's folder is missing — a game that was
reinstalled, a new Mac, or a folder the game has only just recreated with its own
settings file — and never overwrites a file that is already there. A save you
delete on purpose comes back on the next pass, so turn restore off if you want a
deletion to stick. A folder found automatically is added to `Restore` too, since
it only ever held that game's saves.

`Folders` can still be edited by hand, one line per app id, for a game Steam's log
line or folder name does not cover.

Nothing here touches Steam's network traffic. The backup thread runs while Steam
does, re-reads both files when they change, and does not start at all without
`Enabled: yes` (or the older `Cloud: yes` in `config.yaml`, which is still
honoured when `cloud.yaml` is absent).

To see what the client does with cloud jobs, the feature also records every cloud
request and reply of a session to
`~/Library/Application Support/macSteam/cloud/dumps/capture.txt`, with the
message header, the body, and where each configured app id sits inside it. That
file is a diagnostic, not something the running client reads.

## Contributing

PRs are welcome. I could currently badly use a **real name** and an **icon**.

## License

AGPLV2 with grifters being the reason why.
