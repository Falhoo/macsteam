# OnlineFix on macOS: handover

Written at the point the work was stopped. Everything below is what is on this Mac
right now, what was tried, what each attempt showed, and what to do next. The project
root is not a repository; the working checkout with these changes is `macsteam-repo/`,
and nothing there is committed or released.

> **26 November 2026, current state:** Photon now has one explicit route decision,
> `PhotonRoute`. It reads the game's ticket request, its own app ids, the package's
> Custom.dll/BepInEx evidence, the installed chain and Steam networking, in that order.
> A ticket, or R.E.P.O.'s own realtime/voice pair, selects the Steam-auth route: real
> AppID, no swap, no BepInEx chain, and an older chain is removed. A generic package
> carrying Custom.dll no longer wins over that evidence, which is what made a fresh
> R.E.P.O. install hang on Unity 6 before its first frame.
>
> The live check still cannot reach a lobby, and the cause is entitlement, not routing:
> `macsteam.log` records `CheckAppOwnership: SPOOFING appid 3241660 (orig=0)`. The
> signed-in account does not own R.E.P.O. Steam therefore cannot issue a ticket for
> `3241660`, and Photon answers `32755 (Failed(2): error response from Steam)`. No
> file patch, AppID swap or dylib hook can replace that licence.
>
> **R.E.P.O. was uninstalled by Steam at 22:50 on 26 November**, while this work was
> being tested. `content_log.txt` records `Update Required,Fully Installed,Files
> Missing,Uninstalling` then `Uninstalled`, and the appmanifest is gone. Only the
> pre-existing `.before-onlinefix-appid` file copies remain in the folder; the exe and
> `UnityPlayer.dll` are gone. This account cannot download the game again, so R.E.P.O.
> cannot be canaried until an owning account or a backup is available. A synthetic
> folder with those two real files was used to check the route: it reports
> `steamAuth`, both own ids, Unity `6000.3.28f1`, and "no chain".
>
> **Tests:** `swift test` in `onlinefix/` now reports **241 Swift Testing tests in 30
> suites**, plus 10 XCTest cases, all passing. `macsteam-app` reports 55 XCTest cases,
> all passing. The new release binary is installed at
> `/Applications/macSteam.app/Contents/MacOS/MacsteamApp` (SHA-256
> `c53e3f62ccc7d640eedc8dc1a62fee11f9ea7432a4c581d00d50cf527a98d10c`), with the Sparkle
> rpath and an ad-hoc signature. The previous 0.8.10 binary is backed up as
> `~/Library/Application Support/macsteam/backups/MacsteamApp-0.8.10-20261126-231308`;
> the intermediate Photon builds are `MacsteamApp-photon-route-20261126-231450` and
> `…-231713`.
> The bundle still reports version 0.8.10, and nothing is committed or released.

## The goal, and where it stands

OnlineFix games should run on macOS with working Photon multiplayer, starting with PEAK
(`3527290`) and R.E.P.O. (`3241660`). Single player, the fix install, the overlay
workaround, the loader chain and the routing all work. **Photon still cannot reach a
lobby for R.E.P.O. on this account**, and the live test now says why: the account does
not own the game, so Steam refuses the ticket. That is an entitlement limit, not a
remaining file or launch bug.

| Part | State |
| --- | --- |
| OnlineFix-only test lab (reset, probe, install, repair, run, report) | done, `scripts/onlinefix-lab.sh` and `docs/onlinefix-test.md` |
| Fix kit: one scan plus findings plus a plan, packed into `<game>/.macsteam-onlinefix/` | done, works for any game, not just Terraria |
| Install only when the game is actually installed | done, `Store.isInstalled` (manifest `StateFlags` 4 bit plus an exe or `.app`) |
| Store UI shows what the install is doing, not just `Installing ____.rar` | done |
| GDK warning text | changed to `This game is like one of the few that aint gonna connect, try if you want ig tho` |
| CrossOver install merged from `macsteam-0.8.5` | done, and the OnlineFix buttons are enabled again |
| PEAK boots | yes |
| R.E.P.O. boots and reaches its menu with the Steam-auth route | verified before 22:50 on 26 Nov, about 30 seconds, no BepInEx chain; currently uninstalled by Steam |
| PEAK / R.E.P.O. Photon connect | PEAK's newest log says `Steam auth ticket received` and names its own ids, so the audit keeps its real AppID and no chain; it still needs a boot/join check. R.E.P.O. cannot authenticate because the account does not own it |

