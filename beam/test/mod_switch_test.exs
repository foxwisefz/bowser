defmodule ModSwitchModTest do
  use ExUnit.Case, async: true

  test "tab and global scopes are separate, including subdomains and blank tabs" do
    alias BowserBrain.ModControls
    assert ModControls.visible_scope?("x.com", "x.com", false)
    assert ModControls.visible_scope?("x.com", "www.x.com", false)
    refute ModControls.visible_scope?("x.com", "notx.com", false)
    refute ModControls.visible_scope?("x.com", "example.com", false)
    refute ModControls.visible_scope?("x.com", nil, false)
    refute ModControls.visible_scope?(nil, "x.com", false)
    assert ModControls.visible_scope?(nil, "x.com", true)
    assert ModControls.visible_scope?(nil, nil, true)
    refute ModControls.visible_scope?("x.com", "x.com", true)
  end

  test "toolbar selects its originating tab and scope with old process state" do
    state = %{active: 0, urls: %{42 => "https://x.com"}}
    next = BowserBrain.ModControls.handle_event(%{"event" => "chrome_click", "id" => "global_mods", "webview" => 42}, state)
    assert next.active == 42
    assert next.show_global
    next = BowserBrain.ModControls.handle_event(%{"event" => "chrome_click", "id" => "mods", "webview" => 42}, next)
    refute next.show_global
  end

  test "toolbar catalog includes disabled site mods, profiles and host mods but excludes global mods" do
    root = Path.join(System.tmp_dir!(), "toolbar-catalog-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(Path.join(root, "sites/x.com"))
    File.mkdir_p!(Path.join(root, "mods"))
    File.write!(Path.join(root, "sites/x.com/reader.css.off"), "/* bowser-profile: work */\nbody {}")
    File.write!(Path.join(root, "mods/reader.ex"), ~s(use BowserBrain.Mod, host: "x.com"))
    File.write!(Path.join(root, "mods/global.ex"), "use BowserBrain.Mod")
    File.write!(Path.join(root, "sites/x.com/notes.txt"), "ignore")
    entries = BowserBrain.ModControls.toolbar_catalog(root)
    assert length(entries) == 2
    assert Enum.find(entries, &(&1.id == "site|x.com|reader.css.off")) ==
      %{id: "site|x.com|reader.css.off", title: "reader.css", host: "x.com", profile: "work", on: false, subdomains: false}
    assert Enum.find(entries, &(&1.id == "mod|reader.ex")).subdomains
  end

  describe "modname/1" do
    test "reads the defmodule name out of mod source" do
      assert BowserBrain.ModControls.modname("# comment\ndefmodule EdgeDockTabs do\nend") == "EdgeDockTabs"
      assert BowserBrain.ModControls.modname("defmodule My.Nested_Mod do") == "My.Nested_Mod"
      assert BowserBrain.ModControls.modname("no module here") == nil
    end
  end

  describe "toggle_path/1 and enabled?/1" do
    test "off is a rename, on is the rename undone" do
      assert BowserBrain.ModControls.toggle_path("a.css") == "a.css.off"
      assert BowserBrain.ModControls.toggle_path("a.css.off") == "a.css"
      assert BowserBrain.ModControls.toggle_path("dock.ex") == "dock.ex.off"
      assert BowserBrain.ModControls.enabled?("a.css")
      refute BowserBrain.ModControls.enabled?("a.css.off")
    end
  end

  describe "describe_source/1" do
    test "elixir leading comment" do
      assert BowserBrain.ModControls.describe_source("# The panel directory: lists panels.\ndefmodule X do") ==
               "The panel directory: lists panels."
    end

    test "js line comment and css block comment" do
      assert BowserBrain.ModControls.describe_source("// music resume after rolls\n(function(){})()") ==
               "music resume after rolls"

      assert BowserBrain.ModControls.describe_source("/* Timeline-only view for x.com */\nheader {}") ==
               "Timeline-only view for x.com"
    end

    test "no comment yields nil; long lines truncate" do
      assert BowserBrain.ModControls.describe_source("defmodule X do\nend") == nil
      long = "# " <> String.duplicate("a", 100)
      assert String.length(BowserBrain.ModControls.describe_source(long)) <= 61
    end
  end

  describe "host_of_source/1" do
    test "reads the Mod host: declaration" do
      assert BowserBrain.ModControls.host_of_source(~s(use BowserBrain.Mod, host: "x.com")) == "x.com"
      assert BowserBrain.ModControls.host_of_source("use BowserBrain.Mod") == nil
    end
  end

  describe "info expansion" do
    test "the (i) button toggles a row's description open and closed" do
      state = %{active: 0, urls: %{}, info: MapSet.new()}
      ev = %{"event" => "surface", "surface" => "mods", "id" => "info", "value" => "mod|tabs.ex"}

      state = BowserBrain.ModControls.handle_event(ev, state)
      assert MapSet.member?(state.info, "mod|tabs.ex")

      state = BowserBrain.ModControls.handle_event(ev, state)
      refute MapSet.member?(state.info, "mod|tabs.ex")
    end
  end

  describe "parse_toggle/1" do
    test "site and mod payloads round-trip" do
      assert BowserBrain.ModControls.parse_toggle("site|x.com|plurk.css") == {:site, "x.com", "plurk.css"}
      assert BowserBrain.ModControls.parse_toggle("mod|custom.ex") == {:mod, "custom.ex"}
      assert BowserBrain.ModControls.parse_toggle("garbage") == :error
    end
  end

  describe "edit_path/1 (✎ → ModSmith)" do
    test "maps row payloads to catalog paths, stripping .off" do
      assert BowserBrain.ModControls.edit_path("mod|dock.ex") == "mods/dock.ex"
      assert BowserBrain.ModControls.edit_path("mod|nav.ex.off") == "mods/nav.ex"
      assert BowserBrain.ModControls.edit_path("site|x.com|font.css.off") == "sites/x.com/font.css"
      assert BowserBrain.ModControls.edit_path("garbage") == nil
    end
  end

  test "toggle_payload accepts a switch map or a plain button payload" do
    assert BowserBrain.ModControls.toggle_payload(%{"on" => false, "payload" => "mod|dock.ex"}) == "mod|dock.ex"
    assert BowserBrain.ModControls.toggle_payload("site|x.com|a.css") == "site|x.com|a.css"
  end

  test "should_flip? is idempotent for switches and always true for plain buttons" do
    refute BowserBrain.ModControls.should_flip?(%{"on" => true, "payload" => "mod|dock.ex"})
    assert BowserBrain.ModControls.should_flip?(%{"on" => false, "payload" => "mod|dock.ex"})
    refute BowserBrain.ModControls.should_flip?(%{"on" => false, "payload" => "mod|nav.ex.off"})
    assert BowserBrain.ModControls.should_flip?(%{"on" => true, "payload" => "site|x.com|a.css.off"})
    assert BowserBrain.ModControls.should_flip?("mod|dock.ex")
  end
end
