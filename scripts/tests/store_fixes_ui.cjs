// Store-page game-fixes card: which buttons show for not applied / applied / drifted fixes,
// and the privacy-settings button when macOS blocks the write.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('macsteam-app/Sources/MacsteamApp/Resources/hubcap-store.js', 'utf8');

class Element {
    constructor(tag) { this.tag = tag; this.children = []; this.listeners = {}; this.style = {}; this.isConnected = false; }
    append(...kids) { kids.forEach(k => { this.children.push(k); k.parent = this; k.isConnected = this.isConnected; }); }
    appendChild(kid) { this.append(kid); return kid; }
    after(node) { const at = this.parent.children.indexOf(this); this.parent.children.splice(at + 1, 0, node); node.parent = this.parent; node.isConnected = this.isConnected; }
    prepend(kid) { this.children.unshift(kid); kid.parent = this; kid.isConnected = this.isConnected; }
    remove() { this.isConnected = false; if (this.parent) this.parent.children.splice(this.parent.children.indexOf(this), 1); }
    setAttribute(key, value) { this[key] = value; }
    addEventListener(name, fn) {
        // A real click always carries an event; supply one when the test fires it.
        this.listeners[name] = ev => fn(ev ?? {
            preventDefault() {}, stopPropagation() {}, stopImmediatePropagation() {},
        });
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
const flush = () => new Promise(resolve => setImmediate(resolve));

function page() {
    const events = {}, sent = [];
    const host = new Element('purchase'); host.isConnected = true;
    const window = { macsteamHubcap: text => sent.push(JSON.parse(text)), addEventListener(n, f) { (events[n] ||= []).push(f); } };
    const head = new Element('head');
    const document = { title: 'Portal 2 on Steam', head,
        // Only the purchase block is on this fake page: the store's platform icons
        // would be found here too if every selector answered.
        querySelector: selector => selector.startsWith('#game_area_purchase')
            || selector.includes('.game_area_purchase_game:not(') ? host : null,
        createElement: t => new Element(t),
        getElementById: id => head.children.find(child => child.id === id) || null,
        createTextNode: t => { const n = new Element('#text'); n.textContent = t; return n; } };
    const context = vm.createContext({ window, document, location: new URL('https://store.steampowered.com/app/620/Portal_2/'),
        setTimeout, clearTimeout, setInterval: () => 0,
        // Trees that also carry the Add/Install card observe the document.
        MutationObserver: class { observe() {} } });
    vm.runInContext(source, context);
    const answer = async (action, reply) => {
        const i = sent.findIndex(r => r.action === action);
        assert.ok(i >= 0, `expected a ${action} request, saw ${JSON.stringify(sent.map(r => r.action))}`);
        const [request] = sent.splice(i, 1);
        window.__macsteamHubcap.reply(request.id, reply); await flush();
    };
    const card = () => host.children.find(c => c.id === 'macsteam-fixes');
    const buttons = () => card() ? card().querySelectorAll('button') : [];
    const labels = () => buttons().map(b => b.children[0].textContent).sort();
    // The status line sits inside the card's rows box, so search the whole card.
    const status = () => card().querySelectorAll('div').find(c => c.role === 'status');
    const focus = () => events.focus.forEach(fn => fn());
    return { sent, answer, buttons, labels, status, focus, host };
}
const oneFix = flags => ({ gameInstalled: true, manifestInstalled: false,
    fixes: [{ id: 'f1', title: 'Online fix', hasFix: true, hasManifest: false, ...flags }] });

(async () => {
    const p = page();
    await p.answer('fixes', oneFix({ applied: false }));
    assert.deepEqual(p.labels(), ['Install fix'], 'not applied: Install only');

    // "Install fix" installs from the page itself and reports the outcome.
    const installing = p.buttons()[0].listeners.click();
    assert.equal(p.sent.at(-1).action, 'fix-install');
    assert.equal(p.status().textContent, 'Installing the fix… this can take a minute.');
    await p.answer('fix-install', oneFix({ applied: false }));
    await installing; await flush();
    assert.equal(p.status().textContent, 'Fixes are successfully installed!');

    // A failure says so, so nobody waits on a download that is not coming.
    p.focus(); await p.answer('fixes', oneFix({ applied: false }));
    const failing = p.buttons()[0].listeners.click();
    await p.answer('fix-install', { error: 'lua.tools returned HTTP 503.' });
    await failing; await flush();
    assert.equal(p.status().textContent,
        'The fixes failed to install — lua.tools returned HTTP 503.');

    p.focus(); await p.answer('fixes', oneFix({ applied: true, drifted: false }));
    assert.deepEqual(p.labels(), ['Undo fix'], 'applied: Undo only');
    p.focus(); await p.answer('fixes', oneFix({ applied: true, drifted: true }));
    assert.deepEqual(p.labels(), ['Reinstall fix', 'Remove fix'], 'files overwritten by a game update: Reinstall and Remove');
    p.focus(); await p.answer('fixes', oneFix({ applied: false }));
    assert.deepEqual(p.labels(), ['Install fix'], 'Undo disappears once the fix is gone (game deleted)');

    // Undo writes into the game folder as well, so a blocked write still offers the pane.
    p.focus(); await p.answer('fixes', oneFix({ applied: true, drifted: false }));
    const undoing = p.buttons()[0].listeners.click();
    assert.equal(p.sent.at(-1).action, 'fix-undo');
    await p.answer('fix-undo', { error: 'macOS is blocking macSteam', permission: 'Privacy_AllFiles', permissionTitle: 'Full Disk Access' });
    await undoing; await flush();
    assert.ok(p.labels().includes('Open Full Disk Access'), 'offers the privacy pane');
    p.buttons().find(b => b.children[0].textContent === 'Open Full Disk Access').listeners.click();
    assert.deepEqual([p.sent.at(-1).action, p.sent.at(-1).fixID], ['fix-permissions', 'Privacy_AllFiles']);

    // A LuaTools fix carrying the OnlineFix (its "Online Fix" tag) is the one to use, so the
    // OnlineFix card says so and makes its own install a deliberate "Install anyway".
    const rec = page();
    await rec.answer('fixes', { gameInstalled: true, manifestInstalled: false,
        fixes: [{ id: 'online-fix:1', title: 'Online Fix', onlineFix: true,
            hasFix: true, hasManifest: false, applied: false }] });
    await rec.answer('onlinefix-status', { inList: false, fixInstalled: false, gameInstalled: true });
    const text = el => (el.textContent ?? '') + (el.children || []).map(text).join('');
    const online = rec.host.children.find(c => c.id === 'macsteam-onlinefix');
    assert.ok(online, 'the OnlineFix card is shown');
    assert.match(text(online), /we recommend using that one instead/,
        'the OnlineFix card recommends the LuaTools fix');
    assert.ok(online.querySelectorAll('button').some(b => b.children[0].textContent === 'Install anyway'),
        'the OnlineFix card installs only deliberately');
    assert.match(text(rec.host.children.find(c => c.id === 'macsteam-fixes')),
        /Includes the OnlineFix/, 'the LuaTools row says it carries the OnlineFix');

    // A re-check that comes back with the same data must leave the card alone:
    // rebuilding it replaces the button under the pointer and the click is lost.
    const fixesCard = () => rec.host.children.find(c => c.id === 'macsteam-fixes');
    const before = fixesCard();
    rec.focus();
    await rec.answer('fixes', { gameInstalled: true, manifestInstalled: false,
        fixes: [{ id: 'online-fix:1', title: 'Online Fix', onlineFix: true,
            hasFix: true, hasManifest: false, applied: false }] });
    assert.equal(fixesCard(), before, 'an unchanged re-check keeps the same card and buttons');

    // Clicks are claimed from Steam's purchase handlers, or the first one goes nowhere.
    let stopped = false, prevented = false;
    fixesCard().querySelectorAll('button')[0].listeners.mousedown({
        stopPropagation() { stopped = true; },
    });
    assert.ok(stopped, 'mousedown does not reach Steam');
    fixesCard().querySelectorAll('button')[0].listeners.click({
        preventDefault() { prevented = true; },
        stopPropagation() {},
        stopImmediatePropagation() { stopped = true; },
    });
    assert.ok(prevented && stopped, 'click is claimed before Steam sees it');

    // Without one, the card is a plain Install with no recommendation.
    const plain = page();
    await plain.answer('fixes', { gameInstalled: true, manifestInstalled: false,
        fixes: [{ id: 'f1', title: 'Denuvo fix', hasFix: true, hasManifest: false, applied: false }] });
    await plain.answer('onlinefix-status', { inList: true, fixInstalled: false, gameInstalled: true });
    const plainOnline = plain.host.children.find(c => c.id === 'macsteam-onlinefix');
    assert.ok(plainOnline.querySelectorAll('button').some(b => b.children[0].textContent === 'Install'),
        'no OnlineFix in LuaTools: the card installs normally');
    assert.doesNotMatch(text(plainOnline), /recommend/, 'no recommendation without a LuaTools OnlineFix');

    console.log('Store fixes UI: passed (install outcome, undo/reinstall states, stale Undo gone, privacy button, OnlineFix recommendation)');
    process.exit(0);   // unanswered bridge requests keep timers alive
})().catch(error => { console.error(error); process.exit(1); });