## The Photon problem, precisely

Photon runs on a per game application registered with Exit Games, and that application
is tied to the game's own Steam AppID. R.E.P.O.'s stock pair is
`99515094-45b7-4c98-ab70-a448c548c83d` (realtime) and
`dfc40a01-c3a4-4395-9707-b71118816d2b` (voice). That pair is R.E.P.O.'s own game
app, not one of OnlineFix's shared apps; a Steam-ticket request against it is the
game asking for its own licence, not a game patched onto a shared app. Its own logs
show the ticket request:

```
Photon - AppId (Realtime): 99515094-45b7-4c98-ab70-a448c548c83d
Getting Steam Auth Ticket...
Disconnected from server for reason InvalidAuthentication
```

The same run recorded `CheckAppOwnership: SPOOFING appid 3241660 (orig=0)`. The client
is answering as the game but the account has no licence for it, so the ticket Steam
returns is not valid for Photon. The measured answers were:

| Configuration | What the game sends | What comes back |
| --- | --- | --- |
| R.E.P.O.'s own pair, real AppID (`keep-id=1`) | a ticket request for `3241660` | `32755 (Failed(2): error response from Steam)`, then `InvalidAuthentication` |
| Spacewar (`keep-id=0`) | a ticket for `480`, or none | `32755 (Parameter invalid)` or `CustomAuthenticationFailed` |
| `9551e103-6003-43b6-9415-d4ff80eefaea` (a GUID in OnlineFix's `Custom.dll`) | that app id | `GetRegions failed … ApplicationNotFound`; not a real R.E.P.O. app |

The old BepInEx route made this worse in a different way: its preloader stopped Unity 6
before a window existed. The new Steam-auth plan leaves the chain out, removes it if an
earlier install wrote it, keeps the real AppID, and writes `PhotonIntegration=false`.
That is what lets R.E.P.O. boot. It does not, and cannot, create an entitlement.

The user's account does not own `3241660`: the injected licence package in
`config.yaml` does not list it, and the client reports `orig=0`. This is also why no
"try another Photon app id" experiment can succeed. Those ids belong to other apps, and
none of them will accept a ticket for a game the account does not own.

## Next steps, in order

1. **Do not repeat the Photon-id experiments on this account.** They cannot fix a
   missing licence, and the `9551` GUID is not R.E.P.O.'s app. Treat live Photon as
   blocked until an account that owns `3241660` is available.
2. **Positive canary on an owned Steam-auth Photon game.** Install it, confirm the plan
   has no BepInEx chain and `PhotonIntegration=false`, then require a Player.log line
   showing the app id and a joined room before claiming multiplayer works.
3. **Regression check PEAK.** PEAK is not a Steam-relay game and should still get the
   custom-auth chain; install and boot it from the new app before a release.
4. **Release only after those checks.** Bump the bundle version, rebuild, and add
   `@executable_path/../Frameworks` to the executable's rpath before signing. A plain
   SwiftPM binary put into the bundle without that rpath fails at launch with
   `Library not loaded: @rpath/Sparkle.framework/...`.

## What is on this Mac right now

Deployed, all signed ad hoc:

| Path | What |
| --- | --- |
| `/Applications/macSteam.app` | the Photon-route build, `MacsteamApp`, 15,836,304 bytes, Nov 26 23:17, SHA-256 `c53e3f62…`; bundle version still 0.8.10 |
| `/Applications/Steam.app/Contents/MacOS/macsteam.dylib` | our dylib, 317,952 bytes, Nov 24 00:18 |
| `/Applications/Steam.app/Contents/MacOS/notproton.dylib` | rebuilt, 567,888 bytes, Nov 23 23:22 |
| `/Applications/Steam.app/Contents/MacOS/cloud_redirect.dylib` | untouched |

`Info.plist` `LSEnvironment` today:

```
DYLD_INSERT_LIBRARIES = /Applications/Steam.app/Contents/MacOS/macsteam.dylib:.../cloud_redirect.dylib:.../notproton.dylib
LC_ALL                = en_US.UTF-8
MACSTEAM_DISABLE      = GetManifestRequestCode,sendAndRecv
ONLINEFIX_CONFIG      = /Users/falhoo/Library/Application Support/OnlineFixManager/routing.json
ONLINEFIX_LOG         = /Users/falhoo/Library/Application Support/OnlineFixManager/onlinefix.log
ONLINEFIX_SIG         = /Users/falhoo/Library/Application Support/OnlineFixManager/runtime
SDL_JOYSTICK_BLACKLIST_DEVICES = 0x05ac/0x0004
```

`MACSTEAM_FORCE_SPACEWAR_TICKET` is not set. `keepRealAppID` edits in
`~/Library/Application Support/macsteam/config.yaml` do nothing: the dylib reads
`~/Library/Application Support/OnlineFixManager/routing.json` (three games; `3241660`
has `keepRealAppID: true`).

Backups of the previous dylib, if a rollback is needed:
`backups/macsteam-20261124-001132.dylib`, `backups/macsteam-ours-current.dylib`, and
`/Applications/Steam.app/Contents/MacOS/macsteam.dylib.ours`.

### The R.E.P.O. game folder

At 22:50 on 26 November Steam moved `3241660` through `Update Required,Fully
Installed,Files Missing,Uninstalling` to `Uninstalled`. The appmanifest and the
executable are gone, so the game cannot be launched from this copy. The folder still
holds the older fix files and the manager's surviving backups:

- `OnlineFix.ini` with `PhotonIntegration=false`, and no `BepInEx`,
  `Custom.dll`, `winhttp.dll`, `version.dll` or `doorstop_config.ini` at the root.
- `REPO_Data/resources.assets.before-onlinefix-appid` and
  `REPO_Data/globalgamemanagers.before-onlinefix-appid`. The assets still carry
  R.E.P.O.'s own pair, `99515094-45b7-4c98-ab70-a448c548c83d` and
  `dfc40a01-c3a4-4395-9707-b71118816d2b`; the globalgamemanagers header still names
  Unity `6000.3.28f1`.
- `.onlinefix-removed` leftovers (`BepInEx.onlinefix-removed`,
  `Custom.dll.onlinefix-removed`, `doorstop_config.ini.onlinefix-removed`,
  `winhttp.dll.onlinefix-removed`). They are not loaded; do not put them back.

Do not install the chain again on this copy. The route's R.E.P.O. pair check and the
missing executable both say there is nothing to canary here until the game is restored
from an owning account or a backup.

The prefix `user.reg` has `[Software\\Wine\\DllOverrides]` with `winmm.dll`,
`winhttp.dll` and `version.dll` as `native,builtin` and `onlinefix64.dll` as `native`.
No code writes an `AppDefaults` section: NotProton always exports `WINEDLLOVERRIDES`,
and Wine gives that environment variable precedence over the registry. The runner
therefore folds the registry entries into its own `WINEDLLOVERRIDES` before starting Wine.

## How the fix kit works, in short

`scripts/onlinefix-lab.sh` drives the app's own code through
`macSteam.app/Contents/MacOS/MacsteamApp --uninstall-onlinefix`,
`--onlinefix-diagnose <appid>`, `--onlinefix-install <appid>`,
`--onlinefix-repair <appid>`, `--onlinefix-routing-only <appid>`,
`--onlinefix-uninstall <appid>`, `--onlinefix-photon <appid>`, and the read-only
`--onlinefix-photon-audit <appid> [--folder <path>]`. The audit prints the route, every
piece of evidence, the own/shared ids, the chain state and the log it read; it writes
nothing.

One scan of the game and the OnlineFix package produces findings (the `OFnnn` codes in
`docs/onlinefix-errors.md`), the findings produce a `FixPlan`, and the plan is applied and
packed into `<game>/.macsteam-onlinefix/` (`recipe.json` plus `payload/`) so a Steam
verify can be repaired from the pack with no download.

### The post-install audit

`FixService.install` applies the package, forgets the old Photon scan cache, reads the
game again, and runs `FixAudit`. The audit reads four things: the game folder after the
copy, the copies the installed plan says it made, the package, and the API the game is
expected to load. It produces findings `OF100` to `OF110` and a second `FixPlan`, then
`FixApply` applies that plan through the same copy, edit, backup and recipe code. It does
not write files directly, so uninstall and repair keep their exact semantics.

The audit runs after an install and again inside `repair`, including the `repair`
that `verifyAll` runs for every installed pack on launch. That second pass is what
migrates a pack made by an older scanner: its `dlllist.txt` can match the pack and still
be wrong. It skips native Mac builds entirely, and it skips payload, proxy, API, Photon,
ini and list repairs when the installed plan is a routing-only fix, because putting those
files back would undo `keepGameAPI`.

Every package source is checked with `PortableExecutable` before it is copied. A managed
assembly is exempt from bitness. A native payload, proxy or `steam_api` DLL that does
not match the game is a blocking finding when the package has no matching copy, and is
replaced from the package when it has one. A missing API destination is `OF106`; two
destination API DLLs are `OF107`. `OnlineFix.ini` values are compared with the game,
not only checked for presence, so an ini carried over from another game is corrected.

Decisions worth keeping:

- A package that brings OnlineFix's own proxy (`winmm.dll`, `winhttp.dll` or `version.dll`
  exporting `OnlineFix`) is copied as OnlineFix's installer left it. If the game imports a
  different doorway than the package ships (PEAK's GDK package ships `winmm.dll` but the
  player imports `WINHTTP`), the bundled doorway is added beside it.
