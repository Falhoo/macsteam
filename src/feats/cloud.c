// Steam Cloud for unlocked games
//
// A game the account does not own gets no Steam Cloud: the client's cloud calls
// for that app fail, so the library shows a cloud error and nothing is synced
// between machines. The saves themselves are not lost — the game writes them to
//
//     <steam>/userdata/<account>/<appid>/remote/...
//
// and they stay there. What is missing is only the client's own copy of them.
//
// So this keeps a second copy in macSteam's own folder
//
//     <support>/cloud/<appid>/files/...
//
// with one rule: a file name is written there once, the first time it is seen,
// and never overwritten. A save the game later corrupts, or a file it deletes,
// is still in the store afterwards. An app listed under "CloudRestore:" also has
// the store written back into Steam's folder, and only when that folder holds no
// files at all, which is the new-Mac, first-launch case.
//
// Nothing here touches Steam's network traffic, and everything runs only when
// config.yaml holds "Cloud: yes".
#include "cloud.h"

#include "../steam_types.h"
#include "../util/file.h"
#include "../util/log.h"

#include <dirent.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>

extern char **environ;
#include <unistd.h>

#define CLOUD_APPS_MAX        512
#define CLOUD_ROUNDS         2880   // about two days of a running client
#define CLOUD_LOG_APPS         20
#define CLOUD_DEPTH_MAX         8
#define CLOUD_FILE_MAX_BYTES (64ull * 1024ull * 1024ull)
#define CLOUD_RESTORE_MAX      16
#define CLOUD_CAPTURE_BYTES  1024

static void steam_root(char *buf, size_t bufsz) {
    const char *home = sx_resolve_home();
    if (!home) home = "/tmp";
    snprintf(buf, bufsz, "%s/Library/Application Support/Steam", home);
}

// Where the cloud settings live. The config app rewrites config.yaml from the
// fixed set of keys it knows, so anything else belongs in a file of its own:
// config.yaml is only read for these keys when that file is not there.
static FILE *open_cloud_file(char *shown, size_t shown_sz) {
    const char *home = sx_resolve_home();
    if (!home) return NULL;
    char dir[512], path[600];
    sx_macsteam_support_path(dir, sizeof(dir), home, NULL);
    if (snprintf(path, sizeof(path), "%s/cloud.yaml", dir) >= (int)sizeof(path))
        return NULL;
    FILE *f = fopen(path, "r");
    if (f && shown) snprintf(shown, shown_sz, "%s", path);
    return f;
}

// -1 when the key is not in the file, otherwise 0 or 1.
static int key_switch(FILE *f, const char *key) {
    if (!f) return -1;
    size_t klen = strlen(key);
    fseek(f, 0, SEEK_SET);
    char line[1024];
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, key, klen) != 0) continue;
        if (line[klen] != ':') continue;
        const char *v = line + klen + 1;
        while (*v == ' ' || *v == '\t') v++;
        return (v[0] == 'y' || v[0] == 'Y' || v[0] == '1');
    }
    return -1;
}

// cloud.yaml when it is there, otherwise config.yaml.
static FILE *open_settings(char *shown, size_t shown_sz) {
    FILE *f = open_cloud_file(shown, shown_sz);
    if (f) return f;
    char path[512];
    sx_file_config_path(path, sizeof(path));
    if (shown) snprintf(shown, shown_sz, "%s", path);
    return fopen(path, "r");
}

// "Enabled: yes" in cloud.yaml, or "Cloud: yes" in config.yaml. Off unless the
// user asks for it.
static int cloud_enabled(void) {
    char shown[600];
    FILE *f = open_cloud_file(shown, sizeof(shown));
    if (f) {
        int on = key_switch(f, "Enabled");
        fclose(f);
        if (on >= 0) return on;
    }

    char path[512];
    sx_file_config_path(path, sizeof(path));
    f = fopen(path, "r");
    if (!f) return 0;
    int on = key_switch(f, "Cloud");
    fclose(f);
    return on > 0;
}

// "AutoDetect: no" stops the log being followed, so nothing new is looked for.
static int auto_detect_enabled(void) {
    char shown[600];
    FILE *f = open_settings(shown, sizeof(shown));
    if (!f) return 1;
    int on = key_switch(f, "AutoDetect");
    fclose(f);
    return on != 0;   // -1 (not in the file) means on
}

// "RestoreAll: yes" puts every folder macSteam knows back, not only the ones
// named under Restore. On unless turned off, and a folder with saves in it is
// still never replaced.
static int restore_all_enabled(void) {
    char shown[600];
    FILE *f = open_settings(shown, sizeof(shown));
    if (!f) return 1;
    int on = key_switch(f, "RestoreAll");
    fclose(f);
    return on != 0;   // -1 (not in the file) means on
}

// "Restore: 413150, 105600" in cloud.yaml, or "CloudRestore:" in config.yaml —
// the apps whose stored saves may be written back, and only into a folder that
// holds no files at all. Off unless an app is named here, because this is the
// only part that writes outside macSteam's own folder.
static int read_restore_list(int *out, int max) {
    char shown[600];
    FILE *f = open_settings(shown, sizeof(shown));
    if (!f) return 0;

    char line[1024];
    int n = 0;
    while (fgets(line, sizeof(line), f)) {
        char *p = NULL;
        if (strncmp(line, "CloudRestore:", 13) == 0) p = line + 13;
        else if (strncmp(line, "Restore:", 8) == 0) p = line + 8;
        if (!p) continue;
        while (*p && n < max) {
            while (*p && (*p < '0' || *p > '9')) p++;
            if (!*p) break;
            long v = strtol(p, &p, 10);
            if (v > 0) out[n++] = (int)v;
        }
        break;
    }
    fclose(f);
    return n;
}

