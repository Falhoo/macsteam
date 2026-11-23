#!/bin/bash
# OnlineFix lab: the reset, probe, install and run loop for one game at a time.
#
# It drives the app's own code through its command line, so what it does is what the
# app does. Reports are written under ~/Library/Application Support/macSteam/onlinefix-lab.
#
#   ./scripts/onlinefix-lab.sh reset [--keep-gamefiles]
#   ./scripts/onlinefix-lab.sh probe 2644470
#   ./scripts/onlinefix-lab.sh install 2644470 [--name "PICO PARK 2"]
#   ./scripts/onlinefix-lab.sh run 2644470 [seconds]
#   ./scripts/onlinefix-lab.sh repair 2644470
#   ./scripts/onlinefix-lab.sh report [2644470]
#
set -uo pipefail

APP="/Applications/macSteam.app/Contents/MacOS/MacsteamApp"
STEAM="$HOME/Library/Application Support/Steam"
CLIENT="$STEAM/Steam.AppBundle/Steam/Contents/MacOS/steam_osx"
LOGS="$STEAM/logs"
OFM="$HOME/Library/Application Support/OnlineFixManager"
CFG="$HOME/Library/Application Support/macsteam/config.yaml"
LAB="$HOME/Library/Application Support/macSteam/onlinefix-lab"

say() { printf '%s\n' "$*"; }
head1() { printf '\n== %s\n' "$*"; }

need_app() {
    if [ ! -x "$APP" ]; then
        say "macSteam is not at $APP. Install it first."
        exit 1
    fi
}

# The game's Steam name and folder, from its appmanifest.
game_name() {
    local id="$1" manifest="$STEAM/steamapps/appmanifest_$id.acf"
    [ -f "$manifest" ] || return 1
    sed -n 's/.*"name"[[:space:]]*"\(.*\)"/\1/p' "$manifest" | head -1
}

game_dir() {
    local id="$1" manifest="$STEAM/steamapps/appmanifest_$id.acf" dir
    [ -f "$manifest" ] || return 1
    dir=$(sed -n 's/.*"installdir"[[:space:]]*"\(.*\)"/\1/p' "$manifest" | head -1)
    [ -n "$dir" ] || return 1
    printf '%s/steamapps/common/%s' "$STEAM" "$dir"
}

steam_running() { pgrep -x steam_osx >/dev/null 2>&1; }

start_steam() {
    steam_running && return 0
    say "Starting Steam…"
    open /Applications/Steam.app
    local i
    for i in $(seq 1 90); do
        sleep 1
        steam_running && { sleep 5; return 0; }
    done
    say "Steam did not start."
    return 1
}

stamp() { date '+%Y%m%d-%H%M%S'; }

# ---------------------------------------------------------------- reset
cmd_reset() {
    need_app
    local keep=""
    [ "${1:-}" = "--keep-gamefiles" ] && keep="--keep-gamefiles"
    head1 "Removing OnlineFix only"
    "$APP" --uninstall-onlinefix $keep
    local status=$?
    head1 "What is left"
    if [ -d "$OFM" ]; then say "manager folder: still there"; else say "manager folder: gone"; fi
    if grep -q '^OnlineFix:' "$CFG" 2>/dev/null; then
        say "config.yaml: still has an OnlineFix section"
    else
        say "config.yaml: no OnlineFix section"
    fi
    if [ -f "/Applications/Steam.app/Contents/MacOS/onlinefix.dylib" ]; then
        say "Steam.app: onlinefix.dylib still there"
    else
        say "Steam.app: onlinefix.dylib gone"
    fi
    if [ -f "/Applications/Steam.app/Contents/MacOS/macsteam.dylib" ]; then
        say "macSteam injection: still in place"
    else
        say "macSteam injection: MISSING"
    fi
    local left
    left=$(find "$STEAM/steamapps/common" -maxdepth 4 -name '*.onlinefix-*' 2>/dev/null | wc -l | tr -d ' ')
    say "OnlineFix backups left in game folders: $left"
    return $status
}