- A package without that chain, or whose doorway the game never loads, gets the whole
  BepInEx 5.4.23.3 chain and the doorway the game's binaries actually import, unless the
  package is a Microsoft Store (GDK) registration package. Those are blocked by OF080
  instead: a BepInEx chain cannot turn a Steam copy into a registered GDK package.
- Registry DLL overrides are written only in `[Software\\Wine\\DllOverrides]`.
  NotProton always passes its own `WINEDLLOVERRIDES`, and Wine ignores the registry
  whenever that variable is set, so the runner folds the registry entries into its
  environment before launching Wine. A registry edit alone is never enough.
- OF056 (32-bit .NET) and OF060 (no window in the probe) route only, the loader does not
  open those games. OF035 (the package's doorway is not imported) is a notice when the
  bundled chain can cover it and a warning otherwise; OF055 is retired. OF003 blocks only
  a game with no Steam API at all.

The store UI, the `Keep real AppID` toggle (disabled with a Photon note for Photon fixes),
and the ticket trace (`[ticket] dispatch`, `[ticket] reply N bytes`) are all in place.
Ticket handling in the dylib serves Steam's own ticket, then a genuine Spacewar (`480`)
ticket, then a forge; the Spacewar forcing is opt in through
`MACSTEAM_FORCE_SPACEWAR_TICKET`.

## Mac builds

A shipped macOS build loads none of a Windows OnlineFix's files, and the fix's Photon
patch never sees it. The Steam half still works: macSteam's dylib inside Steam supplies
the identity and ticket every game Steam launches inherits. What is left is the game's
own data, and that is what `MacBundlePatch` writes:

- **The Photon app id.** Any Unity build whose id the scanner can place — a
  `PhotonServerSettings` asset, an IL2CPP string literal, or a plain byte search — has
  it replaced with OnlineFix's, in every file that carries it. This is the whole fix for
  such a game; no per-game knowledge is involved.
- **Code changes, per game.** Some games also need an instruction changed in
  `GameAssembly.dylib` (PICO PARK 2's session limit). Those cannot be derived from the
  package, so each is described in a `MacBundlePatch.Profile` by the bytes around it and
  the replacement. A build whose bytes are not the ones the patch was worked out
  against is refused, not corrupted, and the sheet says so.
- **Signing.** Each patched file keeps an untouched copy beside it
  (`.onlinefix-mac-backup`), and the binary and then the bundle are signed again, so
  macOS still runs the game and `codesign --verify --strict` passes.

PICO PARK 2 was the example: `com.tecopark.picopark2` is a profile with one code patch,
and everything else in its bundle is handled by the generic id swap. A game with no
profile is still patched when its id can be read. `MacBundlePatch.profiles` is the whole
per-game list, so adding a game is a profile, not an engine change.

Where it plugs in: `FixBuild` sets `plan.picoPark2` when the folder holds a patchable
bundle (a folder that also holds the Windows build is the forced-Windows install, where
Steam still starts the `.exe`, so the patch is written but the force is left alone), `FixService` writes the patch during install and repair and records the written
files so the fix counts as installed and the game stays routed as itself, `FixPack.undo`
and `OnlineFixRemoval` call `MacBundlePatch.setEnabled(false)`, and `FixCompatibility`
offers rather than refuses the install. `--onlinefix-mac-patch <folder> [--apply] [--off]`
reads, applies and undoes it from the command line.

## Code map

`onlinefix/Sources/OnlineFixApp/`:

| File | What it holds |
| --- | --- |
| `PEExports.swift` | PE export name reader (older, narrow reader) |
| `PortableExecutable.swift` | architecture, managed flag, import table, delay imports and export names, with a small cache |
| `PhotonChain.swift` | doorways, core, plugin, config, `bundle()`, `install`, `imports`, `doorway`, `missing` |
| `PhotonFix.swift` | reads the chain and the Photon patch that is actually on disk; root `Custom.dll` and BepInEx layouts |
| `PhotonPatch.swift` | scans and patches the Photon GUID and Quantum ID in assets, assembly and settings |
| `MacBundlePatch.swift` | the Mac build patch: Photon id swap for any bundle, code changes per profile, backup and re-sign, `--onlinefix-mac-patch` |
| `PicoPark2Patch.swift` | PICO PARK 2's `MacBundlePatch.Profile` by bundle id and AppID, and the thin wrappers the sheet uses |
| `FixBuild.swift` | `FixPlan`, the routing decisions, `addVendorChain` |
| `FixApply.swift` | copies, writes, ini and `dlllist.txt` editors, overlay stubs, backups as `<name>.onlinefix-backup` |
| `FixAudit.swift` | the post-install scan: `OF100` to `OF110`, and the second plan |
| `FixService.swift` | `install`, `repair`, `routingOnly`, `verifyAll`, `uninstall`, `diagnose`, `ensureWine` |
| `FixPackage.swift` | package reading: `iniKeys`, `hashes`, `hasPhotonChain`, `apiItem`, `requiresGDKRegistration` |
| `FixDiagnosis.swift` | the findings, including OF021, OF030, OF035, OF061, OF070 and OF080 |
| `WineOverride.swift` | global and per application DLL overrides |
| `AppModel.swift` | routing entries, `isPhotonFix` |
| `Views.swift` | store card detail and the `Keep real AppID` row |
| `Command.swift` | the command line verbs, `photon` prints Steam's ticket activity |

`src/hooks/hook_ticket.c` and `src/feats/ticket.c` hold the ticket work, and `Makefile`
builds `out/macsteam.dylib`.

`notproton/dylib/feats/compat_run.sh` and
`notproton/app/Sources/NotProtonApp/Resources/payload/run` must stay identical. Both
force `winmm`, `winhttp`, `version` and `onlinefix64` native when the game folder holds
`OnlineFix64.dll`. The executed copy is the staged one at
`~/Library/Application Support/Steam/compatibilitytools.d/notproton-26.3/run`, restaged
from the dylib, so rebuilding the dylib is not enough for a runner change to take effect.
`CrossOverInstaller.swift` and `Resources/crossover-install.sh` are the merged 0.8.5 work,
with the script's licence patch tail deliberately removed.

Tests: `swift test` in `onlinefix/`, 266 Swift Testing tests in 33 suites, all passing;
`macsteam-app` has 46 XCTest cases. Use
`--disable-sandbox` (or `/tmp/swiftshim/swift`) if the macro plugin fails under the
sandbox, and delete `.build/.lock` after a killed run. `git checkout` in `macsteam-repo`
fails with an index lock permission error; use `git_restore` instead.

## Known loose ends

- ~~`docs/onlinefix-errors.md` OF073 still says a Photon game is routed as Spacewar
  whatever the toggle says.~~ Resolved: the routing reads the plan's `keepRealAppID`,
  and that row is gone.
- ~~`--photon-swap` only writes `globalgamemanagers`; it should write
  `resources.assets` too.~~ Resolved: the Photon patch scans both assets and the
  assembly, and the test suite covers the `PhotonServerSettings` field order.
- The Mac build patch is proven on PICO PARK 2 (id swapped, session limit lifted, game
  runs past 15 s with `SteamAPI_Init OK` and AppID 2644470, `--off` restores the
  metadata byte for byte). A second game with a different Photon asset shape has not
  been tried yet; the generic path is the one to watch.
- The route now prefers the ticket or R.E.P.O.'s own pair over a generic Custom.dll
  package. Steam networking alone still does not prove Steam auth, because a custom-auth
  game can use Steam's relay for voice or achievements. A Steam-auth game that is not
  R.E.P.O. and has no log yet can still look like custom auth until its first run writes
  a Player.log. A positive canary on an owned game is the check.
- Photon games nobody owns cannot use a ticket, so they are routed onto OnlineFix's
  shared app with Custom auth (`.customUnlicensed`). The wire part is proven on R.E.P.O.:
  the log shows `Photon - AppId (Realtime): 80449c66…` and Photon's own
  `Authentication type 'Custom' not supported`, so the patched `get_AuthType` is what
  the client sends. What is *not* proven is an accepted connection: all three shared
  apps answer 32755 (`Authentication type not supported`), as does the stock app. The
  next lever is `Custom.dll`'s `AuthParameters`/`UserId` payload — the file is
  VMProtect-packed and has to be decompiled, and its only plaintext GUID
  `9551E103-6003-43B6-9415-D4FF80EEFAEA` is not an app that accepts Custom either.
- A file fixed only by a patch (Photon id or auth) is not an OnlineFix file: it must be
  restored from its backup, not deleted, when the fix comes off. `FixInstaller.uninstall`
  and `FixPack.undo` both check `.onlinefix-photonauth-backup` and
  `.onlinefix-photon-backup` before removing anything, and `FixPack.verify` leaves a
  file the auth patch owns to that patch.
- The SwiftPM release executable needs `@executable_path/../Frameworks` added with
  `install_name_tool` before it is put in the app bundle; otherwise Sparkle fails to
  load at launch. The installed 0.8.10 has that rpath.
- The other OnlineFix manager's `onlinefix.dylib` is byte identical to
  `onlinefix/vendor/onlinefix.dylib` (sha256 `3b10c55658fde5864254ce37f574726c112f6379cfe26705cf778e43b83e298c`).
  It does routing only with no ownership handling, so it cannot replace ours; swapping it
  in emptied the user's library behind "purchase" screens.


## PEAK, tested on 24 November 2026

PEAK is the clean example of why the scanner has to read the package, not only the
game. The only online-fix.me package for PEAK is `PEAK_Fix_Repair_GDK_Generic`:
`GDK_Helper.bat`, `wdapp.exe`, `xsapi.dll`, `OnlineFix64.dll`, `winmm.dll`,
`OnlineFix.ini` with `IsPackaged=false` and `ProductId=9NMKF7LPVX44`. It is the
Microsoft Store fix: the guide installs it by registering `appxmanifest.xml` with
`GDK_Helper`, not by copying files into a Steam folder.

Installing it into the Steam copy does start the game, and the app's automatic Photon
patch writes OnlineFix's ids into `PEAK_Data/resources.assets`. EOS auth then succeeds,
but Photon answers:

```
OperationResponse 230: ReturnCode: 32755 (Failed(2): error response from Steam)
Opening disconnected modal
```

With the same Steam copy and no OnlineFix files, the original Photon ids, and the real
AppID, the game gets through `EOS auth done (0)` and `Photon StartPeerCreated` with no
refusal. So the failure was the GDK store package, not the account ticket.

The scanner now blocks this before copying anything:

- `FixPackage.requiresGDKRegistration` is true when a GDK package ships
  `GDK_Helper.bat` or `wdapp.exe`.
- `GameScan.hasStoreManifest` is true only for a real `AppxManifest.xml`, not for the
  GDK runtime files a Steam build such as PEAK also carries.
- A GDK registration package in a Steam copy produces blocking **OF080**.
- A GDK registration package no longer gets the generic BepInEx chain added; the
  existing chain support still applies to packages that actually ship `Custom.dll`.

The test install left PEAK's original files back in place (`resources.assets` ids
`2be03cc8-3633-4033-a22e-7ef1c243b1fd` and `ba60e90a-af6f-4965-80cf-ff783c91c992`),
removed the BepInEx tree and the `winmm`/`winhttp`/`custom.dll` overrides, and took
PEAK out of My Games and the routing. `--onlinefix-uninstall <appid>` is the per-game
undo used here; the old `--uninstall-onlinefix` still removes the whole manager.

## Photon: what was measured, and why it stops here

After the reset, R.E.P.O. was put back to a working state (OnlineFix's package in the game
folder, `OnlineFix:` entry in `config.yaml` with `KeepRealAppID: false`) and launched
through the client, so the game really runs as Spacewar: the client logs
`networking active: matchmaking uses 480`, `pipe AppID: 3241660 -> 480`, and the game's own
log agrees with `Setting breakpad minidump AppID = 480`.

> **Correction from the latest scans:** `resources.assets` does carry the
> `PhotonServerSettings` pair. R.E.P.O. keeps both fields at offsets 346910360 and
> 346910408 (both the same id), and PEAK at 40038056 and 40038104 (realtime then
> voice). The field-aware patch writes them in order. The assembly can carry another
> copy, which is why the patch also scans the managed assemblies; the statement below
> was written before that scan found the assets pair.

An earlier note claimed the Photon app id was only in
`REPO_Data/Managed/Assembly-CSharp.dll` and not in the assets. The current scanner
disproves that for these builds: it finds the pair in `resources.assets` and (where
present) the assembly, and patches each location it can prove.

Each candidate id was written into the assembly and one connection attempted:

| App id | Where it came from | Photon's answer |
| --- | --- | --- |
| `9551E103-6003-43B6-9415-D4FF80EEFAEA` | the only GUID in OnlineFix's `Custom.dll` | `GetRegions failed … ApplicationNotFound` — not a Photon app at all |
| `9cb5e203-aa4b-4bed-9533-ac78b5672cb4` | `PhotonIDs.knownDefaults` | `32755 (Authentication type not supported (none configured))` — real app, no Steam auth enabled |
| `80449c66-0a91-49a5-acb6-ca805e84e605` | `PhotonIDs.knownDefaults` | `32755 (Failed(2): error response from Steam)` — real app with Steam auth, Steam refuses the ticket |
| `99515094-45b7-4c98-ab70-a448c548c83d` | the game's own app, restored | `32755 (Failed(2): error response from Steam)` — same refusal |

What that means: a Photon app only accepts a ticket Steam signed for the Steam AppID the app
is registered against. Steam signs a ticket for `3241660` only for an account that owns the
game, and this account does not, so the only ticket obtainable here is Spacewar's `480`.
`80449c66` is configured for Steam auth and still refuses a `480` ticket, so it is bound to
some other AppID. There is no client-side setting, patch or dylib hook left that can change
either side of that check.

Also ruled out on the way: OnlineFix's loader never starts under this Wine. Its `winmm.dll`
proxy loads from the game folder, its `DllMain` returns success, and it then never loads
`OnlineFix64.dll` — no exception, no message box, nothing, with both the R.E.P.O. package and
PEAK's. R.E.P.O.'s `UnityPlayer.dll` imports `winmm`, `winhttp` and `version`; PEAK's imports
only `winhttp`, so PEAK's package `winmm.dll` was never loaded at all. That explains one
doorway case, not the loader's failure to start where the doorway did load.

State left behind after the Steam-auth pass: before Steam uninstalled the game at
22:50, the folder had the seven-file OnlineFix package, `OnlineFix.ini` with
`PhotonIntegration=false`, no `BepInEx` tree, no root `Custom.dll` and no
`winhttp.dll`, and the stock pair `99515094…`/`dfc40a01…` in the assets. After the
uninstall only the `.before-onlinefix-appid` copies, the package leftovers and the
routing entry `keepRealAppID: true` remain. The game reached its menu before it was
removed; it never reached a Photon room on this account.

`/Applications/macSteam.app` contains the new SwiftPM release build (still reported as
0.8.10), ad-hoc signed, with `@executable_path/../Frameworks` added so Sparkle loads.
The earlier 0.8.10 executable is backed up under
`~/Library/Application Support/macsteam/backups/`. Nothing is committed and no release
was published.
