# OnlineFix on macOS: handover

Written at the point the work was stopped. Everything below is what is on this Mac
right now, what was tried, what each attempt showed, and what to do next. Nothing here
is committed to git: the project folder itself is not a repository, and `macsteam-repo/`
is a stale copy that predates most of this work.

> **Latest code pass, before the live-game checks below were made:** every install now
> runs a second scan after the package is applied. It compares the game folder, the
> installed copies, the package and the expected API, and applies a normal `FixPlan`
> again for anything the first pass missed. The audit also copies the bundled BepInEx
> chain when a Photon package has no chain or has a doorway the game does not import,
> creates a missing `dlllist.txt`, repairs the ini and the list after a Steam verify,
> and leaves a routing-only fix routing-only. A wrong-bit API, payload or proxy is
> replaced when the package carries the matching copy; wrong `RealAppId`/`FakeAppId`
> values are corrected, not only missing keys added; and a subfolder game's chain is
> checked beside its executable. The plan's `keepRealAppID` decision is
> written back to the game's routing entry, so Steam-relay games are not silently left
> on 480 after an install. The pack records each Photon-patched file's own target ids.
> `swift test --disable-sandbox` is 183 tests in 25 suites. These are code checks and
> scans, not a new live PEAK or R.E.P.O. connection test.

## The goal, and where it stands

OnlineFix games should run on macOS with working Photon multiplayer, starting with PEAK
(`3527290`) and R.E.P.O. (`3241660`). Single player, the fix install, the overlay
workaround, the loader chain and the routing all work. **Photon still does not connect.**
That is the one open problem.

| Part | State |
| --- | --- |
| OnlineFix-only test lab (reset, probe, install, repair, run, report) | done, `scripts/onlinefix-lab.sh` and `docs/onlinefix-test.md` |
| Fix kit: one scan plus findings plus a plan, packed into `<game>/.macsteam-onlinefix/` | done, works for any game, not just Terraria |
| Install only when the game is actually installed | done, `Store.isInstalled` (manifest `StateFlags` 4 bit plus an exe or `.app`) |
| Store UI shows what the install is doing, not just `Installing ____.rar` | done |
| GDK warning text | changed to `This game is like one of the few that aint gonna connect, try if you want ig tho` |
| CrossOver install merged from `macsteam-0.8.5` | done, and the OnlineFix buttons are enabled again |
| PEAK boots | yes |
| PEAK / R.E.P.O. Photon connect | not retested after the bundled-chain and AppID-routing changes; the earlier measurements below are historical |

## The Photon problem, precisely

Photon runs on a per game application registered with Exit Games, and that application
is tied to the game's own Steam AppID. Two configurations were tried, and both are
refused by a different side:

| Configuration | What the game sends | What comes back |
| --- | --- | --- |
| Real AppID (`keep-id=1`, the current state) | a ticket for `3241660` | `OperationResponse 230: ReturnCode: 32755 (Parameter invalid)` |
| Spacewar (`keep-id=0`) | a ticket for `480`, or none | `ReturnCode: 32755 (Failed(2): error response from Steam)`, or `Parameter invalid` |

`Parameter invalid` is Photon rejecting the session parameter, so the ticket is either
empty or not one Steam signed for that AppID. `error response from Steam` is Steam
refusing to vouch for the ticket at all.

What the game's own logs say, in `REPO_Data/PhotonDiag.log`, `REPO_Data/Player.log` (or
the `Player.log` beside the exe) and `BepInEx/LogOutput.log`:

```
Photon - AppId (Realtime): 99515094-45b7-4c98-ab70-a448c548c83d
Disconnected from server for reason CustomAuthenticationFailed
```

`app=3241660 session=480 keep-id=1` in `~/Library/Application Support/macsteam/macsteam.log`
is the last launch recorded. `BepInEx/LogOutput.log` has never appeared in either REPO or
PEAK, which is the clearest sign that **OnlineFix's own loader (`OnlineFix64.dll`) never
initialises under this Wine prefix**. That loader is what reports the fake AppID to the
game and what runs OnlineFix's Photon patch, so without it the game joins Photon as
itself and there is no ticket for a game the account does not own.

`OnlineFix64.dll` cannot be patched to work around this. Its PE has `.text`, `.rdata` and
`.data` with zero raw size and the real image in an encrypted `.ofme2` section (12.5 MB,
entropy 7.68), with no readable strings.

The user's account does not own `3241660`: the injected licence package in
`config.yaml` does not list it (the id appears in an earlier `apps` list only).

## Next steps, in order

Ask before changing anything. The user asked to be told what a change does before it is
applied, and to confirm the real-AppID switch explicitly.