# ---------------------------------------------------------------- probe
cmd_probe() {
    local id="${1:-}"
    [ -n "$id" ] || { say "usage: $0 probe <appid>"; exit 2; }
    local name dir
    name=$(game_name "$id") || { say "$id is not installed in this Steam library."; exit 1; }
    dir=$(game_dir "$id") || { say "$id has no install folder."; exit 1; }

    head1 "$name ($id)"
    say "folder: $dir"

    head1 "Engine"
    local managed il2cpp
    # A Mac build keeps its data inside the .app bundle, so this looks deeper.
    managed=$(find "$dir" -maxdepth 8 -type d -name Managed 2>/dev/null | head -1)
    il2cpp=$(find "$dir" -maxdepth 8 -type f -name global-metadata.dat 2>/dev/null | head -1)
    if [ -n "$managed" ]; then say "Mono build (Managed assemblies at ${managed#$dir/})"; fi
    if [ -n "$il2cpp" ]; then say "IL2CPP build (metadata at ${il2cpp#$dir/})"; fi
    if [ -z "$managed" ] && [ -z "$il2cpp" ]; then say "no Managed folder and no IL2CPP metadata: engine not recognised"; fi

    head1 "Photon"
    local photon=""
    if [ -n "$managed" ]; then
        photon=$(ls "$managed" 2>/dev/null | grep -i '^photon' | tr '\n' ' ')
        [ -n "$photon" ] && say "assemblies: $photon"
    fi
    if [ -z "$photon" ] && [ -n "$il2cpp" ]; then
        if grep -a -q -m1 'PhotonQuantum' "$il2cpp" 2>/dev/null; then photon="PhotonQuantum"; fi
        if [ -z "$photon" ] && grep -a -q -m1 'PhotonRealtime' "$il2cpp" 2>/dev/null; then photon="PhotonRealtime"; fi
        if [ -z "$photon" ] && grep -a -q -m1 'Photon' "$il2cpp" 2>/dev/null; then photon="Photon (metadata)"; fi
        [ -n "$photon" ] && say "metadata marker: $photon"
    fi
    [ -z "$photon" ] && say "no Photon marker found"

    head1 "Fix files in the game folder"
    local f found=0
    for f in OnlineFix64.dll OnlineFix.dll Custom.dll winmm.dll winhttp.dll dlllist.txt \
             OnlineFix.ini SteamOverlay64.dll steam_api64.dll steam_api.dll; do
        if find "$dir" -maxdepth 3 -iname "$f" -print -quit 2>/dev/null | grep -q .; then
            say "  $f"
            found=1
        fi
    done
    [ $found -eq 0 ] && say "  none"

    head1 "Fix files the app recorded"
    if [ -f "$OFM/games.json" ] && grep -q "\"id\" : $id" "$OFM/games.json"; then
        say "in My Games: yes"
        local missing
        missing=$(sed -n "/\"id\" : $id/,/}/p" "$OFM/games.json" | grep -c '"sizes"' 2>/dev/null)
        say "fix record present: $([ "$missing" -gt 0 ] && echo yes || echo no)"
    else
        say "in My Games: no"
    fi

    head1 "Routing"
    if [ -f "$CFG" ]; then
        if awk '/^OnlineFix:/{f=1;next} /^[^ ]/{f=0} f && $0 ~ /^  '"$id"':/{found=1} END{exit !found}' "$CFG"; then
            say "config.yaml OnlineFix entry: yes"
            awk '/^OnlineFix:/{f=1;next} /^[^ ]/{f=0} f && $0 ~ /^  '"$id"':/{p=1;next} f&&p&&/^  [0-9]/{p=0} f&&p{print "  " $0}' "$CFG"
        else
            say "config.yaml OnlineFix entry: no"
        fi
    else
        say "config.yaml: missing"
    fi

    head1 "Photon patch state"
    local backups
    backups=$(find "$dir" -maxdepth 5 -name '*.onlinefix-picopark2-backup' -o -maxdepth 5 -name '*.onlinefix-photon-backup' 2>/dev/null | wc -l | tr -d ' ')
    say "untouched copies kept: $backups"

    head1 "What the app finds"
    if [ -x "$APP" ]; then
        # Read only: the scan, the pack's state and every finding, with its remedy.
        "$APP" --onlinefix-diagnose "$id" 2>&1 | tail -n +2 | sed 's/^/  /'
    else
        say "  macSteam is not installed, so this cannot be read"
    fi

    head1 "Wine prefix"
    local prefix="$STEAM/steamapps/compatdata/$id/pfx"
    if [ -d "$prefix" ]; then
        say "prefix: yes"
        local reg="$prefix/user.reg" overs
        overs=$(grep -icE '"(winmm|winhttp|version|dinput8|onlinefix64|onlinefix|steam_api64|steam_api|steamoverlay64|dnet)"=' "$reg" 2>/dev/null)
        say "DLL overrides onlinefix needed: ${overs:-0}"
    else
        say "prefix: none yet (Steam makes one on the first launch)"
    fi

    head1 "Launch options"
    local vdf="$STEAM/userdata/1530268740/config/localconfig.vdf" opts
    opts=$(awk '/"'"$id"'"[[:space:]]*\{/{f=1} f && /"LaunchOptions"/{print; exit}' "$vdf" 2>/dev/null)
    say "${opts:-no launch options set}"

    head1 "Verdict"
    if [ -z "$photon" ]; then
        say "not a Photon game: AppID routing is what matters for it"
    elif [ -n "$backups" ] && [ "$backups" -gt 0 ]; then
        say "Photon game with a patch already applied (backups kept beside the files)"
    else
        say "Photon game: its own app id needs OnlineFix's, which the app does when it finds it"
    fi
}

