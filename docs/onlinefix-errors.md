# The errors an OnlineFix game runs into

Every rule below is a finding the app makes when it reads a game and a fix package.
A finding says what the player sees, why it happens, and what the build does about
it. Blocking findings stop the install: nothing is copied, because nothing would
work. The rest are worked around, and the fix pack records what was done.

`--onlinefix-diagnose <appid>` prints the findings for a game, read only.

The first pass, `FixDiagnosis`, runs before anything is copied and decides whether the
install can start. The second pass, `FixAudit`, runs only inside
`FixService.install`, after the package has been applied. It reads the result on disk
and applies one more normal `FixPlan`, so copies, edits, backups, removals and the
recipe all keep the same meaning as the first pass. A blocking diagnosis stops the
install. A blocking audit finding is reported after the copy and means the audit has no
safe repair with the files at hand; it does not invent a file.

| Code | What the player sees | Why | What the app does |
| --- | --- | --- | --- |
| OF001 | nothing: the game is not installed | there is no game folder to put files in | stops |
| OF002 | the game starts, but never connects | Steam installed the native Mac build, and OnlineFix's files are Windows PE files a Mac process cannot load | copies nothing; routes the game as itself, or applies the file patch a game needs (PICO PARK 2) |
| OF003 | the game stops at `Failed to load xgameruntime.dll. Error code: 126` | the fix or the game is the Microsoft Store (GDK) build, which needs the Xbox runtime that only exists on Windows. A game that also ships Steam's API is the Steam build with GDK support compiled in (PEAK), and those runtime files are not proof that it is a registered package | refuses a build with no Steam API at all; a Steam build with GDK support is only installed when the package is a Steam fix, not a GDK registration package (OF080) |
| OF080 | `OperationResponse 230: ReturnCode: 32755 (Failed(2): error response from Steam)`, then the disconnected modal | the fix is a Microsoft Store package that installs by registering an Appx manifest with `GDK_Helper`; the game is a Steam install with no Appx manifest, so copying the files cannot register it and the game still authenticates as Steam | refuses before copying anything, and names the store mismatch. PEAK's only online-fix.me package is this kind |
| OF100 | the game starts offline, or the fix does nothing | a file the install wrote is no longer in the game folder, or the package did not carry a file the plan expected | copies it back from the package or the fix pack; a file with no copy anywhere is a blocking finding |
| OF101 | the game exits at once, or a loader error | a payload, proxy or `steam_api` DLL has the wrong bitness for the game, or the package carries only the other build | replaces a wrong installed copy when the package has the matching build, otherwise reports the package/build mismatch; a managed assembly is exempt |
| OF102 | the game starts but the fix's doorway never loads | the proxy the game imports is missing beside the executable, or a loader file sits at the install root while the game runs one folder down | copies the proxy back from the package, or removes the stray root copy |
| OF103 | `CustomAuthenticationError`, or the Photon patch does nothing | `Custom.dll` is missing, or the BepInEx preloader, doorstop or a core file is missing while the plugin layout needs the chain | copies the package's own `Custom.dll` when it has one, otherwise completes the bundled chain at the doorway the game imports; a root `Custom.dll` loaded by `dlllist.txt` does not need the chain |
| OF105 | the game loads Wine's own proxy instead of the fix's | the prefix has no native override for the doorway that is in the game folder, and NotProton's `WINEDLLOVERRIDES` hides the registry | writes the override in `user.reg` and into the launch environment the runner reads, or reports it if the prefix is not there yet |
| OF106 | `SteamAPI_Init` fails, or the game exits at once | the package has the right `steam_api` DLL but it is not in the folder the game loads it from | copies it to the API destination the scan found |
| OF107 | the game loads the untouched Steam API | two `steam_api` DLLs are reachable from the game | reports both and keeps the fix's copy where the game loads it |
| OF109 | `SteamAPI_Init` fails, or Photon stays off | `OnlineFix.ini` is missing, has wrong app ids, or says `PhotonIntegration=false` | copies the package's ini back, corrects missing or wrong app ids, and replaces a false Photon value in place |
| OF110 | the game starts but the payload or Photon patch never starts, or a box says `Failed to load  from the list. Error code: 126` | `dlllist.txt` is missing or does not name the payload; it names `Custom.net`; `SteamOverlay64.dll` is missing or is not the first line; or a blank line, usually a trailing newline, is read as an empty DLL name | creates or completes the list, removes `Custom.net`, keeps `SteamOverlay64.dll` first when it exists, and writes the list with no blank lines or trailing newline |
| OF004 | joining a server is refused | the game ships Easy Anti-Cheat or BattlEye, which OnlineFix and Wine cannot satisfy | refuses, and says why |
| OF010 | the game starts offline, or exits at once | the fix's Steam API DLL is not the copy the game loads, or the game has none | puts the fix's DLL where the game loads it and keeps the game's own copy as a backup |
| OF011 | the game exits at once, or never reaches the menu | the game runs at one bitness and the package only brought the other `steam_api` DLL | refuses, or uses the matching DLL when the package has both |
| OF012 | `SteamAPI_Init` fails and the game exits | the payload and the proxies that start it are not beside the executable, or the package has no payload at all | copies the loader chain to the folder Steam starts the game from |
| OF013 | nothing, or a refusal from OnlineFix itself | `OnlineFix.ini` has no `RealAppId`/`FakeAppId`, or the package shipped none | fills in the app ids; never invents the `[Hashes]` values, and reports a package that disagrees with the game |
| OF014 | the game starts but the fix does nothing, or a box says `Failed to load from the list. Error code: 126` | `dlllist.txt` does not name the payload, names `Custom.net`, has a blank line, or puts the overlay after the first line. The pre-install scan reads a list an earlier attempt left behind; the package is checked as well | adds the payload, a root `Custom.dll` when the Photon patch is there, and rewrites a broken installed list; never `Custom.net` |
| OF015 | a box saying `Failed to load steam overlay dll. Error code: 126`, and Godot or Unity never reaching main | OnlineFix's `SteamOverlay64.dll` loads Valve's renderer, and the compatibility layer prunes that copy on every launch | makes its `DllMain` return TRUE but keeps its line first in `dlllist.txt`; OnlineFix64 refuses a list without it, and the overlay is cosmetic |
| OF016 | nothing, or a fix that does not load after a prefix rebuild | Wine answers the loader with its own built-in copy of the proxy DLL | adds the DLL override in the prefix and in NotProton's launch environment, or says it will on the next pass if the prefix does not exist yet |
| OF017 | the game dies before main, with no log (Godot and Unity) | a copy of `GameOverlayRenderer64.dll` sits beside the game, so Steam takes the game folder for its own client | removes it; the copy that matters lives in the Wine prefix |
| OF018 | the game starts, but online play meets the wrong players | a stale `steam_appid.txt` beside the executable tells every Steam API call a different AppID than the one Steam routed | warns before anything is copied; the player removes the file or sets it to the game's AppID. A value of 480 is the Spacewar identity the routing asks for, so it is left alone |
| OF020 | `CustomAuthenticationError`, or the game cannot find other players | the game carries its own Photon app id; OnlineFix's players are on a different Photon app | replaces it with OnlineFix's id, keeping the game's file as a backup; leaves two different ids to the patch sheet |
| OF021 | `CustomAuthenticationError` in a Photon game | the package does not carry OnlineFix's Photon patch (`Custom.dll` and its BepInEx preloader), so the game answers an auth it cannot satisfy | installs the package's chain when it has one; otherwise copies the bundled BepInEx chain behind the doorway the game imports, and warns only when no doorway can be loaded |
| OF022 | the same, in a Quantum build or a Mac build | the app id sits in the IL2CPP string table, or the build is a Mac one | finds it through the string-literal table, or patches the Mac build's own files (PICO PARK 2) |
| OF030 | `waiting for... relay` forever, or no matchmaking | the game's online play runs on Steam's relay, which only answers for the AppID Steam believes the game is | keeps the real AppID in the routing, and writes that decision back to the game after an install; other games are routed as 480 |
| OF031 | a Mac build that closes a second after starting | it is routed as Spacewar, which it cannot use | starts it as itself |
| OF032 | the fix worked, then a Steam verify or an update broke it | Steam put the game's own files back | notices on the next app start, at the Repair button, or with `--onlinefix-repair`, and copies the files back from the pack |
| OF033 | the fix does nothing though it is installed | an earlier install left the loader files at the game root while the game runs one folder down | puts them beside the executable and removes the stray copies |
| OF034 | the game starts with its own Steam API instead of the fix's | two `steam_api` DLLs are reachable and the game loads the untouched one | keeps only the fix's where the game loads it |
| OF040 | the game stops at start in a fresh prefix | the Microsoft VC++ runtime (`msvcp140.dll`, `vcruntime140.dll`) is neither beside the game nor in its prefix. A runtime already in the prefix counts, so a game that has run once is not warned about | reports it, with the winetricks verb to run |
| OF035 | the game starts but the fix does nothing | the package's doorway DLL (`winmm.dll`, `winhttp.dll` or `version.dll`) is not one the game imports, so Windows never loads it | copies the bundled doorway the game actually imports, with BepInEx's core and `Custom.dll`; a warning only when no bundled chain can be loaded |
| OF056 | the same, in a .NET Framework game | the game is built for 32-bit Windows, and OnlineFix's 32-bit loader starts inside the .NET process and leaves it alive with no window (Terraria) | keeps the game's own Steam API and copies none of the loader; the routing still starts it as 480 |
| OF060 | the game closes, or nothing appears at all | the last launch probe started the game through Steam and no window appeared in the time it waited | records it in `probe-<appid>.json`, and offers the routing-only fix |
| OF061 | the same, once the files are in place | the loader is not what makes this game work here: macSteam's routing already gives it the Spacewar identity the other copies meet on | puts the game's own Steam API back and leaves the loader out; `--onlinefix-routing-only <appid>` does it on its own |
| OF070 | `Failed to connect to Photon Network`, in any Photon game | the game's text for every reason Photon can refuse. Its own log says which one: the AppID it ran as, Photon's return code, and the message naming the side that refused. `error response from Steam` is Steam refusing to vouch for the game's auth ticket | reports it in the fix card and with `--onlinefix-photon <appid>`. A ticket Steam will not vouch for needs the game's own AppID and a ticket Steam issues itself; no file in the game folder changes that |

