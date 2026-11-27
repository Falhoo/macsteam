// Ticket trickery
#include "ticket.h"
#include "../config/config.h"
#include "../onlinefix/onlinefix.h"
#include "../util/log.h"
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdatomic.h>

typedef void (*fn_put_bytes)(void *buf, const void *src, int len);
typedef void (*fn_put_tag)(void *buf, unsigned tag);
typedef int  (*fn_get_bytes)(void *buf, void *dst, int64_t len);

static fn_put_bytes g_put_bytes = NULL;
static fn_put_tag   g_put_tag   = NULL;
static fn_get_bytes g_get_bytes = NULL;

void sx_ticket_set_helpers(uintptr_t put_bytes, uintptr_t put_tag,
                           uintptr_t get_bytes) {
    g_put_bytes = (fn_put_bytes)put_bytes;
    g_put_tag   = (fn_put_tag)put_tag;
    g_get_bytes = (fn_get_bytes)get_bytes;
}

static int utlbuf_read(void *buf, void *dst, int len) {
    if (!g_get_bytes) return 0;
    return g_get_bytes(buf, dst, len);
}

#define IMPL_VTABLE_SLOT 0x348

typedef int64_t (*fn_get_ticket_impl)(void *self, uint32_t appId, void *buf,
                                       uint32_t bufMax, uint32_t *pOffAppId,
                                       uint32_t *pOffSteamId, uint32_t *pOffSig,
                                       uint32_t *pSigSize);

// Spacewar: every account owns it, so Steam always signs a ticket for it, and
// OnlineFix's Photon apps are registered against it. It is also the source a ticket is
// taken from: a ticket for 7 is signed, but Photon's Steam check refuses it, because
// the app names 480 as the AppID it accepts.
#define SPACEWAR_APPID     480
#define SOURCE_APPID       SPACEWAR_APPID
static _Atomic(uint32_t) g_source_app = SOURCE_APPID;
uint32_t sx_ticket_source_app(void) { return atomic_load(&g_source_app); }
void sx_ticket_set_source_app(uint32_t app_id) {
    if (app_id) atomic_store(&g_source_app, app_id);
}
#define MAX_TICKET_BUF     4096

static int should_forge(uint32_t app_id) {
    sx_config_t *cfg = sx_config_current;
    if (!cfg || !sx_config_has_app(cfg, (int)app_id))
        return 0;
    return 1;
}

static void serialize_response(void *resp, int64_t totalSize, const void *ticket,
                               uint32_t cbMaxTicket, uint32_t offAppId,
                               uint32_t offSteamId, uint32_t offSig,
                               uint32_t sigSize) {
    uint32_t v;

    g_put_tag(resp, 0x0B);

    v = (uint32_t)totalSize;
    g_put_bytes(resp, &v, 4);

    g_put_bytes(resp, ticket, (int)cbMaxTicket);

    v = offAppId;
    g_put_bytes(resp, &v, 4);

    v = offSteamId;
    g_put_bytes(resp, &v, 4);

    v = offSig;
    g_put_bytes(resp, &v, 4);

    v = sigSize;
    g_put_bytes(resp, &v, 4);
}