// "CloudFolders:" — the save folders games keep outside Steam's own. A game that
// does not use Steam's RemoteStorage never puts anything in userdata/<appid>, so
// the only way to keep its saves is to be told where they are:
//
//     CloudFolders:
//       413150: ~/.config/StardewValley
//
// Each one is mirrored into <support>/cloud/<appid>/game.
typedef struct {
    int  app_id;
    char path[512];
} cloud_folder_t;

#define CLOUD_FOLDER_MAX 32

static int expand_path(const char *in, char *out, size_t sz) {
    const char *home = sx_resolve_home();
    if (!home) return 0;

    while (*in == ' ' || *in == '\t') in++;
    int written = (in[0] == '~' && (in[1] == '/' || in[1] == '\0'))
                      ? snprintf(out, sz, "%s%s", home, in + 1)
                      : snprintf(out, sz, "%s", in);
    if (written < 0 || (size_t)written >= sz) return 0;

    size_t n = strlen(out);
    while (n > 1 && (out[n - 1] == '/' || out[n - 1] == '\r' || out[n - 1] == ' '))
        out[--n] = '\0';
    return out[0] != '\0';
}

static int read_game_folders(cloud_folder_t *out, int max) {
    char shown[600];
    FILE *f = open_settings(shown, sizeof(shown));
    if (!f) return 0;

    char line[1024];
    int n = 0, in_block = 0;
    while (fgets(line, sizeof(line), f)) {
        if (!in_block) {
            if (strncmp(line, "CloudFolders:", 13) != 0 &&
                strncmp(line, "Folders:", 8) != 0)
                continue;
            in_block = 1;
            continue;
        }

        // The block ends at the next key of its own, or at anything that is not
        // "appid: path".
        if (line[0] != ' ' && line[0] != '\t') break;
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n') continue;

        char *colon = strchr(p, ':');
        if (!colon) break;

        char *id_end = colon;
        while (id_end > p && (id_end[-1] == ' ' || id_end[-1] == '\t')) id_end--;
        size_t id_len = (size_t)(id_end - p);
        if (id_len == 0 || id_len >= 32) break;
        int id = 0, digits = 1;
        for (size_t i = 0; i < id_len; i++) {
            if (p[i] < '0' || p[i] > '9') { digits = 0; break; }
            id = id * 10 + (p[i] - '0');
        }
        if (!digits || id <= 0) break;

        char *v = colon + 1;
        while (*v == ' ' || *v == '\t') v++;
        size_t v_len = strlen(v);
        while (v_len && (v[v_len - 1] == '\n' || v[v_len - 1] == '\r' ||
                         v[v_len - 1] == ' ' || v[v_len - 1] == '\t'))
            v_len--;
        if (v_len >= 2 && (v[0] == '"' || v[0] == '\'') && v[v_len - 1] == v[0]) {
            v++;
            v_len -= 2;
        }
        if (v_len == 0 || v_len >= sizeof(out[0].path)) continue;

        out[n].app_id = id;
        memcpy(out[n].path, v, v_len);
        out[n].path[v_len] = '\0';
        n++;
        if (n >= max) break;
    }

    fclose(f);
    return n;
}

// The folder every backup is kept in: "Destination:" when the app has set one,
// otherwise macSteam's own support folder.
static void store_root(char *buf, size_t bufsz) {
    char shown[600];
    FILE *f = open_settings(shown, sizeof(shown));
    if (f) {
        char line[1024];
        while (fgets(line, sizeof(line), f)) {
            if (strncmp(line, "Destination:", 12) != 0) continue;
            char *v = line + 12;
            while (*v == ' ' || *v == '\t') v++;

            size_t n = strlen(v);
            while (n && (v[n - 1] == '\n' || v[n - 1] == '\r' ||
                         v[n - 1] == ' ' || v[n - 1] == '\t'))
                n--;
            if (n >= 2 && (v[0] == '"' || v[0] == '\'') && v[n - 1] == v[0]) {
                v++;
                n -= 2;
            }

            if (n >= 1 && n < sizeof(line)) {
                char path[700];
                snprintf(path, sizeof(path), "%.*s", (int)n, v);
                if (expand_path(path, buf, bufsz)) {
                    fclose(f);
                    return;
                }
            }
            break;
        }
        fclose(f);
    }

    const char *home = sx_resolve_home();
    if (!home) home = "/tmp";
    sx_macsteam_support_path(buf, bufsz, home, "cloud");
}

// Whether backups are also kept in an online account ("Remote: webdav").
static int remote_configured(void) {
    char shown[600];
    FILE *f = open_settings(shown, sizeof(shown));
    if (!f) return 0;

    char line[1024];
    int on = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "Remote:", 7) != 0) continue;
        const char *v = line + 7;
        while (*v == ' ' || *v == '\t') v++;
        on = (*v != '\0' && *v != '\n' && *v != '\r');
        break;
    }
    fclose(f);
    return on;
}

