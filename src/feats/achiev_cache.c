// Achievement list for the library UI
//
// Steam's library does not build the achievements card from the stats reply.
// steamui asks the native side for the app's cached details
// (Apps.GetCachedAppDetails), which is a plain read of
//     <steam>/userdata/<account>/config/librarycache/<appid>.json
// and renders the card from the "achievements" entry in it. For a game Steam
// does not own that entry is nTotal 0, and every achievements component returns
// null on nTotal 0, so the card never appears at all.
//
// The achievement schema is already on disk: the client writes
//     <steam>/appcache/stats/UserGameStatsSchema_<appid>.bin
// for every app it has seen one for. This file turns that schema into the entry
// the library reads, taking the unlock state from the local stats blob so that
// progress the client did record shows up, and leaving everything else locked.
#include "achiev_cache.h"
#include "../core/reconcile.h"
#include "../core/stats_cache.h"
#include "../constants.h"
#include "../util/file.h"
#include "../util/log.h"
#include "../../vendor/cJSON.h"

#include <dirent.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <zlib.h>

#define ACHIEV_MAX        512
#define ACHIEV_API_LEN    128
#define ACHIEV_NAME_LEN   192
#define ACHIEV_DESC_LEN   512
#define ACHIEV_ICON_LEN   256
#define ACHIEV_SHOWN      12    // vecHighlight / vecUnachieved hold at most this
#define ACHIEV_BKV_DEPTH  128

enum {
    BKV_SECTION = 0x00,
    BKV_STRING  = 0x01,
    BKV_INT     = 0x02,
    BKV_FLOAT   = 0x03,
    BKV_UINT64  = 0x07,
    BKV_END     = 0x08,
    BKV_INT64   = 0x0A,
};

typedef struct {
    uint32_t stat;
    uint32_t bit;
    char     api[ACHIEV_API_LEN];
    char     name[ACHIEV_NAME_LEN];
    char     desc[ACHIEV_DESC_LEN];
    char     icon[ACHIEV_ICON_LEN];
    int      hidden;
} sx_achiev_t;

typedef struct {
    const uint8_t *d;
    size_t         len;
    size_t         pos;
} bkv_t;

