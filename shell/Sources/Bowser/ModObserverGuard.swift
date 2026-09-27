import Foundation

/// Cooperative protection for mod-owned observer chains, not a JavaScript sandbox.
enum ModObserverGuard {
    static let setup = """
    const NativeObserver = globalThis.MutationObserver;
    const now = performance.now.bind(performance);
    const registryKey = Symbol.for('bowser.mod-observers.v1');
    const registry = globalThis[registryKey] || (globalThis[registryKey] = new Map());
    const key = typeof scriptKey === 'string' ? scriptKey : 'anonymous';
    const previous = registry.get(key);
    if (previous) previous.stop();
    const observers = new Set();
    let stopped = false, calls = 0, elapsed = 0, resetPending = false;
    const resetChannel = new MessageChannel();
    resetChannel.port1.onmessage = () => { calls = 0; elapsed = 0; resetPending = false; };
    const stop = () => {
      stopped = true;
      for (const observer of observers) observer.disconnect();
      observers.clear();
      resetChannel.port1.close(); resetChannel.port2.close();
    };
    registry.set(key, {stop});
    const pause = () => {
      if (stopped) return;
      stop();
      try { window.webkit.messageHandlers.bowserScriptFault.postMessage({token: scriptToken}); } catch (_) {}
    };
    class GuardedMutationObserver extends NativeObserver {
      constructor(callback) {
        if (typeof callback !== 'function') throw new TypeError('Observer callback must be a function');
        super((records, observer) => {
          if (stopped) return;
          // A message task can run only once the microtask chain yields. A self-triggering
          // observer never yields, so its shared per-script budget cannot reset.
          if (!resetPending) {
            resetPending = true;
            resetChannel.port2.postMessage(0);
          }
          if (++calls > 100 || elapsed >= 50) { pause(); return; }
          const started = now();
          try { callback.call(observer, records, observer); }
          finally { elapsed += now() - started; if (elapsed >= 50) pause(); }
        });
      }
      observe(target, options) {
        if (stopped) return;
        super.observe(target, options);
        observers.add(this);
      }
      disconnect() { super.disconnect(); observers.delete(this); }
    }
    """
}
