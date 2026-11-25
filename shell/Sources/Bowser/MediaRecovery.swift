import Foundation

/// Event-driven recovery for seekable media with a stable source URL.
enum MediaRecovery {
    static let runtime = UUID().uuidString
    static let script = makeScript(runtime: runtime)

    static func makeScript(runtime: String) -> String {
        """
        (() => {
          if (window.top !== window) return;
          const runtime = '\(runtime)';
          const route = () => location.pathname + location.search;
          const key = () => 'bowser-media-v3:' + location.host + route();
          const stableSource = src => typeof src === 'string' && /^(https?:|file:)/.test(src);
          let pending=null, current=null, recoveryUI=null, expiry=null;
          let currentRoute=route(), lastWrite=-Infinity, lastState=null;
          const recoveryDeadline=Date.now()+20000;
          function source(m) {
            // MediaStreams, live broadcasts and blob URLs cannot be safely
            // identified and seeked across browser processes.
            if (!m?.isConnected || m.srcObject || !Number.isFinite(m.duration) || m.duration<=0) return null;
            const src=m.currentSrc || m.src;
            return stableSource(src) ? src : null;
          }
          try {
            const d=JSON.parse(localStorage.getItem(key()) || 'null');
            if(d && typeof d.runtime==='string' && d.runtime!==runtime &&
               Number.isFinite(d.at) && Date.now()-d.at<120000 && Date.now()>=d.at &&
               stableSource(d.src) && Number.isFinite(d.t) && d.t>=0 && typeof d.paused==='boolean') pending=d;
          } catch (_) {}
          function dismiss() { recoveryUI?.remove(); recoveryUI=null; }
          function finish() {
            pending=null;
            if(expiry!==null) clearTimeout(expiry);
            expiry=null;
            window.removeEventListener('wheel',cancel);
            window.removeEventListener('keydown',cancel);
          }
          function cancel() { finish();dismiss(); }
          function checkRoute() {
            if(route()===currentRoute) return;
            cancel();current=null;currentRoute=route();lastWrite=-Infinity;lastState=null;
          }
          function offer(label, m, src, action) {
            const offeredRoute=currentRoute;
            const valid=()=>route()===offeredRoute && source(m)===src;
            if(recoveryUI || !document.body || !valid()) return;
            const host=document.createElement('div'); recoveryUI=host;
            host.style.cssText='position:fixed;bottom:24px;right:24px;z-index:2147483647';
            const root=host.attachShadow({mode:'closed'});
            const button=document.createElement('button');button.textContent=label;
            button.style.cssText='font:14px system-ui;padding:12px 18px;border:1px solid #777;border-radius:12px;background:#202124;color:white;cursor:pointer';
            button.onclick=()=>{if(valid()) action();dismiss();};root.appendChild(button);
            const close=document.createElement('button');close.textContent='×';close.setAttribute('aria-label','Dismiss video recovery');
            close.style.cssText='font:18px system-ui;padding:10px;border:0;background:#202124;color:white;cursor:pointer';
            close.onclick=dismiss;root.appendChild(close);document.body.appendChild(host);
          }
          function save(flush=false) {
            checkRoute();
            if(pending) return;
            const m=current, src=source(m);
            if(!src || !Number.isFinite(m.currentTime) || m.currentTime<0) return;
            const paused=m.paused || m.ended;
            if(!flush && (paused || Date.now()-lastWrite<1000)) return;
            if(paused && m.currentTime===0) return;
            const full=document.fullscreenElement;
            const state={src,t:m.currentTime,paused,
              fullscreen:!!(m.webkitDisplayingFullscreen || (full && (full===m || full.contains(m))))};
            const signature=JSON.stringify(state);
            // A final save refreshes freshness even after a long pause, but
            // adjacent hide/pagehide events need only one identical write.
            if(signature===lastState && (!flush || Date.now()-lastWrite<1000)) return;
            // Throttle even when storage is unavailable.
            lastWrite=Date.now();
            try {
              localStorage.setItem(key(),JSON.stringify({...state,runtime,at:Date.now()}));
              lastState=signature;
            } catch (_) {}
          }
          function restore() {
            checkRoute();
            if(!pending) return;
            if(Date.now()>=recoveryDeadline) {finish();return;}
            const d=pending;
            const matches=Array.from(document.querySelectorAll('video,audio')).filter(m=>source(m)===d.src);
            if(matches.length!==1 || matches[0].readyState<1) return;
            const m=matches[0];
            try { m.currentTime=Math.min(d.t,Math.max(0,m.duration-0.1)); }
            catch (_) { return; } // A later metadata/canplay event can make it seekable.
            finish();current=m;
            if(d.paused) m.pause();
            else m.play().catch(()=>offer('Resume video',m,d.src,()=>m.play().catch(()=>{})));
            if(d.fullscreen) offer('Resume fullscreen video',m,d.src,()=>{
              if(m.requestFullscreen) m.requestFullscreen().catch(()=>{});
              else m.webkitEnterFullscreen?.();
              if(!d.paused) m.play().catch(()=>{});
            });
          }
          function onMedia(e) {
            if(!e.target.matches?.('video,audio')) return;
            checkRoute();
            if(pending) {
              if(['loadedmetadata','durationchange','canplay','play','playing'].includes(e.type)) restore();
              if(pending) return;
            }
            if(e.type==='play' || e.type==='playing' || !current?.isConnected) current=e.target;
            if(e.target!==current) return;
            if(e.type==='timeupdate') save();
            else if(['pause','ended','seeked','webkitbeginfullscreen','webkitendfullscreen'].includes(e.type)) save(true);
          }
          for(const event of ['play','playing','timeupdate','pause','ended','seeked',
                              'loadedmetadata','durationchange','canplay','webkitbeginfullscreen','webkitendfullscreen']) {
            document.addEventListener(event,onMedia,true);
          }
          document.addEventListener('fullscreenchange',()=>save(true));
          document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='hidden') save(true);});
          window.addEventListener('pagehide',()=>{save(true);cancel();});
          window.addEventListener('popstate',checkRoute);
          if(pending) {
            // One bounded recovery window, with retries driven by media events.
            expiry=setTimeout(finish,20000);
            window.addEventListener('wheel',cancel,{passive:true});
            window.addEventListener('keydown',cancel);
            if(!pending.paused) window.webkit?.messageHandlers?.bowserMediaWarm?.postMessage({runtime});
            restore();
          } else {
            // A player may already be running when document-end scripts arrive.
            current=Array.from(document.querySelectorAll('video,audio')).find(m=>source(m) && !m.paused && !m.ended) || null;
          }
        })();
        """
    }
}