// The config app, which owns the account settings and the keychain entry, run
// headless as the sync helper.
static int helper_path(char *buf, size_t bufsz) {
    buf[0] = '\0';
    char shown[600];
    FILE *f = open_settings(shown, sizeof(shown));
    if (f) {
        char line[1024];
        while (fgets(line, sizeof(line), f)) {
            if (strncmp(line, "Helper:", 7) != 0) continue;
            const char *v = line + 7;
            while (*v == ' ' || *v == '\t') v++;
            size_t n = strlen(v);
            while (n && (v[n - 1] == '\n' || v[n - 1] == '\r' || v[n - 1] == ' '))
                n--;
            if (n && n < bufsz) {
                memcpy(buf, v, n);
                buf[n] = '\0';
            }
            break;
        }
        fclose(f);
    }
    if (buf[0] == '\0')
        snprintf(buf, bufsz,
                 "/Applications/macSteam NotProton.app/Contents/MacOS/MacsteamApp");
    return access(buf, X_OK) == 0;
}

// Runs the helper. A pull is waited for, because the restore pass right after it
// needs the files it brings back; a push is left to finish on its own.
static void run_cloud_sync(const char *direction, int wait_for_it) {
    char helper[1024];
    if (!helper_path(helper, sizeof(helper))) {
        SX_WARN("[cloud] no sync helper to run");
        return;
    }

    char *argv[] = { helper, "--cloud-sync", (char *)direction, NULL };
    pid_t pid = 0;
    if (posix_spawn(&pid, helper, NULL, NULL, argv, environ) != 0) {
        SX_WARN("[cloud] could not start the sync helper");
        return;
    }
    if (!wait_for_it) return;

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return;
    SX_LOG("[cloud] account %s finished (status %d)", direction, status);
}

// The account directory the client keeps its cloud cache under.
static int find_account_dir(char *buf, size_t bufsz) {
    char root[1024], userdata[1100];
    steam_root(root, sizeof(root));
    snprintf(userdata, sizeof(userdata), "%s/userdata", root);

    DIR *d = opendir(userdata);
    if (!d) return 0;

    struct dirent *ent;
    int found = 0;
    while ((ent = readdir(d)) != NULL) {
        if (ent->d_name[0] < '0' || ent->d_name[0] > '9') continue;
        char cand[1400];
        snprintf(cand, sizeof(cand), "%s/%s", userdata, ent->d_name);
        struct stat st;
        if (stat(cand, &st) != 0 || !S_ISDIR(st.st_mode)) continue;
        snprintf(buf, bufsz, "%s", cand);
        found = 1;
        break;
    }
    closedir(d);
    return found;
}

// <support>/cloud, or a folder inside it, created if needed.
static int support_cloud_dir(char *buf, size_t bufsz, const char *sub) {
    const char *home = sx_resolve_home();
    if (!home) return 0;
    char root[1024];
    sx_macsteam_support_path(root, sizeof(root), home, "cloud");
    mkdir(root, 0755);
    if (sub && *sub)
        snprintf(buf, bufsz, "%s/%s", root, sub);
    else
        snprintf(buf, bufsz, "%s", root);
    mkdir(buf, 0755);
    return 1;
}

void sx_cloud_store_path(int app_id, char *buf, size_t bufsz) {
    char root[1200];
    store_root(root, sizeof(root));
    if (root[0] == '\0') {
        snprintf(buf, bufsz, "/tmp");
        return;
    }
    mkdir(root, 0755);
    snprintf(buf, bufsz, "%s/%d", root, app_id);
}

// How much a folder tree holds. Used to report a tree and to decide whether
// Steam's folder for an app is empty.
static int count_files(const char *dir, int depth, int *count,
                       unsigned long long *bytes) {
    *count = 0;
    *bytes = 0;
    if (depth > CLOUD_DEPTH_MAX) return 0;

    DIR *d = opendir(dir);
    if (!d) return 0;

    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (ent->d_name[0] == '.') continue;
        char p[1600];
        struct stat st;
        if (snprintf(p, sizeof(p), "%s/%s", dir, ent->d_name) >= (int)sizeof(p))
            continue;
        if (lstat(p, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) {
            int sub = 0;
            unsigned long long sub_bytes = 0;
            if (count_files(p, depth + 1, &sub, &sub_bytes)) {
                *count += sub;
                *bytes += sub_bytes;
            }
        } else if (S_ISREG(st.st_mode)) {
            (*count)++;
            *bytes += (unsigned long long)st.st_size;
        }
    }
    closedir(d);
    return 1;
}

void sx_cloud_observe(sx_config_t *cfg) {
    if (!cfg || !cfg->app_ids || cfg->app_count <= 0) return;
    if (!cloud_enabled()) return;   // opt-in; silent unless asked for

    char account[1400];
    if (!find_account_dir(account, sizeof(account))) {
        SX_WARN("[cloud] no userdata folder yet; nothing to observe");
        return;
    }

    char root[1200];
    store_root(root, sizeof(root));
    mkdir(root, 0755);

    int apps = 0, files = 0, stored_apps = 0, stored_files = 0;
    unsigned long long bytes = 0, stored_bytes = 0;
    for (int i = 0; i < cfg->app_count; i++) {
        int count = 0;
        unsigned long long bytes_here = 0;
        char remote[1400];
        snprintf(remote, sizeof(remote), "%s/%d/remote", account, cfg->app_ids[i]);
        if (!count_files(remote, 0, &count, &bytes_here)) continue;

        char store[1200], files_dir[1400];
        sx_cloud_store_path(cfg->app_ids[i], store, sizeof(store));
        snprintf(files_dir, sizeof(files_dir), "%s/files", store);
        int kept = 0;
        unsigned long long kept_bytes = 0;
        count_files(files_dir, 0, &kept, &kept_bytes);

        if (count == 0 && kept == 0) continue;

        apps++;
        files += count;
        bytes += bytes_here;
        stored_apps++;
        stored_files += kept;
        stored_bytes += kept_bytes;

        if (apps <= CLOUD_LOG_APPS)
            SX_LOG("[cloud] app %d: %d save file(s) in Steam, %d in the store",
                   cfg->app_ids[i], count, kept);
    }

    SX_LOG("[cloud] observe: %d app(s), %d file(s), %llu byte(s) in Steam; "
           "%d app(s), %d file(s), %llu byte(s) stored here",
           apps, files, bytes, stored_apps, stored_files, stored_bytes);
}

