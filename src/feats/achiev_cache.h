// Achievement cache for the library UI
#ifndef MACSTEAM_FEATS_ACHIEV_CACHE_H
#define MACSTEAM_FEATS_ACHIEV_CACHE_H

#include "../config/config.h"

// Build the library's per-app achievements entry from the schema the client has
// on disk, with every achievement locked. Safe to repeat: the file is only
// rewritten when its contents change.
int sx_achiev_cache_sync_app(int app_id);

/// Retry an app whose schema was not on disk yet when its sync ran.
void sx_achiev_cache_sync_later(int app_id);

// The same for every app in the config.
void sx_achiev_cache_sync(sx_config_t *cfg);

// Keep the config's apps supplied with a list in the background, and re-read the
// config file as it changes so a game imported in the config app is picked up
// without restarting Steam. The client only caches a game's schema once its
// library page has been opened, so an app added just now is retried until it can
// be built.
void sx_achiev_cache_watch(sx_config_t *cfg);

// Drop the progress the stats redirect left in the client's caches for an app,
// once. Returns 1 when something was cleared.
int sx_achiev_purge_borrowed(int app_id);

#endif // MACSTEAM_FEATS_ACHIEV_CACHE_H
