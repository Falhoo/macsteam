// Let the library's achievements card use the cache entry we build.
//
// AppDetailsStore.GetAchievements() loads the achievement list from the app
// details cache only when the details arrived without one:
//
//     C.details?.achievements.vecHighlight === void 0
//
// A game Steam does not own arrives with an empty achievements object — the
// arrays are there, nTotal is 0 — so that test never fires, the cache is never
// read, and every achievements component bails out on `nTotal == 0`. The list
// is in the cache all along (see feats/achiev_cache.c); the store just has to be
// asked for it. Both guards are replaced, because GetAchievements() only calls
// RequestAchievements(), and the second guard decides whether it does anything.
//
// sp.js is minified and its local identifiers are renamed every build, so the
// anchors are the property names only. Each replacement is padded with spaces to
// the length of what it replaces: Steam checks the bundle's size at startup, and
// rewriting the file as text would also invalidate the Cloud-error patcher's
// recovery copy.
#include "hooks.h"
#include "../util/file.h"
#include "../util/log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const char *find;
    const char *replace;
    int         required;
} sx_ui_patch_t;

// Padded to the length of the anchor; see the size asserts below.
#define SX_ACHIEV_GET_FIND ".details?.achievements.vecHighlight===void 0"
#define SX_ACHIEV_GET_REPL ".details?.achievements?.nTotal===0          "

#define SX_ACHIEV_REQ_FIND ".details.achievements.vecHighlight===void 0"
#define SX_ACHIEV_REQ_REPL ".details.achievements?.nTotal===0          "

// Older builds also wrote an empty list back into the cache. Newer ones gate on
// nTotal themselves, so this one is optional.
#define SX_ACHIEV_PUT_FIND "achievements.vecHighlight!==void 0"
#define SX_ACHIEV_PUT_REPL "achievements.nTotal>0             "

_Static_assert(sizeof(SX_ACHIEV_GET_FIND) == sizeof(SX_ACHIEV_GET_REPL), "patch 1 size");
_Static_assert(sizeof(SX_ACHIEV_REQ_FIND) == sizeof(SX_ACHIEV_REQ_REPL), "patch 2 size");
_Static_assert(sizeof(SX_ACHIEV_PUT_FIND) == sizeof(SX_ACHIEV_PUT_REPL), "patch 3 size");

static const sx_ui_patch_t kPatches[] = {
    { SX_ACHIEV_GET_FIND, SX_ACHIEV_GET_REPL, 1 },
    { SX_ACHIEV_REQ_FIND, SX_ACHIEV_REQ_REPL, 1 },
    { SX_ACHIEV_PUT_FIND, SX_ACHIEV_PUT_REPL, 0 },
};

#define SX_ACHIEV_PATCHES (sizeof(kPatches) / sizeof(kPatches[0]))

// The game page's "View all achievements" list asks the client for the signed-in
// account's achievements (SteamClient.Apps.GetMyAchievementsForApp), and the
// client only answers that for a game the account owns. For a game Steam does
// not own it comes back as EResult 2 ("Failed to retrieve user stats"), and the
// page shows "Failed to load achievement data".
//
// macsteam already writes the achievement list Steam's own library card reads
// (feats/achiev_cache.c), including the uncapped `vecAll`, so when the native
// call fails the page is pointed at that cache instead. The replacement is
// padded to the length of the method it replaces, since Steam checks sp.js's
// size at startup.
#define SX_ACHIEV_MY_FIND "async LoadMyAchievements("
#define SX_ACHIEV_MY_END  "m_mapInflightMyAchievementsRequests.delete(A)})}"

static const char kMyAchievementsPatch[] =
    "async LoadMyAchievements(A){"
    "this.m_mapInflightMyAchievementsRequests.set(A,1);"
    "let M=await SteamClient.Apps.GetMyAchievementsForApp(A+\"\");"
    "if(M.result!=e.R)M.data={rgAchievements:(await window.appDetailsCache"
    ".GetCachedDataForApp(A+\"\",\"achievements\",2))?.vecAll};"
    "(0,f.h5)(()=>{this.m_mapMyAchievements.set(A,{data:z(M.data)}),"
    "this.m_mapGlobalAchievements.set(A,{data:S(M.data)}),"
    "this.m_mapInflightMyAchievementsRequests.delete(A)})}";