// ---------------------------------------------------------------------------
// The store

// Copies one file into the store. The destination is only written when it does
// not exist yet, so the first bytes ever seen for a name are the ones kept.
static int mirror_file(const char *src, const char *dst, int *added, int *kept) {
    struct stat st;
    if (lstat(src, &st) != 0 || !S_ISREG(st.st_mode)) return 0;
    if (st.st_size < 0 || (unsigned long long)st.st_size > CLOUD_FILE_MAX_BYTES)
        return 0;

    if (access(dst, F_OK) == 0) {
        (*kept)++;
        return 0;
    }

    char tmp[1700];
    if (snprintf(tmp, sizeof(tmp), "%s.part", dst) >= (int)sizeof(tmp)) return 0;

    FILE *in = fopen(src, "rb");
    if (!in) return 0;
    FILE *out = fopen(tmp, "wb");
    if (!out) {
        fclose(in);
        return 0;
    }

    char buf[16384];
    int ok = 1;
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
        if (fwrite(buf, 1, n, out) != n) {
            ok = 0;
            break;
        }
    }
    fclose(in);
    if (fclose(out) != 0) ok = 0;
    if (!ok || rename(tmp, dst) != 0) {
        unlink(tmp);
        return 0;
    }

    (*added)++;
    return 1;
}

// Walks a save folder, mirroring it into the other one. Subfolders are followed,
// symlinks are not, and a half-written ".part" left by an earlier run is skipped.
static void mirror_tree(const char *src, const char *dst, int depth,
                        int *added, int *kept) {
    if (depth > CLOUD_DEPTH_MAX) return;

    DIR *d = opendir(src);
    if (!d) return;
    mkdir(dst, 0755);

    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (ent->d_name[0] == '.') continue;

        size_t name_len = strlen(ent->d_name);
        if (name_len > 5 && strcmp(ent->d_name + name_len - 5, ".part") == 0)
            continue;

        char s[1600], t[1600];
        int sl = snprintf(s, sizeof(s), "%s/%s", src, ent->d_name);
        int tl = snprintf(t, sizeof(t), "%s/%s", dst, ent->d_name);
        if (sl < 0 || sl >= (int)sizeof(s) || tl < 0 || tl >= (int)sizeof(t))
            continue;

        struct stat st;
        if (lstat(s, &st) != 0) continue;
        if (S_ISLNK(st.st_mode)) continue;
        if (S_ISDIR(st.st_mode))
            mirror_tree(s, t, depth + 1, added, kept);
        else if (S_ISREG(st.st_mode))
            mirror_file(s, t, added, kept);
    }
    closedir(d);
}

// One app pass: back its saves up, and restore them first if it was asked for
// and Steam's folder is empty.
static int sync_app(const char *account, int app_id, int restore) {
    char remote[1400];
    snprintf(remote, sizeof(remote), "%s/%d/remote", account, app_id);

    char store[1200], files[1220];
    sx_cloud_store_path(app_id, store, sizeof(store));
    snprintf(files, sizeof(files), "%s/files", store);

    struct stat st;
    int exists = stat(remote, &st) == 0 && S_ISDIR(st.st_mode);

    // Put back every file macSteam has that this folder is missing — a game that
    // was reinstalled, or a new Mac, where the folder is gone or only holds what
    // the game has just generated. A file that is already there is never
    // overwritten.
    if (restore) {
        int put = 0, kept = 0;
        mirror_tree(files, remote, 0, &put, &kept);
        if (put)
            SX_LOG("[cloud] app %d: put back %d saved file(s) into Steam", app_id, put);
    }

    if (!exists) return 0;   // nothing of the game's own to keep yet

    mkdir(store, 0755);
    int added = 0, kept = 0;
    mirror_tree(remote, files, 0, &added, &kept);
    if (added)
        SX_LOG("[cloud] app %d: backed up %d new save file(s), %d already stored",
               app_id, added, kept);
    return added;
}

// The same for a folder the game keeps outside Steam: mirror it into
// <store>/game, and put it back when the game's folder is empty and the app was
// listed under CloudRestore.
static int sync_game_folder(int app_id, const char *folder, int restore) {
    char path[700];
    if (!expand_path(folder, path, sizeof(path))) return 0;

    char store[1200], dest[1220];
    sx_cloud_store_path(app_id, store, sizeof(store));
    if (snprintf(dest, sizeof(dest), "%s/game", store) >= (int)sizeof(dest))
        return 0;

    struct stat st;
    int exists = stat(path, &st) == 0 && S_ISDIR(st.st_mode);

    if (restore) {
        int put = 0, kept = 0;
        mirror_tree(dest, path, 0, &put, &kept);
        if (put)
            SX_LOG("[cloud] app %d: put back %d saved file(s) to %s", app_id, put, path);
    }

    if (!exists) return 0;

    mkdir(store, 0755);
    int added = 0, kept = 0;
    mirror_tree(path, dest, 0, &added, &kept);
    if (added)
        SX_LOG("[cloud] app %d: backed up %d new save file(s) from %s",
               app_id, added, path);
    return added;
}

