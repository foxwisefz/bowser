import Foundation
import WebKit

enum HistoryCapture {
    @MainActor static let world = WKContentWorld.world(name: "BowserHistory")
    /// Installed only in an enabled, foreground page. Observers are disconnected
    /// when it leaves the foreground. Scroll callbacks never read layout or text.
    static let script = #"""
    (() => {
      if (globalThis.__bowserHistory) return;
      const maxObserved = 400, maxText = 2200;
      let active = false, token = '', observer, mutations, timer, scanTimer, settleTimer, dirtyTimer;
      let images = false, lastScroll = -Infinity, lastImage = -Infinity, lastSend = 0;
      let observed = new Set(), visible = new Set(), pending = new Map(), fingerprints = new WeakMap();
      let scans = [];
      const dirty = new Set();
      const sensitive = 'input,textarea,select,[contenteditable]:not([contenteditable="false"]),[role="textbox"],[data-private],[data-sensitive]';
      const ignored = 'script,style,noscript,template,svg,' + sensitive;
      const candidates = 'article,[role="article"],p,h1,h2,h3,li,img,button,header';
      function clean(s,n=maxText) { return String(s || '').replace(/\s+/g,' ').trim().slice(0,n); }
      function safeURL(raw) {
        try { const u = new URL(raw,location.href); return /^https?:$/.test(u.protocol) && !u.username && !u.password ? u.href.slice(0,4096) : null; } catch { return null; }
      }
      function textOf(el) {
        if (el.closest(ignored) || el.closest('[hidden],[aria-hidden="true"]')) return '';
        const walker = document.createTreeWalker(el, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
          acceptNode(n) {
            if (n.nodeType === 1) {
              if(n.matches(ignored + ',[hidden],[aria-hidden="true"]')) return NodeFilter.FILTER_REJECT;
              const style=getComputedStyle(n);
              return style.display==='none' || style.visibility==='hidden' || style.opacity==='0' ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP;
            }
            return NodeFilter.FILTER_ACCEPT;
          }
        });
        let out = '', n, count = 0;
        while ((n=walker.nextNode()) && count++ < 180 && out.length < maxText) out += ' ' + n.textContent;
        return clean(out);
      }
      function color(raw) {
        const m = raw.match(/^rgba?\(([^)]+)\)/); if (!m) return null;
        const v = m[1].split(/[\s,/]+/).map(Number); if (v.length > 3 && v[3] < .2) return null;
        const r=v[0]/255,g=v[1]/255,b=v[2]/255, hi=Math.max(r,g,b),lo=Math.min(r,g,b),d=hi-lo;
        if (hi < .16) return 'black'; if (lo > .88) return 'white';
        if (d < .12) return 'gray';
        let h = hi===r ? ((g-b)/d)%6 : hi===g ? (b-r)/d+2 : (r-g)/d+4;
        h=(h*60+360)%360;
        if (h<15 || h>=345) return 'red'; if (h<45) return hi<.55 ? 'brown' : 'orange';
        if (h<70) return 'yellow'; if (h<165) return 'green'; if (h<200) return 'cyan';
        if (h<260) return 'blue'; if (h<295) return 'purple'; return 'pink';
      }
      function appearance(el) {
        const backgrounds=new Set(), accents=new Set();
        let nodes=[document.body,el,...Array.from(visible).slice(0,22)].filter(Boolean);
        for (const n of nodes) {
          if (!n.isConnected || n.closest(sensitive)) continue;
          const s=getComputedStyle(n);
          const bg=color(s.backgroundColor), fg=color(s.color), border=color(s.borderTopColor);
          if (bg) backgrounds.add(bg);
          for (const c of [bg,fg,parseFloat(s.borderTopWidth)>0 ? border : null]) if(c && !['white','black','gray'].includes(c)) accents.add(c);
        }
        return clean([backgrounds.size ? [...backgrounds].join(', ')+' backgrounds' : '', accents.size ? [...accents].join(', ')+' accents' : ''].filter(Boolean).join('; '),500);
      }
      function capture(el, styling=false) {
        if (!active || !el.isConnected || !visible.has(el) || el.closest(ignored)) return;
        if(el.checkVisibility && !el.checkVisibility({checkOpacity:true,checkVisibilityCSS:true}))return;
        let text = textOf(el);
        const img = el.matches('img') ? el : el.querySelector('img');
        if (img && !img.closest(sensitive)) text=clean(text+' '+clean(img.alt,300));
        if (text.length < 12 && !img) return;
        let url = safeURL(location.href);
        if (el.matches('article,[role="article"],li')) {
          const timeLink = el.querySelector('time')?.closest('a[href]');
          const permalink = timeLink || el.querySelector('a[rel~="bookmark"],a[itemprop="url"]');
          if (permalink) url=safeURL(permalink.href) || url;
        }
        if (!url) return;
        const fingerprint=url+'\n'+text+'\n'+(img?.currentSrc || '');
        if (fingerprints.get(el)===fingerprint) return;
        fingerprints.set(el,fingerprint);
        const record={url,title:clean(document.title,240),text,appearance:styling ? appearance(el) : '', image:null};
        pending.set(fingerprint,{record,el,img,src:img?.currentSrc});
        while(pending.size>16) pending.delete(pending.keys().next().value);
        schedule();
      }
      function schedule() {
        if (!timer && active && pending.size) timer=setTimeout(flush,Math.max(250,1000-(performance.now()-lastSend)));
      }
      function flush() {
        timer=null; if(!active) return;
        const now=performance.now(), batch=[];
        for (const [key,item] of pending) {
          if(batch.length===4) break;
          pending.delete(key);
          const {record,el,img,src}=item;
          // Text is already copied: recycling/removal cannot erase a seen post.
          if(el.isConnected && visible.has(el)) {
            record.appearance=appearance(el);
            if(images && img?.isConnected && img.currentSrc===src && now-lastScroll>400 && now-lastImage>8000 && !img.closest(sensitive)) {
              const r=img.getBoundingClientRect();
              if(r.width>=100 && r.height>=80 && r.width*r.height<innerWidth*innerHeight*.85 && r.top>=0 && r.left>=0 && r.bottom<=innerHeight && r.right<=innerWidth) {
                // Avoid capturing an editable overlay above an image.
                const points=[[.1,.1],[.5,.5],[.9,.9]];
                const fields=document.querySelectorAll(sensitive);
                const clear=fields.length<64 && !Array.from(fields).some(n=>{
                  const f=n.getBoundingClientRect();return f.width>0 && f.height>0 && f.left<r.right && f.right>r.left && f.top<r.bottom && f.bottom>r.top;
                }) && points.every(([x,y])=>document.elementFromPoint(r.x+r.width*x,r.y+r.height*y)===img);
                if(clear) { record.image={x:r.x,y:r.y,width:r.width,height:r.height,src}; lastImage=now; }
              }
            }
          }
          batch.push(record);
        }
        if(batch.length) {
          lastSend=now;
          try { webkit.messageHandlers.bowserHistory.postMessage({token,url:location.href,records:batch}); } catch {}
        }
        for(const el of observed) if(!el.isConnected) { observed.delete(el);visible.delete(el);observer.unobserve(el); }
        schedule();
      }
      function enqueue(root) {
        if(root?.nodeType!==1 || root.closest(ignored)) return;
        if(scans.length<24) scans.push({root,walker:document.createTreeWalker(root,NodeFilter.SHOW_ELEMENT),first:true});
        if(!scanTimer && active) scanTimer=setTimeout(scan,100);
      }
      function scan() {
        scanTimer=null; if(!active) return;
        let count=0;
        while(scans.length && count++<100) {
          const task=scans[0], el=task.first ? task.root : task.walker.nextNode(); task.first=false;
          if(!el) { scans.shift();continue; }
          if(observed.size>=maxObserved) {
            const old=Array.from(observed).find(n=>!visible.has(n));
            if(old) { observed.delete(old);observer.unobserve(old); } else { scans=[];break; }
          }
          if(el.matches(candidates) && !el.closest(ignored) && !el.parentElement?.closest('article,[role="article"]')) {
            if(!observed.has(el)) { observed.add(el);observer.observe(el); }
          }
        }
        if(scans.length) scanTimer=setTimeout(scan,100);
      }
      function visitViewport() {
        settleTimer=null; if(!active) return;
        if(performance.now()-lastScroll<400) { settleTimer=setTimeout(visitViewport,750);return; }
        // Recover visible blocks beyond the bounded observer set on long pages.
        // This runs once after scrolling settles, never for every scroll event.
        for(const x of [.2,.5,.8]) for(const y of [.15,.4,.65,.9]) {
          const el=document.elementFromPoint(innerWidth*x,innerHeight*y)?.closest(candidates);
          if(el && !el.closest(ignored)) {
            if(!observed.has(el)) {
              if(observed.size>=maxObserved) {
                const old=Array.from(observed).find(n=>!visible.has(n));
                if(!old)continue;observed.delete(old);observer.unobserve(old);
              }
              observed.add(el);observer.observe(el);
            }
            visible.add(el);capture(el);
          }
        }
      }
      const onScroll=()=>{lastScroll=performance.now();if(!settleTimer)settleTimer=setTimeout(visitViewport,750);};
      function drainDirty() {
        dirtyTimer=null;if(!active)return;
        for(const el of Array.from(dirty).slice(0,4)) { dirty.delete(el);capture(el); }
        if(dirty.size)dirtyTimer=setTimeout(drainDirty,250);
      }
      function stop() {
        active=false; observer?.disconnect();mutations?.disconnect();
        clearTimeout(timer);clearTimeout(scanTimer);clearTimeout(settleTimer);clearTimeout(dirtyTimer);timer=scanTimer=settleTimer=dirtyTimer=null;
        dirty.clear();
        observed.clear();visible.clear();pending.clear();scans=[];
        removeEventListener('scroll',onScroll,true);
      }
      globalThis.__bowserHistory={stop,start(nextToken,includeImages) {
        if(active && token===nextToken) { images=includeImages;return; }
        stop();active=true;token=nextToken;images=includeImages;fingerprints=new WeakMap();
        observer=new IntersectionObserver(entries=>{
          for(const e of entries) {
            if(e.isIntersecting && e.intersectionRatio>=.3) { visible.add(e.target);capture(e.target); }
            else visible.delete(e.target);
          }
        },{threshold:[0,.3]});
        mutations=new MutationObserver(records=>{
          let count=0;
          for(const m of records) {
            if(count++>=48) break;
            const el=m.target.nodeType===1 ? m.target : m.target.parentElement;
            const block=el?.closest('article,[role="article"]') || el?.closest(candidates);
            if(block && visible.has(block) && dirty.size<16) dirty.add(block);
            for(const n of Array.from(m.addedNodes).slice(0,12)) enqueue(n);
          }
          if(dirty.size && !dirtyTimer)dirtyTimer=setTimeout(drainDirty,250);
        });
        if(document.body) { enqueue(document.body);mutations.observe(document.body,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['src','alt']}); }
        addEventListener('scroll',onScroll,{passive:true,capture:true});
        settleTimer=setTimeout(visitViewport,750);
      }};
    })();
    """#

    static let validateImage = #"""
    const img=document.elementFromPoint(rect.x+rect.width/2,rect.y+rect.height/2);
    if(!img || img.tagName!=='IMG' || img.currentSrc!==src)return false;
    const r=img.getBoundingClientRect();
    if(['x','y','width','height'].some(k=>Math.abs(r[k]-rect[k])>1))return false;
    const fields=document.querySelectorAll('input,textarea,select,[contenteditable]:not([contenteditable="false"]),[role="textbox"],[data-private],[data-sensitive]');
    if(fields.length>64)return false;
    return !Array.from(fields).some(n=>{
      const f=n.getBoundingClientRect();return f.width>0&&f.height>0&&f.left<r.right&&f.right>r.left&&f.top<r.bottom&&f.bottom>r.top;
    });
    """#
}
