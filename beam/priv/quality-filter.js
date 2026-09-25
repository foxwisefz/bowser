(() => {
  const mode = __BOWSER_MODE__;
  const host = location.hostname;
  if (mode === 'x' ? !/(^|\.)x\.com$/.test(host) : !/(^|\.)amazon\.com$/.test(host)) return;
  window.__bowserQuality?.dispose();
  let stopped = false, enabled = true;
  const seen = new Map(), revealed = new Set(), masks = new Map();
  const selector = mode === 'x' ? 'article[data-testid="tweet"]' : '[data-component-type="s-search-result"][data-asin]';
  const button = document.createElement('button');
  button.textContent = 'Quality filter · On';
  button.title = 'Visible post/listing text is sent to Bowser and TypeSafe for quality judgments. Click to pause and reveal everything.';
  Object.assign(button.style, {position:'fixed',right:'16px',bottom:'16px',zIndex:'2147483646',border:'1px solid #777',borderRadius:'18px',padding:'9px 14px',background:'#202124',color:'#fff',font:'13px system-ui',cursor:'pointer'});
  document.documentElement.appendChild(button);
  const identity = node => mode === 'x' ? node.querySelector('a[href*="/status/"]')?.getAttribute('href')?.match(/\/status\/(\d+)/)?.[1] : node.dataset.asin;
  const extract = node => (mode === 'x' ? node.querySelector('[data-testid="tweetText"]')?.textContent : [node.querySelector('h2')?.textContent,node.querySelector('.a-price')?.textContent,node.querySelector('[aria-label*="stars"]')?.getAttribute('aria-label')].filter(Boolean).join(' | '))?.replace(/\s+/g,' ').trim().slice(0,700) || '';
  function unmask(node) {
    const saved = masks.get(node); if (!saved) return;
    saved.cover.remove();
    for (const [child, visibility] of saved.children) child.style.visibility = visibility;
    node.style.position = saved.position;
    masks.delete(node);
  }
  function mask(node, id) {
    if (masks.has(node) || revealed.has(id)) return;
    const children = Array.from(node.children).map(child => [child, child.style.visibility]);
    const position = node.style.position;
    // Preserve measured geometry, especially X's virtualized timeline. Never
    // transform or remove cellInnerDiv or any of its measured ancestors.
    for (const [child] of children) child.style.visibility = 'hidden';
    node.style.position = 'relative';
    const cover = document.createElement('button');
    cover.textContent = 'Likely low-quality content · Show';
    cover.title = 'A probabilistic quality judgment, not proof of AI authorship. Click to reveal.';
    Object.assign(cover.style,{position:'absolute',inset:'0',width:'100%',height:'100%',border:'0',borderRadius:'12px',background:'Canvas',color:'GrayText',font:'14px system-ui',cursor:'pointer'});
    cover.onclick = event => { event.preventDefault(); event.stopPropagation(); revealed.add(id); unmask(node); };
    node.appendChild(cover); masks.set(node,{id,text:extract(node),cover,children,position});
  }
  const api = {
    apply(kind,id,text,hidden) {
      if (kind !== mode || !enabled) return;
      seen.set(id,{hidden,text,at:Date.now()});
      for (const node of document.querySelectorAll(selector)) if(identity(node) === id && extract(node) === text) { if(hidden) mask(node,id); else unmask(node); }
    },
    status(message) { button.textContent = 'Quality filter · Paused'; button.title = message; },
    dispose() { stopped = true; clearInterval(timer); for(const node of masks.keys()) unmask(node); button.remove(); }
  };
  button.onclick = () => { enabled = !enabled; button.textContent = 'Quality filter · ' + (enabled ? 'On' : 'Off'); if(!enabled) for(const node of masks.keys()) unmask(node); };
  function scan() {
    if(stopped || !enabled || document.visibilityState !== 'visible') return;
    for(const [node,saved] of masks) if(!node.isConnected || identity(node) !== saved.id || extract(node) !== saved.text) unmask(node);
    const items = [];
    for(const node of document.querySelectorAll(selector)) {
      const rect = node.getBoundingClientRect();
      if(rect.bottom < 0 || rect.top > innerHeight) continue;
      const id = identity(node), text = extract(node);
      if(!id || text.length < 30 || revealed.has(id)) continue;
      const existing = seen.get(id);
      if(existing && existing.text === text && Date.now() - existing.at < 900000) { if(existing.hidden) mask(node,id); continue; }
      items.push({id,text}); if(items.length === 1) break;
    }
    if(items.length) window.bowser?.emit({kind:'bowser-quality',mode,items});
    if(seen.size > 500) seen.clear();
    if(revealed.size > 500) revealed.clear();
  }
  const timer = setInterval(scan,2000);
  window.__bowserQuality = api;
  scan();
})();
