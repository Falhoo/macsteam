# Photon Diagnostics

A BepInEx 5 plugin that logs what a Unity game asks Photon for. It changes nothing: no auth is
rewritten, no connection is altered, and every hook is wrapped so a missing Photon type is
logged and skipped instead of thrown into the game.

It exists because a Photon fix cannot be written from guesses. PEAK, R.E.P.O. and the rest each
pick their own app id, region and auth values, and the server decides whether to accept them.
This plugin writes down what the game actually sends and what Photon answers.

## What it writes

`PhotonDiag.log` in the game folder, and the same lines in BepInEx's log:

- the configured app ids and version (`AppIdRealtime`, `AppIdVoice`, `AppVersion`, region),
- `OpAuthenticate`: auth type, user id, token type and length, every `AuthGetParameters` entry,
  the ticket argument, and the app id/region arguments,
- `ConnectToRegionMaster` and `PhotonNetwork.ConnectUsingSettings`,
- every status change, every operation response (`op`, `return`, Photon's debug message),
- `OnError` and `OnDisconnected` with the disconnect cause,
- Photon's own debug lines that mention auth, connect, error or fail.

A token is logged by type and length only, never its contents.

## Build

```bash
./build.sh
```

Needs the .NET SDK 6 or newer. The project targets `net472` (BepInEx 5) and pulls the reference
assemblies from NuGet, so it builds on macOS too. Output: `bin/PhotonDiag.dll`.

## Install

1. Install BepInEx 5 (x64) into the game, the usual way: unzip it into the game folder and run
   the game once. BepInEx uses `winhttp.dll` as its doorway; OnlineFix uses `winmm.dll`, so the
   two can sit in the same folder.
2. Copy `bin/PhotonDiag.dll` into `<game>/BepInEx/plugins/`.
3. Run the game, try to join or host, then quit.

## Reading the result

The useful lines for a fix are:

- `AppIdRealtime = …` — which Photon app the game uses. Two players must be on the same one.
- `auth type = …` — `None` means anonymous, `Custom` means the server validates something the
  game sends (PEAK sends a Steam ticket).
- `auth param …` — the keys the game's backend expects.
- `response op=… return=…` and `error: …` — the exact rejection, e.g. `CustomAuthenticationFailed`.

If `auth type` is `Custom` and the server rejects the ticket, no client-side plugin can make a
non-owned copy connect: the ticket has to be one Steam genuinely issues for the account that owns
the game. OnlineFix does not mint one either, it emulates Steam in the process and changes what
the game sends, per game. If `auth type` is `None`, the app takes anonymous players and a plugin
can connect without ownership, though the game's own backend may still refuse later.

## Limits

- Reflection only, so it loads in PUN1 and PUN2 games, but a game that strips Photon's type names
  or uses IL2CPP will show fewer lines.
- It does not install BepInEx for you, and it is not bundled with the macSteam app: it is a
  diagnostic, not a fix.