// ---------------------------------------------------------------------------
// Finding a game's save folder by itself
//
// Nothing has to be listed by hand. Steam writes ": Game process added" and
// ": Game process removed" lines to logs/console_log.txt with the app id, so a
// session's start can be seen and its end noticed. When the game exits, the
// folders that were written to while it ran are the ones worth keeping, and the
// name in appmanifest_<appid>.acf says which of them is the game's.
//
// Only a handful of places are looked in, one level down, and only a folder that
// was created or written to during that session is ever taken. A mapping found
// this way is written into cloud.yaml under Folders, so the next launch already
// knows where it is.
#define CLOUD_SESSIONS_MAX 4
#define CLOUD_SCAN_BUDGET  20000

typedef struct {
    int    app_id;
    time_t started;
    char   exe[512];
} cloud_session_t;

static cloud_session_t g_sessions[CLOUD_SESSIONS_MAX];
static int             g_session_count;
static off_t           g_log_offset;
static int             g_log_started;

// Letters and digits only, lowercased: "Stardew Valley" and "StardewValley"
// have to look like the same name.
static void norm_name(const char *in, char *out, size_t sz) {
    size_t n = 0;
    for (; *in && n + 1 < sz; in++) {
        unsigned char c = (unsigned char)*in;
        if (c >= 'A' && c <= 'Z') c = (unsigned char)(c - 'A' + 'a');
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) out[n++] = (char)c;
    }
    out[n] = '\0';
}

static int name_matches(const char *base, const char *game, const char *install) {
    char b[256];
    norm_name(base, b, sizeof(b));
    if (b[0] == '\0') return 0;
    if (game[0] && strcmp(b, game) == 0) return 1;
    if (install[0] && strcmp(b, install) == 0) return 1;
    if (game[0] && strlen(b) >= 4 && strstr(game, b)) return 1;
    if (install[0] && strlen(b) >= 4 && strstr(install, b)) return 1;
    if (game[0] && strlen(game) >= 4 && strstr(b, game)) return 1;
    return 0;
}

// The game's own name and install folder, from the app manifest.
static void app_names(int app_id, char *name, size_t name_sz,
                      char *install, size_t install_sz) {
    name[0] = '\0';
    install[0] = '\0';

    char root[1024], path[1200];
    steam_root(root, sizeof(root));
    snprintf(path, sizeof(path), "%s/steamapps/appmanifest_%d.acf", root, app_id);

    FILE *f = fopen(path, "r");
    if (!f) return;

    char line[1024];
    while (fgets(line, sizeof(line), f)) {
        char *key = strstr(line, "\"name\"");
        size_t skip = 6;
        char *out = name;
        size_t out_sz = name_sz;
        if (!key) {
            key = strstr(line, "\"installdir\"");
            skip = 12;
            out = install;
            out_sz = install_sz;
        }
        if (!key) continue;

        char *v = strchr(key + skip, '"');
        if (!v) continue;
        v++;
        char *e = strchr(v, '"');
        if (!e) continue;
        size_t len = (size_t)(e - v);
        if (len >= out_sz) len = out_sz - 1;
        memcpy(out, v, len);
        out[len] = '\0';
    }
    fclose(f);
}

// Whether anything under this folder was written after the game started. A save
// updates the folder's own stamp too, which is the cheap answer; the walk below
// only runs when that is not enough.
static int tree_written_since(const char *path, time_t since, int depth,
                              int *budget) {
    if (depth > 3 || *budget <= 0) return 0;

    DIR *d = opendir(path);
    if (!d) return 0;

    int written = 0;
    struct dirent *ent;
    while (!written && (ent = readdir(d)) != NULL) {
        if (ent->d_name[0] == '.') continue;
        if (--(*budget) <= 0) break;

        char p[1600];
        if (snprintf(p, sizeof(p), "%s/%s", path, ent->d_name) >= (int)sizeof(p))
            continue;

        struct stat st;
        if (lstat(p, &st) != 0) continue;
        if (S_ISDIR(st.st_mode))
            written = tree_written_since(p, since, depth + 1, budget);
        else if (S_ISREG(st.st_mode) && st.st_mtime >= since)
            written = 1;
    }
    closedir(d);
    return written;
}

static int dir_written_since(const char *path, time_t since) {
    struct stat st;
    if (stat(path, &st) != 0 || !S_ISDIR(st.st_mode)) return 0;
    if (st.st_mtime >= since) return 1;
    int budget = CLOUD_SCAN_BUDGET / 4;
    return tree_written_since(path, since, 0, &budget);
}

static int dir_created_since(const char *path, time_t since) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return st.st_birthtime >= since;
}

// Whether a comma-separated list already holds this app id.
static int number_present(const char *s, int id) {
    while (*s) {
        while (*s && (*s < '0' || *s > '9')) s++;
        if (!*s) break;
        int v = 0;
        while (*s >= '0' && *s <= '9') {
            v = v * 10 + (*s - '0');
            s++;
        }
        if (v == id) return 1;
    }
    return 0;
}

