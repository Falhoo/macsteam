# OnlineFix Manager (inside macSteam)

OnlineFix Manager's **My Games** and **Add Games** pages, built as a Swift package
(`OnlineFixApp`) that the macSteam config app hosts in its own sidebar, under the
**OnlineFix** group.

Everything here is the stand-alone manager's source unchanged — `Types`, `Paths`,
`Store`, `AppModel`, `FixSource`, `FixInstaller`, `Steam`, `SteamCatalog`, `Views`. Only
its `App.swift` (the `@main` window) is left out; `Sources/OnlineFixApp/Embed.swift`
replaces it with the small public surface macSteam uses.

## How it fits together

- `Sources/OnlineFixApp/Embed.swift` — `OnlineFixEmbed.Screen` (`.myGames`, `.addGames`),
  `viewController(for:)` and `refresh()`.
- `macsteam-app/Package.swift` — adds this folder as a local package (`../onlinefix`) and
  the `OnlineFixApp` product to `MacsteamApp`.
- `macsteam-app/Sources/MacsteamApp/SidebarViewController.swift` — the OnlineFix group
  with My Games and Add Games.
- `macsteam-app/Sources/MacsteamApp/MainViewController.swift` — routes those leaves to
  `OnlineFixEmbed.viewController(for:)`.
- `scripts/build-onlinefix.sh` — the OnlineFix build step, run by the repo's `build.sh`.
  It copies `vendor/onlinefix.dylib`, `vendor/7zz` and `vendor/runtime/*.json` into the
  assembled app's `Contents/Resources`, which is where the module looks for them.

## Building

Nothing separate to build: `./build.sh` in the repo root compiles this package as part of
the app and runs `scripts/build-onlinefix.sh`.

To type-check this module on its own:

    cd onlinefix && swift build --disable-sandbox

## Bundled resources (`vendor/`)

| file | why |
|---|---|
| `onlinefix.dylib` | the injected client patch |
| `7zz` | 7-Zip, for extracting fix archives |
| `runtime/*.json` | Steam compatibility profiles, including **1794536281** |

## State and data

The pages read and write the same `games.json` the stand-alone manager uses, under
`~/Library/Application Support/OnlineFixManager/`, so an existing list carries over.

## Known limits (unchanged from the stand-alone app)

1. **The dylib is not rebuildable from here.** It is a compiled binary; the app can only
   deploy it. If a future Steam build changes, the fix is a new `runtime/<build>.json`
   profile, not a code change in this module.
2. **Online play for a Steamworks game needs the game-side package.** The Steam-side
   routing alone doesn't replace Steam's API DLL; use **Apply Fix** for that.