## The Photon answer

`Failed to connect to Photon Network` is the game's text for every reason Photon can
refuse, so it says nothing about the cause. The game's own log does:
`--onlinefix-photon <appid>` reads the newest `Player.log` in its Wine prefix (or
`PhotonDiag.log`, if the diagnostic plugin was run) and reports the AppID the game ran
as, Photon's return code, its message, and what that means. `FixDiagnosis` adds the same
as OF070, so the fix card says it too.

PEAK is the case that separates the two: its official Steam build reaches Photon and
EOS auth with no refusal, but copying the Microsoft Store GDK package into it makes
Photon answer `32755`. That is a store mismatch, not a missing Photon `Custom.dll`:
the package has no `Custom.dll` and no BepInEx chain, and adding a generic one does not
change the Steam ticket Photon sees.

## The launch probe

Files in the right place are not proof that a game runs. `--onlinefix-probe <appid>`
starts the game through Steam, watches for a window owned by the compatibility layer,
stops it again and writes the result to
`~/Library/Application Support/OnlineFixManager/probe-<appid>.json`. The next
diagnosis reads that file, so a game that never opened is routed instead of patched.

## The fix pack

An install leaves `.macsteam-onlinefix/` in the folder Steam starts the game from:

- `recipe.json`: the app id and name, the package it came from, every finding, every
  file it wrote with its size and sha256, what it removed, and the routing and Photon
  decisions.
- `payload/`: a copy of every file it wrote, holding the edited `OnlineFix.ini` and
  `dlllist.txt` as well as the payload.

`--onlinefix-repair <appid>` compares the recipe with the folder and copies back what
differs, without a download. `--onlinefix-repair --all` does that for every game. A
Steam verify that removes the pack means the fix has to be installed again.