static void patch_my_achievements(const char *path) {
    size_t size = 0;
    uint8_t *buf = sx_slurp_file(path, &size);
    if (!buf) return;

    uint8_t *start = memmem(buf, size, SX_ACHIEV_MY_FIND, sizeof(SX_ACHIEV_MY_FIND) - 1);
    if (!start) {
        SX_DBG("Achievements: no achievements page in sp.js (bundle changed)");
        free(buf);
        return;
    }
    size_t at = (size_t)(start - buf);

    uint8_t *end = memmem(buf + at, size - at, SX_ACHIEV_MY_END, sizeof(SX_ACHIEV_MY_END) - 1);
    if (!end) {
        SX_WARN("Achievements: could not locate the end of the achievements page method");
        free(buf);
        return;
    }
    size_t span = (size_t)(end - buf) + (sizeof(SX_ACHIEV_MY_END) - 1) - at;
    size_t repl = sizeof(kMyAchievementsPatch) - 1;

    if (repl == span) {  // already patched in this bundle
        free(buf);
        return;
    }
    if (repl > span) {
        SX_WARN("Achievements: page patch does not fit (%zu > %zu bytes); leaving the bundle alone",
                repl, span);
        free(buf);
        return;
    }

    char *out = malloc(span);
    if (!out) {
        free(buf);
        return;
    }
    memcpy(out, kMyAchievementsPatch, repl);
    memset(out + repl, ' ', span - repl);

    FILE *f = fopen(path, "r+b");
    if (!f) {
        SX_WARN("Achievements: could not open %s for the page patch", path);
        free(out);
        free(buf);
        return;
    }
    int ok = fseek(f, (long)at, SEEK_SET) == 0 && fwrite(out, 1, span, f) == span;
    if (fclose(f) != 0) ok = 0;
    free(out);
    free(buf);
    if (ok)
        SX_LOG("Achievements: page falls back to the cache when the account does not own the game");
    else
        SX_WARN("Achievements: could not patch the achievements page in %s", path);
}

// Current builds build the achievements card from three queries: the schema, the
// global percentages, and the player's own achievements. The last one is remote
// (`GetUserAchievements`) and for a game the account does not own it never
// answers — the request hangs instead of failing. The card has a local fallback
// (`GetUserAchievements({gameid})` on the stats service, fed by the stats cache)
// that returns the real, correct list, but it only runs when the remote query
// *rejected*:
//
//     O = !!fnLocal && !!steamid && error instanceof ServerUnreachable
//
// A request that never settles is not a rejection, so the fallback is skipped,
// the summary stays empty, and the card's `achievable.total == 0` guard hides it.
// Dropping that third condition runs the local query unconditionally, which is
// what makes the list appear. The names around it are minified per build, so the
// span is located from the stable key `"local_user_achievements"` and blanked
// with spaces rather than rewritten.
#define SX_ACHIEV_LOCAL_KEY "\"local_user_achievements\""
#define SX_ACHIEV_GATE_WINDOW 160

static int blank_span(uint8_t *buf, size_t size, size_t from, size_t to) {
    if (from >= to || to > size) return 0;
    memset(buf + from, ' ', to - from);
    return 1;
}

