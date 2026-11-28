#!/bin/bash
# Builds MacsteamAutopilot.dll: the managed payload, then the native shim with the
# payload's bytes compiled in.
#
# Needed only when the payload changes — the built DLL is committed and shipped, so
# players never need a compiler. Requires Mono's C# compiler (`mcs`) and a Windows
# cross compiler (`x86_64-w64-mingw32-gcc`), both from Homebrew.
set -euo pipefail
cd "$(dirname "$0")"

MCS="${MCS:-mcs}"
CC="${CC:-x86_64-w64-mingw32-gcc}"
out="../vendor/autopilot"
mkdir -p "$out" /tmp/macsteam-autopilot

"$MCS" -target:library -optimize+ -deterministic \
    -out:/tmp/macsteam-autopilot/MacsteamAutopilot.payload.dll \
    managed/Autopilot.cs

# The payload as a C array. `xxd -i` names it after the file, so the names are fixed
# up to the two the shim uses.
xxd -i /tmp/macsteam-autopilot/MacsteamAutopilot.payload.dll \
    | sed -e 's/^unsigned char .*\[\] = {/static const unsigned char payload_bytes[] = {/' \
          -e 's/^unsigned int .*_len = /static const unsigned int payload_length = /' \
    > /tmp/macsteam-autopilot/payload.h

"$CC" -shared -O2 -municode -Wall -Wextra -o "$out/MacsteamAutopilot.dll" \
    -I/tmp/macsteam-autopilot native/shim.c -static-libgcc \
    -Wl,--kill-at 2>/dev/null \
 || "$CC" -shared -O2 -Wall -Wextra -o "$out/MacsteamAutopilot.dll" \
    -I/tmp/macsteam-autopilot native/shim.c

strip --strip-unneeded "$out/MacsteamAutopilot.dll" 2>/dev/null || true
ls -la "$out/MacsteamAutopilot.dll"