// Adds or updates one line under Folders: in cloud.yaml, leaving everything
// else in the file exactly as it was.
static int remember_folder(int app_id, const char *path) {
    const char *home = sx_resolve_home();
    if (!home) return 0;

    char dir[1024], file[1200];
    sx_macsteam_support_path(dir, sizeof(dir), home, NULL);
    if (snprintf(file, sizeof(file), "%s/cloud.yaml", dir) >= (int)sizeof(file))
        return 0;

    size_t len = 0;
    char *src = (char *)sx_slurp_file(file, &len);

    char mapping[700];
    snprintf(mapping, sizeof(mapping), "  %d: %s\n", app_id, path);

    size_t out_cap = (src ? len : 0) + 4096;
    char *out = calloc(1, out_cap);
    if (!out) {
        free(src);
        return 0;
    }
    size_t used = 0;

    int in_folders = 0, placed = 0, seen_folders = 0, restore_seen = 0;
    const char *p = src;
    while (p && *p) {
        const char *nl = strchr(p, '\n');
        size_t line_len = nl ? (size_t)(nl - p) + 1 : strlen(p);

        if (line_len + strlen(mapping) + 16 < out_cap - used) {
            if (!in_folders && line_len > 8 && strncmp(p, "Restore:", 8) == 0) {
                // A folder found this way only ever held the game's saves, so it
                // is added to Restore too, which only fills an empty folder.
                size_t body = nl ? line_len - 1 : line_len;
                memcpy(out + used, p, body);
                used += body;
                if (!number_present(p + 8, app_id)) {
                    int w = snprintf(out + used, out_cap - used, ", %d", app_id);
                    if (w > 0) used += (size_t)w;
                }
                out[used++] = '\n';
                restore_seen = 1;
            } else if (!in_folders && line_len > 8 && strncmp(p, "Folders:", 8) == 0) {
                in_folders = 1;
                seen_folders = 1;
                memcpy(out + used, p, line_len);
                used += line_len;
            } else if (in_folders && (p[0] == ' ' || p[0] == '\t')) {
                // A "  <appid>: <path>" line: replace ours, keep the others.
                const char *q = p;
                while (*q == ' ' || *q == '\t') q++;
                int id = 0, digits = 0;
                while (*q >= '0' && *q <= '9') {
                    id = id * 10 + (*q - '0');
                    q++;
                    digits++;
                }
                if (digits && *q == ':' && id == app_id) {
                    size_t m = strlen(mapping);
                    memcpy(out + used, mapping, m);
                    used += m;
                    placed = 1;
                } else {
                    memcpy(out + used, p, line_len);
                    used += line_len;
                }
            } else {
                if (in_folders && !placed) {
                    size_t m = strlen(mapping);
                    memcpy(out + used, mapping, m);
                    used += m;
                    placed = 1;
                }
                in_folders = 0;
                memcpy(out + used, p, line_len);
                used += line_len;
            }
        }

        if (!nl) break;
        p = nl + 1;
    }

    if (!restore_seen && used + 32 < out_cap) {
        int w = snprintf(out + used, out_cap - used, "Restore: %d\n", app_id);
        if (w > 0) used += (size_t)w;
    }

    if (!placed) {
        if (!seen_folders && used + 10 < out_cap) {
            memcpy(out + used, "Folders:\n", 9);
            used += 9;
        }
        size_t m = strlen(mapping);
        if (m + 2 < out_cap - used) {
            memcpy(out + used, mapping, m);
            used += m;
        }
    }
    out[used] = '\0';

    int changed = !src || len != used || memcmp(src, out, used) != 0;
    free(src);

    if (!changed) {
        free(out);
        return 0;
    }

    char tmp[1300];
    if (snprintf(tmp, sizeof(tmp), "%s.part", file) >= (int)sizeof(tmp)) {
        free(out);
        return 0;
    }
    FILE *f = fopen(tmp, "w");
    if (!f) {
        free(out);
        return 0;
    }
    size_t wrote = fwrite(out, 1, used, f);
    int ok = (wrote == used);
    free(out);
    if (fclose(f) != 0) ok = 0;
    if (!ok || rename(tmp, file) != 0) {
        unlink(tmp);
        return 0;
    }
    return 1;
}

// The places a game keeps its saves, one level down. Documents, Desktop and
// Downloads are deliberately not here: those are the user's own files.
static const char *const k_scan_roots[] = {
    ".config",
    "Library/Application Support",
    "Library/Containers",
    ".local/share",
};

static void scan_root(const char *root, int app_id, time_t since,
                      const char *game, const char *install,
                      char *best, size_t best_sz, int *best_named) {
    DIR *d = opendir(root);
    if (!d) return;

    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (ent->d_name[0] == '.') continue;
        if (strcmp(ent->d_name, "Steam") == 0 || strcmp(ent->d_name, "macsteam") == 0 ||
            strcmp(ent->d_name, "notproton") == 0 || strcmp(ent->d_name, "Caches") == 0 ||
            strcmp(ent->d_name, "Logs") == 0)
            continue;

        char path[1600];
        if (snprintf(path, sizeof(path), "%s/%s", root, ent->d_name) >= (int)sizeof(path))
            continue;

        struct stat st;
        if (stat(path, &st) != 0 || !S_ISDIR(st.st_mode)) continue;

        int named = name_matches(ent->d_name, game, install);
        if (!dir_written_since(path, since)) continue;
        // A folder named like the game is the usual case; one created while the
        // game ran is the other (a bundle-id folder, say).
        if (!named && !dir_created_since(path, since)) continue;

        SX_LOG("[cloud] app %d: %s was written while it ran%s", app_id, path,
               named ? "" : " (created during the session)");

        // A named match beats an unnamed one; the first of either is kept.
        if (best[0] == '\0' || (named && !*best_named)) {
            snprintf(best, best_sz, "%s", path);
            *best_named = named;
        }
    }
    closedir(d);
}

