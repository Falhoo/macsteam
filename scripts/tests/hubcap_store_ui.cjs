const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('macsteam-app/Sources/MacsteamApp/Resources/hubcap-store.js', 'utf8');

class Element {
    constructor(tag) { this.tag = tag; this.children = []; this.listeners = {}; this.style = {}; this.isConnected = false; }
    append(...children) { this.children.push(...children); children.forEach(c => { c.isConnected = this.isConnected; c.parent = this; }); }
    appendChild(child) { this.append(child); return child; }
    prepend(child) { this.children.unshift(child); child.isConnected = true; child.parent = this; }
    remove() { this.isConnected = false; if (this.parent) this.parent.children.splice(this.parent.children.indexOf(this), 1); }
    setAttribute(key, value) { this[key] = value; }
    addEventListener(name, action) { this.listeners[name] = action; }
    replaceWith(child) {
        const at = this.parent.children.indexOf(this);
        this.parent.children.splice(at, 1, child);
        child.parent = this.parent; child.isConnected = this.isConnected; this.isConnected = false;
    }
    insertBefore(child, next) {
        this.children.splice(this.children.indexOf(next), 0, child);
        child.parent = this; child.isConnected = this.isConnected;
    }
    // Depth-first in document order, like the DOM: a direct child is only the
    // answer if no earlier sibling's subtree holds a match.
    querySelector(selector) {
        const matches = c => selector.startsWith('.') ? c.className?.split(' ').includes(selector.slice(1).split(':')[0]) : c.tag === selector;
        for (const child of this.children) {
            if (matches(child)) return child;
            const nested = child.querySelector(selector);
            if (nested) return nested;
        }
        return null;
    }
    querySelectorAll(tag) { const out = []; const walk = n => { if (n.tag === tag) out.push(n); (n.children || []).forEach(walk); }; walk(this); return out; }
}
function page(url = 'https://store.steampowered.com/app/620/Portal_2/') {
    const host = new Element('purchase');
    host.isConnected = true;
    const card = new Element('div'); card.className = 'game_area_purchase_game';
    const title = new Element('h2'); title.textContent = 'Buy Portal 2';
    const platforms = new Element('platforms');
    const original = new Element('div'); original.className = 'game_purchase_action';
    card.append(title, platforms, original); host.append(card);
    const requests = [];
    let mutation;
    const location = new URL(url);
    const events = {};
    const window = {
        location,
        macsteamHubcap: text => {
            const request = JSON.parse(text);
            // Builds that also carry the game-fixes card ask separately; this test is about the
            // Add/Install card, so those requests are answered with "no fixes".
            if (request.action === 'fixes') { setImmediate(() => window.__macsteamHubcap.reply(request.id, { fixes: [] })); return; }
            // The OnlineFix card is separate too: this test is about the Add/Install card,
            // so it is told there is nothing to show there.
            if (request.action === 'onlinefix-status') { setImmediate(() => window.__macsteamHubcap.reply(request.id, { error: 'not checked' })); return; }
            requests.push(request);
        },
        addEventListener(name, fn) { (events[name] ||= []).push(fn); } };
    const head = new Element('head');
    const document = { documentElement: null, head, querySelector: () => host, createElement: tag => new Element(tag),
        getElementById: id => head.children.find(child => child.id === id) || null,
        createTextNode: text => { const node = new Element('#text'); node.textContent = text; return node; } };
    const context = vm.createContext({ window, document, location, setTimeout, clearTimeout,
        MutationObserver: class { constructor(callback) { mutation = callback; } observe(target) { assert.equal(target, document); } } });
    vm.runInContext(source, context);
    return { host, title, platforms, original, requests, window, events, location, context, mutation: () => mutation?.(),
        reply: result => { const request = requests.shift(); assert.ok(request); window.__macsteamHubcap.reply(request.id, result); } };
}
const flush = () => new Promise(resolve => setImmediate(resolve));
(async () => {
    const p = page();
    assert.equal(p.requests[0].action, 'status');
    assert.equal(p.requests[0].appID, 620);
    p.reply({ configured: false, ready: false });
    await flush();
    let button = p.host.children[0].querySelector('button');
    assert.equal(button.querySelector('span').textContent, 'Add to library');
    assert.equal(p.host.children.length, 2, 'macSteam card is added above the untouched Steam purchase card');
    assert.equal(p.host.children[1].children[0], p.title, 'original game title retained');
    assert.equal(p.host.children[1].children[1], p.platforms, 'original platform icons retained');
    let stopped = false;
    const adding = button.listeners.click({ preventDefault() {}, stopImmediatePropagation() { stopped = true; } });
    assert.ok(stopped, 'purchase click must not reach Steam purchase handlers');
    assert.equal(p.requests[0].action, 'add');
    assert.equal(button.disabled, true);
    await button.listeners.click({ preventDefault() {}, stopImmediatePropagation() {} });
    assert.equal(p.requests.length, 1, 'double clicks cannot duplicate downloads');
    p.reply({ ready: true });
    await adding;
    assert.equal(button.querySelector('span').textContent, 'Install');
    assert.equal(p.location.href, 'https://store.steampowered.com/app/620/Portal_2/', 'adding must keep the current Store document');
    const installing = button.listeners.click({ preventDefault() {}, stopImmediatePropagation() {} });
    assert.equal(p.requests[0].action, 'status', 'Install checks the folder before Steam downloads it again');
    p.reply({ ready: true, installed: false });
    await installing;
    assert.equal(p.location.href, 'steam://install/620');

    // An added game also offers the restart that loads its achievements, next to
    // Install: the card asks for it and leaves the page to Steam.
    const restart = p.host.children[0].querySelectorAll('button')
        .find(b => b.children[0].textContent === 'Restart');
    assert.ok(restart, 'added games offer “Restart”');
    assert.notEqual(restart.style.display, 'none', 'the restart button is shown once added');
    assert.ok(restart.className.startsWith(button.className),
        'the restart button is built on the Install button’s class, so the two are the same size');
    const restarting = restart.listeners.click({ preventDefault() {}, stopImmediatePropagation() {} });
    assert.equal(p.requests.at(-1).action, 'restart', 'the button asks for a Steam restart');
    assert.equal(restart.disabled, true, 'a second click cannot ask for another restart');
    p.reply({ restarting: true }); await restarting; await flush();
    assert.equal(restart.querySelector('span').textContent, 'Restart');
    assert.equal(p.location.href, 'steam://install/620', 'the restart does not navigate the page itself');

    // A game macSteam put in the library can be taken back out from the card.
    const remove = p.host.children[0].querySelectorAll('button')
        .find(b => b.children[0].textContent === 'Remove from Steam');
    assert.ok(remove, 'the card offers “Remove from Steam”');
    assert.notEqual(remove.style.display, 'none', 'the remove button is shown for a game macSteam added');
    const removing = remove.listeners.click({ preventDefault() {}, stopImmediatePropagation() {} });
    await flush();
    assert.equal(p.requests.at(-1).action, 'remove', 'the button asks macSteam to remove the game');
    p.reply({ configured: false, ready: false }); await removing; await flush();
    assert.equal(remove.style.display, 'none', 'the remove button goes away once the game is out');
    assert.ok(p.host.children[0].children.some(c => c.textContent
        && c.textContent.startsWith('Removed from macSteam')), 'the card says the game was removed');

    // Removing leaves a plain restart, which is what makes Steam drop the title.
    const plain = p.host.children[0].querySelectorAll('button')
        .find(b => b.children[0].textContent === 'Restart Steam');
    assert.ok(plain, 'the card offers a “Restart Steam” after a removal');
    assert.notEqual(plain.style.display, 'none', 'the restart button is shown after a removal');
    const restartingPlain = plain.listeners.click({ preventDefault() {}, stopImmediatePropagation() {} });
    assert.equal(p.requests.at(-1).action, 'restart-plain', 'it asks for a plain restart, not the achievements one');
    p.reply({ restarting: true }); await restartingPlain; await flush();

    // A game that was already in the library when the page opened gets no
    // Restart: there is nothing a restart would still be finishing for it.
    const already = page();
    already.reply({ configured: true, ready: true });
    await flush();
    const stale = already.host.children[0].querySelectorAll('button')
        .find(b => b.children[0].textContent === 'Restart');
    assert.ok(stale, 'the card still carries a restart button');
    assert.equal(stale.style.display, 'none',
        'an already-added game offers no Restart button');

    const failed = page();
    failed.reply({ ready: false }); await flush();
    button = failed.host.children[0].querySelector('button');
    const operation = button.listeners.click({ preventDefault() {}, stopImmediatePropagation() {} });
    failed.reply({ error: 'Download failed' }); await operation;
    assert.equal(button.querySelector('span').textContent, 'Add to library');
    assert.equal(button.disabled, false);
    assert.equal(failed.host.children[0].children.find(c => c.role === 'status').textContent, 'Download failed');
    vm.runInContext(source, failed.context);
    assert.equal(failed.host.children.length, 2, 'reinjection must not duplicate controls');
    failed.location.pathname = '/app/400/Portal/';
    failed.mutation();
    assert.equal(failed.requests[0].appID, 400, 'same-document navigation updates the AppID');
    failed.reply({ ready: true }); await flush();
    assert.equal(failed.host.children[0].querySelector('button').querySelector('span').textContent, 'Install');
    // An already-installed game keeps its card (it is the game's hub), but says it is
    // already in the library and hides the install button.
    const text = el => (el.textContent ?? '') + (el.children || []).map(text).join('');
    const owned = page();
    owned.reply({ configured: true, ready: true, installed: true }); await flush();
    const ownedCard = owned.host.children[0];
    assert.match(text(ownedCard), /In your library, added with/, 'installed game says where it is');
    assert.notEqual(ownedCard.querySelector('button').querySelector('span').textContent, 'Install');
    assert.equal(ownedCard.querySelector('.btn_addtocart').style.display, 'none',
        'installed game hides the install button');
    assert.ok(!/Ready to install/.test(text(ownedCard)), 'no visible "Ready to install" text');
    owned.events.focus.forEach(fn => fn());
    assert.equal(owned.requests[0].action, 'status', 'focus re-checks the install state');
    owned.reply({ configured: true, ready: true, installed: false }); await flush();
    assert.equal(ownedCard.querySelector('.btn_addtocart').style.display, '', 'uninstalling brings the button back');
    assert.equal(ownedCard.querySelector('button').querySelector('span').textContent, 'Install');
    owned.events.focus.forEach(fn => fn());
    owned.reply({ configured: true, ready: true, installed: true }); await flush();
    assert.equal(ownedCard.querySelector('.btn_addtocart').style.display, 'none', 'installing hides the button again');
    const foreign = page('https://example.com/app/620/');
    assert.equal(foreign.requests.length, 0);
    assert.equal(foreign.host.children[0].querySelector('.game_purchase_action'), foreign.original);
    const home = page('https://store.steampowered.com/');
    assert.equal(home.requests.length, 0);
    home.location.pathname = '/app/1234567/'; home.mutation();
    assert.equal(home.requests[0].appID, 1234567);
    home.reply({ ready: false }); await flush();
    console.log('Store UI: passed (Add → Install, installed card keeps its hub, native install URL, duplicate clicks, errors, reinjection, navigation, origin)');
})().catch(error => { console.error(error); process.exit(1); });
