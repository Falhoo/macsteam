# The errors an OnlineFix game runs into

Every rule below is a finding the app makes when it reads a game and a fix package.
A finding says what the player sees, why it happens, and what the build does about
it. Blocking findings stop the install: nothing is copied, because nothing would
work. The rest are worked around, and the fix pack records what was done.

`--onlinefix-diagnose <appid>` prints the findings for a game, read only.

| Code | What the player sees | Why | What the app does |
| --- | --- | --- | --- |
| OF001 | nothing: the game is not installed | there is no game folder to put files in | stops |
| OF002 | the game starts, but never connects | Steam installed the native Mac build, and OnlineFix's files are Windows PE files a Mac process cannot load | copies nothing; routes the game as itself, or applies the file patch a game needs (PICO PARK 2) |
| OF003 | the game stops at `Failed to load xgameruntime.dll. Error code: 126` | the fix or the game is the Microsoft Store (GDK) build, which needs the Xbox runtime that only exists on Windows. A game that also ships Steam's API is the Steam build with GDK support compiled in (PEAK), and it runs | refuses a build with no Steam API at all; a game with Steam's API is installed as usual, with its GDK files and the prefix override |
| OF004 | joining a server is refused | the game ships Easy Anti-Cheat or BattlEye, which OnlineFix and Wine cannot satisfy | refuses, and says why |
| OF010 | the game starts offline, or exits at once | the fix's Steam API DLL is not the copy the game loads, or the game has none | puts the fix's DLL where the game loads it and keeps the game's own copy as a backup |
| OF011 | the game exits at once, or never reaches the menu | the game runs at one bitness and the package only brought the other `steam_api` DLL | refuses, or uses the matching DLL when the package has both |
| OF012 | `SteamAPI_Init` fails and the game exits | the payload and the proxies that start it are not beside the executable, or the package has no payload at all | copies the loader chain to the folder Steam starts the game from |
| OF013 | nothing, or a refusal from OnlineFix itself | `OnlineFix.ini` has no `RealAppId`/`FakeAppId`, or the package shipped none | fills in the app ids; never invents the `[Hashes]` values, and reports a package that disagrees with the game |
| OF014 | the game starts but the fix does nothing | `dlllist.txt` does not name the payload, so the loader never starts it | adds the payload, and `Custom.net` when the Photon patch is there |
| OF015 | a box saying `Failed to load steam overlay dll. Error code: 126`, and Godot or Unity never reaching main | OnlineFix's `SteamOverlay64.dll` loads Valve's renderer, and the compatibility layer prunes that copy on every launch | makes its `DllMain` return TRUE and drops its line from `dlllist.txt`; the overlay is cosmetic |
| OF016 | nothing, or a fix that does not load after a prefix rebuild | Wine answers the loader with its own built-in copy of the proxy DLL | adds the DLL override in the prefix, or says it will on the next pass if the prefix does not exist yet |
| OF017 | the game dies before main, with no log (Godot and Unity) | a copy of `GameOverlayRenderer64.dll` sits beside the game, so Steam takes the game folder for its own client | removes it; the copy that matters lives in the Wine prefix |
| OF020 | `CustomAuthenticationError`, or the game cannot find other players | the game carries its own Photon app id; OnlineFix's players are on a different Photon app | replaces it with OnlineFix's id, keeping the game's file as a backup; leaves two different ids to the patch sheet |
| OF021 | `CustomAuthenticationError` in a Photon game | the package does not carry OnlineFix's Photon patch (`Custom.dll` and its BepInEx preloader), so the game answers an auth it cannot satisfy | installs the chain when the package has it, and says what is missing when it does not |
| OF022 | the same, in a Quantum build or a Mac build | the app id sits in the IL2CPP string table, or the build is a Mac one | finds it through the string-literal table, or patches the Mac build's own files (PICO PARK 2) |
| OF030 | `waiting for... relay` forever, or no matchmaking | the game's online play runs on Steam's relay, which only answers for the AppID Steam believes the game is | keeps the real AppID in the routing; other games are routed as 480 |
| OF031 | a Mac build that closes a second after starting | it is routed as Spacewar, which it cannot use | starts it as itself |
| OF032 | the fix worked, then a Steam verify or an update broke it | Steam put the game's own files back | notices on the next app start, at the Repair button, or with `--onlinefix-repair`, and copies the files back from the pack |
| OF033 | the fix does nothing though it is installed | an earlier install left the loader files at the game root while the game runs one folder down | puts them beside the executable and removes the stray copies |
| OF034 | the game starts with its own Steam API instead of the fix's | two `steam_api` DLLs are reachable and the game loads the untouched one | keeps only the fix's where the game loads it |
| OF040 | the game stops at start in a fresh prefix | the Microsoft VC++ runtime (`msvcp140.dll`, `vcruntime140.dll`) is not in the prefix | reports it, with the winetricks verb to run |
| OF055 | the game starts as Spacewar and never shows a window, with no crash and no log | OnlineFix's loader checks `[Hashes]` of the game's own files, and the package was made from a build Steam has since replaced, so the check never passes | warns, and installs as usual; a probe that sees no window then switches it to the routing-only fix |
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