int sx_ticket_serve_extended(void *server_this, void *reqReader, void *respWriter) {
    if (!g_put_bytes || !g_put_tag || !g_get_bytes) {
        SX_LOG_ONCE("GetAppOwnershipTicketExtendedData: helpers unresolved");
        return 0;
    }

    uint32_t req_appId = 0, req_cbMax = 0, req_fence = 0;
    utlbuf_read(reqReader, &req_appId, 4);
    utlbuf_read(reqReader, &req_cbMax, 4);
    utlbuf_read(reqReader, &req_fence, 4);

    if (req_cbMax == 0 || req_cbMax > MAX_TICKET_BUF)
        return 0;

    fn_get_ticket_impl impl = *(fn_get_ticket_impl *)(*(uintptr_t *)server_this + IMPL_VTABLE_SLOT);

    // Steam's own ticket first. It is signed for this app, so anything that checks it
    // with Steam (Photon's servers, EOS, a game's backend) accepts it. A forged one is
    // a genuine ticket with the app id spliced in, and the signature covers that field:
    // Steam answers "error response from Steam" and Photon reports
    // CustomAuthenticationFailed. The forge is only for the apps Steam will not issue a
    // ticket for at all.
    uint8_t *ticket_buf = (uint8_t *)calloc(1, req_cbMax);
    if (!ticket_buf) return 0;

    // On the Spacewar route the game is not itself: Steam tracks it as 480, and the
    // Photon app an OnlineFix copy connects to is registered against 480. A ticket the
    // client signs here carries the game's own id, because macSteam answers ownership
    // for it, and Photon's Steam check then refuses it ("error response from Steam",
    // CustomAuthenticationFailed). Asking for 480 up front is what makes the ticket one
    // Steam vouches for. A game kept on its real AppID still asks for its own.
    {
        OFSession session = of_session();
        if (session.game && !session.keep_id) req_appId = SPACEWAR_APPID;
    }

    uint32_t offAppId = 0, offSteamId = 0, offSig = 0, sigSize = 0;
    int64_t ret = impl(server_this, req_appId, ticket_buf, req_cbMax,
                       &offAppId, &offSteamId, &offSig, &sigSize);

    if (ret > 0 && sigSize > 0) {
        serialize_response(respWriter, ret, ticket_buf, req_cbMax,
                           offAppId, offSteamId, offSig, sigSize);
        free(ticket_buf);
        SX_LOG("[ticket] app %u: Steam's own ticket, %lld bytes", req_appId, (long long)ret);
        return 1;
    }

    // Steam will not issue a ticket for this app: the account does not own it, or the
    // client will not sign one for a game it is not running as. Spacewar is owned by
    // every account, so a ticket for it is always signed, and OnlineFix's Photon apps
    // are registered against 480: Photon asks Steam about 480, and Steam vouches for
    // this one. A forged ticket cannot pass that check, whatever its app id says.
    if (req_appId != SPACEWAR_APPID) {
        uint32_t space_off_app = 0, space_off_steam = 0, space_off_sig = 0, space_sig = 0;
        int64_t space_len = impl(server_this, SPACEWAR_APPID, ticket_buf, req_cbMax,
                                 &space_off_app, &space_off_steam, &space_off_sig, &space_sig);
        if (space_len > 0 && space_sig > 0) {
            serialize_response(respWriter, space_len, ticket_buf, req_cbMax,
                               space_off_app, space_off_steam, space_off_sig, space_sig);
            free(ticket_buf);
            SX_LOG("[ticket] app %u: Steam's own Spacewar ticket, %lld bytes",
                   req_appId, (long long)space_len);
            return 1;
        }
    }

    if (!should_forge(req_appId)) {
        serialize_response(respWriter, ret, ticket_buf, req_cbMax,
                           offAppId, offSteamId, offSig, sigSize);
        free(ticket_buf);
        return 1;
    }
    free(ticket_buf);

    uint8_t *source_buf = (uint8_t *)calloc(1, MAX_TICKET_BUF);
    if (!source_buf) return 0;

    uint32_t src_off_app = 0, src_off_steam = 0, src_off_sig = 0, src_sig_size = 0;
    uint32_t source_app = sx_ticket_source_app();
    int64_t src_len = impl(server_this, source_app, source_buf, MAX_TICKET_BUF,
                           &src_off_app, &src_off_steam, &src_off_sig, &src_sig_size);

    uint32_t body_len = src_off_sig;
    uint32_t sig_size = src_sig_size;

    if (src_len <= 0 || body_len == 0 || sig_size == 0 ||
        body_len + sig_size != (uint32_t)src_len) {
        SX_WARN("GetAppOwnershipTicketExtendedData: source %u ticket invalid (len=%lld, sigOff=%u, sigSize=%u, impl=%p)",
                source_app, (long long)src_len, body_len, sig_size, (void *)impl);
        free(source_buf);
        return 0;
    }

    uint32_t forged_physical = (uint32_t)src_len + 4;

    if (forged_physical > req_cbMax) {
        SX_WARN("GetAppOwnershipTicketExtendedData: forged ticket (%u bytes) exceeds cbMaxTicket (%u)",
                forged_physical, req_cbMax);
        free(source_buf);
        return 0;
    }

    // layout: [body | 4B target appId | sig]
    uint8_t *forged = (uint8_t *)calloc(1, req_cbMax);
    if (!forged) { free(source_buf); return 0; }

    memcpy(forged, source_buf, body_len);
    memcpy(forged + body_len, &req_appId, 4);
    memcpy(forged + body_len + 4, source_buf + body_len, sig_size);

    uint32_t reported_size = (uint32_t)src_len;

    serialize_response(respWriter, (int64_t)reported_size, forged, req_cbMax,
                       body_len,
                       src_off_steam,
                       body_len + 4,
                       sig_size);

    SX_LOG("GetAppOwnershipTicketExtendedData: FORGED app %u (source=%u, bodyLen=%u, sigOff=%u->%u, physical=%u, reported=%u)",
           req_appId, source_app, body_len, src_off_sig, body_len + 4, forged_physical, reported_size);

    free(forged);
    free(source_buf);
    return 1;
}
