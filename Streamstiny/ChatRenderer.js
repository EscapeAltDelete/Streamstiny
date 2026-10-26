/* Application-owned DOM renderer. First-party styles supply all emote animations. */
(() => {
  'use strict';
  const content = document.getElementById('content');
  const style = document.getElementById('native-styles');
  const records = new Map();
  const resources = new Map();
  const failedResources = new Set();
  const decoded = new Map(), resourceVersions = new Map();
  let manifest = [], manifestVersion = 0, favorites = new Set(), account = {}, mode = 'chat';
  let search = '', pickerSignature = '', profileSignature = '', following = true;
  let active = true, animations = true, anchor = null, holding = false;
  let holdTimer = 0, startPoint = null;
  let recovery = 0, retryVersion = 0;
  let rowWidth = window.innerWidth;
  let touching = false, wheelUntil = 0, retiredHeight = 0, retireTimer = 0;
  let scrollAnimation = 0, pendingPin = false;
  const stats = { updates: 0, inserted: 0, replaced: 0, removed: 0, pickerBuilds: 0, assetFailures: 0, scrollWrites: 0 };
  const send = data => window.webkit?.messageHandlers?.chat?.postMessage(data);
  const proxy = address => address.replace(/^https:/, 'dgg-asset:');
  const allows = item => account.privileged || (item.patreonOnly ? account.patreonMember : item.minimumSubTier <= (account.tier || 0));
  const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  const bottomOffset = viewport => Math.max(0, viewport.scrollHeight - viewport.clientHeight);

  function rememberAnchor(scrolled = false) {
    const viewport = document.scrollingElement;
    const distance = bottomOffset(viewport) - viewport.scrollTop;
    // WKWebView can acknowledge scrollTo after the next message update. Keep
    // that request's intent until it reaches the bottom or the user intervenes.
    if (pendingPin && (!scrolled || Math.abs(distance) > 1)) return;
    pendingPin = false;
    const next = distance <= 60;
    if (next !== following) {
      following = next;
      if (mode === 'chat') send({ action: 'following', value: following });
    }
    if (following) { anchor = null; return; }
    const node = document.elementFromPoint(12, 2)?.closest('[data-message]');
    if (node) anchor = { id: node.dataset.message, top: node.getBoundingClientRect().top };
  }
  function cancelScroll() { cancelAnimationFrame(scrollAnimation); scrollAnimation = 0; pendingPin = false; }
  function scrollToBottom() {
    if (!active || mode !== 'chat') return;
    cancelScroll();
    const viewport = document.scrollingElement, start = viewport.scrollTop, began = performance.now();
    const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
    function step(now) {
      const progress = reducedMotion ? 1 : Math.max(0, Math.min(1, (now - began) / 250));
      const target = start + (bottomOffset(viewport) - start) * (1 - (1 - progress) ** 3);
      if (progress === 1 && Math.abs(target - viewport.scrollTop) > 0.5) pendingPin = true;
      stats.scrollWrites++;
      window.scrollTo(0, target);
      if (progress < 1) scrollAnimation = requestAnimationFrame(step);
      else { scrollAnimation = 0; rememberAnchor(); }
    }
    scrollAnimation = requestAnimationFrame(step);
  }
  function restoreAnchor(saved, follow = following || pendingPin) {
    if (follow) {
      const viewport = document.scrollingElement;
      const bottom = bottomOffset(viewport);
      if (Math.abs(bottom - viewport.scrollTop) > 0.5) {
        pendingPin = true;
        stats.scrollWrites++; window.scrollTo(0, bottom);
      }
    }
    else if (saved) {
      const node = records.get(saved.id)?.node;
      const delta = node ? node.getBoundingClientRect().top - saved.top : 0;
      if (Math.abs(delta) > 0.5) { stats.scrollWrites++; window.scrollBy(0, delta); }
    }
  }
  function releaseRetiredRows() {
    clearTimeout(retireTimer);
    retireTimer = setTimeout(() => {
      retireTimer = 0;
      if (touching || scrollAnimation || !retiredHeight) return;
      rememberAnchor();
      const saved = anchor;
      retiredHeight = 0; content.style.paddingTop = '';
      restoreAnchor(saved); rememberAnchor();
    }, 120);
  }
  window.addEventListener('pointerdown', () => { cancelScroll(); touching = true; }, { passive: true });
  for (const event of ['pointerup', 'pointercancel']) window.addEventListener(event, () => {
    touching = false; if (retiredHeight) releaseRetiredRows();
  }, { passive: true });
  window.addEventListener('wheel', () => { cancelScroll(); wheelUntil = performance.now() + 120; }, { passive: true });
  window.addEventListener('scroll', () => {
    rememberAnchor(true); if (retiredHeight) releaseRetiredRows();
  }, { passive: true });
  window.addEventListener('resize', () => requestAnimationFrame(() => {
    if (mode !== 'badges') {
      if (rowWidth !== window.innerWidth) { rowWidth = window.innerWidth; restoreRows(); }
      if (!scrollAnimation && !touching && performance.now() >= wheelUntil) restoreAnchor(anchor);
    }
  }));
  new ResizeObserver(() => {
    if (mode === 'badges') send({ action: 'height', height: content.getBoundingClientRect().height });
  }).observe(content);

  // Retain measured row boxes and the original nodes, but remove distant rich
  // content from layout. No paint containment: native effects may overflow rows.
  function mountRow(item) {
    if (!item.fragment) return;
    item.node.append(item.fragment); item.fragment = null; item.node.style.height = '';
    observe(item.node);
  }
  const rows = new IntersectionObserver(entries => {
    const changes = entries.flatMap(entry => {
      const item = records.get(entry.target.dataset.message);
      if (!item || !entry.target.isConnected) return [];
      if (entry.isIntersecting && !item.fragment) { item.seen = true; return []; }
      if (!entry.isIntersecting && item.fragment) return [];
      return [{ item, visible: entry.isIntersecting, height: entry.boundingClientRect.height }];
    });
    // Read animation state before changing layout. Targets remain the same nodes
    // in the detached fragment, so repeated emotes and pseudo-elements stay distinct.
    const saving = new Map(changes.filter(({ item, visible }) => !visible && item.seen).map(({ item }) => [item.node, item]));
    for (const item of saving.values()) item.times = new Map();
    if (saving.size) for (const animation of content.getAnimations({ subtree: true })) {
      const item = saving.get(animation.effect.target.closest('[data-message]'));
      if (item) {
        const target = animation.effect.target;
        if (!item.times.has(target)) item.times.set(target, new Map());
        item.times.get(target).set(animation.animationName + ':' + (animation.effect.pseudoElement || ''), animation.currentTime);
      }
    }
    for (const { item, visible, height } of changes) {
      if (visible) mountRow(item);
      else if (height > 0) {
        for (const node of item.node.querySelectorAll('[data-resource]')) node.classList.add('not-visible');
        forget(item.node); item.node.style.height = height + 'px';
        item.fragment = document.createDocumentFragment();
        item.fragment.append(...item.node.childNodes);
      }
    }
    const restoring = new Map(changes.filter(({ item, visible }) => visible && item.times).map(({ item }) => [item.node, item]));
    if (restoring.size) for (const animation of content.getAnimations({ subtree: true })) {
      const item = restoring.get(animation.effect.target.closest('[data-message]'));
      if (item) {
        const time = item.times.get(animation.effect.target)?.get(animation.animationName + ':' + (animation.effect.pseudoElement || ''));
        if (time !== undefined) animation.currentTime = time;
        else {
          const end = animation.effect.getComputedTiming().endTime;
          if (Number.isFinite(end)) animation.currentTime = end;
        }
      }
    }
    for (const { item, visible } of changes) if (visible) {
      item.times = null; item.seen = true;
    }
  }, { rootMargin: '600px 0px' });
  function restoreRows() {
    for (const item of records.values()) {
      mountRow(item); item.times = null;
      rows.unobserve(item.node); rows.observe(item.node);
    }
  }

  function freeze(node) {
    if (animations || !node.classList.contains('emote') || node.classList.contains('not-visible') || node.querySelector('canvas')) return;
    const url = node.dataset.resource;
    if (!url) return;
    const image = new Image();
    image.onload = () => {
      if (animations || !node.isConnected || node.classList.contains('not-visible')) return;
      const css = getComputedStyle(node);
      const canvas = document.createElement('canvas');
      const width = Math.ceil(node.getBoundingClientRect().width), height = Math.ceil(node.getBoundingClientRect().height);
      if (!width || !height) return;
      canvas.width = width; canvas.height = height;
      const positions = css.backgroundPosition.split(' ');
      const offset = (value, available) => value.endsWith('%') ? available * parseFloat(value) / 100 : parseFloat(value) || 0;
      const size = css.backgroundSize.split(' ');
      let imageWidth = image.naturalWidth, imageHeight = image.naturalHeight;
      if (size[0] === 'contain' || size[0] === 'cover') {
        const scale = Math[size[0] === 'contain' ? 'min' : 'max'](width / imageWidth, height / imageHeight);
        imageWidth *= scale; imageHeight *= scale;
      } else {
        if (size[0] !== 'auto') imageWidth = offset(size[0], width);
        if (size[1] && size[1] !== 'auto') imageHeight = offset(size[1], height);
        else imageHeight *= imageWidth / image.naturalWidth;
        if (size[0] === 'auto') imageWidth = image.naturalWidth * imageHeight / image.naturalHeight;
      }
      // Canvas uses the default/first frame of an animated image, per HTML.
      canvas.getContext('2d').drawImage(image, offset(positions[0], width - imageWidth), offset(positions[1], height - imageHeight), imageWidth, imageHeight);
      canvas.setAttribute('aria-hidden', 'true');
      node.append(canvas);
    };
    image.src = url;
  }
  function loadPreview(node) {
    const key = node.dataset.resource, address = resourceVersions.get(key) || key;
    node.onload = () => imageResult(key, true);
    node.onerror = () => imageResult(key, false);
    if (node.getAttribute('src') !== address) node.src = address;
  }
  function stopPreview(node) {
    if (node.tagName === 'IMG') { node.onload = node.onerror = null; node.removeAttribute('src'); }
  }
  const visibility = new IntersectionObserver(entries => {
    for (const entry of entries) {
      const node = entry.target;
      if (!node.isConnected) continue;
      node.classList.toggle('not-visible', !active || !entry.isIntersecting);
      if (entry.isIntersecting && active) {
        if (node.tagName === 'IMG') loadPreview(node); else checkImage(node.dataset.resource);
        freeze(node);
      } else {
        stopPreview(node);
        const item = decoded.get(node.dataset.resource);
        if (item?.image && ![...(resources.get(node.dataset.resource) || [])].some(node => !node.classList.contains('not-visible'))) {
          decoded.delete(node.dataset.resource); item.image.src = '';
        }
      }
    }
  }, { rootMargin: '100px 0px' });
  function imageResult(key, success) {
    if (!resources.has(key)) return;
    if (!success && !failedResources.has(key)) send({ action: 'assetFailure' });
    if (success) failedResources.delete(key); else failedResources.add(key);
    for (const node of resources.get(key) || []) {
      if (!success && !node.classList.contains('missing-asset')) stats.assetFailures++;
      node.classList.toggle('missing-asset', !success);
      if (node.classList.contains('flair')) node.textContent = success ? '' : node.getAttribute('aria-label');
      if (success) freeze(node);
    }
  }
  function checkImage(key) {
    if (!key || decoded.has(key)) return;
    const image = new Image(), item = { image };
    decoded.set(key, item);
    const finish = success => {
      if (decoded.get(key) !== item) return;
      item.image = null; image.onload = image.onerror = null;
      imageResult(key, success);
    };
    image.onload = () => finish(image.naturalWidth > 0 && image.naturalHeight > 0);
    image.onerror = () => finish(false);
    image.src = resourceVersions.get(key) || key;
  }
  function observe(parent) {
    for (const node of parent.querySelectorAll('[data-resource]')) {
      let nodes = resources.get(node.dataset.resource);
      if (!nodes) resources.set(node.dataset.resource, nodes = new Set());
      nodes.add(node);
      visibility.observe(node);
    }
  }
  function forget(parent) {
    for (const node of parent.querySelectorAll('[data-resource]')) {
      visibility.unobserve(node);
      stopPreview(node);
      const nodes = resources.get(node.dataset.resource);
      nodes?.delete(node);
      if (!nodes?.size) {
        const key = node.dataset.resource, item = decoded.get(key);
        decoded.delete(key); if (item?.image) item.image.src = '';
        resources.delete(key); failedResources.delete(key);
        if (resourceVersions.has(key) && !style.textContent.includes(key)) resourceVersions.delete(key);
      }
    }
  }
  function clear() {
    cancelScroll();
    clearTimeout(retireTimer); retireTimer = 0; retiredHeight = 0; content.style.paddingTop = '';
    rows.disconnect(); forget(content); content.replaceChildren(); records.clear(); pickerSignature = ''; profileSignature = '';
  }
  function assetFinished(url, success) {
    const key = proxy(url);
    const nodes = resources.get(key);
    // Native combo/pseudo-element styles can reference an additional image that
    // isn't the catalog's primary image. Keep those failures retryable too.
    if (!nodes) {
      if (style.textContent.includes(key)) {
        if (success) failedResources.delete(key); else failedResources.add(key);
      }
      return;
    }
    if (!success) imageResult(key, false);
    else if ([...nodes].some(node => node.tagName !== 'IMG' && !node.classList.contains('not-visible'))) checkImage(key);
  }
  function retryFailedAssets() {
    if (!failedResources.size) return;
    retryVersion++;
    const previous = new Map();
    const replacements = new Map([...failedResources].map(address => {
      previous.set(address, resourceVersions.get(address) || address);
      const url = new URL(address); url.searchParams.set('__streamstiny_retry', String(retryVersion));
      decoded.delete(address); resourceVersions.set(address, url.href);
      return [address, url.href];
    }));
    function repair(rules) {
      for (const rule of rules) {
        if (rule.cssRules) repair(rule.cssRules);
        if (!rule.style) continue;
        for (const property of Array.from(rule.style)) {
          const original = rule.style.getPropertyValue(property);
          let value = original;
          for (const [address, to] of replacements) {
            const from = previous.get(address);
            value = value.split('url("' + from + '")').join('url("' + to + '")');
          }
          if (value !== original) rule.style.setProperty(property, value, rule.style.getPropertyPriority(property));
        }
      }
    }
    repair(style.sheet.cssRules);
    for (const [address, replacement] of replacements) for (const node of resources.get(address) || []) {
      node.classList.remove('missing-asset');
      if (!node.classList.contains('not-visible')) {
        if (node.tagName === 'IMG') loadPreview(node); else checkImage(address);
      }
    }
  }
  window.addEventListener('online', retryFailedAssets);
  function motion() {
    const next = account.animate !== false && !matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (next !== animations) {
      restoreRows();
      animations = next;
      document.documentElement.classList.toggle('static-emotes', !animations);
      for (const node of content.querySelectorAll('.emote')) {
        if (animations) node.querySelector('canvas')?.remove(); else freeze(node);
      }
    }
  }
  matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change', motion);
  function setActive(value) {
    if (active === value) return;
    active = value;
    document.documentElement.classList.toggle('paused', !active);
    if (!active) {
      cancelScroll();
      touching = false; wheelUntil = 0;
      clearTimeout(retireTimer); retireTimer = 0;
    } else if (retiredHeight) releaseRetiredRows();
    for (const nodes of resources.values()) for (const node of nodes) {
      if (active) {
        node.classList.remove('missing-asset');
        visibility.unobserve(node); visibility.observe(node);
      } else { node.classList.add('not-visible'); stopPreview(node); }
    }
    if (!active) for (const [key, item] of decoded) if (item.image) {
      decoded.delete(key); item.image.src = '';
    }
  }

  function updateChat(data) {
    if (data.interacting) cancelScroll();
    const interacting = data.interacting || touching || scrollAnimation !== 0 || performance.now() < wheelUntil;
    const follow = (following || pendingPin) && !interacting;
    if (interacting) rememberAnchor();
    let saved = anchor;
    const desired = data.ids ? new Set(data.ids) : null;
    const removed = [];
    if (desired) for (const [id, item] of records) if (!desired.has(id)) removed.push(item);
    // Keep removed offscreen row space during touch/inertial scrolling. Drop
    // their resources now and perform one offset correction after scrolling.
    if (interacting && !follow) {
      const height = removed.reduce((sum, item) => {
        const bounds = item.node.getBoundingClientRect();
        return sum + (bounds.bottom <= 0 ? bounds.height : 0);
      }, 0);
      if (height) {
        retiredHeight += height;
        if (!retireTimer && !touching) releaseRetiredRows();
      }
    }
    if (saved && desired && !desired.has(saved.id)) {
      const original = records.get(saved.id)?.node;
      let next = original;
      while (next && !desired.has(next.dataset.message)) next = next.nextElementSibling;
      if (!next) {
        next = original?.previousElementSibling;
        while (next && !desired.has(next.dataset.message)) next = next.previousElementSibling;
      }
      saved = next ? { id: next.dataset.message, top: next.getBoundingClientRect().top } : null;
    }
    for (const record of data.records || []) {
      let item = records.get(record.id);
      if (!item) {
        item = { node: document.createElement('div'), html: '', fragment: null, seen: false, times: null };
        item.node.dataset.message = record.id;
        item.node.setAttribute('role', 'listitem');
        records.set(record.id, item); stats.inserted++;
        rows.observe(item.node);
      }
      if (item.node.className !== record.classes || item.node.dataset.comboGroup !== record.comboGroup) item.times = null;
      item.node.className = record.classes;
      item.node.dataset.username = record.username;
      if (record.combo > 1) {
        item.node.dataset.combo = String(record.combo);
        item.node.dataset.comboGroup = record.comboGroup;
      } else { delete item.node.dataset.combo; delete item.node.dataset.comboGroup; }
      item.node.style.backgroundColor = record.background || '';
      item.node.style.opacity = record.faded ? '0.3' : '';
      item.node.setAttribute('aria-label', record.accessibility);
      if (item.html !== record.html) {
        item.fragment = null; item.times = null; item.node.style.height = '';
        forget(item.node);
        item.node.innerHTML = record.html;
        item.html = record.html;
        observe(item.node); stats.replaced++;
        rows.unobserve(item.node); rows.observe(item.node);
      }
      const counter = (item.fragment || item.node).querySelector('.combo');
      if (counter) counter.textContent = record.combo > 1 ? record.combo + '× combo' : '';
    }
    if (data.ids) {
      if (retiredHeight) content.style.paddingTop = retiredHeight + 'px';
      for (const item of removed) {
        rows.unobserve(item.node); forget(item.node); item.node.remove(); records.delete(item.node.dataset.message); stats.removed++;
      }
      let cursor = content.firstElementChild;
      for (const id of data.ids) {
        const node = records.get(id)?.node;
        if (!node) continue;
        if (node !== cursor) content.insertBefore(node, cursor);
        cursor = node.nextElementSibling;
      }
    }
    if (!scrollAnimation) restoreAnchor(saved, follow);
    rememberAnchor();
  }
  function updatePicker() {
    const signature = JSON.stringify([manifestVersion, [...favorites].sort(), account.tier, account.patreonMember, account.privileged]);
    if (signature !== pickerSignature) {
      forget(content); content.replaceChildren(); stats.pickerBuilds++;
      const groups = new Map();
      for (const item of manifest) {
        const key = item.patreonOnly ? 'patreon' : item.minimumSubTier;
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(item);
      }
      const keys = [...groups.keys()].sort((a, b) => a === 'patreon' ? 1 : b === 'patreon' ? -1 : a - b);
      for (const key of keys) {
        const section = document.createElement('section');
        const title = document.createElement('h2');
        title.textContent = key === 'patreon' ? 'Patreon Members' : key === 0 ? 'All Users' : `Tier ${key} Subscribers`;
        const grid = document.createElement('div'); grid.className = 'emote-group';
        const items = groups.get(key).sort((a, b) => Number(favorites.has(b.prefix)) - Number(favorites.has(a.prefix)));
        for (const item of items) {
          const button = document.createElement('button');
          button.className = 'emote-item'; button.dataset.name = item.prefix;
          button.disabled = !allows(item);
          button.setAttribute('aria-label', item.prefix + (button.disabled ? ', locked' : ''));
          const image = document.createElement('div');
          image.className = 'emote ' + item.prefix + ' not-visible';
          image.textContent = item.prefix + ' '; image.title = item.prefix;
          image.dataset.resource = item.resource;
          const label = document.createElement('span'); label.className = 'emote-label';
          label.textContent = (favorites.has(item.prefix) ? '★ ' : '') + item.prefix;
          const visual = document.createElement('span'); visual.className = 'emote-visual'; visual.append(image);
          button.append(visual, label); grid.append(button);
        }
        section.append(title, grid); content.append(section);
      }
      pickerSignature = signature;
      observe(content);
    }
    setSearch(search);
  }
  function setSearch(value) {
    search = String(value).toLowerCase();
    for (const section of content.querySelectorAll('section')) {
      let matches = 0;
      for (const node of section.querySelectorAll('.emote-item')) {
        const show = node.dataset.name.toLowerCase().includes(search);
        node.hidden = !show;
        if (show) matches++;
      }
      section.hidden = matches === 0;
    }
  }
  function update(data) {
    stats.updates++;
    if (data.mode && data.mode !== mode) { clear(); mode = data.mode; }
    content.className = mode;
    content.setAttribute('role', mode === 'chat' ? 'list' : 'group');
    if (data.stylesheet !== undefined && style.textContent !== data.stylesheet) {
      style.textContent = data.stylesheet; failedResources.clear(); resourceVersions.clear();
      restoreRows();
    }
    if (data.manifest) { manifest = data.manifest; manifestVersion++; }
    if (data.favorites) favorites = new Set(data.favorites);
    if (data.account) account = data.account;
    if (data.fontSize && document.body.style.fontSize !== data.fontSize + 'px') {
      document.body.style.fontSize = data.fontSize + 'px'; restoreRows();
    }
    if (data.hideBadges !== undefined) document.documentElement.classList.toggle('hide-badges', data.hideBadges);
    if (data.active !== undefined) setActive(data.active);
    if (data.recovery !== undefined && data.recovery !== recovery) { recovery = data.recovery; retryFailedAssets(); }
    motion();
    if (mode === 'picker') { if (data.search !== undefined) search = data.search; updatePicker(); }
    else if (mode === 'badges') {
      if (profileSignature !== data.html) {
        forget(content); content.innerHTML = data.html || ''; profileSignature = data.html; observe(content);
      }
    } else updateChat(data);
  }
  content.addEventListener('click', event => {
    if (holding) { holding = false; event.preventDefault(); return; }
    const emote = event.target.closest('.emote-item');
    if (emote && !emote.disabled) { send({ action: 'insert', name: emote.dataset.name }); return; }
    const link = event.target.closest('a[href]');
    if (link) { event.preventDefault(); send({ action: 'link', url: link.getAttribute('href') }); return; }
    const user = event.target.closest('.user');
    if (user) send({ action: 'profile', id: user.closest('[data-message]')?.dataset.message });
  });
  function menu(event) {
    const emote = event.target.closest('.emote-item');
    const message = event.target.closest('[data-message]');
    if (!emote && !message) return;
    event.preventDefault();
    clearTimeout(holdTimer);
    if (holding) return;
    holding = true;
    send({ action: 'menu', id: message?.dataset.message, name: emote?.dataset.name, x: event.clientX, y: event.clientY });
  }
  content.addEventListener('contextmenu', menu);
  content.addEventListener('pointerdown', event => {
    holding = false; startPoint = [event.clientX, event.clientY];
    clearTimeout(holdTimer);
    if (event.pointerType !== 'mouse') holdTimer = setTimeout(() => menu(event), 550);
  }, { passive: true });
  for (const name of ['pointerup', 'pointercancel']) content.addEventListener(name, () => clearTimeout(holdTimer), { passive: true });
  content.addEventListener('pointermove', event => {
    if (startPoint && Math.hypot(event.clientX - startPoint[0], event.clientY - startPoint[1]) > 8) clearTimeout(holdTimer);
  }, { passive: true });
  window.ChatRenderer = { update, setSearch, assetFinished, scrollToBottom, metrics: () => ({ ...stats, nodes: records.size, mounted: [...records.values()].filter(item => !item.fragment).length, resources: resources.size, decoded: decoded.size }) };
  send({ action: 'ready' });
})();
