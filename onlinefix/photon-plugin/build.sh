#!/bin/bash
# Builds PhotonDiag.dll. Needs the .NET SDK (6 or newer) and network access once,
# to fetch BepInEx's reference assemblies.
set -euo pipefail
cd "$(dirname "$0")"

command -v dotnet >/dev/null || {
    echo "dotnet is missing. Install the .NET SDK: https://dot.net" >&2
    exit 1
}

dotnet build -c Release -o bin
echo
echo "Built: $(pwd)/bin/PhotonDiag.dll"
echo "Install: copy it into <game>/BepInEx/plugins/ (BepInEx 5, x64, in the same game)."
