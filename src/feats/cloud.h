// Steam Cloud for unlocked games
#ifndef MACSTEAM_FEATS_CLOUD_H
#define MACSTEAM_FEATS_CLOUD_H

#include "../config/config.h"
#include <stdint.h>

// Report what the local cloud store holds for the config's apps, using the
// client's own per-app cloud folder as the source. Read-only: nothing is
// intercepted, answered or deleted, so no save can be affected.
//
// Runs only when config.yaml holds "Cloud: yes".
void sx_cloud_observe(sx_config_t *cfg);

// Start the thread that keeps the store up to date. It copies each configured
// app's save folder into <support>/cloud/<appid>/files, only ever writing a file
// name it has not stored before, so the first bytes seen are never overwritten.
// Apps listed under "CloudRestore:" also get their stored saves written back
// into Steam's folder, and only when that folder is empty.
void sx_cloud_start(void);

// Record one cloud job: the message header, the body, and where the configured
// app ids sit inside it. Written to <support>/cloud/dumps/capture.txt so the
// wire format of this client build can be read. No message is altered.
void sx_cloud_capture(const char *tag, void *msg);

// <support>/cloud/<appid>, the folder the store keeps an app's saves in.
void sx_cloud_store_path(int app_id, char *buf, size_t bufsz);

#endif // MACSTEAM_FEATS_CLOUD_H