static void copy_str(char *dst, size_t cap, const char *src) {
    if (!dst || cap == 0) return;
    if (!src) { dst[0] = '\0'; return; }
    size_t n = strlen(src);
    if (n >= cap) n = cap - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

static int name_as_u32(const char *name, size_t n, uint32_t *out) {
    if (n == 0) return 0;
    uint64_t v = 0;
    for (size_t i = 0; i < n; i++) {
        if (name[i] < '0' || name[i] > '9') return 0;
        v = v * 10 + (uint64_t)(name[i] - '0');
        if (v > 0xFFFFFFFFull) return 0;
    }
    *out = (uint32_t)v;
    return 1;
}

static int key_is(const char *name, size_t len, const char *want) {
    size_t w = strlen(want);
    return len == w && memcmp(name, want, w) == 0;
}

// A name and a string value are both NUL-terminated in this format.
static const char *bkv_read_name(bkv_t *c, size_t *out_len) {
    size_t start = c->pos;
    while (c->pos < c->len && c->d[c->pos] != 0) c->pos++;
    if (c->pos >= c->len) return NULL;
    if (out_len) *out_len = c->pos - start;
    const char *s = (const char *)(c->d + start);
    c->pos++;
    return s;
}

static int bkv_read_u32(bkv_t *c, uint32_t *out) {
    if (c->pos + 4 > c->len) return 0;
    uint32_t v;
    memcpy(&v, c->d + c->pos, 4);
    c->pos += 4;
    *out = v;
    return 1;
}

static int bkv_skip_scalar(bkv_t *c, uint8_t type) {
    switch (type) {
    case BKV_STRING:
        return bkv_read_name(c, NULL) != NULL;
    case BKV_INT:
    case BKV_FLOAT:
        if (c->pos + 4 > c->len) return 0;
        c->pos += 4;
        return 1;
    case BKV_UINT64:
    case BKV_INT64:
        if (c->pos + 8 > c->len) return 0;
        c->pos += 8;
        return 1;
    default:
        return 0;
    }
}

static int bkv_skip_section(bkv_t *c, int depth) {
    if (depth > ACHIEV_BKV_DEPTH) return 0;
    while (c->pos < c->len) {
        uint8_t type = c->d[c->pos++];
        if (type == BKV_END) return 1;
        if (!bkv_read_name(c, NULL)) return 0;
        if (type == BKV_SECTION) {
            if (!bkv_skip_section(c, depth + 1)) return 0;
        } else if (!bkv_skip_scalar(c, type)) {
            return 0;
        }
    }
    return 0;
}

// "display" holds the per-language name and description, and in some schemas
// also the hidden flag and the icon file name.
static int parse_display(bkv_t *c, sx_achiev_t *a, int depth) {
    if (depth > ACHIEV_BKV_DEPTH) return 0;
    while (c->pos < c->len) {
        uint8_t type = c->d[c->pos++];
        if (type == BKV_END) return 1;
        size_t nlen = 0;
        const char *name = bkv_read_name(c, &nlen);
        if (!name) return 0;

        if (type == BKV_INT) {
            uint32_t v;
            if (!bkv_read_u32(c, &v)) return 0;
            if (key_is(name, nlen, "hidden")) a->hidden = v != 0;
            continue;
        }
        if (type == BKV_STRING) {
            const char *v = bkv_read_name(c, NULL);
            if (!v) return 0;
            if (key_is(name, nlen, "icon")) copy_str(a->icon, sizeof(a->icon), v);
            continue;
        }
        if (type != BKV_SECTION) {
            if (!bkv_skip_scalar(c, type)) return 0;
            continue;
        }

        int is_name = key_is(name, nlen, "name");
        int is_desc = key_is(name, nlen, "desc");
        if (!is_name && !is_desc) {
            if (!bkv_skip_section(c, depth + 1)) return 0;
            continue;
        }
        while (c->pos < c->len) {
            uint8_t lt = c->d[c->pos++];
            if (lt == BKV_END) break;
            size_t llen = 0;
            const char *lang = bkv_read_name(c, &llen);
            if (!lang) return 0;
            if (lt != BKV_STRING) {
                if (!bkv_skip_scalar(c, lt)) return 0;
                continue;
            }
            const char *value = bkv_read_name(c, NULL);
            if (!value) return 0;
            if (key_is(lang, llen, "english")) {
                if (is_name)
                    copy_str(a->name, sizeof(a->name), value);
                else
                    copy_str(a->desc, sizeof(a->desc), value);
            }
        }
    }
    return 0;
}

static int parse_bit(bkv_t *c, sx_achiev_t *a, int depth) {
    if (depth > ACHIEV_BKV_DEPTH) return 0;
    while (c->pos < c->len) {
        uint8_t type = c->d[c->pos++];
        if (type == BKV_END) return 1;
        size_t nlen = 0;
        const char *name = bkv_read_name(c, &nlen);
        if (!name) return 0;

        if (type == BKV_STRING) {
            const char *v = bkv_read_name(c, NULL);
            if (!v) return 0;
            if (key_is(name, nlen, "name"))
                copy_str(a->api, sizeof(a->api), v);
            else if (key_is(name, nlen, "icon"))
                copy_str(a->icon, sizeof(a->icon), v);
            continue;
        }
        if (type == BKV_INT) {
            uint32_t v;
            if (!bkv_read_u32(c, &v)) return 0;
            if (key_is(name, nlen, "hidden")) a->hidden = v != 0;
            continue;
        }
        if (type == BKV_SECTION) {
            if (key_is(name, nlen, "display")) {
                if (!parse_display(c, a, depth + 1)) return 0;
            } else if (!bkv_skip_section(c, depth + 1)) {
                return 0;
            }
            continue;
        }
        if (!bkv_skip_scalar(c, type)) return 0;
    }
    return 0;
}

// stats/<statid>/bits/<bit>/ { name, display, ... } — one entry per achievement.
static int parse_bits(bkv_t *c, uint32_t stat_id, sx_achiev_t *out, int count,
                      int max, int depth) {
    if (depth > ACHIEV_BKV_DEPTH) return -1;
    while (c->pos < c->len) {
        uint8_t type = c->d[c->pos++];
        if (type == BKV_END) return count;
        size_t nlen = 0;
        const char *name = bkv_read_name(c, &nlen);
        if (!name) return -1;
        if (type != BKV_SECTION) {
            if (!bkv_skip_scalar(c, type)) return -1;
            continue;
        }

        uint32_t bit = 0;
        int have_bit = name_as_u32(name, nlen, &bit);
        sx_achiev_t a;
        memset(&a, 0, sizeof(a));
        a.stat = stat_id;
        a.bit = bit;
        if (!parse_bit(c, &a, depth + 1)) return -1;
        if (have_bit && count < max) out[count++] = a;
    }
    return -1;
}

static int parse_stat(bkv_t *c, uint32_t stat_id, sx_achiev_t *out, int count,
                      int max, int depth) {
    if (depth > ACHIEV_BKV_DEPTH) return -1;
    while (c->pos < c->len) {
        uint8_t type = c->d[c->pos++];
        if (type == BKV_END) return count;
        size_t nlen = 0;
        const char *name = bkv_read_name(c, &nlen);
        if (!name) return -1;
        if (type != BKV_SECTION) {
            if (!bkv_skip_scalar(c, type)) return -1;
            continue;
        }
        if (key_is(name, nlen, "bits")) {
            count = parse_bits(c, stat_id, out, count, max, depth + 1);
            if (count < 0) return -1;
        } else if (!bkv_skip_section(c, depth + 1)) {
            return -1;
        }
    }
    return -1;
}

static int parse_stats(bkv_t *c, sx_achiev_t *out, int max, int depth) {
    if (depth > ACHIEV_BKV_DEPTH) return -1;
    int count = 0;
    while (c->pos < c->len) {
        uint8_t type = c->d[c->pos++];
        if (type == BKV_END) return count;
        size_t nlen = 0;
        const char *name = bkv_read_name(c, &nlen);
        if (!name) return -1;
        if (type != BKV_SECTION) {
            if (!bkv_skip_scalar(c, type)) return -1;
            continue;
        }
        uint32_t stat_id = 0;
        if (name_as_u32(name, nlen, &stat_id)) {
            count = parse_stat(c, stat_id, out, count, max, depth + 1);
            if (count < 0) return -1;
        } else if (!bkv_skip_section(c, depth + 1)) {
            return -1;
        }
    }
    return -1;
}

static int load_schema(const char *path, sx_achiev_t *out, int max) {
    size_t len = 0;
    uint8_t *data = sx_slurp_file(path, &len);
    if (!data) return 0;
    if (len < 2 || data[0] != BKV_SECTION) { free(data); return 0; }

    bkv_t c = { data, len, 1 };
    if (!bkv_read_name(&c, NULL)) { free(data); return 0; }

    int count = 0;
    while (c.pos < c.len) {
        uint8_t type = data[c.pos++];
        if (type == BKV_END) break;
        size_t nlen = 0;
        const char *name = bkv_read_name(&c, &nlen);
        if (!name) break;
        if (type != BKV_SECTION) {
            if (!bkv_skip_scalar(&c, type)) break;
            continue;
        }
        if (key_is(name, nlen, "stats")) {
            count = parse_stats(&c, out, max, 1);
            if (count < 0) count = 0;
            break;
        }
        if (!bkv_skip_section(&c, 1)) break;
    }
    free(data);
    return count;
}

// Steam's own on-disk copy of a game's achievement schema.
//
// The library asks the client for the schema of every app it displays
// (`GetGameAchievements`), which works for a game the account does not own, and
// the client caches the answer as gzipped JSON:
//
//   <steam>/userdata/<account>/querycache/achievements/
//       achievements_<appid>_schema-<hash>.cmsg
//
// This is the source used first. It needs no network and no owner lookup, the
// names, descriptions and icon URLs come from Valve's own copy, and it is
// complete: the appcache .bin schemas drop DLC groups and are only written for
// apps the old stats path happened to touch.
// Steam's cached copy of a game's schema, as a parsed JSON document.
static int load_querycache_json(const char *userdir, int app_id, cJSON **out) {
    char dir[1400];
    snprintf(dir, sizeof(dir), "%s/querycache/achievements", userdir);

    char prefix[64];
    snprintf(prefix, sizeof(prefix), "achievements_%d_schema-", app_id);

    DIR *d = opendir(dir);
    if (!d) return 0;
    char path[1500] = {0};
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (strncmp(ent->d_name, prefix, strlen(prefix)) != 0) continue;
        snprintf(path, sizeof(path), "%s/%s", dir, ent->d_name);
        break;
    }
    closedir(d);
    if (!path[0]) return 0;

    gzFile gz = gzopen(path, "rb");
    if (!gz) return 0;
    size_t cap = 1 << 20, len = 0;
    char *raw = malloc(cap);
    if (!raw) { gzclose(gz); return 0; }
    int n;
    while ((n = gzread(gz, raw + len, (unsigned)(cap - len - 1))) > 0) {
        len += (size_t)n;
        if (len + 1 >= cap) {
            if (cap >= (16u << 20)) break;
            char *bigger = realloc(raw, cap * 2);
            if (!bigger) break;
            raw = bigger;
            cap *= 2;
        }
    }
    gzclose(gz);
    raw[len] = '\0';

    cJSON *doc = cJSON_Parse(raw);
    free(raw);
    if (!doc) return 0;
    *out = doc;
    return 1;
}