static void discover_for(int app_id, time_t since) {
    char name[256], install[256];
    app_names(app_id, name, sizeof(name), install, sizeof(install));

    char game[256], installdir[256];
    norm_name(name, game, sizeof(game));
    norm_name(install, installdir, sizeof(installdir));

    const char *home = sx_resolve_home();
    if (!home) return;

    char best[1600];
    best[0] = '\0';
    int best_named = 0;
    for (size_t i = 0; i < sizeof(k_scan_roots) / sizeof(k_scan_roots[0]); i++) {
        char root[1400];
        if (snprintf(root, sizeof(root), "%s/%s", home, k_scan_roots[i]) >= (int)sizeof(root))
            continue;
        scan_root(root, app_id, since, game, installdir, best, sizeof(best), &best_named);
    }

    if (best[0] == '\0') {
        SX_LOG("[cloud] app %d (%s): no save folder changed while it ran", app_id,
               name[0] ? name : "unknown");
        return;
    }

    int added = remember_folder(app_id, best);
    SX_LOG("[cloud] app %d (%s): save folder %s%s", app_id, name[0] ? name : "unknown",
           best, added ? ", added to cloud.yaml" : " (already known)");
    sync_game_folder(app_id, best, 0);
}

// Follows Steam's own log: it is where a session's start and end are stated.
static void poll_console_log(void) {
    char root[1024], path[1200];
    steam_root(root, sizeof(root));
    snprintf(path, sizeof(path), "%s/logs/console_log.txt", root);

    FILE *f = fopen(path, "r");
    if (!f) return;

    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return;
    }
    off_t size = ftell(f);
    if (!g_log_started) {
        g_log_offset = size;   // only what happens from now on
        g_log_started = 1;
        fclose(f);
        return;
    }
    if (size < g_log_offset) g_log_offset = 0;   // the log was rotated

    if (fseek(f, g_log_offset, SEEK_SET) != 0) {
        fclose(f);
        return;
    }

    char line[1024];
    while (fgets(line, sizeof(line), f)) {
        // A line that fills the buffer without ending is one Steam is still
        // writing; leave it for the next round. A line too long to fit at all is
        // skipped rather than blocking every later one.
        if (!strchr(line, '\n')) {
            if (strlen(line) >= sizeof(line) - 1) {
                g_log_offset += (off_t)strlen(line);
                continue;
            }
            break;
        }
        g_log_offset += (off_t)strlen(line);

        const char *marker = "Game process added : AppID ";
        const char *at = strstr(line, marker);
        int removed = 0;
        if (!at) {
            marker = "Game process removed: AppID ";
            at = strstr(line, marker);
            removed = 1;
        }
        if (!at) continue;
        at += strlen(marker);

        int app_id = 0, digits = 0;
        while (*at >= '0' && *at <= '9') {
            app_id = app_id * 10 + (*at - '0');
            at++;
            digits++;
        }
        if (!digits || app_id <= 0) continue;

        int y = 0, mo = 0, d = 0, h = 0, mi = 0, s = 0;
        time_t when = time(NULL);
        if (line[0] == '[' && sscanf(line, "[%d-%d-%d %d:%d:%d]", &y, &mo, &d, &h, &mi, &s) == 6) {
            struct tm tm = {0};
            tm.tm_year = y - 1900;
            tm.tm_mon = mo - 1;
            tm.tm_mday = d;
            tm.tm_hour = h;
            tm.tm_min = mi;
            tm.tm_sec = s;
            tm.tm_isdst = -1;
            time_t parsed = mktime(&tm);
            if (parsed != (time_t)-1) when = parsed;
        }

        if (!removed) {
            if (g_session_count >= CLOUD_SESSIONS_MAX) {
                memmove(&g_sessions[0], &g_sessions[1],
                        sizeof(g_sessions[0]) * (CLOUD_SESSIONS_MAX - 1));
                g_session_count = CLOUD_SESSIONS_MAX - 1;
            }
            g_sessions[g_session_count].app_id = app_id;
            g_sessions[g_session_count].started = when;
            const char *exe = strchr(at, '\'');
            snprintf(g_sessions[g_session_count].exe,
                     sizeof(g_sessions[g_session_count].exe), "%s",
                     exe ? exe + 1 : "");
            char *end = strchr(g_sessions[g_session_count].exe, '\'');
            if (end) *end = '\0';
            g_session_count++;
            continue;
        }

        for (int i = 0; i < g_session_count; i++) {
            if (g_sessions[i].app_id != app_id) continue;
            time_t started = g_sessions[i].started;
            memmove(&g_sessions[i], &g_sessions[i + 1],
                    sizeof(g_sessions[0]) * (size_t)(g_session_count - i - 1));
            g_session_count--;
            discover_for(app_id, started - 5);
            break;
        }
    }
    fclose(f);
}

