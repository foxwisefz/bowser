defmodule BowserBrain.UserContentTest do
  use ExUnit.Case, async: true
  alias BowserBrain.UserContent

  test "releasing a disabled mod removes its scripts and scoped styles across profiles" do
    state = %{
      scripts: %{{:notes, "work"} => ["notes JS"],
        {{:scoped_styles, :notes}, "work"} => ["notes CSS"],
        {:notes, "personal"} => ["other profile notes"],
        {:other, "work"} => ["keep JS"]},
      styles: %{{:notes, "personal"} => ["global CSS"], {:other, "work"} => ["keep CSS"]}
    }
    {:reply, :ok, next} = UserContent.handle_call({:release, :notes}, nil, state)
    assert next.scripts == %{{:other, "work"} => ["keep JS"]}
    assert next.styles == %{{:other, "work"} => ["keep CSS"]}
    assert {:reply, :ok, ^next} = UserContent.handle_call({:release, :notes}, nil, next)
  end

  test "replacing and clearing one owner retains other owners and content kinds" do
    state = %{scripts: %{}, styles: %{}}

    {:reply, :ok, state} =
      UserContent.handle_call({:put, :scripts, {:a, "work"}, ["old"], false}, nil, state)

    {:reply, :ok, state} =
      UserContent.handle_call({:put, :scripts, {:b, "work"}, ["keep"], false}, nil, state)

    {:reply, :ok, state} =
      UserContent.handle_call({:put, :styles, {:a, "work"}, ["css"], false}, nil, state)

    {:reply, :ok, state} =
      UserContent.handle_call({:put, :scripts, {:a, "work"}, ["replacement"], false}, nil, state)

    assert state.scripts == %{{:a, "work"} => ["replacement"], {:b, "work"} => ["keep"]}

    {:reply, :ok, state} =
      UserContent.handle_call({:put, :scripts, {:a, "work"}, [], false}, nil, state)

    assert state.scripts == %{{:b, "work"} => ["keep"]}
    assert state.styles == %{{:a, "work"} => ["css"]}
  end
  test "scoped styles replace independently of scripts and clear on host changes" do
    key = {:owner, "work"}
    scoped = {{:scoped_styles, :owner}, "work"}
    state = %{scripts: %{key => ["keep JS"]}, styles: %{key => ["old global CSS"]}}
    {:reply, :ok, state} = UserContent.handle_call({:put_styles, key, ["body{}"], "one.test", false}, nil, state)
    assert state.scripts[key] == ["keep JS"]
    assert [%{host: "one.test", world: "isolated"}] = state.scripts[scoped]
    refute Map.has_key?(state.styles, key)
    {:reply, :ok, state} = UserContent.handle_call({:put_styles, key, ["p{}"], "two.test", false}, nil, state)
    assert [%{host: "two.test"}] = state.scripts[scoped]
    {:reply, :ok, state} = UserContent.handle_call({:put_styles, key, ["global{}"], nil, false}, nil, state)
    refute Map.has_key?(state.scripts, scoped)
    assert state.styles[key] == ["global{}"]
    {:reply, :ok, state} = UserContent.handle_call({:put_styles, key, [], nil, false}, nil, state)
    assert state.styles == %{}
    assert state.scripts == %{key => ["keep JS"]}
  end

  @tag skip: if(System.find_executable("node"), do: false, else: "Node.js is required to execute the preservation script")
  test "preservation deletes field snapshots without reading them and only saves scroll" do
    harness = ~S"""
    const assert = require('node:assert/strict');
    const vm = require('node:vm');
    const now = Date.now();
    const scrollKey = 'bowser-scroll:example.com/page';
    const reads = [];
    function storage(initial) {
      const values = new Map(Object.entries(initial));
      return {
        values,
        get length() { return values.size; },
        key(i) { return [...values.keys()][i]; },
        getItem(key) {
          reads.push(key);
          assert.ok(!key.startsWith('bowser-preserve:'), 'must not read saved fields');
          return values.get(key) || null;
        },
        setItem(key, value) { values.set(key, value); },
        removeItem(key) { values.delete(key); }
      };
    }
    const local = storage({
      'bowser-preserve:example.com/page': '{"f":{"token":"sensitive"},"y":90}',
      'bowser-preserve:example.com/other': '{"f":{"draft":"private"}}',
      'website-preference': 'keep',
      [scrollKey]: JSON.stringify({ y: 320, at: now })
    });
    const session = storage({ 'bowser-preserve:example.com/page': 'private' });
    const listeners = {};
    const win = {
      scrollY: 0, innerHeight: 100,
      addEventListener(name, fn) { listeners[name] = fn; },
      scrollTo(x, y) { this.scrollY = y; }
    };
    const doc = {
      readyState: 'complete',
      scrollingElement: { scrollHeight: 1000 },
      querySelectorAll() { throw new Error('must not inspect form fields'); },
      addEventListener(name) { assert.equal(name, 'visibilitychange'); }
    };
    const context = {
      window: win, document: doc, location: { host: 'example.com', pathname: '/page' },
      localStorage: local, sessionStorage: session,
      setTimeout() {},
      clearTimeout() {},
      setInterval() { throw new Error('must not poll form values'); }
    };
    vm.runInNewContext(process.argv[1], context);
    assert.equal(win.scrollY, 320);
    assert.equal(session.length, 0);
    assert.equal(local.getItem('website-preference'), 'keep');
    assert.ok(![...local.values.keys()].some(key => key.startsWith('bowser-preserve:')));
    win.scrollY = 0;
    listeners.scroll();
    listeners.pagehide();
    const saved = JSON.parse(local.getItem(scrollKey));
    assert.deepEqual(Object.keys(saved).sort(), ['at', 'y']);
    assert.equal(saved.y, 0);
    assert.equal(typeof saved.at, 'number');
    assert.ok(!('input' in listeners) && !('keyup' in listeners));
    console.log('scroll-only preservation passed');
    """

    {output, status} = System.cmd("node", ["-e", harness, UserContent.preservation_script()], stderr_to_stdout: true)
    assert status == 0, output
  end

  @tag skip: if(System.find_executable("node"), do: false, else: "Node.js is required to execute the preservation script")
  test "scroll persistence batches gestures and flushes the latest position on lifecycle events" do
    harness = ~S"""
    const assert = require('node:assert/strict');
    const vm = require('node:vm');
    const source = process.argv[1];
    function fixture() {
      let now = 100000, nextTimer = 0, storageAvailable = true;
      const timers = new Map(), writes = [], windowListeners = {}, documentListeners = {};
      const storage = {
        length: 0, getItem() { return null; },
        setItem(key, value) {
          if (!storageAvailable) throw new Error('storage unavailable');
          writes.push({ key, ...JSON.parse(value) });
        }
      };
      const win = {
        scrollY: 0,
        addEventListener(name, fn, options) {
          if (name === 'scroll') assert.equal(options.passive, true);
          windowListeners[name] = fn;
        }
      };
      const doc = {
        readyState: 'complete', visibilityState: 'visible',
        addEventListener(name, fn) { documentListeners[name] = fn; }
      };
      vm.runInNewContext(source, {
        window: win, document: doc, location: { host: 'example.com', pathname: '/feed' },
        localStorage: storage, sessionStorage: storage, Date: { now: () => now },
        setTimeout(fn, delay) { const id = nextTimer++; timers.set(id, { fn, at: now + delay }); return id; },
        clearTimeout(id) { timers.delete(id); }
      });
      return {
        writes,
        scroll(y) { win.scrollY = y; windowListeners.scroll(); },
        advance(ms) {
          const end = now + ms;
          for (;;) {
            const next = [...timers].sort((a, b) => a[1].at - b[1].at)[0];
            if (!next || next[1].at > end) break;
            now = next[1].at; timers.delete(next[0]); next[1].fn();
          }
          now = end;
        },
        hide() { doc.visibilityState = 'hidden'; documentListeners.visibilitychange(); },
        show() { doc.visibilityState = 'visible'; documentListeners.visibilitychange(); },
        leave() { windowListeners.pagehide(); },
        storage(available) { storageAvailable = available; }
      };
    }

    const burst = fixture();
    for (let i = 1; i <= 60; i++) { burst.scroll(i * 10); burst.advance(8); }
    assert.equal(burst.writes.length, 0, 'a scroll burst must not synchronously write storage');
    burst.advance(250);
    assert.deepEqual(burst.writes.map(w => [w.key, w.y]), [['bowser-scroll:example.com/feed', 600]]);
    burst.advance(2000);
    assert.equal(burst.writes.length, 1, 'settled pages must not keep writing');

    const continuous = fixture();
    for (let i = 1; i <= 240; i++) { continuous.scroll(i); continuous.advance(10); }
    assert.equal(continuous.writes.length, 2, 'long gestures retain periodic checkpoints');
    assert.deepEqual(continuous.writes.map(w => w.y), [100, 200]);
    continuous.advance(250);
    assert.equal(continuous.writes.at(-1).y, 240, 'the final position must be saved');

    for (const event of ['hide', 'leave']) {
      const page = fixture();
      page.scroll(123); page[event]();
      assert.equal(page.writes.at(-1).y, 123, event + ' must flush pending scroll');
      page.advance(2000);
      assert.equal(page.writes.length, 1, event + ' must cancel delayed writes');
      page.show();
      assert.equal(page.writes.length, 1, 'becoming visible does not require a write');
      page.scroll(0); page.advance(250);
      assert.equal(page.writes.at(-1).y, 0, 'saving still works after returning to the page');
    }

    const unavailable = fixture();
    unavailable.storage(false); unavailable.scroll(42);
    assert.doesNotThrow(() => unavailable.advance(1500));
    assert.doesNotThrow(() => unavailable.leave());
    unavailable.storage(true); unavailable.scroll(84); unavailable.advance(250);
    assert.equal(unavailable.writes.at(-1).y, 84, 'a storage error must not stop later saves');
    console.log('batched scroll preservation passed');
    """

    {output, status} = System.cmd("node", ["-e", harness, UserContent.preservation_script()], stderr_to_stdout: true)
    assert status == 0, output
  end

end
