import JavaScriptCore
import XCTest
@testable import Bowser

final class MediaRecoveryTests: XCTestCase {
    private func fixture(_ setup: String = "") -> JSContext {
        let context = JSContext()!
        context.evaluateScript("""
        var window=globalThis;window.top=window;
        var now=1000000;Date.now=()=>now;
        var location={host:'media.example',pathname:'/watch',search:''};
        var key='bowser-media-v3:media.example/watch';
        var values={},writes=[],attempts=0,denyStorage=false;
        var localStorage={getItem:k=>values[k] || null,setItem:(k,v)=>{
          attempts++;if(denyStorage) throw Error('denied');values[k]=v;writes.push({key:k,data:JSON.parse(v)});
        }};
        var listeners={document:{},window:{}};
        function listen(owner,type,fn) {(listeners[owner][type] ||= new Set()).add(fn);}
        function emit(type,target,owner='document') {
          for(const fn of [...(listeners[owner][type] || [])]) fn({type,target:target || document});
        }
        window.addEventListener=(t,f)=>listen('window',t,f);
        window.removeEventListener=(t,f)=>listeners.window[t]?.delete(f);
        var timers=new Map(),nextTimer=0;
        var setTimeout=(fn,delay)=>{timers.set(++nextTimer,{fn,at:now+delay});return nextTimer;};
        var clearTimeout=id=>timers.delete(id);
        var setInterval=()=>{throw Error('Media recovery must not poll');};
        function advance(ms) {
          const end=now+ms;
          while(true) {
            const next=[...timers].filter(([id,t])=>t.at<=end).sort((a,b)=>a[1].at-b[1].at)[0];
            if(!next) break;
            now=next[1].at;timers.delete(next[0]);next[1].fn();
          }
          now=end;
        }
        var warms=0;window.webkit={messageHandlers:{bowserMediaWarm:{postMessage:()=>warms++}}};
        function media(src) {
          return {src,currentSrc:src,srcObject:null,currentTime:0,duration:100,readyState:1,
            paused:true,ended:false,isConnected:true,plays:0,pauses:0,
            matches:s=>s==='video,audio',contains:()=>false,
            play(){this.plays++;this.paused=false;return Promise.resolve();},
            pause(){this.pauses++;this.paused=true;},
            requestFullscreen(){this.fullscreenRequested=true;return Promise.resolve();}};
        }
        var correct=media('https://cdn.example/video.mp4'),wrong=media('https://cdn.example/other.mp4');
        var available=[],queries=0,buttons=[];
        var document={visibilityState:'visible',fullscreenElement:null,
          addEventListener:(t,f)=>listen('document',t,f),
          querySelectorAll:s=>{if(s!=='video,audio')throw Error('Unexpected DOM scan');queries++;return available;},
          body:{appendChild:()=>{}},
          createElement:tag=>{var el={style:{},setAttribute:()=>{},remove:()=>{},attachShadow:()=>({appendChild:()=>{}})};
            if(tag==='button')buttons.push(el);return el;}};
        function snapshot(overrides={}) {
          values[key]=JSON.stringify({runtime:'previous',src:correct.src,t:42,paused:false,at:now,fullscreen:false,...overrides});
        }
        \(setup)
        """)
        XCTAssertNil(context.exception)
        context.evaluateScript(MediaRecovery.makeScript(runtime: "current"))
        XCTAssertNil(context.exception)
        return context
    }

    private func run(_ script: String, in context: JSContext, file: StaticString = #filePath, line: UInt = #line) {
        context.evaluateScript(script)
        XCTAssertNil(context.exception, context.exception?.toString() ?? "", file: file, line: line)
    }

    func testIdlePageHasNoRecurringWork() {
        let context = fixture()
        let queries = context.evaluateScript("queries")!.toInt32()
        run("advance(60000)", in: context)
        XCTAssertEqual(context.evaluateScript("timers.size")?.toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("writes.length")?.toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("queries")?.toInt32(), queries)
    }