static void *cloud_worker(void *arg) {
    (void)arg;

    int *apps = calloc(CLOUD_APPS_MAX, sizeof(int));
    if (!apps) return NULL;
    int app_count = 0;

    char config_path[512];
    sx_file_config_path(config_path, sizeof(config_path));
    time_t cfg_mtime = 0;
    off_t cfg_size = -1;

    for (int round = 0; round < CLOUD_ROUNDS; round++) {
        if (round > 0) sleep(round < 12 ? 10 : 60);
        if (!cloud_enabled()) continue;

        // Notice a game that started or stopped since the last round.
        if (auto_detect_enabled()) poll_console_log();

        // A game imported in the config app is only in the file, so the list is
        // re-read whenever the file changes rather than kept from launch.
        struct stat cst;
        if (stat(config_path, &cst) == 0 &&
            (cst.st_mtime != cfg_mtime || cst.st_size != cfg_size)) {
            sx_config_t *fresh = calloc(1, sizeof(*fresh));
            if (fresh) {
                if (sx_config_load(config_path, fresh) == 0 &&
                    fresh->app_ids && fresh->app_count > 0) {
                    app_count = fresh->app_count < CLOUD_APPS_MAX
                                    ? fresh->app_count : CLOUD_APPS_MAX;
                    memcpy(apps, fresh->app_ids, (size_t)app_count * sizeof(int));
                }
                sx_config_free(fresh);
                free(fresh);
            }
            cfg_mtime = cst.st_mtime;
            cfg_size = cst.st_size;
        }

        int restore[CLOUD_RESTORE_MAX];
        int restore_n = read_restore_list(restore, CLOUD_RESTORE_MAX);
        int restore_all = restore_all_enabled();
        int remote = remote_configured();

        // Anything the account has that this Mac does not comes down first, so
        // the restore below can put it in the game's folder.
        if (remote) run_cloud_sync("pull", 1);

        int added_total = 0;

        char account[1400];
        if (app_count > 0 && find_account_dir(account, sizeof(account))) {
            for (int i = 0; i < app_count; i++) {
                int wanted = restore_all;
                for (int k = 0; k < restore_n && !wanted; k++)
                    if (restore[k] == apps[i]) wanted = 1;
                added_total += sync_app(account, apps[i], wanted);
            }
        }

        // Folders the games keep outside Steam, for the ones that never touch
        // its cloud at all.
        cloud_folder_t folders[CLOUD_FOLDER_MAX];
        int folder_n = read_game_folders(folders, CLOUD_FOLDER_MAX);
        for (int i = 0; i < folder_n; i++) {
            int wanted = restore_all;
            for (int k = 0; k < restore_n && !wanted; k++)
                if (restore[k] == folders[i].app_id) wanted = 1;
            added_total += sync_game_folder(folders[i].app_id, folders[i].path, wanted);
        }

        // New saves go up once the round's work is on disk.
        if (remote && added_total > 0) run_cloud_sync("push", 0);
    }

    free(apps);
    return NULL;
}

void sx_cloud_start(void) {
    if (!cloud_enabled()) return;

    static int started = 0;
    if (started) return;
    started = 1;

    pthread_t thread;
    if (pthread_create(&thread, NULL, cloud_worker, NULL) == 0)
        pthread_detach(thread);
    else
        SX_WARN("[cloud] could not start the backup thread");
}

// ---------------------------------------------------------------------------
// Capturing the wire format
//
// The client deserializes every cloud reply into memory before a hook can see
// it, so answering one means knowing this build's in-memory layout, not just the
// protobuf. Each cloud job is therefore recorded whole — the message header, the
// body, and every offset in the body that holds one of the configured app ids —
// into <support>/cloud/dumps/capture.txt. Nothing is altered on the wire.
static void write_hex(FILE *f, const unsigned char *b, size_t n) {
    for (size_t i = 0; i < n; i++) fprintf(f, "%02x", b[i]);
    fprintf(f, "\n");
}

void sx_cloud_capture(const char *tag, void *msg) {
    if (!cloud_enabled() || !msg || !tag) return;

    char dir[1024];
    if (!support_cloud_dir(dir, sizeof(dir), "dumps")) return;

    char path[1200];
    if (snprintf(path, sizeof(path), "%s/capture.txt", dir) >= (int)sizeof(path))
        return;

    // One file per client run, so the jobs of one launch are not mixed into the
    // next launch's.
    static int first = 1;
    FILE *f = fopen(path, first ? "w" : "a");
    if (!f) return;
    first = 0;

    const unsigned char *m = (const unsigned char *)msg;

    // The object handed to sendAndRecv is not laid out like the packet struct in
    // steam_types.h: its protocol number sits at 0x28 with 0x80000000 set, and
    // the deserialized body pointer at 0x38. Reading 0x20 as the id gives the 0
    // or 7 that an earlier capture recorded.
    uint32_t e_msg = *(uint32_t *)((char *)msg + 0x28) & 0x7FFFFFFFu;
    uintptr_t body = *(uintptr_t *)((char *)msg + 0x38);

    fprintf(f, "== %s eMsg=%u body=%p\n", tag, e_msg, (void *)body);
    fprintf(f, "msg: ");
    write_hex(f, m, 0x40);

    if (!body) {
        fclose(f);
        return;
    }

    const unsigned char *b = (const unsigned char *)body;
    fprintf(f, "body: ");
    write_hex(f, b, CLOUD_CAPTURE_BYTES);

    sx_config_t *cfg = atomic_load(&sx_config_current);
    if (cfg && cfg->app_ids && cfg->app_count > 0) {
        fprintf(f, "appid:");
        for (size_t off = 0; off + 4 <= CLOUD_CAPTURE_BYTES; off += 2) {
            uint32_t v;
            memcpy(&v, b + off, 4);
            for (int i = 0; i < cfg->app_count; i++) {
                if ((uint32_t)cfg->app_ids[i] == v) {
                    fprintf(f, " %zu=%u", off, v);
                    break;
                }
            }
        }
        fprintf(f, "\n");
    }

    fclose(f);
}
