// GetUserStats owner redirect
//
// An unlocked game has no achievement list of its own, so Steam's stats request
// for it is answered with a failure and the library shows no achievements.
// macsteam points that request at an account that does own the game and keeps
// the achievement list (the schema) from the reply.
//
// Everything happens in one place: the request/response pair itself. That is
// the only path that was ever observed to work, and it needs no other hook.
#include "hooks.h"
#include "../config/config.h"
#include "../core/reconcile.h"
#include "../feats/achiev_cache.h"
#include "../feats/schema_owners.h"
#include "../feats/cloud.h"
#include "../constants.h"
#include "../steam_types.h"
#include "../util/log.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define MSG_BODY_OFF          offsetof(CProtoBufMsg_t, body)

// CMsgClientGetUserStats, the request.
#define SEND_HASBITS_OFF      0x10
#define SEND_GAME_ID_OFF      0x18
#define SEND_STEAMID_OFF      0x28
#define SEND_STEAMID_HASBIT   8

// CMsgClientGetUserStatsResponse.
#define RECV_ERESULT_OFF      0x5C
#define RECV_STATS_COUNT_OFF  0x20
#define RECV_ACH_COUNT_OFF    0x38
#define RECV_COUNT_SANE_MAX   4096

typedef int (*fn_sendAndRecv)(void *self, void *send, uint32_t a2,
                              uint32_t timeOut, void *recv, uint32_t targetType);
static void *orig_sendAndRecv = NULL;

static inline uintptr_t msg_body(void *msg) {
    if (!msg) return 0;
    return *(uintptr_t *)((char *)msg + MSG_BODY_OFF);
}

static void send_set_owner(uintptr_t body, uint64_t owner) {
    *(uint64_t *)(body + SEND_STEAMID_OFF) = owner;
    *(uint32_t *)(body + SEND_HASBITS_OFF) |= SEND_STEAMID_HASBIT;
}

// 1 = the server answered OK, 0 = it did not, -1 = the value is not an eresult,
// which means the offset is wrong for this build.
static int recv_result(uintptr_t body) {
    int32_t v = *(int32_t *)(body + RECV_ERESULT_OFF);
    if (v == USERSTATS_RESP_ERESULT_OK) return 1;
    if (v == 0 || v == 2 || v == 3) return 0;
    return -1;
}

// The reply carries the achievement list (the schema), the owner's stats and
// their achievement blocks. Steam shows the list because of the schema, but it
// merges the stats into the player's own progress, which is what made a borrowed
// schema arrive with dozens of achievements already unlocked. Clearing the two
// repeated fields keeps the list and drops the progress.
static void recv_clear_stats(uintptr_t body) {
    uint32_t *stats = (uint32_t *)(body + RECV_STATS_COUNT_OFF);
    uint32_t *blocks = (uint32_t *)(body + RECV_ACH_COUNT_OFF);
    if (*stats > RECV_COUNT_SANE_MAX || *blocks > RECV_COUNT_SANE_MAX) {
        SX_WARN("[stats] reply counts look wrong (%u/%u); not touching them",
                *stats, *blocks);
        return;
    }
    uint32_t had_stats = *stats, had_blocks = *blocks;
    *stats = 0;
    *blocks = 0;
    SX_DBG("[stats] reply: dropped %u owner stat(s) and %u achievement block(s)",
           had_stats, had_blocks);
}

// Ask for one account's stats. Returns 1 when the server answered OK.
static int try_owner(void *self, void *send, uint32_t a2, uint32_t timeOut,
                     void *recv, uintptr_t send_body, uintptr_t recv_body,
                     uint64_t owner) {
    fn_sendAndRecv orig = (fn_sendAndRecv)orig_sendAndRecv;
    send_set_owner(send_body, owner);
    int ret = orig(self, send, a2, timeOut, recv,
                   EMSG_CLIENT_GET_USER_STATS_RESPONSE);
    return ret && recv_result(recv_body) == 1;
}

