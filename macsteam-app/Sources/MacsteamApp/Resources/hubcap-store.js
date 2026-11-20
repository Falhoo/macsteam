(() => {
    'use strict';
    if (location.protocol !== 'https:' || location.hostname !== 'store.steampowered.com' || window.__macsteamHubcap) return;
    let appID = 0;
    const pending = new Map();
    let sequence = 0;
    let state = 'checking';
    let busy = false;
    let fixBusy = false;
    let root, button, restartButton, removeButton, message, titlePrefix, fixesRoot, buttonHost;
    // Whether macSteam has this app in its config, which is what the Remove button acts on.
    let configured = false;
    let onlineRoot, onlineButton, onlineStatus, onlineDesc, onlineNote, onlineChoices;
    let onlineBusy = false;
    let restarting = false;
    // Restart belongs to the card that just added this game, not to a game that
    // was already in the library: opening its page later must not offer it.
    let addedNow = false;
    // After a Remove, a plain restart is what makes Steam drop the title.
    let removedNow = false;
    // A re-check that finds the same data must not rebuild a card: that would
    // replace the button under the pointer between mousedown and click, and the
    // click would be lost (the "click it twice" behaviour).
    let fixesSignature = '';
    let onlineSignature = '';
    let fixLoading = false;
    let onlineLoading = false;
    // The LuaTools fix for this game that carries an OnlineFix (its "Online Fix"
    // tag), if any. It is the same fix, built for LuaTools, so the OnlineFix card
    // recommends it instead of installing its own copy.
    let luaOnlineFix = null;
    let onlineFixInstalled = false;
    let onlineGameInstalled = true;
    // Whether this game's online play uses Steam's relay network (SDR), and
    // whether it is set to start as itself instead of Spacewar.
    let onlineUsesSDR = false;
    let onlineKeepID = false;
    const bridge = window.macsteamHubcap;
    if (typeof bridge !== 'function') return;
    window.__macsteamHubcap = {
        reply(id, result) {
            const request = pending.get(id);
            if (!request) return;
            pending.delete(id);
            clearTimeout(request.timer);
            request.resolve(result);
        }
    };
    window.__macsteamOnlineFix = {
        progress(text) {
            if (!onlineStatus) return;
            onlineStatus.hidden = false;
            onlineStatus.style.color = '#acb2b8';
            onlineStatus.textContent = text;
        }
    };
    function request(action, fixID, name, folder) {
        return new Promise(resolve => {
            const id = `${appID}:${++sequence}`;
            // Installing an OnlineFix downloads and unpacks an archive; a restart
            // is answered at once, so a long wait there means nobody is listening.
            const timer = setTimeout(() => {
                pending.delete(id);
                resolve({ error: action === 'restart'
                    ? 'macSteam did not answer. Quit and reopen macSteam Config, then try again.'
                    : 'macSteam did not respond. Open macSteam Config and try again.' });
            }, action === 'onlinefix-install' ? 600000 : action === 'restart' ? 20000 : 180000);
            pending.set(id, { resolve, timer });
            bridge(JSON.stringify({ id, appID, action, fixID, name: name || '', folder: folder || '' }));
        });
    }
    // Steam's own store page tells us the platforms it sells: a Mac icon means a
    // native build exists, and LuaTools' Windows fixes cannot patch it.
    function pageSaysNativeMac() {
        return !!document.querySelector(
            '.game_area_purchase_platform .platform_img.mac,'
            + ' .game_area_purchase_game_wrapper .platform_img.mac,'
            + ' .game_area_purchase .platform_img.mac');
    }
    // Whether the player asked to see LuaTools fixes for a game that also ships a
    // native macOS build, remembered across store pages.
    const NATIVE_FIXS_KEY = 'macsteam.showNativeMacFixes';
    function nativeFixesShown() {
        try { return localStorage.getItem(NATIVE_FIXS_KEY) === '1'; } catch (error) { return false; }
    }
    function setNativeFixesShown(shown) {
        try { localStorage.setItem(NATIVE_FIXS_KEY, shown ? '1' : '0'); } catch (error) {}
    }
    function gameName() {
        const node = document.querySelector('.apphub_AppName, #appHubAppName');
        const text = (node?.textContent || '').trim();
        if (text) return text;
        return document.title.replace(/\s+on\s+Steam\s*$/i, '').trim();
    }
    function render() {
        if (!button) return;
        // Already installed: nothing to add or install, so the card says so and
        // offers no button. It is still shown, so the card is visibly there.
        root.style.display = '';
        if (buttonHost) buttonHost.style.display = state === 'installed' ? 'none' : '';
        if (state === 'installed') {
            titlePrefix.textContent = 'In your library, added with ';
            message.hidden = true;
            if (removeButton) removeButton.style.display = configured ? '' : 'none';
            if (restartButton) restartButton.style.display = removedNow ? '' : 'none';
            return;
        }
        message.hidden = !message.textContent;
        titlePrefix.textContent = state === 'ready' ? 'Ready to install with ' :
            state === 'checking' ? 'Checking Steam library for ' : 'Add to library with ';
        if (restartButton) {
            const showRestart = (state === 'ready' && addedNow) || removedNow;
            restartButton.style.display = showRestart ? '' : 'none';
            const label = restartButton.querySelector('span');
            if (label && !restarting) label.textContent = removedNow ? 'Restart Steam' : 'Restart';
        }
        if (removeButton) removeButton.style.display = configured ? '' : 'none';
        button.disabled = busy || state === 'checking';
        button.querySelector('span').textContent = busy ? 'Adding to library…' :
            state === 'ready' ? 'Install' : state === 'checking' ? 'Checking library…' : 'Add to library';
        button.setAttribute('aria-busy', String(busy));
    }
    async function refresh() {
        const requestedApp = appID;
        const result = await request('status');
        if (requestedApp !== appID) return;
        // Keep the "restart Steam" prompt up: a plain status refresh must not wipe it.
        const keepPrompt = (message.textContent || '').startsWith('Added to your library');
        if (result.error) {
            state = 'add';
            message.textContent = result.error;
        } else {
            configured = !!(result.configured || result.ready || result.installed);
            state = result.installed ? 'installed' : result.ready ? 'ready' : 'add';
            if (!keepPrompt) message.textContent = '';
        }
        render();
    }
    // Game fixes: a second card listing LuaTools fixes for this game.
    function removeFixes() {
        fixesRoot?.remove();
        fixesRoot = null;
        fixesSignature = '';
    }
    function actionButton(label, onClick) {
        const el = document.createElement('button');
        el.type = 'button';
        el.className = 'btn_grey_steamui btn_small';
        el.style.cssText = 'border:0;cursor:pointer;font:inherit;margin-left:6px';
        const text = document.createElement('span');
        text.textContent = label;
        el.appendChild(text);
        // The cards sit inside Steam's purchase area, whose own handlers can act
        // on a click they do not recognise. Claim both events before it sees them;
        // otherwise the first click goes nowhere and the second one works.
        el.addEventListener('mousedown', event => {
            event.stopPropagation();
        });
        el.addEventListener('click', event => {
            event.preventDefault();
            event.stopImmediatePropagation();
            onClick(event);
        });
        return el;
    }
    function renderFixes(result, statusText, statusColor) {
        if (!root?.isConnected) return;
        // A LuaTools fix patches the game's Windows DLLs. When Steam ships a native
        // macOS build, that Mac app is what launches, so the fix has nothing to
        // patch: the card says so and keeps its fixes behind an opt-in checkbox, for
        // players who install the Windows build under NotProton instead.
        const nativeMac = !!(result.nativeMac || pageSaysNativeMac());
        const showRows = !nativeMac || nativeFixesShown();
        // Everything the card shows, so an unchanged re-check can leave it alone.
        const signature = JSON.stringify({
            text: statusText || '',
            color: statusColor || '',
            gameInstalled: !!result.gameInstalled,
            manifestInstalled: !!result.manifestInstalled,
            nativeMac,
            showRows,
            error: result.error || '',
            fixes: (result.fixes || []).map(f => [f.id, f.title, f.description,
                f.hasFix, f.hasManifest, f.applied, f.drifted, f.onlineFix]),
        });
        if (fixesRoot?.isConnected && signature === fixesSignature) return;
        removeFixes();
        fixesSignature = signature;
        // A LuaTools fix carrying the OnlineFix means the OnlineFix card should point
        // at it rather than install its own copy — but only while its rows are on
        // offer, since the fix cannot patch a native Mac build.
        luaOnlineFix = (result.error || !result.fixes?.length || !showRows)
            ? null
            : ((result.fixes || []).find(f => f.onlineFix) || null);
        if (result.error || !result.fixes?.length) { applyOnlineRecommendation(); return; }
        fixesRoot = document.createElement('div');
        fixesRoot.id = 'macsteam-fixes';
        fixesRoot.className = 'game_area_purchase_game';
        const title = document.createElement('h2');
        title.className = 'title';
        title.textContent = 'Game fixes with LuaTools';
        fixesRoot.appendChild(title);
        if (nativeMac) {
            // The note is the point of the card: the fix exists, and why it does not
            // work here. The checkbox below is the one way to ask for it anyway.
            const note = document.createElement('div');
            note.textContent = 'A LuaTools fix for this game does exist, but this game '
                + 'includes a native macOS port so LuaTools\' fixes won\'t work.';
            note.style.cssText = 'color:#e8a54b;font-size:12px;margin:6px 0';
            fixesRoot.appendChild(note);
            const label = document.createElement('label');
            label.style.cssText = 'display:flex;align-items:flex-start;gap:6px;font-size:12px;'
                + 'color:#acb2b8;margin:0 0 6px;cursor:pointer';
            const box = document.createElement('input');
            box.type = 'checkbox';
            box.checked = showRows;
            box.style.cssText = 'margin:2px 0 0';
            // The card sits inside Steam's purchase area, whose handlers act on
            // clicks they do not recognise: claim them before it sees them.
            box.addEventListener('mousedown', event => event.stopPropagation());
            box.addEventListener('click', event => event.stopPropagation());
            box.addEventListener('change', () => {
                setNativeFixesShown(box.checked);
                // Rebuilt from the same reply; the signature now differs, so the
                // fix rows follow the checkbox.
                renderFixes(result, statusText, statusColor);
            });
            const text = document.createElement('span');
            text.textContent = 'Show the LuaTools fixes anyway, to install them for the '
                + 'Windows build under NotProton (Steam → Properties → Compatibility).';
            label.append(box, text);
            fixesRoot.appendChild(label);
        }
        // The fix rows live in their own box, so the note above stays put while they
        // are hidden.
        const rows = document.createElement('div');
        rows.style.display = showRows ? '' : 'none';
        fixesRoot.appendChild(rows);
        const status = document.createElement('div');
        status.setAttribute('role', 'status');
        status.setAttribute('aria-live', 'polite');
        status.style.cssText = 'font-size:12px;color:#acb2b8;margin:6px 0';
        if (statusColor) status.style.color = statusColor;
        const needsGame = !result.gameInstalled && result.fixes.some(f => f.hasFix);
        status.textContent = statusText ||
            (needsGame ? 'You can only install game fixes AFTER you install the game!' : '');
        status.hidden = !status.textContent;
        rows.appendChild(status);
        for (const fix of result.fixes) {
            const row = document.createElement('div');
            row.style.cssText = 'display:flex;align-items:center;justify-content:space-between;gap:12px;padding:8px 0;border-top:1px solid rgba(198,212,223,.12)';
            const info = document.createElement('div');
            const name = document.createElement('div');
            name.textContent = fix.title;
            name.style.cssText = 'color:#fff;font-size:14px';
            info.appendChild(name);
            if (fix.description) {
                const desc = document.createElement('div');
                desc.textContent = fix.description;
                desc.style.cssText = 'color:#acb2b8;font-size:12px;margin-top:2px';
                info.appendChild(desc);
            }
            if (fix.onlineFix) {
                const note = document.createElement('div');
                note.textContent = 'Includes the OnlineFix — we recommend this one over '
                    + 'macSteam\'s OnlineFix card.';
                note.style.cssText = 'color:#a4d007;font-size:12px;margin-top:2px';
                info.appendChild(note);
            }
            const actions = document.createElement('div');
            actions.style.cssText = 'white-space:nowrap';
            const run = async (action, button) => {
                if (fixBusy) return;
                fixBusy = true;
                const requestedApp = appID;
                const wasDisabled = new Set([...fixesRoot.querySelectorAll('button')].filter(b => b.disabled));
                fixesRoot.querySelectorAll('button').forEach(b => { b.disabled = true; });
                status.hidden = false;
                status.textContent = 'Working…';
                const reply = await request(action, fix.id);
                fixBusy = false;
                if (requestedApp !== appID) return;
                if (reply.error) {
                    fixesRoot.querySelectorAll('button').forEach(b => { b.disabled = wasDisabled.has(b); });
                    status.textContent = reply.error;
                    if (reply.permission) {
                        // macOS blocked the write: point the user at the right privacy pane.
                        const open = actionButton('Open ' + (reply.permissionTitle || 'Privacy Settings'),
                            () => request('fix-permissions', reply.permission));
                        open.style.marginLeft = '0';
                        open.style.display = 'block';
                        open.style.marginTop = '6px';
                        status.appendChild(open);
                    }
                    return;
                }
                renderFixes(reply, reply.message);
            };
            // The fix is installed here and now: macSteam downloads it and copies its files
            // into the game folder, so the row can say how it went when it is done.
            const installOnSteam = async fix => {
                if (fixBusy) return;
                fixBusy = true;
                const requestedApp = appID;
                const wasDisabled = new Set([...fixesRoot.querySelectorAll('button')].filter(b => b.disabled));
                fixesRoot.querySelectorAll('button').forEach(b => { b.disabled = true; });
                status.hidden = false;
                status.style.color = '#acb2b8';
                status.textContent = 'Installing the fix… this can take a minute.';
                const reply = await request('fix-install', fix.id);
                fixBusy = false;
                if (requestedApp !== appID) return;
                if (reply.error) {
                    fixesRoot.querySelectorAll('button').forEach(b => { b.disabled = wasDisabled.has(b); });
                    status.style.color = '#e8a54b';
                    status.textContent = 'The fixes failed to install — ' + reply.error;
                    if (reply.permission) {
                        // macOS blocked the write: point the user at the right privacy pane.
                        const open = actionButton('Open ' + (reply.permissionTitle || 'Privacy Settings'),
                            () => request('fix-permissions', reply.permission));
                        open.style.marginLeft = '0';
                        open.style.display = 'block';
                        open.style.marginTop = '6px';
                        status.appendChild(open);
                    }
                    return;
                }
                // Re-rendered first, so the row offers Undo and the message lands on the new card.
                renderFixes(reply, 'Fixes are successfully installed!', '#a4d007');
            };
            if (fix.hasManifest) {
                const b = actionButton(result.manifestInstalled ? 'Manifest installed' : 'Install manifest',
                    () => run('fix-manifest'));
                b.disabled = !!result.manifestInstalled;
                actions.appendChild(b);
            }
            if (fix.hasFix && (!fix.applied || fix.drifted)) {
                const b = actionButton(fix.drifted ? 'Reinstall fix' : 'Install fix',
                    () => installOnSteam(fix));
                b.disabled = !result.gameInstalled;
                actions.appendChild(b);
            }
            if (fix.applied) {
                actions.appendChild(actionButton(fix.drifted ? 'Remove fix' : 'Undo fix', () => run('fix-undo')));
            }
            if (fix.drifted) {
                const note = document.createElement('div');
                note.textContent = 'Some files changed since install (a game update?).';
                note.style.cssText = 'color:#e8a54b;font-size:12px;margin-top:2px';
                info.appendChild(note);
            }
            row.append(info, actions);
            rows.appendChild(row);
        }
        root.after(fixesRoot);
        applyOnlineRecommendation();
    }
    async function loadFixes() {
        // One at a time: two overlapping answers would rebuild the card twice.
        if (fixLoading) return;
        fixLoading = true;
        const requestedApp = appID;
        const result = await request('fixes');
        fixLoading = false;
        if (requestedApp !== appID) return;
        renderFixes(result);
    }
    // OnlineFix: adds the game to the manager, installs its fix and routes it
    // through AppID 480.
    function removeOnlineFix() {
        onlineRoot?.remove();
        onlineRoot = null;
        onlineButton = null;
        onlineStatus = null;
        onlineDesc = null;
        onlineNote = null;
        onlineChoices = null;
        onlineSignature = '';
    }
    // When online-fix.me has no folder under the exact name, the reply carries the
    // similar ones: one button each, and picking one installs that folder's fix —
    // all without leaving the store page.
    function renderOnlineChoices(choices) {
        if (!onlineRoot) return;
        onlineChoices?.remove();
        onlineChoices = document.createElement('div');
        onlineChoices.style.cssText = 'display:flex;flex-wrap:wrap;align-items:center;'
            + 'gap:6px;margin-top:8px;max-width:560px';
        const label = document.createElement('span');
        label.textContent = 'Which one is this game?';
        label.style.cssText = 'color:#acb2b8;font-size:12px;margin-right:2px';
        onlineChoices.appendChild(label);
        for (const choice of choices) {
            const name = String(choice.name || '');
            if (!name) continue;
            const percent = Number(choice.percent);
            const text = Number.isFinite(percent) ? `${name} · ${percent}% match` : name;
            onlineChoices.appendChild(actionButton(text, () => installOnlineFix(name)));
        }
        (onlineStatus?.isConnected ? onlineStatus : onlineRoot).after(onlineChoices);
    }
    function clearOnlineChoices() {
        onlineChoices?.remove();
        onlineChoices = null;
    }
    // When LuaTools carries an Online Fix for the game, this card says to use that
    // one and leaves its own Install as a deliberate "Install anyway" (that is what
    // sets up macSteam's AppID 480 routing).
    function applyOnlineRecommendation() {
        if (!onlineRoot) return;
        const fix = luaOnlineFix;
        if (onlineDesc) {
            onlineDesc.textContent = onlineFixInstalled
                ? (onlineKeepID
                    ? 'Installed. Launch the game from Steam — it runs as its own AppID.'
                    : 'Installed. Launch the game from Steam — it runs as AppID 480.')
                : (onlineKeepID
                    ? 'Installs the game\'s fix and keeps its own Steam AppID, so Steam can grant '
                      + 'its relay network.'
                    : 'Installs the game\'s fix and runs its Steam session as AppID 480 (Spacewar).');
        }
        if (onlineNote) {
            onlineNote.hidden = !fix;
            onlineNote.textContent = !fix ? ''
                : onlineFixInstalled
                    ? 'LuaTools has a version of OnlineFix for this game. we recommend using that '
                      + 'one instead of this OnlineFix. It is the same fix, but our OnlineFix isn\'t '
                      + 'always stable/working. Uninstall here first, so the two copies do not '
                      + 'overwrite each other.'
                    : 'LuaTools has a version of OnlineFix for this game'
                      + (fix.applied ? ' (installed)' : '') + '. we recommend using that one instead '
                      + 'of this OnlineFix. It is the same fix, but our OnlineFix isn\'t always '
                      + 'stable/working.';
        }
        if (onlineButton) {
            const label = onlineFixInstalled ? 'Reinstall' : fix ? 'Install anyway' : 'Install';
            onlineButton.querySelector('span').textContent = label;
            onlineButton.disabled = !onlineGameInstalled;
        }
    }
    function renderOnlineFix(result) {
        if (!root?.isConnected) return;
        // Same numbers as the card already shows: keep the button the user is
        // pointing at instead of replacing it.
        const signature = JSON.stringify({
            inList: !!result.inList,
            fixInstalled: !!result.fixInstalled,
            gameInstalled: !!result.gameInstalled,
            usesSDR: !!result.usesSteamNetworking,
            keepID: !!result.keepRealAppID,
        });
        if (onlineRoot?.isConnected && signature === onlineSignature) {
            applyOnlineRecommendation();
            return;
        }
        removeOnlineFix();
        onlineSignature = signature;
        onlineRoot = document.createElement('div');
        onlineRoot.id = 'macsteam-onlinefix';
        onlineRoot.className = 'game_area_purchase_game';
        const title = document.createElement('h2');
        title.className = 'title';
        title.textContent = 'Use OnlineFix';
        onlineRoot.appendChild(title);
        const row = document.createElement('div');
        row.style.cssText = 'display:flex;align-items:center;justify-content:space-between;gap:12px;padding:8px 0';
        const info = document.createElement('div');
        const name = document.createElement('div');
        name.textContent = 'OnlineFix for ' + gameName();
        name.style.cssText = 'color:#fff;font-size:14px';
        const desc = document.createElement('div');
        desc.style.cssText = 'color:#acb2b8;font-size:12px;margin-top:2px;max-width:520px';
        onlineDesc = desc;
        onlineFixInstalled = !!result.fixInstalled;
        onlineGameInstalled = !!result.gameInstalled;
        onlineUsesSDR = !!result.usesSteamNetworking;
        onlineKeepID = !!result.keepRealAppID;
        info.append(name, desc);
        const actions = document.createElement('div');
        actions.style.cssText = 'white-space:nowrap';
        if (result.fixInstalled) {
            const remove = actionButton('Uninstall', () => uninstallOnlineFix());
            actions.appendChild(remove);
        }
        onlineButton = actionButton(result.fixInstalled ? 'Reinstall' : 'Install', () => installOnlineFix());
        onlineButton.disabled = !result.gameInstalled;
        actions.appendChild(onlineButton);
        row.append(info, actions);
        onlineRoot.appendChild(row);
        // Steam's relay network (SDR) is per AppID: as Spacewar this game has no
        // relay and waits at "waiting for other resources…" forever. Say so, and
        // offer the one setting that can work, rather than looking broken.
        if (result.usesSteamNetworking) {
            if (result.keepRealAppID) {
                const kept = document.createElement('div');
                kept.style.cssText = 'font-size:12px;color:#a4d007;margin-top:6px;max-width:560px';
                kept.textContent = 'Starts as its own AppID — this game uses Steam\'s relay network '
                    + '(SDR), so it needs to reach the client as itself.';
                onlineRoot.appendChild(kept);
                const back = actionButton('Use Spacewar instead', () => setOnlineKeepID(false));
                back.style.marginLeft = '0';
                back.style.marginTop = '6px';
                onlineRoot.appendChild(back);
            } else {
                const relay = document.createElement('div');
                relay.style.cssText = 'font-size:12px;color:#e8a54b;margin-top:8px;'
                    + 'max-width:560px;line-height:1.45';
                relay.textContent = 'In order to use OnlineFix for this game, we recommend you use '
                    + 'the "Keep real AppID" button, because the game uses the Steam relay servers, '
                    + 'which aren\'t compatible with Spacewar (AppID 480).';
                onlineRoot.appendChild(relay);
                const keep = actionButton('Keep real AppID', () => setOnlineKeepID(true));
                keep.style.marginLeft = '0';
                keep.style.marginTop = '6px';
                onlineRoot.appendChild(keep);
            }
        }
        onlineStatus = document.createElement('div');
        onlineStatus.setAttribute('role', 'status');
        onlineStatus.setAttribute('aria-live', 'polite');
        onlineStatus.style.cssText = 'font-size:12px;color:#acb2b8;margin-top:6px';
        if (!result.gameInstalled) {
            onlineStatus.textContent = 'You can only install an OnlineFix AFTER you install the game!';
        }
        onlineStatus.hidden = !onlineStatus.textContent;
        onlineRoot.appendChild(onlineStatus);
        onlineNote = document.createElement('div');
        onlineNote.style.cssText = 'font-size:12px;color:#a4d007;margin-top:6px;max-width:520px';
        onlineNote.hidden = true;
        onlineRoot.appendChild(onlineNote);
        (fixesRoot?.isConnected ? fixesRoot : root).after(onlineRoot);
        applyOnlineRecommendation();
    }
    async function loadOnlineFix() {
        if (onlineBusy || onlineLoading) return;
        onlineLoading = true;
        const requestedApp = appID;
        const result = await request('onlinefix-status');
        onlineLoading = false;
        if (requestedApp !== appID) return;
        if (result.error || result.inList === undefined) return;
        renderOnlineFix(result);
    }
    async function uninstallOnlineFix() {
        if (onlineBusy) return;
        onlineBusy = true;
        onlineStatus.hidden = false;
        onlineStatus.style.color = '#acb2b8';
        onlineStatus.textContent = 'Removing the OnlineFix…';
        const reply = await request('onlinefix-uninstall');
        onlineBusy = false;
        if (!onlineRoot) return;
        if (reply.error) {
            onlineStatus.style.color = '#e8a54b';
            onlineStatus.textContent = 'Could not remove the OnlineFix — ' + reply.error;
            onlineBusy = false;
            return;
        }
        renderOnlineFix({ inList: true, fixInstalled: false, gameInstalled: true,
                          usesSteamNetworking: onlineUsesSDR, keepRealAppID: onlineKeepID });
        onlineStatus.style.color = '#a4d007';
        onlineStatus.hidden = false;
        onlineStatus.textContent = reply.message || 'OnlineFix removed.';
    }
    // Starts the game as itself (or back as Spacewar). Only SDR games show this,
    // and it applies to the next launch.
    async function setOnlineKeepID(keep) {
        if (onlineBusy) return;
        onlineBusy = true;
        if (onlineStatus) {
            onlineStatus.hidden = false;
            onlineStatus.style.color = '#acb2b8';
            onlineStatus.textContent = 'Saving…';
        }
        const requestedApp = appID;
        const reply = await request(keep ? 'onlinefix-keep-id' : 'onlinefix-spacewar');
        onlineBusy = false;
        if (requestedApp !== appID || !onlineRoot) return;
        if (reply.error) {
            if (onlineStatus) {
                onlineStatus.style.color = '#e8a54b';
                onlineStatus.textContent = 'Could not change it — ' + reply.error;
            }
            return;
        }
        renderOnlineFix({
            inList: reply.inList,
            fixInstalled: reply.fixInstalled,
            gameInstalled: reply.gameInstalled,
            usesSteamNetworking: reply.usesSteamNetworking,
            keepRealAppID: reply.keepRealAppID,
        });
        if (onlineStatus) {
            onlineStatus.style.color = '#a4d007';
            onlineStatus.hidden = false;
            onlineStatus.textContent = reply.message || (keep
                ? 'This game now starts as its own AppID.'
                : 'This game now starts as Spacewar (480).');
        }
    }
    async function installOnlineFix(folderName) {
        if (onlineBusy || !onlineButton) return;
        onlineBusy = true;
        const requestedApp = appID;
        const wasDisabled = onlineButton.disabled;
        onlineButton.disabled = true;
        clearOnlineChoices();
        onlineStatus.hidden = false;
        onlineStatus.style.color = '#acb2b8';
        onlineStatus.textContent = folderName
            ? `Downloading and installing “${folderName}”… this can take a minute.`
            : 'Downloading and installing the OnlineFix… this can take a minute.';
        const reply = await request('onlinefix-install', null, gameName(), folderName);
        onlineBusy = false;
        if (requestedApp !== appID || !onlineRoot) return;
        if (reply.error) {
            onlineButton.disabled = wasDisabled;
            onlineStatus.style.color = '#e8a54b';
            onlineStatus.textContent = 'OnlineFix failed — ' + reply.error;
            return;
        }
        // Several uploads folders look like this game: ask here, not in the app.
        if (Array.isArray(reply.choices) && reply.choices.length) {
            onlineButton.disabled = wasDisabled;
            onlineStatus.style.color = '#acb2b8';
            onlineStatus.textContent = reply.message || 'Pick the right match.';
            renderOnlineChoices(reply.choices);
            return;
        }
        renderOnlineFix({ inList: true, fixInstalled: true, gameInstalled: true,
                          usesSteamNetworking: onlineUsesSDR, keepRealAppID: onlineKeepID });
        onlineStatus.style.color = '#a4d007';
        onlineStatus.hidden = false;
        onlineStatus.textContent = reply.message || 'OnlineFix installed.';
    }
    // A game added while Steam runs only gets its achievement list the next time
    // the client starts, so the card offers to do that here and open the game's
    // library page once Steam is back.
    async function restartSteam(label, action = 'restart') {
        if (restarting) return;
        restarting = true;
        if (restartButton) restartButton.disabled = true;
        if (label) label.textContent = 'Restarting Steam…';
        message.hidden = false;
        message.style.color = '#acb2b8';
        message.textContent = action === 'restart-plain'
            ? 'Restarting Steam. It drops the removed game from your library when it comes back.'
            : "Opening this game's library page, then restarting Steam back into it.";
        const reply = await request(action);
        // The page normally goes away with Steam; if it did not, undo the state.
        restarting = false;
        if (restartButton) restartButton.disabled = false;
        if (label) label.textContent = removedNow ? 'Restart Steam' : 'Restart';
        if (reply && reply.error) {
            message.style.color = '#e8a54b';
            message.textContent = `Could not restart Steam — ${reply.error}`;
        }
    }
    // Takes the game out of macSteam's config, so Steam stops showing it as
    // macSteam's and drops it from the library on the next refresh.
    async function removeGame() {
        if (busy) return;
        busy = true;
        if (removeButton) removeButton.disabled = true;
        render();
        const requestedApp = appID;
        const result = await request('remove');
        if (requestedApp !== appID) return;
        busy = false;
        if (removeButton) removeButton.disabled = false;
        message.hidden = false;
        if (result.error) {
            message.style.color = '#e8a54b';
            message.textContent = 'Could not remove it — ' + result.error;
        } else {
            configured = false;
            removedNow = true;
            state = result.installed ? 'installed' : result.ready ? 'ready' : 'add';
            message.style.color = '#acb2b8';
            message.textContent = 'Removed from macSteam. Restart Steam so it drops from your library.';
        }
        render();
    }
    async function clicked(event) {
        event.preventDefault();
        event.stopImmediatePropagation();
        if (busy) return;
        if (state === 'ready') {
            // Steam handles its own installation dialog and library location selection.
            location.href = `steam://install/${appID}`;
            return;
        }
        busy = true;
        message.textContent = '';
        render();
        const requestedApp = appID;
        const result = await request('add');
        if (requestedApp !== appID) return;
        busy = false;
        if (result.ready) {
            state = 'ready';
            addedNow = true;
            configured = !!(result.configured || result.ready);
            // The achievement list is only built while Steam starts, so say what to
            // do next: the Restart button does it.
            message.textContent = 'Added to your library. Restart Steam to load its achievements.'
                + '\nIf you are restarting later, restart twice to load achievements.';
            message.style.color = '#a4d007';
        } else {
            state = 'add';
            message.textContent = result.error || 'Steam has not confirmed the library refresh. Try again.';
            message.style.color = '#acb2b8';
        }
        render();
    }
    // The green medium button reproduced as a grey one, so "Restart" matches
    // the Install button beside it exactly.
    function ensureRestartButtonStyle() {
        if (document.getElementById('macsteam-restart-btn-style')) return;
        const style = document.createElement('style');
        style.id = 'macsteam-restart-btn-style';
        style.textContent =
            '.macsteam-restart-btn{background:rgba(103,112,123,.55)!important;' +
            'color:#dcdedf!important;text-shadow:none!important}' +
            '.macsteam-restart-btn:hover{background:#5c7080!important;color:#fff!important}';
        document.head.appendChild(style);
    }
    function mount() {
        const match = location.pathname.match(/^\/app\/([1-9][0-9]*)(?:\/|$)/);
        const id = match ? Number(match[1]) : 0;
        const nextApp = Number.isSafeInteger(id) && id <= 2147483647 ? id : 0;
        if (nextApp !== appID) {
            root?.remove();
            root = null;
            buttonHost = null;
            restartButton = null;
            removeButton = null;
            configured = false;
            removedNow = false;
            restarting = false;
            addedNow = false;
            removeFixes();
            removeOnlineFix();
            luaOnlineFix = null;
            onlineFixInstalled = false;
            fixBusy = false;
            onlineBusy = false;
            fixLoading = false;
            onlineLoading = false;
            appID = nextApp;
            busy = false;
            state = 'checking';
        }
        if (!appID) return;
        // The card belongs at the top of the purchase block, right above the
        // editions and price rows. Steam often adds that block after the title, so a
        // card mounted during the fallback has to be moved once the block appears.
        // (The :not() guards keep our own cards from being picked as the host.)
        let host = document.querySelector('#game_area_purchase, .game_area_purchase, .game_area_purchase_game_wrapper, .game_area_purchase_game:not(#macsteam-hubcap-purchase):not(#macsteam-fixes)');
        let after = false;
        if (!host) {
            const header = document.querySelector('#game_highlights, .apphub_HomeHeaderContent, .page_title_area');
            if (header) { host = header; after = true; }
        }
        if (!host) host = document.querySelector('.page_content');
        if (!host) return;
        if (root) {
            const settled = after ? root.previousElementSibling === host
                                   : root.parentElement === host && host.firstElementChild === root;
            if (settled) return;
            if (after) host.after(root); else host.prepend(root);
            return;
        }
        root = document.createElement('div');
        root.id = 'macsteam-hubcap-purchase';
        root.className = 'game_area_purchase_game';
        const title = document.createElement('h2');
        title.className = 'title';
        titlePrefix = document.createTextNode('Add to library with ');
        const brand = document.createElement('span');
        brand.textContent = 'macSteam';
        brand.style.cssText = 'display:inline-block;margin-left:6px;padding:2px 8px;border:1px solid rgba(198,212,223,.28);border-radius:999px;color:#c6d4df;font-size:.72em;line-height:1.4;vertical-align:2px';
        title.append(titlePrefix, brand);
        const actions = document.createElement('div');
        actions.className = 'game_purchase_action';
        const background = document.createElement('div');
        background.className = 'game_purchase_action_bg';
        const buttonContainer = document.createElement('div');
        buttonContainer.className = 'btn_addtocart';
        buttonHost = buttonContainer;
        button = document.createElement('button');
        button.type = 'button';
        button.className = 'btn_green_steamui btn_medium';
        button.style.cssText = 'border:0;cursor:pointer;font:inherit';
        button.appendChild(document.createElement('span'));
        button.addEventListener('click', clicked);
        message = document.createElement('div');
        message.setAttribute('role', 'status');
        message.setAttribute('aria-live', 'polite');
        message.style.cssText = 'font-size:12px;color:#acb2b8;margin-top:8px;max-width:75%;white-space:pre-line';
        buttonContainer.appendChild(button);
        // Once the game is in the library, restart Steam for it: a game added
        // while Steam runs only gets its achievement list on the next start.
        ensureRestartButtonStyle();
        restartButton = document.createElement('button');
        restartButton.type = 'button';
        // Steam's green medium button, recoloured: using the same class as the
        // Install button beside it is what keeps the two the same size and the
        // labels on one line. The grey class is a different shape entirely.
        restartButton.className = 'btn_green_steamui btn_medium macsteam-restart-btn';
        restartButton.style.cssText = 'border:0;cursor:pointer;font:inherit;margin-left:8px';
        restartButton.style.display = 'none';
        restartButton.title = "Restart Steam, then open this game's library page";
        const restartText = document.createElement('span');
        restartText.textContent = 'Restart';
        restartButton.appendChild(restartText);
        restartButton.addEventListener('click', event => {
            event.preventDefault();
            event.stopImmediatePropagation();
            void restartSteam(restartText, removedNow ? 'restart-plain' : 'restart');
        });
        buttonContainer.appendChild(restartButton);
        // A game macSteam put in the library can be taken back out here, the same
        // way the macSteam app's own Remove does it.
        removeButton = actionButton('Remove from Steam', () => { void removeGame(); });
        removeButton.style.marginLeft = '0';
        removeButton.style.marginTop = '8px';
        removeButton.style.alignSelf = 'flex-start';
        removeButton.style.display = 'none';
        background.appendChild(buttonContainer);
        actions.appendChild(background);
        root.append(title, message, actions, removeButton);
        if (after) host.after(root); else host.prepend(root);
        render();
        if (!busy) void refresh();
        void loadFixes();
        void loadOnlineFix();
    }
    new MutationObserver(mount).observe(document, { childList: true, subtree: true });
    window.addEventListener('popstate', mount);
    // Returning from Steam's install dialog (or an uninstall) must update the card.
    window.addEventListener('focus', () => {
        if (!appID || !root?.isConnected) return;
        if (!busy) void refresh();
        // The game may have been updated, uninstalled or wiped while the user was away.
        if (!fixBusy) void loadFixes();
        if (!onlineBusy) void loadOnlineFix();
    });
    window.navigation?.addEventListener('currententrychange', mount);
    mount();
})();