    func testPlaybackEventsThrottleWritesAndFlushFinalPosition() {
        let context = fixture("available=[correct];")
        run("""
        correct.paused=false;emit('play',correct);
        for(let i=0;i<120;i++){advance(10);correct.currentTime=i/10;emit('timeupdate',correct);}
        """, in: context)
        XCTAssertEqual(context.evaluateScript("writes.length")?.toInt32(), 2)
        XCTAssertEqual(context.evaluateScript("queries")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("timers.size")?.toInt32(), 0)
        run("correct.paused=true;correct.currentTime=12;emit('pause',correct);", in: context)
        XCTAssertEqual(context.evaluateScript("writes.length")?.toInt32(), 3)
        XCTAssertEqual(context.evaluateScript("writes.at(-1).data.t")?.toDouble(), 12)
        XCTAssertEqual(context.evaluateScript("writes.at(-1).data.paused")?.toBool(), true)
        run("""
        for(let i=0;i<20;i++){advance(1000);emit('timeupdate',correct);}
        """, in: context)
        XCTAssertEqual(context.evaluateScript("writes.length")?.toInt32(), 3)
        run("advance(120000);document.visibilityState='hidden';emit('visibilitychange');emit('pagehide',null,'window');", in: context)
        XCTAssertEqual(context.evaluateScript("writes.length")?.toInt32(), 4)
        XCTAssertEqual(context.evaluateScript("writes.at(-1).data.at === now")?.toBool(), true)
    }

    func testHideAndPagehideFlushBeforeNextCheckpoint() {
        let context = fixture("available=[correct];correct.paused=false;")
        run("""
        correct.currentTime=1;emit('timeupdate',correct);
        advance(100);correct.currentTime=1.1;document.visibilityState='hidden';emit('visibilitychange');
        advance(100);correct.currentTime=1.2;emit('pagehide',null,'window');
        """, in: context)
        XCTAssertEqual(context.evaluateScript("writes.length")?.toInt32(), 3)
        XCTAssertEqual(context.evaluateScript("writes.at(-1).data.t")?.toDouble(), 1.2)
    }

    func testOnlyStableSeekableMediaIsSavedOrRestored() {
        for setup in ["correct.srcObject={};", "correct.duration=Infinity;", "correct.duration=NaN;",
                      "correct.currentSrc=correct.src='blob:ephemeral';", "correct.isConnected=false;"] {
            let context = fixture("snapshot();available=[correct];\(setup)")
            XCTAssertEqual(context.evaluateScript("correct.currentTime")?.toDouble(), 0, setup)
            XCTAssertEqual(context.evaluateScript("correct.plays")?.toInt32(), 0, setup)
            run("advance(20000);correct.currentTime=10;correct.paused=false;emit('play',correct);emit('timeupdate',correct);emit('pause',correct);", in: context)
            XCTAssertEqual(context.evaluateScript("writes.length")?.toInt32(), 0, setup)
        }
    }

    func testFreshSnapshotWaitsForMatchingMetadataWithoutPolling() {
        let context = fixture("snapshot();available=[wrong];")
        XCTAssertEqual(context.evaluateScript("warms")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("timers.size")?.toInt32(), 1)
        let queries = context.evaluateScript("queries")?.toInt32()
        run("advance(10000);emit('timeupdate',wrong);", in: context)
        XCTAssertEqual(context.evaluateScript("queries")?.toInt32(), queries)
        XCTAssertEqual(context.evaluateScript("wrong.currentTime")?.toDouble(), 0)
        XCTAssertEqual(context.evaluateScript("writes.length")?.toInt32(), 0)
        run("available=[wrong,correct];emit('loadedmetadata',correct);", in: context)
        XCTAssertEqual(context.evaluateScript("correct.currentTime")?.toDouble(), 42)
        XCTAssertEqual(context.evaluateScript("correct.plays")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("wrong.currentTime")?.toDouble(), 0)
        XCTAssertEqual(context.evaluateScript("timers.size")?.toInt32(), 0)
    }

