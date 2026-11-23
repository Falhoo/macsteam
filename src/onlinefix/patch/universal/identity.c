// Adapted from ElfariaKensington/SomeAppOnlineFix (AGPL-3.0).
#include "../../onlinefix.h"
#include "../../ipc.h"
#include <string.h>

uint32_t of_identity(OFSession session, uint32_t reported) {
    // A fixed game matches players as Spacewar (480): that is the identity every
    // other fixed copy is in, so it is the only one its lobbies are reachable at.
    // "Keep real AppID" is about Steam's own side of the pipe (the client, which
    // needs the real AppID for relay config, appinfo and playtime), not about what
    // the game is told, so it does not bring the real ID back here.
    //
    // The one exception is the start of a launch: some games read their AppID
    // before they have touched Steam networking, and start up badly as 480. The
    // startup patch keeps the real ID for that window only.
    bool restore = session.patches.startup_id && !session.networking;
    return session.game && reported == 480 && restore ? session.game : reported;
}

static OFDispatch utils_original;

static uint64_t utils_hook(void *object, void *request, void *reply, void *context) {
    IPCBuffer *in = request, *out = reply;
    OFSession before = of_session();
    uint32_t method = 0;
    int start = -1;
    if (of_ready && before.game && readable(in, 4) && out &&
        !out->error && !(out->mode & 1) && out->written >= 0 && out->written <= out->capacity) {
        memcpy(&method, in->bytes + in->cursor, 4);
        start = out->written;
    }
    uint64_t result = utils_original(object, request, reply, context);
    if (method != 0x09607ec4 || start < 0 || !readable(out, 0) ||
        out->written < start || out->written - start < 5 || out->bytes[start] != 0x0b)
        return result;
    OFSession after = of_session();
    if (before.generation == after.generation) {
        uint32_t id;
        memcpy(&id, out->bytes + start + 1, 4);
        id = of_identity(after, id);
        memcpy(out->bytes + start + 1, &id, 4);
    }
    return result;
}

OFHook of_identity_hook = {"IClientUtils::__ipc_server_dispatch", (void *)utils_hook, (void **)&utils_original};