static void patch_local_fallback(const char *path) {
    size_t size = 0;
    uint8_t *buf = sx_slurp_file(path, &size);
    if (!buf) return;

    uint8_t *key = memmem(buf, size, SX_ACHIEV_LOCAL_KEY, strlen(SX_ACHIEV_LOCAL_KEY));
    if (!key) {
        SX_DBG("Achievements: no local achievements query in sp.js (bundle changed)");
        free(buf);
        return;
    }

    size_t key_at = (size_t)(key - buf);
    size_t window_start = key_at > SX_ACHIEV_GATE_WINDOW ? key_at - SX_ACHIEV_GATE_WINDOW : 0;

    // The gate's `instanceof` is the last one before the key.
    size_t inst = 0;
    int have_inst = 0;
    for (size_t i = key_at; i > window_start; i--) {
        if (i >= 9 && memcmp(buf + i - 9, "instanceof", 9) == 0) { inst = i - 9; have_inst = 1; break; }
    }
    if (!have_inst) {
        SX_DBG("Achievements: local fallback gate already dropped");
        free(buf);
        return;
    }

    // Cut at the `&&` that joins the error check, right before it.
    size_t cut = 0;
    int have_cut = 0;
    for (size_t i = inst; i > window_start; i--) {
        if (i >= 2 && buf[i - 2] == '&' && buf[i - 1] == '&') { cut = i - 2; have_cut = 1; break; }
    }
    // The gate ends at the comma that opens the next statement.
    size_t end = 0;
    for (size_t i = inst + 9; i < key_at; i++) {
        if (buf[i] == ',') { end = i; break; }
    }
    if (!have_cut || !end) {
        SX_WARN("Achievements: could not locate the local fallback gate in sp.js");
        free(buf);
        return;
    }

    if (!blank_span(buf, size, cut, end)) {
        free(buf);
        return;
    }

    FILE *f = fopen(path, "r+b");
    if (!f) {
        SX_WARN("Achievements: could not open %s", path);
        free(buf);
        return;
    }
    int ok = fseek(f, (long)cut, SEEK_SET) == 0 &&
             fwrite(buf + cut, 1, end - cut, f) == end - cut;
    if (fclose(f) != 0) ok = 0;
    free(buf);
    if (ok)
        SX_LOG("Achievements: local achievement lookup enabled (size preserved)");
    else
        SX_WARN("Achievements: could not patch the local fallback in %s", path);
}

void sx_achiev_patch_installed_js(void) {
    const char *home = sx_resolve_home();
    if (!home) return;

    char path[2048];
    int n = snprintf(path, sizeof(path),
                     "%s/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamui/sp.js",
                     home);
    if (n < 0 || (size_t)n >= sizeof(path)) return;

    patch_my_achievements(path);
    patch_local_fallback(path);

    size_t size = 0;
    uint8_t *buf = sx_slurp_file(path, &size);
    if (!buf) return;

    size_t offsets[SX_ACHIEV_PATCHES];
    int wanted[SX_ACHIEV_PATCHES];
    size_t count = 0;
    for (size_t k = 0; k < SX_ACHIEV_PATCHES; k++) {
        uint8_t *hit = memmem(buf, size, kPatches[k].find, strlen(kPatches[k].find));
        if (!hit) {
            if (kPatches[k].required) {
                // Already patched, or this bundle lays the store out differently:
                // either way there is nothing safe to do here.
                SX_DBG("Achievements: sp.js anchor %zu not found; leaving the bundle alone", k);
                free(buf);
                return;
            }
            continue;
        }
        offsets[count] = (size_t)(hit - buf);
        wanted[count] = (int)k;
        count++;
    }
    free(buf);
    if (!count) return;

    FILE *f = fopen(path, "r+b");
    if (!f) {
        SX_WARN("Achievements: could not open %s", path);
        return;
    }
    size_t patched = 0;
    for (size_t i = 0; i < count; i++) {
        const sx_ui_patch_t *p = &kPatches[wanted[i]];
        size_t rlen = strlen(p->replace);
        if (fseek(f, (long)offsets[i], SEEK_SET) == 0 &&
            fwrite(p->replace, 1, rlen, f) == rlen)
            patched++;
        else
            SX_WARN("Achievements: write failed at offset %zu in %s", offsets[i], path);
    }
    if (fclose(f) != 0)
        SX_WARN("Achievements: close failed for %s", path);
    if (patched == count)
        SX_LOG("Achievements: library card reads the achievement cache");
}