static int hook_sendAndRecv(void *self, void *send, uint32_t a2,
                            uint32_t timeOut, void *recv, uint32_t targetType) {
    fn_sendAndRecv orig = (fn_sendAndRecv)orig_sendAndRecv;

    if (targetType != EMSG_CLIENT_GET_USER_STATS_RESPONSE ||
        sx_hook_passthrough("sendAndRecv")) {
        // Cloud discovery: keep the request and the answer of every cloud job
        // whole, so the next build can answer them itself. Nothing is changed.
        int cloud_reply = (targetType >= 5520u && targetType <= 5600u);
        if (cloud_reply) {
            char tag[32];
            snprintf(tag, sizeof(tag), "%u_req", targetType);
            sx_cloud_capture(tag, send);
        }
        int r = orig(self, send, a2, timeOut, recv, targetType);
        if (cloud_reply && r) {
            char tag[32];
            snprintf(tag, sizeof(tag), "%u_res", targetType);
            sx_cloud_capture(tag, recv);
        }
        return r;
    }

    uintptr_t send_body = msg_body(send);
    uintptr_t recv_body = msg_body(recv);
    if (!send_body || !recv_body)
        return orig(self, send, a2, timeOut, recv, targetType);

    sx_config_t *cfg = sx_config_current;
    int appId = (int)(*(uint64_t *)(send_body + SEND_GAME_ID_OFF) & 0xFFFFFF);
    if (!cfg || !sx_config_has_app(cfg, appId))
        return orig(self, send, a2, timeOut, recv, targetType);

    uint64_t original = *(uint64_t *)(send_body + SEND_STEAMID_OFF);
    int ret = 0;

    // The owner that worked last time first; it usually still works.
    uint64_t pref = sx_schema_owners_preferred(appId);
    if (pref && try_owner(self, send, a2, timeOut, recv,
                          send_body, recv_body, pref)) {
        recv_clear_stats(recv_body);
        SX_DBG("[stats] app %d: schema via preferred owner %llu", appId,
               (unsigned long long)pref);
        ret = 1;
    } else {
        sx_owner_list_t reviewers;
        sx_schema_owners_get(appId, &reviewers);
        for (int i = 0; i < reviewers.count; i++) {
            uint64_t owner = reviewers.ids[i];
            if (owner == pref) continue;
            if (try_owner(self, send, a2, timeOut, recv,
                          send_body, recv_body, owner)) {
                recv_clear_stats(recv_body);
                sx_schema_owners_set_preferred(appId, owner);
                SX_LOG("[stats] app %d: schema via reviewer %llu", appId,
                       (unsigned long long)owner);
                ret = 1;
                break;
            }
            sx_schema_owners_blacklist(appId, owner);
        }
        if (!ret) {
            // Nothing worked: hand the request back exactly as Steam made it,
            // so the client behaves as it would without us.
            *(uint64_t *)(send_body + SEND_STEAMID_OFF) = original;
            SX_LOG("[stats] app %d: no owner schema, passthrough", appId);
            ret = orig(self, send, a2, timeOut, recv, targetType);
        }
    }

    // The library is asking about this app, so its achievement cache entry is
    // worth having: the reply above may have just written the schema, and the
    // player may have unlocked something since launch. Once per app per session.
    // Every stats reply is a chance to write the app's list: the first one may
    // arrive before a schema exists, and the reply itself is what brings it. A
    // list written now has to reach the library in this session, so ask for one
    // refresh instead of leaving Steam with the empty card it cached earlier.
    // sync_app returns 2 when nothing changed, so this does not loop.
    int synced = sx_achiev_cache_sync_app(appId);
    if (synced == 1)
        sx_reconcile_arm_library_refresh();
    else if (synced == 0)
        // No schema yet: Steam writes it from this reply, so try again shortly.
        sx_achiev_cache_sync_later(appId);

    return ret;
}

static sx_hook_def_t g_hooks[] = {
    {
        .name     = "sendAndRecv",
        .sig_name = "CAPIJob::sendAndRecv",
        .hook_fn  = (void *)hook_sendAndRecv,
        .orig_fn  = &orig_sendAndRecv,
        .optional = 1,
    },
};

int sx_hooks_stats_count(void) {
    return (int)(sizeof(g_hooks) / sizeof(g_hooks[0]));
}

sx_hook_def_t *sx_hooks_stats_defs(void) {
    return g_hooks;
}