static int load_schema_querycache(const char *userdir, int app_id,
                                  sx_achiev_t *out, int max) {
    cJSON *doc = NULL;
    if (!load_querycache_json(userdir, app_id, &doc)) return 0;

    cJSON *data = cJSON_GetObjectItemCaseSensitive(doc, "data");
    cJSON *groups = cJSON_GetObjectItemCaseSensitive(data, "groups");
    int count = 0;
    if (cJSON_IsArray(groups)) {
        cJSON *group;
        cJSON_ArrayForEach(group, groups) {
            cJSON *achievements =
                cJSON_GetObjectItemCaseSensitive(group, "achievements");
            if (!cJSON_IsArray(achievements)) continue;
            cJSON *entry;
            cJSON_ArrayForEach(entry, achievements) {
                if (count >= max) break;
                cJSON *name = cJSON_GetObjectItemCaseSensitive(entry, "name");
                cJSON *api = cJSON_GetObjectItemCaseSensitive(entry, "api_name");
                cJSON *desc = cJSON_GetObjectItemCaseSensitive(entry, "description");
                cJSON *icon = cJSON_GetObjectItemCaseSensitive(entry, "icon_unachieved");
                cJSON *hidden = cJSON_GetObjectItemCaseSensitive(entry, "hidden");

                sx_achiev_t *a = &out[count];
                memset(a, 0, sizeof(*a));
                copy_str(a->api, sizeof(a->api),
                         cJSON_IsString(api) ? api->valuestring : "");
                copy_str(a->name, sizeof(a->name),
                         cJSON_IsString(name) ? name->valuestring : "");
                copy_str(a->desc, sizeof(a->desc),
                         cJSON_IsString(desc) ? desc->valuestring : "");
                copy_str(a->icon, sizeof(a->icon),
                         cJSON_IsString(icon) ? icon->valuestring : "");
                a->hidden = cJSON_IsTrue(hidden);
                if (!a->name[0] && !a->api[0]) continue;
                count++;
            }
        }
    }
    cJSON_Delete(doc);
    return count;
}