# ---------------------------------------------------------------- install
cmd_install() {
    local id="${1:-}"
    [ -n "$id" ] || { say "usage: $0 install <appid> [--name name]"; exit 2; }
    need_app
    shift
    local name=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --name) name="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done
    [ -z "$name" ] && name=$(game_name "$id")
    head1 "Installing the fix for ${name:-$id}"
    if [ -n "$name" ]; then
        "$APP" --onlinefix-install "$id" --name "$name"
    else
        "$APP" --onlinefix-install "$id"
    fi
    local status=$?
    head1 "After the install"
    "$0" probe "$id"
    return $status
}

# ---------------------------------------------------------------- run
cmd_run() {
    local id="${1:-}" seconds="${2:-90}"
    [ -n "$id" ] || { say "usage: $0 run <appid> [seconds]"; exit 2; }
    local name dir
    name=$(game_name "$id") || { say "$id is not installed in this Steam library."; exit 1; }
    dir=$(game_dir "$id") || { say "$id has no install folder."; exit 1; }
    start_steam || exit 1

    # A copy left running from an earlier run would hide the launch: Steam would
    # refuse the new one and the report would be about the old process.
    local running
    running=$(pgrep -f "$dir" | head -1)
    if [ -n "$running" ]; then
        say "Quitting the copy that is already running (pid $running)…"
        kill "$running" 2>/dev/null
        local wait
        for wait in $(seq 1 15); do
            pgrep -f "$dir" >/dev/null 2>&1 || break
            sleep 1
        done
    fi

    local out="$LAB/$id-$(stamp)"
    mkdir -p "$out"

    local console="$LOGS/console_log.txt" before=0
    [ -f "$console" ] && before=$(wc -l < "$console" | tr -d ' ')
    local onlinefix="$OFM/onlinefix.log" ofbefore=0
    [ -f "$onlinefix" ] && ofbefore=$(wc -l < "$onlinefix" | tr -d ' ')

    head1 "Launching $name ($id)"
    "$CLIENT" -applaunch "$id" >/dev/null 2>&1
    say "Waiting ${seconds}s for it to settle…"
    sleep "$seconds"

    # What Steam did with it.
    if [ -f "$console" ]; then
        tail -n +$((before + 1)) "$console" | grep -i "$id\|error\|failed" > "$out/console.txt"
    fi
    [ -f "$onlinefix" ] && tail -n +$((ofbefore + 1)) "$onlinefix" > "$out/onlinefix.txt"

    # What the game itself wrote. Player.log sits in a folder named after the game, so
    # the newest one written since this started is the one this launch made.
    local player
    player=$(find "$HOME/Library/Logs" -name 'Player.log' -mmin -10 -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null | head -1)
    [ -n "$player" ] && tail -n 120 "$player" > "$out/player.txt"

    # Where it is connected, which is the closest thing to a verdict.
    local pid
    pid=$(pgrep -f "$dir" | head -1)
    if [ -n "$pid" ]; then
        echo "pid: $pid" > "$out/connections.txt"
        lsof -nP -i -a -p "$pid" 2>/dev/null | tail -n +2 >> "$out/connections.txt"
    fi

    {
        echo "# $name ($id) at $(date)"
        echo
        echo "## Steam"
        cat "$out/console.txt" 2>/dev/null || echo "nothing new in console_log.txt"
        echo
        echo "## OnlineFix log"
        cat "$out/onlinefix.txt" 2>/dev/null || echo "no onlinefix.log"
        echo
        echo "## Game log (last 120 lines)"
        cat "$out/player.txt" 2>/dev/null || echo "no Player.log written in the last ten minutes"
        echo
        echo "## Connections"
        cat "$out/connections.txt" 2>/dev/null || echo "the game was not running when this was taken"
    } > "$out/report.md"

    head1 "Report"
    say "$out/report.md"
    cat "$out/report.md"
}

# ---------------------------------------------------------------- repair
cmd_repair() {
    local id="${1:-}"
    [ -n "$id" ] || { say "usage: $0 repair <appid>"; exit 2; }
    need_app
    head1 "Repairing from the fix pack"
    "$APP" --onlinefix-repair "$id"
    local status=$?
    head1 "After the repair"
    "$0" probe "$id"
    return $status
}

# ---------------------------------------------------------------- report
cmd_report() {
    local id="${1:-}"
    local dir
    if [ -n "$id" ]; then
        dir=$(ls -dt "$LAB/$id"-* 2>/dev/null | head -1)
    else
        dir=$(ls -dt "$LAB"/*/ 2>/dev/null | head -1)
        dir="${dir%/}"
    fi
    if [ -z "$dir" ] || [ ! -f "$dir/report.md" ]; then
        say "No report yet. Run '$0 run <appid>' first."
        exit 1
    fi
    cat "$dir/report.md"
}

case "${1:-}" in
    reset) shift; cmd_reset "$@" ;;
    probe) shift; cmd_probe "$@" ;;
    install) shift; cmd_install "$@" ;;
    run) shift; cmd_run "$@" ;;
    repair) shift; cmd_repair "$@" ;;
    report) shift; cmd_report "$@" ;;
    *)
        sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