1. **The one untried configuration.** Every hookable feature on, so `TicketForge` and
   `TicketReader` install, with `keepRealAppID: true` for `3241660`. That means removing
   `MACSTEAM_DISABLE` from `Info.plist` entirely (today it holds
   `GetManifestRequestCode,sendAndRecv`). The hope is that the client signs a ticket for
   `3241660` itself from the injected licence. Explain this before applying it.
2. **Two candidate Photon app ids, one per launch**, one line of feedback from the user
   after each: `9cb5e203-aa4b-4bed-9533-ac78b5672cb4`, then
   `f06cfaa3-c29b-4dba-a8ca-551f45bf9b6d`. Patch **both**
   `REPO_Data/resources.assets` and `REPO_Data/globalgamemanagers` by hand; the CLI
   `--photon-swap` only writes `globalgamemanagers`, and the game reads the id from
   `resources.assets`.
3. **If Photon still refuses**, say plainly that Photon's application is registered to
   the game's own AppID and no client side change can pass it. The only remaining route
   is OnlineFix's loader, which is packed and does not start under this prefix.

## What is on this Mac right now

Deployed, all signed ad hoc:

| Path | What |
| --- | --- |
| `/Applications/macSteam.app` | the app, `MacsteamApp`, 14,431,952 bytes, Nov 24 00:00 |
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

`…/steamapps/common/REPO` holds the package's own files and nothing of ours: `OnlineFix.ini`
(`RealAppId=3241660`, `FakeAppId=480`, `PhotonIntegration=true`), `dlllist.txt`,
`OnlineFix64.dll`, `winmm.dll`, `Custom.dll`, `SteamOverlay64.dll` (stubbed `DllMain`,
dated Nov 24 00:05), `BepInEx/core/BepInEx.Preloader.dll`, `OnlineFix.url`, and
`REPO_Data/Plugins/x86_64/steam_api64.dll`. There is no `steam_appid.txt` and no
`.macsteam-onlinefix` pack. `dlllist.txt` names `SteamOverlay64.dll` as its first line,
and it stays there: OnlineFix64 stops with error 126 when that entry is missing or empty.

Two things were done by hand and should be undone when convenient:

- **Photon id swapped** in `REPO_Data/resources.assets` and
  `REPO_Data/globalgamemanagers` to `80449c66-0a91-49a5-acb6-ca805e84e605`. Put the
  originals back from `resources.assets.onlinefix-photon-backup` and
  `globalgamemanagers.onlinefix-photon-backup` in the same folder.
- **Verbose Wine logging is on**: `.macsteam-winelog` sits in the game folder, which makes
  the runner pass `WINEDEBUG=+loaddll,err+all,fixme-all`. Delete that marker when the
  logs are no longer wanted.

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
`--onlinefix-uninstall <appid>` and `--onlinefix-photon <appid>`.

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

## Code map

`onlinefix/Sources/OnlineFixApp/`:

| File | What it holds |
| --- | --- |
| `PEExports.swift` | PE export name reader (older, narrow reader) |
| `PortableExecutable.swift` | architecture, managed flag, import table, delay imports and export names, with a small cache |
| `PhotonChain.swift` | doorways, core, plugin, config, `bundle()`, `install`, `imports`, `doorway`, `missing` |
| `PhotonFix.swift` | reads the chain and the Photon patch that is actually on disk; root `Custom.dll` and BepInEx layouts |
| `PhotonPatch.swift` | scans and patches the Photon GUID and Quantum ID in assets, assembly and settings |
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

Tests: `swift test --disable-sandbox` in `onlinefix/`, 183 passing in 25 suites. Use
`--disable-sandbox` (or `/tmp/swiftshim/swift`) because the macro plugin fails under the
sandbox, and delete `.build/.lock` after a killed run. `git checkout` in `macsteam-repo`
fails with an index lock permission error; use `git_restore` instead.

## Known loose ends

- ~~`docs/onlinefix-errors.md` OF073 still says a Photon game is routed as Spacewar
  whatever the toggle says.~~ Resolved: the routing reads the plan's `keepRealAppID`,
  and that row is gone.
- ~~`--photon-swap` only writes `globalgamemanagers`; it should write
  `resources.assets` too.~~ Resolved: the Photon patch scans both assets and the
  assembly, and the test suite covers the `PhotonServerSettings` field order.
- Nothing is committed. `macsteam-repo/` predates this work, so the merge, the ticket
  work, the CrossOver install and the fix kit exist only in the working tree here.
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

State left behind: the game folder holds OnlineFix's package with the client routing it as
480, the assembly carries the game's own Photon ids again, and Steam runs the clean 0.8.5
`macsteam.dylib`. The instrumented build is not installed.