// The unlock state the client recorded for the app, if it recorded any.
//
// It is deliberately not consulted: for an app on the unlock list the stats the
// client holds are the ones macsteam itself answered a stats request with, so
// they carry another account's progress. What is left is the account's own
// progress, so a game played here keeps the achievements it earned.
static uint32_t achievement_unlock_time(const sx_stats_snapshot_t *snap,
                                        uint32_t stat, uint32_t bit) {
    if (!snap || bit >= SX_STATS_ACH_BITS) return 0;
    for (int i = 0; i < snap->stat_count; i++) {
        const sx_stat_entry_t *s = &snap->stats[i];
        if (s->stat_id != stat) continue;
        if (!s->has_ach_times) return 0;
        return s->unlock_time[bit];
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Writing Steam's achievement schema
//
// The client only writes appcache/stats/UserGameStatsSchema_<appid>.bin after a
// stats exchange succeeds, which never happens for an app the account does not
// own. Without that file Steam reports no achievements at all, so a game added
// to the unlock list would never show a card.
//
// The client does cache the full schema as gzipped JSON in the querycache, and
// each entry's internal_key is stat*256 + bit, so the binary file can be
// rebuilt from it. Three details make the difference between Steam accepting it
// and silently reporting zero achievements:
//   - the root carries "version" and "gamename" after "stats";
//   - every achievement stat carries type "ACHIEVEMENTS";
//   - the file ends with the root END plus one sentinel END, nothing else.
// A real schema round-trips through this writer byte for byte.
// ---------------------------------------------------------------------------

static int write_bytes_atomic(const char *path, const void *data, size_t len);
static int name_is_digits(const char *s);

typedef struct {
    uint8_t *p;
    size_t   len;
    size_t   cap;
    int      ok;
} bkvw_t;

static void bw_need(bkvw_t *b, size_t n) {
    if (!b->ok) return;
    if (b->len + n <= b->cap) return;
    size_t cap = b->cap ? b->cap : 1024;
    while (cap < b->len + n) cap *= 2;
    uint8_t *p = realloc(b->p, cap);
    if (!p) { b->ok = 0; return; }
    b->p = p;
    b->cap = cap;
}

static void bw_raw(bkvw_t *b, const void *d, size_t n) {
    bw_need(b, n);
    if (!b->ok) return;
    memcpy(b->p + b->len, d, n);
    b->len += n;
}

static void bw_u8(bkvw_t *b, uint8_t v) { bw_raw(b, &v, 1); }

static void bw_name(bkvw_t *b, const char *name) {
    bw_raw(b, name, strlen(name));
    bw_u8(b, 0);
}

static void bw_open(bkvw_t *b, const char *name) {
    bw_u8(b, BKV_SECTION);
    bw_name(b, name);
}

static void bw_end(bkvw_t *b) { bw_u8(b, BKV_END); }

static void bw_str(bkvw_t *b, const char *name, const char *val) {
    bw_u8(b, BKV_STRING);
    bw_name(b, name);
    bw_name(b, val ? val : "");
}

static void bw_int(bkvw_t *b, const char *name, int32_t v) {
    bw_u8(b, BKV_INT);
    bw_name(b, name);
    bw_raw(b, &v, 4);
}

typedef struct {
    uint32_t key;
    cJSON   *entry;
} ach_key_t;

static int ach_key_cmp(const void *a, const void *b) {
    uint32_t x = ((const ach_key_t *)a)->key;
    uint32_t y = ((const ach_key_t *)b)->key;
    return (x > y) - (x < y);
}

// Basename of an icon URL, which is what the schema stores.
static void icon_basename(char *dst, size_t cap, const char *url) {
    if (!url || !url[0]) { dst[0] = '\0'; return; }
    const char *slash = strrchr(url, '/');
    copy_str(dst, cap, slash ? slash + 1 : url);
}

static int json_int(cJSON *o, const char *name) {
    cJSON *v = cJSON_GetObjectItemCaseSensitive(o, name);
    return cJSON_IsNumber(v) ? (int)v->valuedouble : 0;
}

static const char *json_str(cJSON *o, const char *name) {
    cJSON *v = cJSON_GetObjectItemCaseSensitive(o, name);
    return cJSON_IsString(v) ? v->valuestring : "";
}

// Build UserGameStats_<account>_<appid>.bin, the per-user stats cache.
//
// The schema alone is not enough: Steam only reports a game's achievements as
// achievable when it can also load the user's stats cache for that app, so
// without this file the library card stays hidden even though the schema is
// there. Every achievement bit starts at zero, which is what a game that has
// never been played should look like.
static int write_stats_from_querycache(const char *root, const char *userdir,
                                       int app_id) {
    const char *acct = strrchr(userdir, '/');
    acct = acct ? acct + 1 : userdir;
    if (!name_is_digits(acct)) return 0;

    char path[1500];
    snprintf(path, sizeof(path), "%s/appcache/stats/UserGameStats_%s_%d.bin",
             root, acct, app_id);
    if (access(path, F_OK) == 0) return 0;   // keep whatever progress exists

    cJSON *doc = NULL;
    if (!load_querycache_json(userdir, app_id, &doc)) return 0;

    cJSON *data = cJSON_GetObjectItemCaseSensitive(doc, "data");
    cJSON *groups = cJSON_GetObjectItemCaseSensitive(data, "groups");

    ach_key_t *keys = NULL;
    int count = 0, cap = 0;
    if (cJSON_IsArray(groups)) {
        cJSON *group;
        cJSON_ArrayForEach(group, groups) {
            cJSON *achievements =
                cJSON_GetObjectItemCaseSensitive(group, "achievements");
            if (!cJSON_IsArray(achievements)) continue;
            cJSON *entry;
            cJSON_ArrayForEach(entry, achievements) {
                cJSON *ik = cJSON_GetObjectItemCaseSensitive(entry, "internal_key");
                if (!cJSON_IsNumber(ik)) continue;
                if (count == cap) {
                    int ncap = cap ? cap * 2 : 64;
                    ach_key_t *n = realloc(keys, (size_t)ncap * sizeof(*n));
                    if (!n) break;
                    keys = n;
                    cap = ncap;
                }
                keys[count].key = (uint32_t)ik->valuedouble;
                keys[count].entry = entry;
                count++;
            }
        }
    }
    if (count == 0) { free(keys); cJSON_Delete(doc); return 0; }

    qsort(keys, (size_t)count, sizeof(*keys), ach_key_cmp);

    bkvw_t b = {0};
    b.ok = 1;
    bw_open(&b, "cache");
    bw_int(&b, "crc", 0);
    bw_int(&b, "PendingChanges", 0);
    int i = 0;
    while (i < count) {
        uint32_t stat = keys[i].key >> 8;
        char sname[16];
        snprintf(sname, sizeof(sname), "%u", stat);
        bw_open(&b, sname);
        bw_int(&b, "data", 0);
        bw_open(&b, "AchievementTimes");
        while (i < count && (keys[i].key >> 8) == stat) {
            char bname[16];
            snprintf(bname, sizeof(bname), "%u", keys[i].key & 0xFF);
            bw_int(&b, bname, 0);
            i++;
        }
        bw_end(&b);                           // AchievementTimes
        bw_end(&b);                           // stat
    }
    bw_end(&b);                               // cache
    bw_end(&b);                               // sentinel

    free(keys);
    cJSON_Delete(doc);

    if (!b.ok || !b.p) { free(b.p); return 0; }
    int rc = write_bytes_atomic(path, b.p, b.len);
    free(b.p);
    if (rc == 0)
        SX_LOG("[achiev] app %d: wrote stats cache (%d achievement(s) at zero)",
               app_id, count);
    return rc == 0;
}

// Build UserGameStatsSchema_<appid>.bin from the cached querycache schema.
// Returns 1 when the file was written.
static int write_schema_from_querycache(const char *root, const char *userdir,
                                        int app_id) {
    char path[1500];
    snprintf(path, sizeof(path),
             "%s/appcache/stats/UserGameStatsSchema_%d.bin", root, app_id);

    cJSON *doc = NULL;
    if (!load_querycache_json(userdir, app_id, &doc)) return 0;

    cJSON *data = cJSON_GetObjectItemCaseSensitive(doc, "data");
    cJSON *groups = cJSON_GetObjectItemCaseSensitive(data, "groups");

    ach_key_t *keys = NULL;
    int count = 0, cap = 0;
    if (cJSON_IsArray(groups)) {
        cJSON *group;
        cJSON_ArrayForEach(group, groups) {
            cJSON *achievements =
                cJSON_GetObjectItemCaseSensitive(group, "achievements");
            if (!cJSON_IsArray(achievements)) continue;
            cJSON *entry;
            cJSON_ArrayForEach(entry, achievements) {
                cJSON *ik = cJSON_GetObjectItemCaseSensitive(entry, "internal_key");
                if (!cJSON_IsNumber(ik)) continue;
                if (count == cap) {
                    int ncap = cap ? cap * 2 : 64;
                    ach_key_t *n = realloc(keys, (size_t)ncap * sizeof(*n));
                    if (!n) break;
                    keys = n;
                    cap = ncap;
                }
                keys[count].key = (uint32_t)ik->valuedouble;
                keys[count].entry = entry;
                count++;
            }
        }
    }
    if (count == 0) { free(keys); cJSON_Delete(doc); return 0; }

    qsort(keys, (size_t)count, sizeof(*keys), ach_key_cmp);

    bkvw_t b = {0};
    b.ok = 1;
    char rootname[16];
    snprintf(rootname, sizeof(rootname), "%d", app_id);
    bw_open(&b, rootname);

    bw_open(&b, "stats");
    int i = 0;
    while (i < count) {
        uint32_t stat = keys[i].key >> 8;
        char sname[16];
        snprintf(sname, sizeof(sname), "%u", stat);
        bw_open(&b, sname);
        bw_str(&b, "type", "ACHIEVEMENTS");

        bw_open(&b, "bits");
        while (i < count && (keys[i].key >> 8) == stat) {
            cJSON *e = keys[i].entry;
            uint32_t bit = keys[i].key & 0xFF;
            char bname[16];
            snprintf(bname, sizeof(bname), "%u", bit);
            bw_open(&b, bname);

            const char *api = json_str(e, "api_name");
            bw_str(&b, "name", api);

            bw_open(&b, "display");
            bw_open(&b, "name");
            bw_str(&b, "english", json_str(e, "name"));
            bw_end(&b);
            bw_open(&b, "desc");
            bw_str(&b, "english", json_str(e, "description"));
            bw_end(&b);
            char icon[ACHIEV_ICON_LEN];
            icon_basename(icon, sizeof(icon), json_str(e, "icon_unachieved"));
            if (icon[0]) bw_str(&b, "icon", icon);
            cJSON *hid = cJSON_GetObjectItemCaseSensitive(e, "hidden");
            if (cJSON_IsTrue(hid)) bw_int(&b, "hidden", 1);
            bw_end(&b);                       // display

            bw_open(&b, "progress");
            bw_int(&b, "min_val", json_int(e, "min_progress"));
            bw_int(&b, "max_val", json_int(e, "max_progress"));
            bw_open(&b, "value");
            bw_str(&b, "operation", "statvalue");
            bw_str(&b, "operand1", api);
            bw_end(&b);                       // value
            bw_end(&b);                       // progress

            bw_end(&b);                       // bit
            i++;
        }
        bw_end(&b);                           // bits
        bw_end(&b);                           // stat
    }
    bw_end(&b);                               // stats

    cJSON *ver = cJSON_GetObjectItemCaseSensitive(data, "schema_version");
    bw_int(&b, "version", cJSON_IsNumber(ver) ? (int32_t)ver->valuedouble : 0);
    bw_str(&b, "gamename", "");
    bw_end(&b);                               // root
    bw_end(&b);                               // sentinel

    free(keys);
    cJSON_Delete(doc);

    if (!b.ok || !b.p) { free(b.p); return 0; }

    int rc = write_bytes_atomic(path, b.p, b.len);
    free(b.p);
    if (rc == 0)
        SX_LOG("[achiev] app %d: wrote achievement schema (%d achievement(s))",
               app_id, count);
    else
        SX_WARN("[achiev] app %d: could not write %s", app_id, path);
    return rc == 0;
}

static cJSON *build_achievement(const sx_achiev_t *a, int app_id,
                                const sx_stats_snapshot_t *snap) {
    cJSON *item = cJSON_CreateObject();
    if (!item) return NULL;

    uint32_t unlocked = achievement_unlock_time(snap, a->stat, a->bit);

    char id[ACHIEV_API_LEN + 32];
    if (a->api[0])
        snprintf(id, sizeof(id), "%s", a->api);
    else
        snprintf(id, sizeof(id), "%u_%u", a->stat, a->bit);

    const char *name = a->name[0] ? a->name : (a->api[0] ? a->api : "Achievement");
    cJSON_AddStringToObject(item, "strID", id);
    cJSON_AddStringToObject(item, "strName", name);
    cJSON_AddStringToObject(item, "strDescription", a->desc);
    if (a->icon[0]) {
        char url[ACHIEV_ICON_LEN + 128];
        if (strncmp(a->icon, "http", 4) == 0)
            snprintf(url, sizeof(url), "%s", a->icon);
        else
            snprintf(url, sizeof(url),
                     "https://shared.steamstatic.com/community_assets/images/apps/%d/%s",
                     app_id, a->icon);
        cJSON_AddStringToObject(item, "strImage", url);
    }
    cJSON_AddBoolToObject(item, "bAchieved", unlocked != 0);
    cJSON_AddNumberToObject(item, "rtUnlocked", (double)unlocked);
    cJSON_AddNumberToObject(item, "flAchieved", 0);
    cJSON_AddNumberToObject(item, "flMinProgress", 0);
    cJSON_AddNumberToObject(item, "flCurrentProgress", 0);
    cJSON_AddNumberToObject(item, "flMaxProgress", 0);
    return item;
}

// ["achievements", {"version":2,"data":{...}}], the shape the library reads.
static cJSON *build_entry(const sx_achiev_t *list, int count, int app_id,
                          const sx_stats_snapshot_t *snap, int *achieved_out) {
    cJSON *pair = cJSON_CreateArray();
    cJSON *entry = cJSON_CreateObject();
    cJSON *data = cJSON_CreateObject();
    if (!pair || !entry || !data) {
        cJSON_Delete(pair);
        cJSON_Delete(entry);
        cJSON_Delete(data);
        return NULL;
    }

    cJSON_AddNumberToObject(entry, "version", 2);
    cJSON_AddItemToObject(entry, "data", data);
    cJSON_AddItemToArray(pair, cJSON_CreateString("achievements"));
    cJSON_AddItemToArray(pair, entry);

    cJSON *highlight = cJSON_AddArrayToObject(data, "vecHighlight");
    cJSON *unachieved = cJSON_AddArrayToObject(data, "vecUnachieved");
    cJSON *hidden = cJSON_AddArrayToObject(data, "vecAchievedHidden");
    // The full list, uncapped: the "View all achievements" page uses it when
    // Steam will not answer for a game this account does not own (see
    // hooks/hook_achievui.c). The library card keeps to the capped arrays above.
    cJSON *all = cJSON_AddArrayToObject(data, "vecAll");
    if (!highlight || !unachieved || !hidden || !all) return pair;

    int achieved = 0, shown_highlight = 0, shown_unachieved = 0;
    for (int i = 0; i < count; i++) {
        cJSON *item = build_achievement(&list[i], app_id, snap);
        if (item) cJSON_AddItemToArray(all, item);
        if (achievement_unlock_time(snap, list[i].stat, list[i].bit)) {
            achieved++;
            if (shown_highlight >= ACHIEV_SHOWN) continue;
            cJSON *shown = build_achievement(&list[i], app_id, snap);
            if (shown) { cJSON_AddItemToArray(highlight, shown); shown_highlight++; }
            continue;
        }
        if (shown_unachieved >= ACHIEV_SHOWN) continue;
        cJSON *shown = build_achievement(&list[i], app_id, snap);
        if (shown) { cJSON_AddItemToArray(unachieved, shown); shown_unachieved++; }
    }
    cJSON_AddNumberToObject(data, "nTotal", count);
    cJSON_AddNumberToObject(data, "nAchieved", achieved);
    if (achieved_out) *achieved_out = achieved;
    return pair;
}

static int write_bytes_atomic(const char *path, const void *data, size_t len) {
    char tmp[2304];
    int n = snprintf(tmp, sizeof(tmp), "%s.macsteam-new", path);
    if (n < 0 || (size_t)n >= sizeof(tmp)) return -1;

    mode_t mode = 0644;
    struct stat st;
    if (stat(path, &st) == 0) mode = st.st_mode & 07777;

    FILE *f = fopen(tmp, "wb");
    if (!f) return -1;
    int ok = fwrite(data, 1, len, f) == len && fflush(f) == 0;
    if (ok) fsync(fileno(f));
    if (fclose(f) != 0) ok = 0;
    if (!ok) { unlink(tmp); return -1; }
    chmod(tmp, mode);
    if (rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

static int write_file_atomic(const char *path, const char *text, mode_t mode) {
    char tmp[2304];
    int n = snprintf(tmp, sizeof(tmp), "%s.macsteam-new", path);
    if (n < 0 || (size_t)n >= sizeof(tmp)) return -1;

    FILE *f = fopen(tmp, "wb");
    if (!f) return -1;
    size_t len = strlen(text);
    size_t wrote = fwrite(text, 1, len, f);
    int ok = wrote == len && fflush(f) == 0;
    if (fclose(f) != 0) ok = 0;
    if (!ok) { unlink(tmp); return -1; }
    chmod(tmp, mode);
    if (rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

static void steam_root_path(char *buf, size_t bufsz) {
    const char *home = sx_resolve_home();
    if (!home) home = "/tmp";
    snprintf(buf, bufsz, "%s/Library/Application Support/Steam", home);
}

static int name_is_digits(const char *s) {
    if (!s || !s[0]) return 0;
    for (size_t i = 0; s[i]; i++)
        if (s[i] < '0' || s[i] > '9') return 0;
    return 1;
}

// The account directory that holds a library cache.
// The account directory's library cache, and the account directory itself.
static int find_librarycache(char *buf, size_t bufsz,
                             char *userdir, size_t userdirsz) {
    char root[1024], userdata[1100];
    steam_root_path(root, sizeof(root));
    snprintf(userdata, sizeof(userdata), "%s/userdata", root);

    DIR *d = opendir(userdata);
    if (!d) return 0;
    struct dirent *ent;
    int found = 0;
    while ((ent = readdir(d)) != NULL) {
        if (!name_is_digits(ent->d_name)) continue;
        char candidate[1400];
        snprintf(candidate, sizeof(candidate), "%s/%s/config/librarycache",
                 userdata, ent->d_name);
        struct stat st;
        if (stat(candidate, &st) != 0 || !S_ISDIR(st.st_mode)) continue;
        snprintf(buf, bufsz, "%s", candidate);
        if (userdir && userdirsz)
            snprintf(userdir, userdirsz, "%s/%s", userdata, ent->d_name);
        found = 1;
        break;
    }
    closedir(d);
    return found;
}

// Sets a number in an object, replacing it when it already exists.
static void set_number(cJSON *object, const char *name, double value) {
    cJSON *item = cJSON_GetObjectItemCaseSensitive(object, name);
    if (cJSON_IsNumber(item)) {
        item->valuedouble = value;
        item->valueint = (int)value;
        return;
    }
    if (item) cJSON_DeleteItemFromObject(object, name);
    cJSON_AddNumberToObject(object, name, value);
}

// Sets a bool in an object, replacing it whatever it was before.
static void set_bool(cJSON *object, const char *name, int value) {
    cJSON *item = cJSON_GetObjectItemCaseSensitive(object, name);
    if (cJSON_IsBool(item)) {
        item->type = value ? cJSON_True : cJSON_False;
        return;
    }
    if (item) cJSON_DeleteItemFromObject(object, name);
    cJSON_AddBoolToObject(object, name, value);
}

// The library grid's achievement badge does not come from the library cache but
// from a second one, librarycache/achievement_progress.json (steamui's
// AppAchievementsProgressCache). The CM service fills that in only for apps the
// account owns; for the apps on the unlock list it answers total 0, so every
// tile says "No achievements" even though the game's page has the list. Write
// the same numbers from the local schema and stats, leaving an entry that
// already carries a real total (an owned game) untouched.
static void write_progress_cache(const char *cache_dir, int app_id,
                                 int total, int achieved) {
    if (!cache_dir || total <= 0) return;

    char path[1500];
    int n = snprintf(path, sizeof(path), "%s/achievement_progress.json", cache_dir);
    if (n < 0 || (size_t)n >= sizeof(path)) return;

    struct stat st;
    mode_t mode = stat(path, &st) == 0 ? (st.st_mode & 0777) : 0644;

    cJSON *doc = NULL;
    size_t len = 0;
    uint8_t *raw = sx_slurp_file(path, &len);
    if (raw) {
        doc = cJSON_Parse((const char *)raw);
        free(raw);
    }
    if (!cJSON_IsObject(doc)) {
        if (doc) cJSON_Delete(doc);
        doc = cJSON_CreateObject();
    }
    if (!doc) return;

    set_number(doc, "nVersion", 4);

    cJSON *cache = cJSON_GetObjectItemCaseSensitive(doc, "mapCache");
    if (cache && !cJSON_IsArray(cache)) {
        cJSON_DeleteItemFromObject(doc, "mapCache");
        cache = NULL;
    }
    if (!cache) cache = cJSON_AddArrayToObject(doc, "mapCache");
    if (!cache) { cJSON_Delete(doc); return; }

    cJSON *entry = NULL;
    for (int i = 0; i < cJSON_GetArraySize(cache); i++) {
        cJSON *pair = cJSON_GetArrayItem(cache, i);
        if (!cJSON_IsArray(pair) || cJSON_GetArraySize(pair) != 2) continue;
        cJSON *key = cJSON_GetArrayItem(pair, 0);
        if (!cJSON_IsNumber(key) || key->valueint != app_id) continue;
        cJSON *value = cJSON_GetArrayItem(pair, 1);
        if (!cJSON_IsObject(value)) continue;
        entry = value;
        break;
    }

    int cached_total = total;
    if (entry) {
        int cached = json_int(entry, "total");
        if (cached > 0) {
            // Steam's own count (an owned game). Refresh it only when the local
            // stats know more than that cached reply does: progress a game saved
            // while Steam was not running never reaches the CM cache.
            if (json_int(entry, "unlocked") >= achieved) { cJSON_Delete(doc); return; }
            cached_total = cached;
        }
    } else {
        cJSON *pair = cJSON_CreateArray();
        entry = cJSON_CreateObject();
        if (!pair || !entry) {
            cJSON_Delete(pair);
            cJSON_Delete(entry);
            cJSON_Delete(doc);
            return;
        }
        set_number(entry, "appid", app_id);
        set_bool(entry, "vetted", 1);
        set_number(entry, "groups_completed_base", 0);
        set_number(entry, "groups_total_base", 0);
        set_number(entry, "groups_completed_dlc", 0);
        set_number(entry, "groups_total_dlc", 0);
        cJSON_AddItemToArray(pair, cJSON_CreateNumber(app_id));
        cJSON_AddItemToArray(pair, entry);
        cJSON_AddItemToArray(cache, pair);
    }

    set_number(entry, "unlocked", achieved);
    set_number(entry, "total", cached_total);
    set_number(entry, "percentage", (int)((long)achieved * 100 / cached_total));
    set_bool(entry, "all_unlocked", achieved >= cached_total);
    set_number(entry, "cache_time", (double)time(NULL));
    set_number(entry, "base_game_total", cached_total);

    char *text = cJSON_PrintUnformatted(doc);
    cJSON_Delete(doc);
    if (!text) return;
    write_file_atomic(path, text, mode);
    cJSON_free(text);
}


// Apps whose first sync found no schema yet: the list can only be built once
// Steam has written that file, which for a game added mid-session happens when
// the library fetches its achievements a moment later. The watch thread retries
// them until the file turns up, so the card appears without a restart.
#define ACHIEV_RETRY_MAX 128
// About a minute of tries at the two-second retry pace, then the app waits for
// the next stats reply instead of being retried forever.
#define ACHIEV_RETRY_TRIES 30

static pthread_mutex_t g_retry_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_retry_ids[ACHIEV_RETRY_MAX];
static int g_retry_attempts[ACHIEV_RETRY_MAX];
static int g_retry_count;

// Caller holds the lock.
static int retry_index(int app_id) {
    for (int i = 0; i < g_retry_count; i++)
        if (g_retry_ids[i] == app_id) return i;
    return -1;
}

// Caller holds the lock.
static void retry_remove_at(int slot) {
    for (int j = slot + 1; j < g_retry_count; j++) {
        g_retry_ids[j - 1] = g_retry_ids[j];
        g_retry_attempts[j - 1] = g_retry_attempts[j];
    }
    g_retry_count--;
}

void sx_achiev_cache_sync_later(int app_id) {
    pthread_mutex_lock(&g_retry_lock);
    if (retry_index(app_id) < 0 && g_retry_count < ACHIEV_RETRY_MAX) {
        g_retry_ids[g_retry_count] = app_id;
        g_retry_attempts[g_retry_count] = 0;
        g_retry_count++;
        SX_LOG("[achiev] app %d: no schema yet, will retry", app_id);
    }
    pthread_mutex_unlock(&g_retry_lock);
}

// Hands out the apps still worth another try. They stay queued, so an app that
// fails again keeps its attempt count and one that succeeds is dropped by
// retry_done.
static int take_retries(int *out, int max) {
    pthread_mutex_lock(&g_retry_lock);
    int n = 0;
    for (int i = 0; i < g_retry_count;) {
        if (g_retry_attempts[i] >= ACHIEV_RETRY_TRIES) {
            SX_LOG("[achiev] app %d: gave up waiting for its schema", g_retry_ids[i]);
            retry_remove_at(i);
            continue;
        }
        if (n < max) out[n++] = g_retry_ids[i];
        g_retry_attempts[i]++;
        i++;
    }
    pthread_mutex_unlock(&g_retry_lock);
    return n;
}

static void retry_done(int app_id) {
    pthread_mutex_lock(&g_retry_lock);
    int slot = retry_index(app_id);
    if (slot >= 0) retry_remove_at(slot);
    pthread_mutex_unlock(&g_retry_lock);
}

// Returns 1 when the file was rewritten, 2 when it already held the list, and 0
// when there was no schema to build one from.
static int sync_app(int app_id, const char *root, const char *cache_dir,
                    const char *userdir) {
    sx_achiev_t *list = calloc(ACHIEV_MAX, sizeof(*list));
    if (!list) return 0;

    // Clear the borrowed progress first. It deletes the app's stats file, so
    // doing it after the writers below would throw away the zeroed one they just
    // wrote and leave Steam reporting the game as having no achievements. It runs
    // once per app, then leaves a marker behind.
    sx_achiev_purge_borrowed(app_id);

    // The client only writes the schema file after a stats exchange succeeds,
    // which never happens for an app the account does not own. Rebuild it from
    // the cached querycache copy so Steam has something to serve.
    if (userdir) {
        char sp[1500];
        snprintf(sp, sizeof(sp),
                 "%s/appcache/stats/UserGameStatsSchema_%d.bin", root, app_id);
        if (access(sp, R_OK) != 0)
            write_schema_from_querycache(root, userdir, app_id);
        write_stats_from_querycache(root, userdir, app_id);
    }

    // The client's own cached schema first: complete, and present for any app
    // whose page has been opened. A schema rebuilt from the querycache can list
    // the achievements without their internal keys (stat/bit), which leaves every
    // one of them looking unearned, so the binary file wins when it is there.
    char schema[1400];
    snprintf(schema, sizeof(schema),
             "%s/appcache/stats/UserGameStatsSchema_%d.bin", root, app_id);
    int count = access(schema, R_OK) == 0 ? load_schema(schema, list, ACHIEV_MAX) : 0;
    if (count <= 0 && userdir)
        count = load_schema_querycache(userdir, app_id, list, ACHIEV_MAX);
    if (count <= 0) { free(list); return 0; }

    char path[1500];
    snprintf(path, sizeof(path), "%s/%d.json", cache_dir, app_id);

    struct stat st;
    int existed = stat(path, &st) == 0;
    mode_t mode = existed ? (st.st_mode & 0777) : 0644;

    cJSON *doc = NULL;
    char *before = NULL;
    size_t before_len = 0;
    if (existed) {
        uint8_t *raw = sx_slurp_file(path, &before_len);
        if (raw) {
            before = (char *)raw;
            doc = cJSON_Parse(before);
        }
        if (doc && !cJSON_IsArray(doc)) { cJSON_Delete(doc); doc = NULL; }
    }
    if (!doc) doc = cJSON_CreateArray();
    if (!doc) { free(before); free(list); return 0; }

    // The entry is always rebuilt: an app on the unlock list starts with nothing
    // earned, and a list left behind by an earlier run (or written from another
    // account's stats) must not survive.
    int at = -1;
    for (int i = 0; i < cJSON_GetArraySize(doc); i++) {
        cJSON *pair = cJSON_GetArrayItem(doc, i);
        if (!cJSON_IsArray(pair) || cJSON_GetArraySize(pair) != 2) continue;
        cJSON *key = cJSON_GetArrayItem(pair, 0);
        if (!cJSON_IsString(key) || strcmp(key->valuestring, "achievements") != 0) continue;
        at = i;
        break;
    }

    // The user's own stats hold the real unlock state: a game played earlier has
    // achievements the per-app cache Steam wrote can lag behind.
    sx_stats_snapshot_t snap;
    int have_snapshot = 0;
    if (userdir) {
        const char *acct = strrchr(userdir, '/');
        acct = acct ? acct + 1 : userdir;
        if (name_is_digits(acct)) {
            uint32_t account = (uint32_t)strtoul(acct, NULL, 10);
            have_snapshot = sx_stats_cache_load(app_id, account, &snap) == 1;
        }
    }

    int achieved = 0;
    cJSON *entry = build_entry(list, count, app_id,
                               have_snapshot ? &snap : NULL, &achieved);
    free(list);
    if (!entry) { cJSON_Delete(doc); free(before); return 0; }

    // The grid badge reads this, whether or not the library cache changed.
    write_progress_cache(cache_dir, app_id, count, achieved);

    if (at >= 0)
        cJSON_ReplaceItemInArray(doc, at, entry);
    else if (!cJSON_AddItemToArray(doc, entry))
        cJSON_Delete(entry);

    char *text = cJSON_PrintUnformatted(doc);
    cJSON_Delete(doc);
    if (!text) { free(before); return 0; }

    int rc = 2;
    if (!before || before_len != strlen(text) || memcmp(before, text, before_len) != 0)
        rc = write_file_atomic(path, text, mode) == 0 ? 1 : 0;
    cJSON_free(text);
    free(before);
    return rc;
}

int sx_achiev_cache_sync_app(int app_id) {
    char root[1024], cache_dir[1400], userdir[1400];
    steam_root_path(root, sizeof(root));
    if (!find_librarycache(cache_dir, sizeof(cache_dir), userdir, sizeof(userdir))) {
        SX_DBG("[achiev] app %d: no userdata library cache yet", app_id);
        return 0;
    }
    int rc = sync_app(app_id, root, cache_dir, userdir);
    if (rc == 1)
        SX_LOG("[achiev] app %d: achievement list written to the library cache", app_id);
    return rc;
}

void sx_achiev_cache_sync(sx_config_t *cfg) {
    if (!cfg || !cfg->app_ids || cfg->app_count <= 0) return;

    char root[1024], cache_dir[1400], userdir[1400];
    steam_root_path(root, sizeof(root));
    if (!find_librarycache(cache_dir, sizeof(cache_dir), userdir, sizeof(userdir))) {
        SX_WARN("[achiev] no userdata library cache found; skipping");
        return;
    }
    int filled = 0;
    for (int i = 0; i < cfg->app_count; i++)
        if (sync_app(cfg->app_ids[i], root, cache_dir, userdir) == 1) filled++;
    if (filled)
        SX_LOG("[achiev] %d app(s): achievement lists written to the library cache", filled);
}

// Keep the config's apps supplied with a list, and keep watching for apps added
// while Steam runs.
//
// A game has no cached schema until its library page has been opened once, so an
// app that cannot be built yet is retried. The config file is re-read whenever it
// changes, because a game imported in the config app is only in that file and not
// in the copy read at launch, which is why an import used to need a Steam restart.
// Every VERIFY_EVERY rounds the whole list is synced again, in case Steam has
// rewritten an entry in the meantime.
void sx_achiev_cache_watch(sx_config_t *cfg) {
    enum { WATCH_MAX = 512, VERIFY_EVERY = 30 };
    static int done[WATCH_MAX];
    int done_count = 0;

    // Our own copy of the app list: the caller's belongs to the launch snapshot.
    // Only the ids are kept here. sx_config_t carries the depot-key table and is
    // over a megabyte, far more than this thread's stack has room for, so a whole
    // config is only ever built on the heap.
    int *live = calloc(WATCH_MAX, sizeof(int));
    int live_count = 0;
    if (!live) return;
    if (cfg && cfg->app_ids && cfg->app_count > 0) {
        live_count = cfg->app_count < WATCH_MAX ? cfg->app_count : WATCH_MAX;
        memcpy(live, cfg->app_ids, (size_t)live_count * sizeof(int));
    }

    char config_path[512];
    sx_file_config_path(config_path, sizeof(config_path));
    time_t cfg_mtime = 0;
    off_t cfg_size = -1;

    for (int round = 0;; round++) {
        // Soon after launch, then slower — but quickly while an app is waiting
        // for the schema its first sync could not find yet.
        pthread_mutex_lock(&g_retry_lock);
        int retrying = g_retry_count > 0;
        pthread_mutex_unlock(&g_retry_lock);
        sleep(retrying ? 2 : (round < 12 ? 5 : 20));

        // The config app rewrites this file when it imports a game.
        struct stat cst;
        if (stat(config_path, &cst) == 0 &&
            (cst.st_mtime != cfg_mtime || cst.st_size != cfg_size)) {
            sx_config_t *fresh = calloc(1, sizeof(*fresh));
            if (fresh) {
                if (sx_config_load(config_path, fresh) == 0 &&
                    fresh->app_ids && fresh->app_count > 0) {
                    int n = fresh->app_count < WATCH_MAX ? fresh->app_count : WATCH_MAX;
                    memcpy(live, fresh->app_ids, (size_t)n * sizeof(int));
                    live_count = n;
                }
                sx_config_free(fresh);
                free(fresh);
            }
            cfg_mtime = cst.st_mtime;
            cfg_size = cst.st_size;
            // A game was added or removed: go through the whole list again so the
            // new one gets its achievement caches now, not at the next launch.
            done_count = 0;
        }

        if (live_count <= 0) continue;

        char root[1024], cache_dir[1400], userdir[1400];
        steam_root_path(root, sizeof(root));
        if (!find_librarycache(cache_dir, sizeof(cache_dir), userdir, sizeof(userdir)))
            continue;


        if (round > 0 && round % VERIFY_EVERY == 0) done_count = 0;

        for (int i = 0; i < live_count; i++) {
            int app = live[i];
            int known = 0;
            for (int k = 0; k < done_count; k++)
                if (done[k] == app) { known = 1; break; }
            if (known) continue;
            if (sync_app(app, root, cache_dir, userdir) != 0 && done_count < WATCH_MAX)
                done[done_count++] = app;
        }

        // Apps whose schema only arrived after their first sync (a stats reply
        // that ran before Steam wrote the file). Try them again now that it is
        // there, and show the result without waiting for a restart.
        int retries[ACHIEV_RETRY_MAX];
        int retry_count = take_retries(retries, ACHIEV_RETRY_MAX);
        int wrote_retry = 0;
        for (int i = 0; i < retry_count; i++) {
            int rc = sync_app(retries[i], root, cache_dir, userdir);
            if (rc == 0) continue;             // still no schema: keep trying
            retry_done(retries[i]);
            SX_LOG("[achiev] retry: app %d synced (rc=%d)", retries[i], rc);
            if (rc == 1) wrote_retry = 1;
        }
        if (wrote_retry) sx_reconcile_arm_library_refresh();
    }

    free(live);
}

// An app that goes through the stats redirect has the owner's numbers written to
// the client's own stats cache, and the library's achievement card counts those,
// so a game nobody played shows progress it never had. The reply is cleared on
// the way past, but this Steam build stores the borrow anyway. Purging the two
// files the client keeps for the app leaves it starting from nothing, and the
// marker stops that from happening again once the player has earned something.
int sx_achiev_purge_borrowed(int app_id) {
    const char *home = sx_resolve_home();
    if (!home) return 0;

    char marker_dir[1024], marker[1200];
    sx_macsteam_support_path(marker_dir, sizeof(marker_dir), home, "achiev-cleared");
    mkdir(marker_dir, 0755);
    snprintf(marker, sizeof(marker), "%s/%d", marker_dir, app_id);
    if (access(marker, F_OK) == 0) return 0;

    char root[1024], cache_dir[1400], userdir[1400];
    steam_root_path(root, sizeof(root));
    if (!find_librarycache(cache_dir, sizeof(cache_dir), userdir, sizeof(userdir)))
        return 0;

    // <steam>/appcache/stats/UserGameStats_<account>_<appid>.bin
    char stats_dir[1200];
    snprintf(stats_dir, sizeof(stats_dir), "%s/appcache/stats", root);
    DIR *d = opendir(stats_dir);
    if (d) {
        struct dirent *ent;
        while ((ent = readdir(d)) != NULL) {
            size_t n = strlen(ent->d_name);
            char suffix[32];
            snprintf(suffix, sizeof(suffix), "_%d.bin", app_id);
            size_t sl = strlen(suffix);
            if (n <= sl || strcmp(ent->d_name + n - sl, suffix) != 0) continue;
            if (strncmp(ent->d_name, "UserGameStats_", 14) != 0) continue;
            char path[1500];
            snprintf(path, sizeof(path), "%s/%s", stats_dir, ent->d_name);
            unlink(path);
        }
        closedir(d);
    }

    // <steam>/userdata/<account>/querycache/achievements/
    //     achievements_<appid>_user_achievements_<steamid>-<hash>.cmsg
    char qdir[1400];
    snprintf(qdir, sizeof(qdir), "%s/querycache/achievements", userdir);
    d = opendir(qdir);
    if (d) {
        struct dirent *ent;
        char prefix[64];
        snprintf(prefix, sizeof(prefix), "achievements_%d_user_achievements_", app_id);
        size_t pl = strlen(prefix);
        while ((ent = readdir(d)) != NULL) {
            if (strncmp(ent->d_name, prefix, pl) != 0) continue;
            char path[1500];
            snprintf(path, sizeof(path), "%s/%s", qdir, ent->d_name);
            unlink(path);
        }
        closedir(d);
    }

    FILE *f = fopen(marker, "w");
    if (f) fclose(f);
    SX_LOG("[achiev] app %d: cleared borrowed progress", app_id);
    return 1;
}
