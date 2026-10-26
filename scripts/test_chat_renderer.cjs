// Run with Playwright available in the development environment, never in the app.
// Linux Chromium uses HTTPS in place of WKURLSchemeHandler's dgg-asset transport.
const { chromium } = require('playwright');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { promisify } = require('node:util');
const execFile = promisify(require('node:child_process').execFile);

(async () => {
  const output = process.env.CHAT_RESULTS_DIR || path.join(os.tmpdir(), 'streamstiny-chat-tests');
  await fs.mkdir(output, { recursive: true });
  const downloads = new Map(), requests = new Set(), failures = [];
  let active = 0;
  const waiting = [];
  async function fetch(url, revalidate = false) {
    if (downloads.has(url)) return downloads.get(url);
    const task = (async () => {
      if (active >= 4) await new Promise(resolve => waiting.push(resolve));
      active++;
      try {
        const name = crypto.createHash('sha256').update(url).digest('hex');
        const file = path.join(output, name);
        let body, mime;
        try {
          if (revalidate) throw new Error('Refresh discovery');
          body = await fs.readFile(file); mime = await fs.readFile(file + '.mime', 'utf8');
        }
        catch {
          const result = await execFile('curl', ['--fail', '--silent', '--show-error', '--location', '--max-time', '30', '--user-agent', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15', '--output', file, '--write-out', '%{content_type}', url]);
          body = await fs.readFile(file); mime = result.stdout;
          await fs.writeFile(file + '.mime', mime);
        }
        return { body, contentType: mime };
      } finally { active--; waiting.shift()?.(); }
    })();
    downloads.set(url, task);
    return task;
  }
  const html = (await fetch('https://www.destiny.gg/embed/chat', true)).body.toString();
  const base = html.match(/data-cdn=["']([^"']+)["']/)[1];
  const version = html.match(/data-cache-key=["']([^"']*)["']/)[1];
  const catalog = JSON.parse((await fetch(`${base}/emotes/emotes.json?_=${version}`)).body);
  const flairs = JSON.parse((await fetch(`${base}/flairs/flairs.json?_=${version}`)).body);
  const [emotes, badges] = await Promise.all(['emotes/emotes.css', 'flairs/flairs.css'].map(async file => {
    const url = `${base}/${file}?_=${version}`;
    return (await fetch(url)).body.toString().replace(/url\(\s*(?:"([^"]*)"|'([^']*)'|([^\s)]*))\s*\)/g, (match, a, b, c) => {
      const value = a ?? b ?? c;
      return value.startsWith('#') || value.startsWith('data:') ? match : `url("${new URL(value, url).href}")`;
    });
  }));
  const swift = await fs.readFile('Streamstiny/ChatWebView.swift', 'utf8');
  const basic = swift.match(/<style>\n([\s\S]*?)<\/style><style id="native-styles">/)[1];
  const source = (await fs.readFile('Streamstiny/ChatRenderer.js', 'utf8')).replace("address.replace(/^https:/, 'dgg-asset:')", 'address');
  const document = `<meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none';script-src 'nonce-test';style-src 'unsafe-inline';img-src https: data:"><style>${basic}</style><style id="native-styles"></style><main id="content"></main><script nonce="test">window.events=[];window.webkit={messageHandlers:{chat:{postMessage:data=>events.push(data)}}};${source}</script>`;
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || '/usr/bin/chromium', headless: true, args: ['--no-sandbox'] });
  try {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
    const errors = [];
    page.on('pageerror', error => errors.push(String(error)));
    await page.route(/^https:\/\//, async route => {
      const url = route.request().url(); requests.add(url);
      try { await route.fulfill(await fetch(url)); }
      catch (error) { failures.push({ url, error: String(error) }); await route.fulfill({ status: 404, body: '' }); }
    });
    await page.setContent(document);
    const manifest = catalog.map(item => ({ ...item, resource: item.image[0]?.url || '' }));
    const init = { stylesheet: emotes + '\n' + badges, manifest, favorites: [], account: { tier: 5, patreonMember: true, privileged: true, animate: true } };
    const started = performance.now();
    await page.evaluate(data => ChatRenderer.update({ ...data, mode: 'picker' }), init);
    await page.waitForFunction(() => document.querySelector('.emote:not(.not-visible)'));
    await page.waitForTimeout(1500);
    const opening = performance.now() - started;
    assert.equal(await page.locator('.emote-item').count(), catalog.length, 'No collection entries may be dropped');
    const coldRequests = requests.size;
    assert(coldRequests > 0 && coldRequests < catalog.length / 2, 'Load visible picker assets without fetching the entire collection');
    const builds = await page.evaluate(() => ChatRenderer.metrics().pickerBuilds);
    await page.evaluate(() => { for (let i = 0; i < 50; i++) ChatRenderer.assetFinished('https://example.invalid/not-an-asset.png', true); });
    assert.equal(await page.evaluate(() => ChatRenderer.metrics().pickerBuilds), builds, 'Image completion must not rebuild the picker');
    const searchTimes = [];
    for (const query of ['pepe', 'LISTEN', 'no-matching-emote-92834', '']) {
      const elapsed = await page.evaluate(query => { const start = performance.now(); ChatRenderer.setSearch(query); return performance.now() - start; }, query);
      searchTimes.push(elapsed);
      if (query === 'LISTEN') assert(await page.locator('.emote-item:not([hidden])').count() > 0);
      if (query.startsWith('no-matching')) assert.equal(await page.locator('.emote-item:not([hidden])').count(), 0);
    }
    await page.screenshot({ path: path.join(output, 'picker.png') });
    function markup(name) {
      const item = catalog.find(item => item.prefix === name); assert(item, `${name} must exist in authoritative metadata`);
      return `<div title="${name}" class="emote ${name} not-visible" data-resource="${item.image[0].url}">${name} </div>`;
    }
    const names = ['Listening', 'pepeW', 'PepoPunch'];
    const rows = names.map((name, index) => ({ id: String(index), html: `<span class="text">${markup(name)}</span>`, classes: 'msg-chat msg-user', username: 'benchmark', accessibility: name }));
    await page.evaluate(data => ChatRenderer.update({ mode: 'chat', records: data, ids: data.map(item => item.id) }), rows);
    await page.waitForTimeout(1200);
    const dimensions = {};
    for (const name of names) {
      const element = page.locator(`.emote.${name}`);
      dimensions[name] = await element.evaluate(node => ({ width: node.offsetWidth, height: node.offsetHeight, image: getComputedStyle(node).backgroundImage, animation: getComputedStyle(node).animation }));
      const expected = catalog.find(item => item.prefix === name).image[0];
      assert.equal(dimensions[name].height, expected.height);
      if (name !== 'PepoPunch') assert.equal(dimensions[name].width, expected.width);
    }
    async function readAt(y) {
      await page.evaluate(y => {
        dispatchEvent(new PointerEvent('pointerdown'));
        scrollTo(0, y);
        dispatchEvent(new PointerEvent('pointerup'));
      }, y);
    }
    // Preserve exact nodes and animation objects across incoming unrelated messages.
    const padding = Array.from({ length: 30 }, (_, index) => ({ id: String(index + 3), html: '<span class="text">padding</span>', classes: 'msg-chat msg-user', username: 'benchmark', accessibility: 'padding' }));
    await page.evaluate(records => ChatRenderer.update({ records, ids: [...Array(33)].map((_, index) => String(index)) }), padding);
    await readAt(0); await page.waitForTimeout(100);
    await page.evaluate(() => { window.originalEmote = document.querySelector('.PepoPunch'); window.originalAnimation = originalEmote.getAnimations()[0]; });
    for (let i = 33; i < 133; i++) {
      await page.evaluate(row => ChatRenderer.update({ records: [row], ids: [...Array(Number(row.id) + 1)].map((_, index) => String(index)) }), { id: String(i), html: '<span class="text">new message</span>', classes: 'msg-chat msg-user', username: 'benchmark', accessibility: 'new message' });
    }
    assert(await page.evaluate(() => originalEmote === document.querySelector('.PepoPunch') && originalAnimation === originalEmote.getAnimations()[0]), 'Unrelated messages must retain emote and animation identity');
    const combo = { ...rows[2], html: rows[2].html + ' <span class="combo"></span>', combo: 3, comboGroup: 'x2' };
    await page.evaluate(record => { ChatRenderer.update({ records: [record] }); window.comboEmote = document.querySelector('.PepoPunch'); window.comboAnimation = comboEmote.getAnimations()[0]; }, combo);
    await page.evaluate(record => ChatRenderer.update({ records: [record] }), { ...combo, combo: 4 });
    assert(await page.evaluate(() => comboEmote === document.querySelector('.PepoPunch') && comboAnimation === comboEmote.getAnimations()[0]), 'Combo count updates must not restart the emote');
    assert.equal(await page.locator('.combo').textContent(), '4× combo');
    const menus = await page.evaluate(() => events.filter(event => event.action === 'menu').length);
    await page.locator('.PepoPunch').dispatchEvent('pointerdown', { pointerType: 'touch', clientX: 20, clientY: 20 });
    await page.waitForTimeout(600);
    await page.locator('.PepoPunch').dispatchEvent('contextmenu', { clientX: 20, clientY: 20 });
    assert.equal(await page.evaluate(() => events.filter(event => event.action === 'menu').length), menus + 1, 'A touch long press must open exactly one native menu');
    await page.evaluate(() => {
      const node = document.querySelector('.PepoPunch'); node.style.animation = 'none'; void node.offsetWidth; node.style.animation = '';
      node.getAnimations().forEach(animation => { animation.pause(); animation.currentTime = 750; });
      window.virtualEmote = node; window.scrollTo(0, document.scrollingElement.scrollHeight);
    });
    await page.waitForTimeout(200);
    assert.equal(await page.locator('.PepoPunch').count(), 0, 'Distant rich content must leave layout');
    await readAt(0); await page.waitForTimeout(200);
    assert(await page.evaluate(() => virtualEmote === document.querySelector('.PepoPunch')), 'Scrolling must restore the same emote nodes');
    assert(await page.locator('.PepoPunch').evaluate(node => node.getAnimations().every(animation => animation.currentTime >= 750)), 'Offscreen sprite animations must retain their frame times');
    await page.locator('.PepoPunch').evaluate(node => node.getAnimations().forEach(animation => animation.currentTime = 4500));
    await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight)); await page.waitForTimeout(200);
    await readAt(0); await page.waitForTimeout(200);
    assert.equal(await page.locator('.PepoPunch').evaluate(node => node.getAnimations().length), 0, 'Finished finite animations must stay finished after scrolling');
    await readAt(0); await page.waitForTimeout(200);
    // A separate DOM uses the native formatter structure and unmodified first-party rules.
    const oracle = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
    await oracle.route(/^https:\/\//, async route => route.fulfill(await fetch(route.request().url())));
    await oracle.setContent(`<style>${basic}\n${emotes}\n${badges}</style><div class="msg-chat msg-user"><span class="text">${markup('PepoPunch').replace(' not-visible', '')} ${markup('PepoPunch').replace(' not-visible', '')}</span></div>`);
    await page.evaluate(html => ChatRenderer.update({ records: [{ id: 'punch', html: `<span class="text">${html} ${html}</span>`, classes: 'msg-chat msg-user', username: 'benchmark', accessibility: 'PepoPunch pair' }], ids: ['punch'] }), markup('PepoPunch'));
    await page.waitForTimeout(300);
    const sequences = [];
    for (const time of [0, 125, 375, 875, 1100, 2750, 4500]) {
      const sample = async current => current.evaluate(time => {
        document.getAnimations().forEach(animation => { animation.pause(); animation.currentTime = time; });
        return [...document.querySelectorAll('.PepoPunch')].map(node => {
          const css = getComputedStyle(node);
          return { position: css.backgroundPosition, transform: css.transform, width: css.width, duration: css.animationDuration, delay: css.animationDelay, iterations: css.animationIterationCount, timing: css.animationTimingFunction };
        });
      }, time);
      const actual = await sample(page), expected = await sample(oracle);
      assert.deepEqual(actual, expected, `PepoPunch native CSS position/transform/loop mismatch at ${time} ms`);
      sequences.push({ time, actual });
      await page.screenshot({ path: path.join(output, `PepoPunch-${time}.png`) });
    }
    assert.notEqual(sequences[0].actual[0].position, sequences[1].actual[0].position, 'PepoPunch must advance in stepped frames');
    await oracle.close();
    // Animated PNG/GIF must actually change pixels, not merely return HTTP 200.
    const animationHashes = {};
    for (const name of ['Listening', 'pepeW']) {
      await page.evaluate(record => ChatRenderer.update({ records: [record], ids: [record.id] }), rows.find(row => row.accessibility === name));
      await page.waitForTimeout(500);
      const hashes = new Set();
      for (let frame = 0; frame < 8; frame++) {
        const image = await page.locator('.emote.' + name).screenshot();
        hashes.add(crypto.createHash('sha256').update(image).digest('hex'));
        if (frame === 0) await fs.writeFile(path.join(output, name + '.png'), image);
        await page.waitForTimeout(150);
      }
      assert(hashes.size > 1, `${name} must animate, not display a static first frame`);
      animationHashes[name] = hashes.size;
    }
    // A failed response and a corrupt HTTP-200 image must both recover without
    // replacing unrelated message nodes or restarting their sprite animation.
    const recoveryRequests = [];
    const fixture = await fetch(catalog.find(item => item.prefix === 'PepoPunch').image[0].url);
    await page.route(/^https:\/\/assets\.streamstiny\.invalid\/recover\.png/, async route => {
      recoveryRequests.push(route.request().url());
      if (recoveryRequests.length === 1) await route.fulfill({ status: 404, body: '' });
      else if (recoveryRequests.length === 2) await route.fulfill({ status: 200, contentType: 'image/png', body: 'corrupt image' });
      else await route.fulfill(fixture);
    });
    const recoveryURL = 'https://assets.streamstiny.invalid/recover.png';
    await page.evaluate(data => ChatRenderer.update(data), { stylesheet: init.stylesheet + `.emote.TestRecovery{background-image:url("${recoveryURL}");width:16px;height:16px}`,
      records: [{ id: 'recovery', html: `<span class="text">${markup('PepoPunch')} <div class="emote TestRecovery not-visible" data-resource="${recoveryURL}">TestRecovery </div></span>`, classes: 'msg-chat msg-user', username: 'test', accessibility: 'recovery' }], ids: ['recovery'] });
    await page.waitForFunction(() => document.querySelector('.TestRecovery.missing-asset'));
    await page.evaluate(() => { window.recoveryAnimation = document.querySelector('.PepoPunch').getAnimations()[0]; window.dispatchEvent(new Event('online')); });
    await page.waitForFunction(() => document.querySelector('.TestRecovery.missing-asset'));
    await page.evaluate(() => window.dispatchEvent(new Event('online')));
    await page.waitForFunction(() => !document.querySelector('.TestRecovery').classList.contains('missing-asset'));
    await page.waitForTimeout(100);
    assert.equal(recoveryRequests.length, 3, 'Retry only the failed asset, once per recovery event');
    assert.equal(new URL(recoveryRequests[2]).searchParams.getAll('__streamstiny_retry').length, 1, 'Repeated retries must not accumulate query markers');
    assert(await page.evaluate(() => recoveryAnimation === document.querySelector('.PepoPunch').getAnimations()[0]), 'Asset recovery must not restart unrelated animations');
    await page.evaluate(() => ChatRenderer.update({ active: false }));
    assert(await page.locator('.PepoPunch').evaluate(node => node.classList.contains('not-visible')), 'Background surfaces must suspend offscreen assets');
    await page.evaluate(() => ChatRenderer.update({ active: true }));
    await page.waitForFunction(() => !document.querySelector('.PepoPunch').classList.contains('not-visible'));
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.waitForFunction(() => document.querySelector('.PepoPunch canvas'));
    const frozen = await page.locator('.PepoPunch').screenshot();
    await page.locator('.PepoPunch canvas').evaluate(node => node.style.visibility = 'hidden');
    const blank = await page.locator('.PepoPunch').screenshot();
    assert.notDeepEqual(frozen, blank, 'Reduced-motion rendering must contain image pixels, not a blank canvas');
    await page.emulateMedia({ reducedMotion: 'no-preference' });
    await page.waitForFunction(() => !document.querySelector('.PepoPunch canvas'));
    const scaleImage = 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100" fill="red"/><rect x="25" y="25" width="50" height="50" fill="blue"/></svg>');
    await page.evaluate(data => ChatRenderer.update(data), { stylesheet: init.stylesheet + `.emote.TestScale{width:16px;height:16px;background-image:url("${scaleImage}");background-size:16px 16px;background-position:center}`,
      records: [{ id: 'scale', html: `<span class="text"><div class="emote TestScale not-visible" data-resource="${scaleImage}">TestScale</div></span>`, classes: 'msg-chat msg-user', username: 'test', accessibility: 'scale' }], ids: ['scale'] });
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.waitForFunction(() => document.querySelector('.TestScale canvas'));
    const pixels = await page.locator('.TestScale canvas').evaluate(canvas => {
      const context = canvas.getContext('2d');
      return { corner: [...context.getImageData(1, 1, 1, 1).data], center: [...context.getImageData(8, 8, 1, 1).data] };
    });
    assert.deepEqual(pixels, { corner: [255, 0, 0, 255], center: [0, 0, 255, 255] }, 'Frozen emotes must honor native background-size and percentage positioning');
    await page.emulateMedia({ reducedMotion: 'no-preference' });

    const history = Array.from({ length: 500 }, (_, index) => ({ id: 'history-' + index, html: `<span class="text">Message ${index}</span>`, classes: 'msg-chat msg-user', username: 'test', accessibility: 'history' }));
    await page.evaluate(rows => ChatRenderer.update({ records: rows, ids: rows.map(row => row.id) }), history);
    await readAt(1500); await page.waitForTimeout(100);
    const anchor = await page.evaluate(() => { const node = document.elementFromPoint(12, 2).closest('[data-message]'); return { id: node.dataset.message, y: node.getBoundingClientRect().y }; });
    await page.evaluate(ids => ChatRenderer.update({ records: [], ids }), history.slice(20).map(row => row.id));
    assert(Math.abs(await page.locator(`[data-message="${anchor.id}"]`).evaluate(node => node.getBoundingClientRect().y) - anchor.y) < 1, 'History pruning must preserve the reading position');
    assert.equal(await page.locator('[data-message]').count(), 480, 'Pruned messages must release their DOM nodes');
    const arriving = [0, 1, 2].map(i => ({ id: 'arriving-' + i, html: `<span class="text">Incoming ${i}</span>`, classes: 'msg-chat msg-user', username: 'test' }));
    const retainedIDs = history.slice(25).map(row => row.id).concat(arriving.map(row => row.id));
    const writesBeforeGesture = await page.evaluate(() => { window.dispatchEvent(new PointerEvent('pointerdown')); return ChatRenderer.metrics().scrollWrites; });
    await page.evaluate(data => ChatRenderer.update(data), { records: arriving, ids: retainedIDs, interacting: true });
    assert.equal(await page.locator('[data-message]').count(), retainedIDs.length, 'Incoming messages render immediately during scrolling');
    assert.equal(await page.evaluate(() => ChatRenderer.metrics().scrollWrites), writesBeforeGesture, 'Pruning must not interrupt touch scrolling with an offset write');
    assert(Math.abs(await page.locator(`[data-message="${anchor.id}"]`).evaluate(node => node.getBoundingClientRect().y) - anchor.y) < 1);
    await page.evaluate(() => window.dispatchEvent(new PointerEvent('pointerup')));
    await page.waitForFunction(() => !document.getElementById('content').style.paddingTop);
    assert(Math.abs(await page.locator(`[data-message="${anchor.id}"]`).evaluate(node => node.getBoundingClientRect().y) - anchor.y) < 1, 'One idle correction preserves the same reading anchor');
    const afterIdle = await page.evaluate(() => ChatRenderer.metrics().scrollWrites);
    assert.equal(afterIdle, writesBeforeGesture + 1);
    const appended = { id: 'append-only', html: '<span class="text">Another message</span>', classes: 'msg-chat msg-user', username: 'test' };
    await page.evaluate(data => ChatRenderer.update(data), { records: [appended], ids: retainedIDs.concat(appended.id) });
    assert.equal(await page.evaluate(() => ChatRenderer.metrics().scrollWrites), afterIdle, 'Appending below a reader needs no scroll correction');
    await page.evaluate(ids => {
      window.dispatchEvent(new PointerEvent('pointerdown'));
      ChatRenderer.update({ records: [], ids, interacting: true });
      ChatRenderer.update({ active: false });
    }, retainedIDs.slice(2).concat(appended.id));
    await page.waitForTimeout(180);
    assert.equal(await page.evaluate(() => ChatRenderer.metrics().scrollWrites), afterIdle, 'Backgrounding cancels pending gesture corrections');
    await page.evaluate(() => ChatRenderer.update({ active: true }));
    await page.waitForFunction(() => !document.getElementById('content').style.paddingTop);
    assert(Math.abs(await page.locator(`[data-message="${anchor.id}"]`).evaluate(node => node.getBoundingClientRect().y) - anchor.y) < 1, 'Foregrounding releases retained space without losing the anchor');
    const followingEvents = () => page.evaluate(() => events.filter(event => event.action === 'following'));
    assert.equal((await followingEvents()).at(-1).value, false, 'Reading old messages reports the canonical scroll state');
    await page.evaluate(() => {
      const immediate=window.scrollTo.bind(window);
      window.restoreImmediateScroll=()=>{window.scrollTo=immediate};
      window.scrollTo=(...args)=>setTimeout(()=>immediate(...args),40);
      ChatRenderer.scrollToBottom();
    });
    for (let batch = 0; batch < 12; batch++) {
      const row = { id: 'during-jump-' + batch, html: `<span class="text">Live ${batch}</span>`, classes: 'msg-chat msg-user', username: 'test' };
      await page.evaluate(record => ChatRenderer.update({ records: [record], ids: [...document.querySelectorAll('[data-message]')].map(node => node.dataset.message).concat(record.id) }), row);
      await page.waitForTimeout(25);
    }
    await page.waitForFunction(() => Math.abs(document.scrollingElement.scrollHeight - innerHeight - scrollY) < 2);
    await page.waitForFunction(() => events.filter(event=>event.action==='following').at(-1)?.value===true);
    await page.evaluate(() => restoreImmediateScroll());
    assert.equal((await followingEvents()).at(-1).value, true, 'The jump reaches the latest arrivals and resumes following');
    await readAt(800); await page.waitForTimeout(50);
    const beforeIdle = (await followingEvents()).length;
    await page.evaluate(() => ChatRenderer.update({ records: [] }));
    assert.equal((await followingEvents()).length, beforeIdle, 'Unchanged scroll state sends no redundant native messages');
    await page.evaluate(() => ChatRenderer.scrollToBottom());
    await page.waitForTimeout(35);
    await page.evaluate(() => { window.dispatchEvent(new PointerEvent('pointerdown')); window.scrollTo(0, 600); window.dispatchEvent(new PointerEvent('pointerup')); });
    await page.waitForTimeout(300);
    assert(Math.abs(await page.evaluate(() => scrollY) - 600) < 1, 'Touch scrolling cancels the jump immediately');
    await page.emulateMedia({ reducedMotion: 'reduce' });
    const writesBeforeSnap = await page.evaluate(() => { const count=ChatRenderer.metrics().scrollWrites; ChatRenderer.scrollToBottom(); return count; });
    await page.waitForFunction(() => Math.abs(document.scrollingElement.scrollHeight - innerHeight - scrollY) < 2);
    assert.equal(await page.evaluate(() => ChatRenderer.metrics().scrollWrites), writesBeforeSnap + 1, 'Reduce Motion uses one immediate scroll');
    await page.emulateMedia({ reducedMotion: 'no-preference' });
    await readAt(600); await page.waitForTimeout(50);
    const neighbor = await page.evaluate(() => {
      const original=document.elementFromPoint(12,2).closest('[data-message]'), next=original.nextElementSibling;
      return { removed: original.dataset.message, id: next.dataset.message, top: next.getBoundingClientRect().top };
    });
    await page.evaluate(removed => ChatRenderer.update({ records: [], ids: [...document.querySelectorAll('[data-message]')].map(node=>node.dataset.message).filter(id=>id!==removed) }), neighbor.removed);
    assert(Math.abs(await page.locator(`[data-message="${neighbor.id}"]`).evaluate(node => node.getBoundingClientRect().top) - neighbor.top) < 1, 'Removing the reading anchor preserves its nearest retained neighbor');
    await page.route('https://assets.streamstiny.invalid/preview.png', route => route.fulfill(fixture));
    const preview = { id: 'preview', html: '<img class="preview not-visible" width="200" height="120" data-resource="https://assets.streamstiny.invalid/preview.png">', classes: 'msg-chat msg-user', username: 'test', accessibility: 'preview' };
    await page.evaluate(record => ChatRenderer.update({ records: [record], ids: [record.id] }), preview);
    await page.waitForFunction(() => document.querySelector('.preview').naturalWidth > 0);
    await page.evaluate(() => ChatRenderer.update({ active: false }));
    assert.equal(await page.locator('.preview').getAttribute('src'), null, 'Background previews must release their image requests');
    await page.evaluate(() => ChatRenderer.update({ active: true }));
    await page.waitForFunction(() => document.querySelector('.preview').naturalWidth > 0);
    await page.evaluate(() => ChatRenderer.update({ mode: 'picker', account: { tier: 0, patreonMember: false, privileged: false, animate: true } }));
    const patreon = manifest.find(item => item.patreonOnly);
    if (patreon) assert(await page.locator(`button[data-name="${patreon.prefix}"]`).isDisabled());
    const decoding = await page.evaluate(async catalog => {
      let next = 0;
      const errors = [], dimensions = [];
      await Promise.all(Array.from({ length: 4 }, async () => {
        while (next < catalog.length) {
          const item = catalog[next++], image = new Image();
          try {
            image.src = item.image[0].url;
            await image.decode();
            if (!image.naturalWidth || !image.naturalHeight) throw new Error('Empty decoded image');
            dimensions.push({ name: item.prefix, width: image.naturalWidth, height: image.naturalHeight, mime: item.image[0].mime });
          } catch (error) { errors.push({ name: item.prefix, url: item.image[0].url, error: String(error) }); }
        }
      }));
      return { dimensions, errors };
    }, catalog);
    assert.deepEqual(decoding.errors, [], 'Every current catalog image must decode, including APNG/GIF/AVIF');
    const profile = process.env.CHAT_PROFILE ? await page.context().newCDPSession(page) : null;
    if (profile) await profile.send('Tracing.start', { categories: 'devtools.timeline', transferMode: 'ReturnAsStream' });
    const stress = await page.evaluate(async ({ markup, batches }) => {
      ChatRenderer.update({ mode: 'chat', records: [], ids: [] });
      const times = [], ids = [], start = performance.now();
      for (let batch = 0; batch < batches; batch++) {
        const records = Array.from({ length: 50 }, (_, index) => {
          const id = String(batch * 50 + index); ids.push(id);
          return { id, html: '<span class="text">Message ' + id + ' ' + markup[index % markup.length] + '</span>', classes: 'msg-chat msg-user', username: 'stress', accessibility: 'stress' };
        });
        if (ids.length > 5000) ids.splice(0, ids.length - 5000);
        const tick = performance.now(); ChatRenderer.update({ records, ids }); times.push(performance.now() - tick);
        await new Promise(requestAnimationFrame);
      }
      times.sort((a, b) => a - b);
      const result = { messages: batches * 50, elapsed_ms: performance.now() - start, median_update_ms: times[Math.floor(times.length / 2)], p95_update_ms: times[Math.floor(times.length * .95)], max_update_ms: times[times.length - 1], retained: ChatRenderer.metrics() };
      ChatRenderer.update({ records: [], ids: [] });
      await new Promise(resolve => setTimeout(resolve, 100));
      result.released = ChatRenderer.metrics(); return result;
    }, { markup: names.map(markup), batches: Math.max(100, Number(process.env.CHAT_STRESS_BATCHES) || 500) });
    if (profile) {
      const complete = new Promise(resolve => profile.once('Tracing.tracingComplete', resolve));
      await profile.send('Tracing.end'); const { stream } = await complete;
      const traceFile = path.join(output, 'trace.json'); await fs.writeFile(traceFile, '');
      while (true) {
        const chunk = await profile.send('IO.read', { handle: stream });
        await fs.appendFile(traceFile, chunk.base64Encoded ? Buffer.from(chunk.data, 'base64') : chunk.data);
        if (chunk.eof) break;
      }
      await profile.send('IO.close', { handle: stream });
    }
    assert.equal(stress.retained.nodes, 5000, 'Long sessions must retain only the configured history');
    assert(stress.retained.mounted < 150, 'Only nearby rich message content should participate in layout');
    assert.equal(stress.released.nodes, 0); assert.equal(stress.released.resources, 0); assert.equal(stress.released.decoded, 0, 'Pruned history must release resource/probe bookkeeping');
    const metrics = { catalog_count: catalog.length, flair_count: flairs.length, cache_key: version, cdn: base,
      picker_ms_including_fixed_1500ms_settle: opening, initial_unique_asset_requests: coldRequests,
      search_ms: searchTimes, dimensions, sequences, animated_distinct_frames: animationHashes, recovery_requests: recoveryRequests,
      renderer: await page.evaluate(() => ChatRenderer.metrics()), long_session: stress, full_collection_decoding: decoding, failures, errors,
      note: 'Chromium CSS/DOM conformance checks with HTTPS transport. Does not measure iPhone FPS, WKURLSchemeHandler, or UIKit presentation latency.' };
    assert.deepEqual(errors, [], 'Renderer must not throw JavaScript errors');
    await fs.writeFile(path.join(output, 'results.json'), JSON.stringify(metrics, null, 2));
    console.log(JSON.stringify(metrics, null, 2));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
