(() => {
    'use strict';
    if (location.protocol !== 'https:' || location.hostname !== 'store.steampowered.com' || window.__macsteamHubcap) return;
    let appID = 0;
    const pending = new Map();
    let sequence = 0;
    let state = 'checking';
    let busy = false;
    let fixBusy = false;
    let root, button, restartButton, removeButton, message, titlePrefix, fixesRoot, buttonHost, brandSpan;
    // The player's own Steam licence for the page's app, from the store session.
    let owned = false;
    const ownershipCache = new Map();
    // Free to play: nothing to unlock, and no reason to add it to a library that
    // already lists it.
    let freeGame = false;
    const freeCache = new Map();
    // Whether macSteam has this app in its config, which is what the Remove button acts on.
    let configured = false;
    let onlineRoot, onlineButton, onlineStatus, onlineDesc, onlineNote, onlineChoices, onlineConfirmRow;
    // Tick "Show me anyway": the install runs only when it is on.
    let onlineConfirmed = false;
    let onlineGdk = false;
    let onlineFree = false;
    let onlineOverlay = false;
    // Native macOS build: OnlineFix has no file that can load in a Mac process, only
    // Steam-side routing applies.
    let onlineNative = false;
    // A Mac build whose only fix is the AppID 480 routing, and that routing is on.
    let onlineRouteInstalled = false;
    // What online-fix.me has for this page's game, asked once before any install.
    let onlineProbe = null;
    let onlineProbeFor = 0;
    let onlineProbeBusy = false;
    let onlineWindows = false;
    let onlineNativeTool = '';
    let onlineNativePoll = 0;
    let onlineNativeTimer = null;
    let onlineNativeWarning = null;
    let onlineRouteRow = null;
    let onlineReroute = null;
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
    // The install's steps, one line each, so a minute of work reads as progress
    // instead of one sentence that never changes.
    function onlineFixStep(text) {
        if (!onlineStatus) return;
        onlineStatus.hidden = false;
        onlineStatus.style.color = '#acb2b8';
        let list = onlineStatus.querySelector('.of-steps');
        if (!list) {
            onlineStatus.textContent = '';
            list = document.createElement('div');
            list.className = 'of-steps';
            onlineStatus.appendChild(list);
        }
        const line = document.createElement('div');
        line.textContent = '· ' + text;
        line.style.cssText = 'font-size:12px;line-height:1.5;opacity:.85';
        list.appendChild(line);
        while (list.children.length > 10) list.removeChild(list.firstChild);
    }
    window.__macsteamOnlineFix = {
        progress(text) { onlineFixStep(text); },
        reset() {
            if (!onlineStatus) return;
            onlineStatus.textContent = '';
        }
    };
    function request(action, fixID, name, folder, extra) {
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
            bridge(JSON.stringify({ id, appID, action, fixID, name: name || '', folder: folder || '',
                confirmed: !!extra }));
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
    // A game the player bought already belongs to them: the card must not offer to
    // add it, and must never offer to remove it. The store's own session knows.
    async function pageOwnsGame(id) {
        if (ownershipCache.has(id)) return ownershipCache.get(id);
        let answer = false;
        try {
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), 4000);
            const reply = await fetch('/dynamicstore/userdata/', {
                credentials: 'include', signal: controller.signal,
            });
            clearTimeout(timer);
            if (reply.ok) {
                const data = await reply.json();
                const apps = Array.isArray(data.rgOwnedApps) ? data.rgOwnedApps : [];
                answer = apps.includes(id);
            }
        } catch (error) {
            answer = false;
        }
        ownershipCache.set(id, answer);
        return answer;
    }
    // Whether Steam sells the app for nothing. A free game needs no unlock, so the
    // OnlineFix card warns and the add-to-library card stays away.
    async function pageGameIsFree(id) {
        if (freeCache.has(id)) return freeCache.get(id);
        let answer = false;
        try {
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), 4000);
            const reply = await fetch(`/api/appdetails?appids=${id}&filters=basic`, {
                credentials: 'include', signal: controller.signal,
            });
            clearTimeout(timer);
            if (reply.ok) {
                const data = await reply.json();
                const entry = data[String(id)];
                answer = !!(entry && entry.success && entry.data && entry.data.is_free);
            }
        } catch (error) {
            answer = false;
        }
        freeCache.set(id, answer);
        return answer;
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
        // A free game needs no macSteam action: it is in every library already.
        if (freeGame) {
            root.style.display = 'none';
            if (buttonHost) buttonHost.style.display = 'none';
            return;
        }
        // A bought game needs no macSteam action at all: the library already has it,
        // and Remove must stay out of reach of a real licence.
        if (owned) {
            root.style.display = '';
            if (buttonHost) buttonHost.style.display = 'none';
            if (button) button.style.display = 'none';
            titlePrefix.textContent = 'You own this game';
            if (brandSpan) brandSpan.style.display = 'none';
            message.hidden = true;
            if (removeButton) removeButton.style.display = 'none';
            if (restartButton) restartButton.style.display = 'none';
            return;
        }
        if (brandSpan) brandSpan.style.display = '';
        if (button) button.style.display = '';
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
        if (ownershipCache.has(requestedApp)) {
            owned = ownershipCache.get(requestedApp);
        } else {
            owned = false;
            void pageOwnsGame(requestedApp).then(value => {
                if (appID !== requestedApp) return;
                owned = value;
                render();
            });
        }
        if (freeCache.has(requestedApp)) {
            freeGame = freeCache.get(requestedApp);
        } else {
            freeGame = false;
            void pageGameIsFree(requestedApp).then(value => {
                if (appID !== requestedApp) return;
                freeGame = value;
                render();
                if (value) void loadOnlineFix();
            });
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
        // The OnlineFix card already says a GDK game cannot be patched; a second card
        // offering a LuaTools patch for it would contradict that. Once the player
        // ticks "Show me anyway" both patches are on offer, so the card comes back.
        if (onlineGdk && !onlineConfirmed) {
            luaOnlineFix = null;
            removeFixes();
            return;
        }
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
        // A LuaTools fix that carries OnlineFix exists for the same game as the
        // OnlineFix card. Both write the same files, so only one may be installed.
        if (result.fixes.some(f => f.onlineFix)) {
            const warning = document.createElement('div');
            warning.style.cssText = 'font-size:12px;color:#e8a54b;margin-top:10px;'
                + 'max-width:560px;line-height:1.45';
            warning.textContent = 'Dont install both onlinefix and luatools, trust me, '
                + 'you dont wanna know, one at a time.';
            rows.appendChild(warning);
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
        onlineConfirmRow?.remove();
        onlineConfirmRow = null;
        onlineNativeWarning = null;
        onlineRouteRow?.remove();
        onlineRouteRow = null;
        onlineReroute?.remove();
        onlineReroute = null;
        onlineSignature = '';
    }
    // When online-fix.me has no folder under the exact name, the reply carries the
    // similar ones: one button each, and picking one installs that folder's fix —
    // all without leaving the store page.
    // `confirmed` carries the player's yes through: picking a folder must not ask
    // the same question again.
    function renderOnlineChoices(choices, confirmed) {
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
            onlineChoices.appendChild(actionButton(text, () => installOnlineFix(name, confirmed)));
        }
        (onlineStatus?.isConnected ? onlineStatus : onlineRoot).after(onlineChoices);
    }
    function clearOnlineChoices() {
        onlineChoices?.remove();
        onlineChoices = null;
        onlineConfirmRow?.remove();
        onlineConfirmRow = null;
    }
    // One tick for every install the app warns about, GDK or post-check: nothing is
    // downloaded until it is on.
    function showConfirmCheckbox(parent, label) {
        onlineConfirmRow?.remove();
        onlineConfirmRow = document.createElement('label');
        onlineConfirmRow.style.cssText = 'display:flex;align-items:center;gap:6px;'
            + 'font-size:12px;color:#acb2b8;margin-top:6px;cursor:pointer;max-width:560px';
        const box = document.createElement('input');
        box.type = 'checkbox';
        box.checked = !!onlineConfirmed;
        box.addEventListener('change', () => {
            onlineConfirmed = box.checked;
            refreshOnlineButton();
            if (onlineNative) {
                if (onlineNativeWarning) onlineNativeWarning.hidden = !onlineConfirmed;
                const span = onlineButton?.querySelector('span');
                if (span) {
                    span.textContent = onlineConfirmed ? 'Install files anyway'
                        : 'Install Windows version';
                }
            }
            // The LuaTools card follows the tick: hidden with the advice, back on
            // offer once the player accepts that neither patch will work here.
            if (onlineGdk) {
                if (onlineConfirmed) {
                    void loadFixes();
                } else {
                    luaOnlineFix = null;
                    removeFixes();
                    applyOnlineRecommendation();
                }
            }
        });
        const text = document.createElement('span');
        text.textContent = label
            || (onlineFree && !onlineGdk ? 'just show me anyway goddamn it' : 'Show me anyway');
        onlineConfirmRow.append(box, text);
        parent.appendChild(onlineConfirmRow);
    }
    // Hands the game to Steam's own compatibility setting, then lets it install the
    // Windows build. The callback means the tool is saved before the install starts.
    async function switchToWindowsBuild() {
        const requestedApp = appID;
        if (onlineStatus) {
            onlineStatus.hidden = false;
            onlineStatus.style.color = '#acb2b8';
            onlineStatus.textContent = 'Switching the game to NotProton…';
        }
        // Steam's own Compatibility API lives in its UI realm, so the bridge calls it
        // there. The page only asks; it never pretends the change happened.
        const reply = await request('onlinefix-windows');
        if (requestedApp !== appID || !onlineRoot) return;
        if (!reply.switched) {
            // Steam would not take the setting from us. It can still open its own
            // Properties dialog, where the Compatibility tab is the same setting.
            if (reply.opened) {
                if (onlineStatus) {
                    onlineStatus.style.color = '#a4d007';
                    onlineStatus.textContent = 'Opened the game’s Properties. On the '
                        + 'Compatibility tab choose “Force the use of a specific Steam Play '
                        + 'compatibility tool” → NotProton.';
                }
                onlineReroute?.remove();
                onlineReroute = actionButton('Check again', () => {
                    void loadOnlineFix();
                    scheduleWindowsPoll();
                });
                if (onlineStatus) onlineStatus.after(onlineReroute);
                scheduleWindowsPoll();
                return;
            }
            // Otherwise open the game's page, say exactly which menu holds it, and keep
            // watching the folder so the card flips as soon as the Windows build is there.
            location.href = 'steam://nav/games/details/' + appID;
            if (onlineStatus) {
                onlineStatus.style.color = '#e8a54b';
                onlineStatus.textContent = 'Steam did not let macSteam set it. Open the game’s '
                    + 'Properties (gear icon) → Compatibility → “Force the use of a specific '
                    + 'Steam Play compatibility tool” → NotProton, then press Check again.';
            }
            onlineReroute?.remove();
            onlineReroute = actionButton('Check again', () => {
                void loadOnlineFix();
                scheduleWindowsPoll();
            });
            if (onlineStatus) onlineStatus.after(onlineReroute);
            scheduleWindowsPoll();
            return;
        }
        // Steam installs one platform at a time; with the tool set, its install/verify
        // replaces the Mac files with the Windows depot.
        location.href = 'steam://validate/' + appID;
        scheduleWindowsPoll();
        if (onlineStatus) {
            onlineStatus.style.color = '#a4d007';
            onlineStatus.textContent = 'NotProton set. Steam will fetch the Windows build; '
                + 'this card updates when it is in the folder.';
        }
    }
    // Looks again every few seconds while the Windows build is downloading, so the
    // card turns into "OnlineFix WILL work" on its own.
    function scheduleWindowsPoll() {
        if (onlineNativeTimer) clearTimeout(onlineNativeTimer);
        onlineNativeTimer = null;
        if (!onlineNative || onlineWindows || onlineNativePoll >= 120) return;
        onlineNativePoll += 1;
        const requestedApp = appID;
        onlineNativeTimer = setTimeout(() => {
            onlineNativeTimer = null;
            if (appID !== requestedApp || !onlineRoot?.isConnected) return;
            void loadOnlineFix();
            scheduleWindowsPoll();
        }, 5000);
    }
    function refreshOnlineButton() {
        if (!onlineButton) return;
        // A native build has a working action either way: switch to the Windows build,
        // or copy the files over once the player says so.
        if (onlineNative) {
            onlineButton.disabled = !onlineGameInstalled;
            return;
        }
        onlineButton.disabled = !onlineGameInstalled
            || (!onlineConfirmed && (!!onlineGdk || !!onlineFree));
    }
    // When LuaTools carries an Online Fix for the game, this card says to use that
    // one and leaves its own Install as a deliberate "Install anyway" (that is what
    // sets up macSteam's AppID 480 routing).
    function applyOnlineRecommendation() {
        if (!onlineRoot) return;
        const fix = luaOnlineFix;
        if (onlineDesc) {
            onlineDesc.textContent = onlineNative
                ? (onlineRouteInstalled
                    ? 'Installed. Only the AppID 480 routing is set: uninstall the fix to go '
                      + 'back to normal.'
                    : 'Installs the AppID 480 routing for this Mac build. No game files are '
                      + 'changed, and uninstalling goes back to normal.')
                : (onlineFixInstalled
                    ? (onlineKeepID
                        ? 'Installed. Launch the game from Steam, it runs as its own AppID.'
                        : 'Installed. Launch the game from Steam, it runs as AppID 480.')
                    : (onlineKeepID
                        ? 'Installs the game\'s fix and keeps its own Steam AppID, so Steam can '
                          + 'grant its relay network.'
                        : 'Installs the game\'s fix and runs its Steam session as AppID 480 '
                          + '(Spacewar).'));
        }
        if (onlineNote) {
            const muted = onlineGdk && !onlineConfirmed;
            onlineNote.hidden = true;
            if (muted) onlineNote.textContent = '';
            else
            onlineNote.textContent = '';
        }
        if (onlineButton) {
            const label = onlineFixInstalled ? 'Reinstall'
                : fix ? 'Install anyway' : 'Install';
            onlineButton.querySelector('span').textContent = label;
            refreshOnlineButton();
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
            photon: result.photonIssue || '',
            gdk: !!result.gdkRestricted || !!(onlineProbe && onlineProbe.gdk),
            overlayStub: !!result.overlayStub,
            free: !!freeGame,
            probe: onlineProbe ? [!!onlineProbe.available, !!onlineProbe.gdk] : null,
            nativeMac: !!result.nativeMacBuild,
            windows: !!result.windowsBuildInstalled,
        });
        if (onlineRoot?.isConnected && signature === onlineSignature) {
            applyOnlineRecommendation();
            if (onlineNative) scheduleWindowsPoll();
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
        onlineGdk = !!result.gdkRestricted || !!(onlineProbe && onlineProbe.gdk);
        onlineFree = !!freeGame;
        onlineOverlay = !!result.overlayStub;
        // "Windows version installed" only means something for a game Steam also sells
        // a Mac build of; for a Windows-only game that is just the game.
        const macCapable = !!result.nativeMacBuild || pageSaysNativeMac();
        onlineWindows = !!result.windowsBuildInstalled && macCapable;
        // Once Steam has swapped in the Windows build the card is a normal fix card
        // again; the native handling only applies while the folder still has the .app.
        onlineNative = !!result.nativeMacBuild && !onlineWindows;
        onlineNativeTool = result.compatTool || '';
        // A Mac build has nothing to install but the identity, so a routed Mac app is
        // installed as far as the card is concerned: Uninstall turns it back off.
        onlineRouteInstalled = onlineNative && !!result.inList && !onlineKeepID;
        if (onlineRouteInstalled) onlineFixInstalled = true;
        if (onlineWindows && onlineNativeTimer) {
            clearTimeout(onlineNativeTimer);
            onlineNativeTimer = null;
        }
        // A GDK game has no usable LuaTools patch either: its card would only offer
        // something that cannot work, so it stays down until the tick brings it back.
        if (onlineGdk) {
            if (onlineConfirmed) void loadFixes();
            else {
                luaOnlineFix = null;
                removeFixes();
            }
        }
        info.append(name, desc);
        const actions = document.createElement('div');
        actions.style.cssText = 'white-space:nowrap';
        if (result.fixInstalled || onlineRouteInstalled) {
            const remove = actionButton('Uninstall', () => uninstallOnlineFix());
            actions.appendChild(remove);
        }
        // A routed Mac build has nothing to reinstall: Uninstall is the only action.
        if (onlineNative && onlineRouteInstalled) {
            onlineButton = null;
        } else {
            onlineButton = actionButton(result.fixInstalled ? 'Reinstall' : 'Install',
                () => installOnlineFix(undefined, onlineConfirmed));
            onlineButton.disabled = !result.gameInstalled;
            actions.appendChild(onlineButton);
            refreshOnlineButton();
        }
        row.append(info, actions);
        onlineRoot.appendChild(row);
        // A GDK game cannot be fixed by OnlineFix or LuaTools under Wine: the only
        // package needs the Xbox runtime. Say so up front, and keep the install
        // behind a tick so it is a deliberate choice, not a surprise. onlineGdk also
        // covers a game the probe found only a GDK archive for, before any install.
        if (onlineGdk) {
            const warning = document.createElement('div');
            warning.style.cssText = 'font-size:12px;color:#e8a54b;margin-top:8px;'
                + 'max-width:560px;line-height:1.45';
            warning.textContent = 'This game is like one of the few that aint gonna connect, try if you want ig tho';
            onlineRoot.appendChild(warning);
            showConfirmCheckbox(onlineRoot);
        } else {
            // The switch worked: the folder is the Windows build, which is what the
            // fix can patch. Say so before anything else.
            if (onlineWindows) {
                const ready = document.createElement('div');
                ready.style.cssText = 'font-size:12px;color:#a4d007;margin-top:8px;'
                    + 'max-width:560px;line-height:1.45';
                ready.textContent = 'This version of your game is the Windows version, '
                    + 'OnlineFix WILL work, go ahead.';
                onlineRoot.appendChild(ready);
            }
            // A native macOS build takes no OnlineFix files; a free game needs no
            // unlock. Both can be true at once, so each gets its own line and the
            // free one keeps its tick.
            if (onlineNative) {
                const note = document.createElement('div');
                note.style.cssText = 'font-size:12px;color:#acb2b8;margin-top:8px;'
                    + 'max-width:560px;line-height:1.45';
                note.textContent = onlineRouteInstalled
                    ? 'Installed. This is the Mac build, so the fix is only the AppID 480 '
                      + '(Spacewar) routing: the game starts the way a fixed game does and '
                      + 'no game files were changed. Uninstall the fix to go back to normal.'
                    : 'This is the Mac build, so OnlineFix\'s Windows files cannot load here. '
                      + 'Install sets up the AppID 480 (Spacewar) routing instead, which is '
                      + 'the whole fix for a Mac build, and changes no game files. Uninstall '
                      + 'the fix to go back to normal.';
                onlineRoot.appendChild(note);
                // The routing is the Mac path; the Windows build is the other one, and it
                // is what lets the real fix files install and work.
                if (!onlineRouteInstalled) {
                    const windows = actionButton('Get the Windows version',
                        () => { void switchToWindowsBuild(); });
                    windows.style.marginLeft = '0';
                    windows.style.marginTop = '6px';
                    onlineRoot.appendChild(windows);
                }
            }
            if (onlineFree) {
                const warning = document.createElement('div');
                warning.style.cssText = 'font-size:12px;color:#a4d007;margin-top:8px;'
                    + 'max-width:560px;line-height:1.45';
                warning.textContent = 'This game is free and already works without OnlineFix.';
                onlineRoot.appendChild(warning);
                showConfirmCheckbox(onlineRoot);
            }
        }
        // R.E.P.O.'s Photon app is stored in the game's asset file. When OnlineFix's
        // default app is overloaded, a pair the player supplies can be written there,
        // the same patch the original OnlineFix Manager offers.
        // Nothing installed yet: ask online-fix.me what exists for this game, so a GDK
        // package is warned about before anything is downloaded.
        if (!result.fixInstalled && onlineProbeFor !== appID && !onlineProbeBusy) {
            onlineProbeBusy = true;
            const requestedApp = appID;
            void request('onlinefix-probe', null, gameName()).then(reply => {
                onlineProbeBusy = false;
                if (requestedApp !== appID || reply.error) return;
                onlineProbeFor = requestedApp;
                onlineProbe = { available: !!reply.available, gdk: !!reply.gdk };
                void loadOnlineFix();
            });
        }
        // Say what the probe found, once it has answered.
        if (onlineProbeFor === appID && onlineProbe && !result.fixInstalled && !onlineProbe.gdk
            && !onlineNative) {
            const found = document.createElement('div');
            found.style.cssText = 'font-size:11px;margin-top:8px;max-width:560px;line-height:1.4;'
                + (onlineProbe.available ? 'color:#a4d007' : 'color:#8f98a0');
            found.textContent = onlineProbe.available
                ? 'OnlineFix has a fix for this game; its files are laid out automatically '
                  + 'when you install it.'
                : 'No OnlineFix folder was found for this game on online-fix.me.';
            onlineRoot.appendChild(found);
        }
        // The identity Steam starts this game with, for the games that can take fix
        // files. A Mac build is not one of them: its Install button is the routing,
        // so the card gets no separate route button for it.
        if (!result.gdkRestricted && !onlineNative) {
            const identity = document.createElement('div');
            identity.style.cssText = 'font-size:12px;margin-top:8px;max-width:560px;'
                + 'line-height:1.45';
            const text = document.createElement('div');
            let label;
            let run;
            if (!result.inList) {
                identity.style.color = '#acb2b8';
                text.textContent = 'Not in My Games yet. macSteam can still start this game as '
                    + 'Spacewar (480), the identity an OnlineFix runs with, without writing '
                    + 'any game files.';
                label = 'Route through 480';
                run = () => setOnlineRoute(true);
            } else if (result.keepRealAppID) {
                identity.style.color = '#e8a54b';
                text.textContent = 'Starts as its own AppID ('
                    + appID + '). '
                    + (result.usesSteamNetworking
                        ? 'That is what a game on Steam\'s relay servers needs, and it '
                          + 'still matches players as Spacewar (480), so leave it on.'
                        : (result.fixInstalled
                            ? 'It still matches players as Spacewar (480); this only '
                              + 'changes what Steam reports for it.'
                            : 'Turning this off starts it as Spacewar (480), the identity an '
                              + 'OnlineFix would use.'));
                label = 'Use Spacewar (480)';
                run = () => setOnlineKeepID(false);
            } else {
                identity.style.color = '#a4d007';
                text.textContent = 'Starts as Spacewar (480), the identity an OnlineFix '
                    + 'matches players as.'
                    + (result.usesSteamNetworking
                        ? ' This game uses Steam\'s relay servers, which only exist for its '
                          + 'own AppID: if multiplayer waits forever, switch it back.'
                        : '');
                label = 'Use real AppID';
                run = () => setOnlineKeepID(true);
            }
            identity.appendChild(text);
            const button = actionButton(label, run);
            button.style.marginLeft = '0';
            button.style.marginTop = '6px';
            identity.appendChild(button);
            onlineRoot.appendChild(identity);
        }
        // Steam's macOS client cannot run NotProton's `NAME=value` launch prefix
        // once a game launches natively; it fails with OS error 260. The bridge
        // clears it through Steam before answering.
        if (result.launchOptionsFixed) {
            const cleared = document.createElement('div');
            cleared.style.cssText = 'font-size:11px;color:#a4d007;margin-top:8px;'
                + 'max-width:560px;line-height:1.4';
            cleared.textContent = 'Removed the Windows-only launch options that stopped this '
                + 'game from starting (OS error 260). It launches normally again.';
            onlineRoot.appendChild(cleared);
        }
        // OnlineFix's Photon support is a second patch that runs inside the game.
        // When one of its pieces is missing, the fix looks installed and the game
        // still fails with CustomAuthenticationError, so say what is missing here.
        if (result.photonIssue) {
            const photon = document.createElement('div');
            photon.style.cssText = 'font-size:12px;color:#e8a54b;margin-top:8px;'
                + 'max-width:560px;line-height:1.45';
            photon.textContent = result.photonIssue;
            onlineRoot.appendChild(photon);
        }
        onlineStatus = document.createElement('div');
        onlineStatus.setAttribute('role', 'status');
        onlineStatus.setAttribute('aria-live', 'polite');
        onlineStatus.style.cssText = 'font-size:12px;color:#acb2b8;margin-top:6px';
        if (!result.gameInstalled) {
            onlineStatus.textContent = 'You can only install an OnlineFix once the game is installed: the fix is built from the game\'s own files, so there has to be something there to scan.';
        }
        onlineStatus.hidden = !onlineStatus.textContent;
        onlineRoot.appendChild(onlineStatus);
        onlineNote = document.createElement('div');
        onlineNote.style.cssText = 'font-size:12px;color:#a4d007;margin-top:6px;max-width:520px';
        onlineNote.hidden = true;
        onlineRoot.appendChild(onlineNote);
        (fixesRoot?.isConnected ? fixesRoot : root).after(onlineRoot);
        applyOnlineRecommendation();
        if (onlineNative) scheduleWindowsPoll();
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
        // The fix is gone, so the game may now need its own AppID: ask for the
        // fresh status instead of re-rendering the flags from before the install.
        const wasMac = onlineNative;
        await loadOnlineFix();
        onlineStatus.style.color = '#a4d007';
        onlineStatus.hidden = false;
        onlineStatus.textContent = wasMac
            ? 'Uninstalled. The Mac build starts as itself again, back to normal.'
            : (reply.message || 'OnlineFix removed.');
    }
    // Starts the game as itself (or back as Spacewar), which applies to the next
    // launch. Every game offers this, whatever its engine or fix.
    async function setOnlineKeepID(keep) {
        if (onlineBusy) return;
        onlineBusy = true;
        if (onlineStatus) {
            onlineStatus.hidden = false;
            onlineStatus.style.color = '#acb2b8';
            onlineStatus.textContent = 'Saving…';
        }
        const requestedApp = appID;
        const reply = await request(keep ? 'onlinefix-keep-id' : 'onlinefix-spacewar',
            null, gameName());
        onlineBusy = false;
        if (requestedApp !== appID || !onlineRoot) return;
        if (reply.error) {
            if (onlineStatus) {
                onlineStatus.style.color = '#e8a54b';
                onlineStatus.textContent = 'Could not change it: ' + reply.error;
            }
            return;
        }
        // Ask for the whole status again: re-rendering the few flags this reply
        // carries dropped the rest (GDK, overlay stub, Windows build, native), and
        // the card changed shape after one click.
        await loadOnlineFix();
        if (onlineStatus) {
            onlineStatus.style.color = '#a4d007';
            onlineStatus.hidden = false;
            onlineStatus.textContent = reply.message || (keep
                ? 'This game now starts as its own AppID.'
                : 'This game now starts as Spacewar (480).');
        }
    }
    // Routes a game that has no OnlineFix through AppID 480 anyway: macSteam starts
    // it as Spacewar, the identity a fix would have given it. No files are written.
    async function setOnlineRoute(on) {
        if (onlineBusy) return;
        onlineBusy = true;
        if (onlineStatus) {
            onlineStatus.hidden = false;
            onlineStatus.style.color = '#acb2b8';
            onlineStatus.textContent = 'Saving…';
        }
        const requestedApp = appID;
        const reply = await request('onlinefix-route', null, gameName(), null, on);
        onlineBusy = false;
        if (requestedApp !== appID || !onlineRoot) return;
        if (reply.error) {
            if (onlineStatus) {
                onlineStatus.style.color = '#e8a54b';
                onlineStatus.textContent = 'Could not route it: ' + reply.error;
            }
            return;
        }
        await loadOnlineFix();
        if (onlineStatus) {
            onlineStatus.style.color = '#a4d007';
            onlineStatus.hidden = false;
            onlineStatus.textContent = reply.message || (on
                ? 'This game now starts as Spacewar (480).'
                : 'This game now starts as its own AppID.');
        }
    }
    // A Mac build has no files to take: its Install is the AppID 480 routing, which
    // is the whole fix for it. Uninstall removes the game from My Games again.
    async function installOnlineRoute() {
        if (onlineBusy) return;
        onlineBusy = true;
        if (onlineButton) onlineButton.disabled = true;
        if (onlineStatus) {
            onlineStatus.hidden = false;
            onlineStatus.style.color = '#acb2b8';
            onlineStatus.textContent = 'Setting up the AppID 480 (Spacewar) routing…';
        }
        const requestedApp = appID;
        const reply = await request('onlinefix-route', null, gameName(), null, true);
        onlineBusy = false;
        if (requestedApp !== appID || !onlineRoot) return;
        if (reply.error) {
            if (onlineButton) onlineButton.disabled = false;
            if (onlineStatus) {
                onlineStatus.style.color = '#e8a54b';
                onlineStatus.textContent = 'Could not set up the routing: ' + reply.error;
            }
            return;
        }
        await loadOnlineFix();
        if (onlineStatus) {
            onlineStatus.style.color = '#a4d007';
            onlineStatus.hidden = false;
            onlineStatus.textContent = 'OnlineFix installed for this Mac build: it only routes '
                + 'the game through AppID 480 (Spacewar), and no game files were changed. '
                + 'Uninstall the fix to go back to normal.';
        }
    }
    // `confirmed` is set when the player already said to install a fix the app
    // warned them about, so it does not ask twice.
    async function installOnlineFix(folderName, confirmed) {
        if (onlineBusy) return;
        // A Mac build takes the routing path, which has no archive to download.
        if (onlineNative) {
            await installOnlineRoute();
            return;
        }
        if (!onlineButton) return;
        onlineBusy = true;
        const requestedApp = appID;
        const wasDisabled = onlineButton.disabled;
        onlineButton.disabled = true;
        clearOnlineChoices();
        onlineStatus.hidden = false;
        onlineStatus.style.color = '#acb2b8';
        window.__macsteamOnlineFix?.reset();
        onlineFixStep(confirmed
            ? (folderName
                ? `Downloading and installing “${folderName}”… this can take a minute.`
                : 'Downloading and installing the OnlineFix… this can take a minute.')
            : 'Checking whether OnlineFix works for this game…');
        const reply = await request('onlinefix-install', null, gameName(), folderName, confirmed);
        onlineBusy = false;
        if (requestedApp !== appID || !onlineRoot) return;
        // The fix may not work: say why, and install only if the player still wants it.
        if (reply.confirmation) {
            onlineButton.disabled = wasDisabled;
            onlineStatus.style.color = '#e8a54b';
            onlineStatus.textContent = reply.confirmation;
            showConfirmCheckbox(onlineStatus);
            return;
        }
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
            renderOnlineChoices(reply.choices, confirmed);
            return;
        }
        // A native build: the page switches Steam to NotProton and starts the Windows
        // download, so the fix has a folder it can work in.
        if (reply.windowsBuild) {
            void switchToWindowsBuild();
            return;
        }
        // The fix is in place now: ask for the fresh status rather than re-rendering
        // the flags from before the install.
        await loadOnlineFix();
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
        // Belt and braces: the button is hidden for an owned game, but a real
        // licence is never worth finding out about the hard way.
        if (await pageOwnsGame(appID)) {
            owned = true;
            render();
            return;
        }
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
            onlineConfirmed = false;
            onlineGdk = false;
            onlineFree = false;
            onlineOverlay = false;
            onlineNative = false;
            onlineNativeTool = '';
            onlineProbe = null;
            onlineProbeFor = 0;
            onlineProbeBusy = false;
            onlineNativeWarning = null;
            onlineRouteRow = null;
            onlineConfirmRow = null;
            onlineNativePoll = 0;
            onlineReroute?.remove();
            onlineReroute = null;
            if (onlineNativeTimer) {
                clearTimeout(onlineNativeTimer);
                onlineNativeTimer = null;
            }
            owned = false;
            freeGame = false;
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
        brandSpan = brand;
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
