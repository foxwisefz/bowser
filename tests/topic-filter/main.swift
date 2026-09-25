import AppKit
import WebKit

struct Failure: Error { let message: String }
@MainActor final class Probe: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { @MainActor in
      do { try await run(); print("Topic Filter WebKit fixtures passed"); exit(0) }
      catch { fputs("Topic Filter fixture failed: \(error)\n", stderr); exit(1) }
    }
  }
  func run() async throws {
    let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    let window = NSWindow(contentRect: NSRect(x:0,y:0,width:900,height:700), styleMask:[.titled], backing:.buffered, defer:false)
    let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: window.contentView!.bounds, configuration:configuration)
    window.contentView!.addSubview(web); window.makeKeyAndOrderFront(nil)
    func js(_ code: String) async throws -> Any { try await web.evaluateJavaScript(code) as Any }
    func check(_ code: String, _ message: String) async throws {
      guard try await js(code) as? Bool == true else { throw Failure(message:message) }
    }
    let fixtures: [(String,String)] = [
      ("https://x.com/home", "<article data-testid='tweet'><a href='/author/status/1'><time>now</time></a><div data-testid='tweetText'>A post about politics and elections today.</div></article>"),
      ("https://www.reddit.com/r/test", "<shreddit-post id='t3_one' post-title='A post about politics and elections today.'><div slot='text-body'>More detail.</div></shreddit-post>"),
      ("https://www.youtube.com/watch?v=test", "<ytd-comment-view-model><span id='published-time-text'><a href='?v=test&lc=one'>now</a></span><div id='content-text'>A comment about politics and elections today.</div></ytd-comment-view-model>"),
      ("https://news.ycombinator.com/", "<table><tbody><tr class='athing' id='one'><td><span class='titleline'><a>Politics and elections today.</a></span></td></tr></tbody></table>"),
      ("https://www.linkedin.com/feed/", "<div class='feed-shared-update-v2' data-urn='one'><div class='update-components-text'>A post about politics and elections today.</div></div>")
    ]
    for (url, body) in fixtures {
      web.loadHTMLString("<html><body>\(body)</body></html>", baseURL:URL(string:url))
      for _ in 0..<100 {
        if !web.isLoading, (try? await js("document.readyState")) as? String == "complete" { break }
        try await Task.sleep(for:.milliseconds(50))
      }
      _ = try await js("window.events=[];window.bowser={emit:e=>events.push(e)};window.tick=null;window.setInterval=f=>(window.tick=f,1);window.clearInterval=()=>{};true")
      let settings: [String:Any] = ["enabled":true,"consent":true,"paused_until":0,"site_x":true,"site_reddit":true,"site_youtube":true,"site_hn":true,"site_linkedin":true,"mode":"cover","politics":true,"custom":""]
      func script(_ settings: [String:Any], _ generation:Int = 1) throws -> String {
        let data = try JSONSerialization.data(withJSONObject:["settings":settings,"generation":generation])
        return source.replacingOccurrences(of:"__TOPIC_FILTER_CONFIG__", with:String(decoding:data,as:UTF8.self))
      }
      _ = try await js(try script(settings))
      try await check("events.filter(e=>e.kind==='topic-filter').length===1", "extract one target: \(url)")
      _ = try await js("window.request=events.find(e=>e.kind==='topic-filter');window.__bowserTopicFilter.apply(request,{labels:['Politics'],cached:false,uncertain:false});true")
      try await check("document.querySelector('[role=status]').textContent.includes('1 evaluated · 1 hidden')", "hide counters: \(url)")
      _ = try await js("tick();tick();true")
      try await check("events.filter(e=>e.kind==='topic-filter').length===1", "deduplication: \(url)")
      try await check("!request.text.includes('Topic Filter')", "UI excluded: \(url)")
      _ = try await js("[...document.querySelectorAll('button')].find(b=>b.textContent.startsWith('Topic Filter · Politics')).click();true")
      try await check("document.querySelector('[role=status]').textContent.includes('0 hidden')", "reveal: \(url)")
      _ = try await js("tick();true")
      try await check("document.querySelector('[role=status]').textContent.includes('0 hidden')", "reveal survives scan: \(url)")
      _ = try await js(try script(settings,2))
      _ = try await js("window.__bowserTopicFilter.apply(request,{labels:['Politics']});true")
      try await check("document.querySelector('[role=status]').textContent.includes('0 evaluated')", "stale generation: \(url)")
      _ = try await js("window.fresh=events.filter(e=>e.kind==='topic-filter').at(-1);window.__bowserTopicFilter.apply(fresh,{error:'Service unavailable'});true")
      try await check("document.querySelector('[role=status]').textContent.includes('Service unavailable')", "error visible: \(url)")
      for mode in ["dim", "remove"] {
        var changed = settings; changed["mode"] = mode
        _ = try await js(try script(changed,4))
        _ = try await js("window.current=events.filter(e=>e.kind==='topic-filter').at(-1);window.__bowserTopicFilter.apply(current,{labels:['Politics']});tick();true")
        try await check("document.querySelector('[role=status]').textContent.includes('1 hidden')", "presentation \(mode): \(url)")
        _ = try await js("[...document.querySelectorAll('button')].find(b=>b.textContent==='Show hidden').click();true")
        try await check("document.querySelector('[role=status]').textContent.includes('0 hidden')", "show all \(mode): \(url)")
      }
      _ = try await js(try script(settings,5))
      _ = try await js("window.oldRequest=events.filter(e=>e.kind==='topic-filter').at(-1);document.querySelector('[data-testid=tweetText], [slot=text-body], #content-text, .titleline a, .update-components-text').textContent='Edited content about cooking';window.__bowserTopicFilter.apply(oldRequest,{labels:['Politics']});true")
      try await check("document.querySelector('[role=status]').textContent.includes('0 hidden')", "edited post rejects stale result: \(url)")
      _ = try await js("window.current=events.filter(e=>e.kind==='topic-filter').at(-1);window.__bowserTopicFilter.apply(current,{labels:[],uncertain:true});true")
      try await check("document.querySelector('[role=status]').textContent.includes('1 evaluated · 0 hidden')", "all keep is evaluated: \(url)")
      if url.contains("x.com") {
        _ = try await js("history.pushState({},'', '/messages/123');window.events=[];tick();true")
        try await check("events.every(e=>e.kind!=='topic-filter') && document.querySelector('[data-bowser-topic-ui]').hidden", "SPA inbox excluded")
      }
      var disabled = settings; disabled["enabled"] = false
      _ = try await js("window.events=[];true")
      _ = try await js(try script(disabled,3))
      try await check("events.every(e=>e.kind!=='topic-filter')", "disabled sends no text: \(url)")
      try await check("[...document.querySelectorAll('button')].some(b=>b.textContent==='Turn on…') && ![...document.querySelectorAll('button')].some(b=>b.textContent==='Resume this tab')", "off offers setup, not resume: \(url)")
      _ = try await js("[...document.querySelectorAll('button')].find(b=>b.textContent==='Turn on…').click();true")
      try await check("events.at(-1).kind==='topic-filter-settings' && events.every(e=>e.kind!=='topic-filter')", "turn on routes to settings without granting consent: \(url)")

      _ = try await js("window.__bowserTopicFilter.dispose();true")
      try await check("document.querySelectorAll('[data-bowser-topic-ui]').length===0", "dispose removes UI: \(url)")
    }
  }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Probe(); app.delegate = delegate
app.run()
