(() => {
  const config = __TOPIC_FILTER_CONFIG__;
  window.__bowserTopicFilter?.dispose();
  const {settings, generation} = config;
  const host = location.hostname;
  const site = ({'x.com':'x','www.reddit.com':'reddit','reddit.com':'reddit','old.reddit.com':'reddit',
    'www.youtube.com':'youtube','youtube.com':'youtube','news.ycombinator.com':'hn','www.linkedin.com':'linkedin'})[host];
  if (location.protocol !== 'https:' || !site) return;
  const allowed = () => site === 'x' ? !/^\/(messages|i\/chat|notifications|settings)(\/|$)/.test(location.pathname)
    : site === 'reddit' ? !/^\/(message|chat)(\/|$)/.test(location.pathname) : site === 'linkedin' ? /^\/feed(?:\/|$)/.test(location.pathname) : true;
  let url = location.href, documentID = crypto.randomUUID(), stopped = false, paused = false, showAll = false;
  let pending = null, retryAt = 0, error = '';
  const records = new Map(), masks = new Map(), reveals = new Set();
  const clean = value => (value || '').replace(/\s+/g, ' ').trim().slice(0, 3000);
  const selector = ({x:'article[data-testid="tweet"]', reddit:'shreddit-post, shreddit-comment, .thing.link, .thing.comment',
    youtube:'ytd-comment-view-model, ytd-comment-renderer', hn:'tr.athing', linkedin:'.feed-shared-update-v2'})[site];
  function extract(node) {
    // Never include usernames, controls, nested replies, or our own UI.
    if (site === 'x') return clean(node.querySelector('[data-testid="tweetText"]')?.textContent);
    if (site === 'reddit') return clean(node.matches('shreddit-post') ? [node.getAttribute('post-title'), node.querySelector('[slot="text-body"]')?.textContent].filter(Boolean).join(' ') :
      node.matches('shreddit-comment') ? node.querySelector('[slot="comment"]')?.textContent : node.querySelector('.entry .title, .entry .usertext-body')?.textContent);
    if (site === 'youtube') return clean(node.querySelector('#content-text')?.textContent);
    if (site === 'hn') return clean(node.querySelector('.commtext, .titleline a')?.textContent);
    return clean(node.querySelector('.update-components-text, .feed-shared-update-v2__description')?.textContent);
  }
  function identity(node, text) {
    if (site === 'x') return node.querySelector('a[href*="/status/"] time')?.closest('a')?.getAttribute('href')?.match(/\/status\/(\d+)/)?.[1];
    if (site === 'reddit') return node.getAttribute('thingid') || node.id || node.getAttribute('data-fullname');
    if (site === 'hn') return node.id;
    if (site === 'linkedin') return node.getAttribute('data-urn') || text;
    const href = node.querySelector('#published-time-text a')?.getAttribute('href');
    return href ? new URL(href, location.href).searchParams.get('lc') : null;
  }
  const ui = document.createElement('div');
  ui.dataset.bowserTopicUi = '';
  Object.assign(ui.style,{position:'fixed',right:'16px',bottom:'16px',zIndex:'2147483646',padding:'12px',maxWidth:'340px',border:'1px solid #777',borderRadius:'14px',background:'Canvas',color:'CanvasText',font:'12px system-ui',boxShadow:'0 4px 24px #0003'});
  const status = document.createElement('div');
  status.setAttribute('role','status');
  ui.append(status);
  function control(label, fn) {
    const b = document.createElement('button'); b.textContent = label;
    Object.assign(b.style,{margin:'8px 6px 0 0',cursor:'pointer'}); b.onclick = fn; ui.append(b); return b;
  }
  const needsSetup = () => !settings.enabled || !settings.consent || !settings['site_' + site];
  const openSettings = () => window.bowser?.emit({kind:'topic-filter-settings'});
  const pause = control('Turn on…', () => {
    if(needsSetup() || settings.paused_until * 1000 > Date.now()) {openSettings(); return;}
    paused = !paused; if(paused) restoreAll(); scan();
  });
  const show = control('Show hidden', () => {showAll = !showAll; show.textContent = showAll ? 'Hide again' : 'Show hidden'; if(showAll) restoreAll(); scan();});
  control('Settings', openSettings);
  document.documentElement.append(ui);
  function restore(node) {
    const saved = masks.get(node); if (!saved) return;
    saved.badge.remove();
    for (const [child, property, value, priority] of saved.styles) child.style.setProperty(property, value, priority);
    masks.delete(node);
  }
  function restoreAll() { for(const node of masks.keys()) restore(node); }
  function mask(node, id, text, labels) {
    if (masks.has(node) || showAll || reveals.has(id + '\n' + text)) return;
    const styles = [];
    const set = (el, prop, value) => {styles.push([el,prop,el.style.getPropertyValue(prop),el.style.getPropertyPriority(prop)]); el.style.setProperty(prop,value,'important');};
    const badge = document.createElement('button'); badge.dataset.bowserTopicUi = '';
    badge.textContent = 'Topic Filter · ' + labels.join(', ') + ' · Show';
    Object.assign(badge.style,{display:'block',padding:'10px',border:'1px solid #888',borderRadius:'8px',background:'Canvas',color:'CanvasText',font:'13px system-ui',cursor:'pointer'});
    badge.onclick = event => {event.preventDefault(); event.stopPropagation(); reveals.add(id + '\n' + text); restore(node); updateStatus();};
    // HN table rows cannot host an overlay button. Hide only their text cell.
    const target = site === 'hn' ? node.querySelector('.commtext, .titleline') : node;
    if (!target) return;
    if (settings.mode === 'remove' && site !== 'x') {
      set(target,'display','none'); target.parentElement.insertBefore(badge,target);
    } else if (settings.mode === 'dim') {
      set(target,'opacity','0.18'); target.parentElement.insertBefore(badge,target);
    } else {
      // Preserve measured heights, including X's virtualized ancestors.
      const height = target.getBoundingClientRect().height;
      set(target,'min-height',height + 'px'); set(target,'position','relative');
      for(const child of target.children) set(child,'visibility','hidden');
      // Text-only HN comments use color instead of hiding the entire target.
      set(target,'color','transparent');
      Object.assign(badge.style,{position:'absolute',inset:'0',width:'100%',height:'100%',visibility:'visible'});
      target.append(badge);
    }
    masks.set(node,{id,text,badge,styles});
  }
  function updateStatus() {
    const items = [...records.values()];
    const evaluated = items.filter(r => r.result).length, cached = items.filter(r => r.result?.cached).length;
    const uncertain = items.filter(r => r.result?.uncertain).length;
    const off = needsSetup();
    pause.textContent = off ? 'Turn on…' : settings.paused_until * 1000 > Date.now() ? 'Resume in Settings…' : paused ? 'Resume this tab' : 'Pause this tab';
    show.disabled = off;

    status.textContent = off ? 'Topic Filter · Off — choose Turn on… to finish setup' : paused || settings.paused_until * 1000 > Date.now() ? 'Topic Filter · Paused' :
      error ? 'Topic Filter · ' + error : !items.length ? 'Topic Filter · No matching items found' :
      `Topic Filter · ${items.length} found · ${evaluated} evaluated · ${masks.size} hidden · ${items.length-evaluated} pending` + (cached ? ` · ${cached} cached` : '') + (uncertain ? ` · ${uncertain} uncertain` : '');
  }
  const api = {
    generation,
    apply(request, result) {
      if(stopped || request.generation !== generation || request.document !== documentID || request.url !== location.href) return;
      const record = records.get(request.id);
      if(!record || record.text !== request.text) return;
      const matching = [...document.querySelectorAll(selector)].some(node => {
        const text = masks.get(node)?.text || extract(node);
        return identity(node,text) === request.id && text === request.text;
      });
      if(!matching) { if(pending?.id === request.id) pending = null; scan(); return; }
      if(pending?.id === request.id && pending.text === request.text) pending = null;
      if(result.retry) {retryAt = Date.now() + 2000;}
      else if(result.error) {error = result.error; retryAt = Date.now() + 60000;}
      else if(Array.isArray(result.labels)) {record.result = result; error = '';}
      scan();
    },
    dispose() {stopped = true; clearInterval(timer); restoreAll(); ui.remove();}
  };
  function scan() {
    if(stopped) return;
    if(url !== location.href) {restoreAll(); records.clear(); reveals.clear(); pending = null; error = ''; retryAt = 0; url = location.href; documentID = crypto.randomUUID();}
    ui.hidden = !allowed();
    const enabled = allowed() && settings.enabled && settings.consent && settings['site_' + site] && !paused && settings.paused_until * 1000 <= Date.now();
    if(!enabled) {restoreAll(); updateStatus(); return;}
    if(document.visibilityState !== 'visible') return;
    for(const [node, saved] of masks) {
      // Temporarily detach our badge to ensure extracted text never includes it.
      saved.badge.remove(); const text = extract(node); const id = identity(node,text);
      if(!node.isConnected || id !== saved.id || text !== saved.text) restore(node);
      else if(settings.mode === 'cover' || (settings.mode === 'remove' && site === 'x')) (site === 'hn' ? node.querySelector('.commtext, .titleline') : node)?.append(saved.badge);
      else {const target = site === 'hn' ? node.querySelector('.commtext, .titleline') : node; target?.parentElement.insertBefore(saved.badge,target);}
    }
    if(reveals.size > 1000) reveals.clear();
    const current = new Set();
    for(const node of document.querySelectorAll(selector)) {
      const saved = masks.get(node);
      const text = saved?.text || extract(node), id = identity(node,text);
      if(!id || id.length > 200 || !text) continue;
      current.add(id);
      const rect = node.getBoundingClientRect();
      let record = records.get(id);
      if(record && record.text !== text) {restore(node); records.delete(id); record = null;}
      if(!record && rect.bottom >= 0 && rect.top <= innerHeight) {record = {text}; records.set(id,record);}
      if(record?.result?.labels.length && !showAll) mask(node,id,text,record.result.labels);
    }
    for(const id of records.keys()) if(!current.has(id)) records.delete(id);
    if(pending && Date.now()-pending.at > 95000) {pending = null; error = 'Request timed out; retrying'; retryAt = Date.now()+60000;}
    const topics = ['politics','rage','doom','dunks','harassment','engagement','crypto','filler'].some(id => settings[id]) || settings.custom.trim();
    if(!topics) {error = 'Choose topics in Settings'; updateStatus(); return;}
    if(!pending && Date.now() >= retryAt) {
      for(const node of document.querySelectorAll(selector)) {
        const text = masks.get(node)?.text || extract(node), id = identity(node,text), record = records.get(id);
        const rect = node.getBoundingClientRect();
        if(!record || record.result || rect.bottom < 0 || rect.top > innerHeight) continue;
        pending = {id,text,at:Date.now()};
        window.bowser?.emit({kind:'topic-filter',generation,document:documentID,id,text,url}); break;
      }
    }
    updateStatus();
  }
  const timer = setInterval(scan,1500);
  window.__bowserTopicFilter = api;
  window.bowser?.emit({kind:"topic-filter-ready"});
  scan();
})();
