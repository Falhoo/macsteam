# OnlineFix: reset and test one game

The loop is: remove OnlineFix, look at what the game is, install its fix, launch it,
read the report. Each step writes down what it saw, so one attempt can be compared
with the next.

Everything below is done by `scripts/onlinefix-lab.sh`, which drives the app's own
code through `macSteam.app --uninstall-onlinefix` and `--onlinefix-install <appid>`.

## What "removing OnlineFix" takes out, and what it leaves

Takes out:

| Where | What |
| --- | --- |
| `~/Library/Application Support/OnlineFixManager` | My Games, the fix records, the routing list, the per-build profiles, the log. Moved to `OnlineFixManager-removed-<stamp>/`, never deleted. |
| `~/Library/Application Support/macsteam/config.yaml` | the `OnlineFix:` block only. The `Apps` list stays, because cloud saves and achievements use it. |
| `/Applications/Steam.app` | `onlinefix.dylib`, and the `ONLINEFIX_SIG`, `ONLINEFIX_CONFIG`, `ONLINEFIX_LOG` keys. Re-signed afterwards. |
| each game folder | the files each fix placed (the game's own files put back), the Photon patches, and whatever an older install left behind, including `BepInEx/`. Moved to `game-files/<game>/` in the same archive folder. |
| each game's Wine prefix | the DLL override lines OnlineFix needed, and only those. |

Leaves: `macsteam.dylib`, `cloud_redirect.dylib`, `notproton.dylib`, the injection
list, both `steam.cfg` update blocks, the signatures, the notproton runners,
launchers and prefixes, and Steam's own compatibility and launch settings.

Two ways to call it:

```
macSteam.app/Contents/MacOS/MacsteamApp --uninstall-onlinefix
macSteam.app/Contents/MacOS/MacsteamApp --uninstall-onlinefix --keep-gamefiles
```

`--keep-gamefiles` leaves the files each fix placed and the Photon patches in place,
so another install needs no download. The manager state and the Steam.app edits still
go.

## The loop

```
scripts/onlinefix-lab.sh reset            # or: reset --keep-gamefiles
scripts/onlinefix-lab.sh probe 2644470
scripts/onlinefix-lab.sh install 2644470
scripts/onlinefix-lab.sh repair 2644470   # from the pack, no download
scripts/onlinefix-lab.sh run 2644470 90
scripts/onlinefix-lab.sh report 2644470
```

An install builds the fix for that game from its package and its own folder, then packs
it in `.macsteam-onlinefix/` beside the game: `recipe.json` says what was found and
written, `payload/` holds a copy of every file it wrote. `repair` compares the recipe
with the folder and copies back what differs, so a Steam verify needs no download.
`--onlinefix-repair --all` does the same for every game, and the app does it on every
start.

`probe` is read only: Mono or IL2CPP, Photon or not, the fix files present, whether the
game is in My Games with a record, its entry in `config.yaml`, its prefix and the DLL
overrides, and its launch options. It then prints what `--onlinefix-diagnose` finds: the
engine, where Steam starts the game, the state of the fix pack, and every finding with
its remedy (`docs/onlinefix-errors.md` has the codes).

Two more commands answer the question the files cannot: does the game actually open?

```
MacsteamApp --onlinefix-routing-only 105600   # put the game's own Steam API back
MacsteamApp --onlinefix-probe 105600 --seconds 90
```

`--onlinefix-routing-only` is the fix for a game whose loader starts and leaves the
process alive with no window, which is what a 32-bit .NET game such as Terraria does
under this Wine (OF056, OF061). The game keeps its own `steam_api.dll`, OnlineFix's
loader is not copied, and macSteam's routing still starts it as 480, so online play
meets the other copies. The same decision is taken on its own when a fix is installed
for such a game.

`--onlinefix-probe` launches the game through Steam, watches for a window owned by the
compatibility layer, stops the game and writes
`~/Library/Application Support/OnlineFixManager/probe-<appid>.json`. The diagnosis reads
that file, so a game that never opened is routed instead of patched (OF060).

An id is found without a per-game entry: a GUID by the settings field it sits beside,
and a Quantum id through the build's own string-literal table, which gives each
literal's length and position. That matters because an IL2CPP build packs its literals
end to end, so the id is glued to its neighbours and never looks like a 64-character
run of its own.

`run` launches the game through Steam, waits, and collects into
`~/Library/Application Support/macSteam/onlinefix-lab/<appid>-<stamp>/`:

- `console.txt`: this AppID's lines from Steam's `console_log.txt`, which is where
  `Game process added`, `AppError_46` and `Failed to spawn process` show up.
- `onlinefix.txt`: what the injected OnlineFix side logged.
- `player.txt`: the tail of the game's own `Player.log`.
- `connections.txt`: the game's sockets, which is the closest thing to a verdict
  (a Photon game that is connected holds a session to a Photon endpoint).
- `report.md`: all of the above in one page.

## What a pass looks like

1. After `reset`: `probe` shows no fix files, no `config.yaml` entry, no DLL
   overrides, no untouched copies; `config.yaml` has no `OnlineFix:` block.
2. After `install`: `probe` shows the fix files, the game in My Games with a record,
   its `config.yaml` entry, and the overrides in its prefix. For a Photon game it also
   shows OnlineFix's app id in the game's files, marked `(OnlineFix's already)`, and
   `Automatic patch: nothing to do`.
3. After `run`: `report.md` holds `Game process added` for the AppID, the game's log
   starting up, and the game still running when the report is taken.

A game that installs and launches but shows no Photon connection is where the next
piece of work goes: its app id was not found in its files, or it does not carry one.
Note that a game sitting at its title screen holds only local sockets: a Photon
session appears once it joins an online room, so that one step is done by hand.

## Mac builds start as themselves

A game whose folder holds a native `.app` loads none of the fix's Windows files, so
routing it as Spacewar (480) gains it nothing, and PICO PARK 2's Mac build closes
itself a second after starting when Steam calls it Spacewar. For those games the app
writes `KeepRealAppID: yes` into `config.yaml` whatever the game's own toggle says,
so what the fix does is the patch in the game's files, not a different AppID.

PICO PARK 2's Mac build, after `install`: both files patched (the Photon app id in
`global-metadata.dat`, the session limit in `GameAssembly.dylib`), the bundle signed
again and verifying, and the game starting as AppID 2644470 and staying up. Its log
shows `Setting breakpad minidump AppID = 2644470`, `QuantumUnityNativeAllocator` and
`ResourceManager initialized`.