    func testInvalidAndSameRuntimeSnapshotsDoNotReplayOrWarm() {
        for override in ["{runtime:'current'}", "{at:now-120001}", "{at:now+1000}",
                         "{t:-1}", "{src:'blob:old'}", "{paused:'false'}"] {
            let context = fixture("snapshot(\(override));available=[correct];")
            XCTAssertEqual(context.evaluateScript("warms")?.toInt32(), 0, override)
            XCTAssertEqual(context.evaluateScript("correct.currentTime")?.toDouble(), 0, override)
            XCTAssertEqual(context.evaluateScript("timers.size")?.toInt32(), 0, override)
        }
    }

    func testPausedSnapshotRestoresWithoutAutoplayOrBackgroundWarm() {
        let context = fixture("snapshot({paused:true});available=[correct];")
        XCTAssertEqual(context.evaluateScript("warms")?.toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("correct.currentTime")?.toDouble(), 42)
        XCTAssertEqual(context.evaluateScript("correct.paused")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("correct.plays")?.toInt32(), 0)
    }

    func testAmbiguousDuplicateSourcesAreNotRestored() {
        let context = fixture("snapshot();wrong.src=wrong.currentSrc=correct.src;available=[wrong,correct];")
        run("emit('canplay',correct);advance(20000);", in: context)
        XCTAssertEqual(context.evaluateScript("correct.currentTime")?.toDouble(), 0)
        XCTAssertEqual(context.evaluateScript("wrong.currentTime")?.toDouble(), 0)
        XCTAssertEqual(context.evaluateScript("timers.size")?.toInt32(), 0)
    }

    func testExpiredCancelledOrNavigatedRecoveryDoesNotSeekLateMedia() {
        for cancel in ["advance(20000)", "now+=20001", "emit('wheel',null,'window')", "emit('keydown',null,'window')",
                       "location.pathname='/other';emit('popstate',null,'window')", "emit('pagehide',null,'window')"] {
            let context = fixture("snapshot();")
            run("\(cancel);available=[correct];emit('canplay',correct);", in: context)
            XCTAssertEqual(context.evaluateScript("correct.currentTime")?.toDouble(), 0, cancel)
            XCTAssertEqual(context.evaluateScript("timers.size")?.toInt32(), 0, cancel)
            XCTAssertEqual(context.evaluateScript("listeners.window.wheel.size")?.toInt32(), 0, cancel)
        }
    }

    func testFullscreenRecoveryRequiresExplicitClickAndChecksSource() {
        let context = fixture("snapshot({fullscreen:true});available=[correct];")
        XCTAssertEqual(context.evaluateScript("!!correct.fullscreenRequested")?.toBool(), false)
        XCTAssertEqual(context.evaluateScript("buttons[0].textContent")?.toString(), "Resume fullscreen video")
        run("buttons[0].onclick();", in: context)
        XCTAssertEqual(context.evaluateScript("correct.fullscreenRequested")?.toBool(), true)
        let changed = fixture("snapshot({fullscreen:true});available=[correct];")
        run("correct.currentSrc='https://cdn.example/new.mp4';buttons[0].onclick();", in: changed)
        XCTAssertEqual(changed.evaluateScript("!!correct.fullscreenRequested")?.toBool(), false)
    }

    func testStorageFailuresStayThrottledAndCanRecover() {
        let context = fixture("available=[correct];correct.paused=false;denyStorage=true;")
        run("for(let i=0;i<100;i++){advance(10);correct.currentTime=i+1;emit('timeupdate',correct);}", in: context)
        XCTAssertEqual(context.evaluateScript("attempts")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("writes.length")?.toInt32(), 0)
        run("denyStorage=false;advance(1000);emit('timeupdate',correct);", in: context)
        XCTAssertEqual(context.evaluateScript("writes.length")?.toInt32(), 1)
    }

    func testRouteChangesCannotRestoreOrWritePreviousPlayerUnderNewRoute() {
        let context = fixture("available=[correct];correct.paused=false;")
        run("correct.currentTime=10;emit('timeupdate',correct);location.pathname='/other';emit('pagehide',null,'window');", in: context)
        XCTAssertEqual(context.evaluateScript("writes.length")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("writes[0].key")?.toString(), "bowser-media-v3:media.example/watch")
    }
}
