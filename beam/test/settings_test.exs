defmodule BowserBrain.SettingsTest do
  use ExUnit.Case, async: false
  alias BowserBrain.Settings

  setup do
    root = Path.join(System.tmp_dir!(), "settings-#{System.unique_integer([:positive])}")
    old_path = Application.get_env(:bowser_brain, :settings_path)
    old_state = :sys.get_state(Settings)
    Application.put_env(:bowser_brain, :settings_path, Path.join(root, "settings.json"))

    assert Settings.path() == Path.join(root, "settings.json"),
           "Refusing settings writes outside the fixture"

    :sys.replace_state(Settings, fn _ -> %{declared: %{}} end)

    on_exit(fn ->
      :sys.replace_state(Settings, fn _ -> old_state end)

      if old_path,
        do: Application.put_env(:bowser_brain, :settings_path, old_path),
        else: Application.delete_env(:bowser_brain, :settings_path)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "settings roundtrip through isolated disk, preserving unrelated keys", %{root: root} do
    assert Settings.path() == Path.join(root, "settings.json")
    assert Settings.get("missing", "fallback") == "fallback"
    assert :ok = Settings.put("first", "hello")
    assert :ok = Settings.put("second", "world")
    assert JSON.decode!(File.read!(Settings.path())) == %{"first" => "hello", "second" => "world"}
    assert :ok = Settings.delete("first")
    assert Settings.all() == %{"second" => "world"}
    File.write!(Settings.path(), "invalid json")
    assert Settings.all() == %{}
  end

  test "DockTabs defaults and immediate controls preserve typed preferences" do
    assert Settings.dock_preferences() == %{always_show: false, reduce_motion: false}
    state = %{declared: %{}}
    edit = fn id, value ->
      Settings.handle_info({:browser_event, %{"event" => "surface", "surface" => "settings", "id" => id, "value" => value}}, state)
    end
    deck = BowserBrain.TabDeck.handle_event(%{"event" => "hello", "tabs" => [], "active" => nil}, BowserBrain.TabDeck.initial_state())
    edit.("dock_always_show", nil)
    updated = BowserBrain.TabDeck.handle_event(%{"event" => "dock_settings_changed"}, deck)
    assert updated.last_items == deck.last_items
    assert updated.last_preferences.always_show
    assert Settings.dock_preferences() == %{always_show: true, reduce_motion: false}
    edit.("dock_quiet_auto_hide", nil)
    assert Settings.dock_preferences() == %{always_show: false, reduce_motion: true}
    edit.("dock_auto_hide", nil)
    assert Settings.dock_preferences() == %{always_show: false, reduce_motion: false}
  end

  test "saved DockTabs preferences map to one mode, and an explicit selection takes precedence" do
    stored = %{"dock_visibility" => "auto_hide", "dock_reduce_motion" => true}
    assert Settings.dock_behavior(stored) == "quiet_auto_hide"
    assert Settings.dock_behavior(%{stored | "dock_visibility" => "always_show"}) == "always_show"
    assert Settings.dock_behavior(Map.put(stored, "dock_behavior", "auto_hide")) == "auto_hide"
  end

  test "deleting an unset key works before the settings directory exists" do
    assert :ok = Settings.delete("absent")
    assert Settings.all() == %{}
  end

  test "declared and inferred secrets never expose even short values in summaries" do
    Settings.declare("credential", secret: true, about: "Service login")
    Settings.declare("not_configured", about: "Optional setting")
    Settings.put("credential", "abc")
    Settings.put("api_token", "uniquesecret123")
    Settings.put("theme", "dark")
    summary = Settings.summary()
    assert Settings.declarations()["credential"].secret
    assert summary =~ "Service login"
    assert summary =~ "NOT set"
    assert summary =~ "dark"
    refute summary =~ "abc"
    refute summary =~ "unique"
  end

  test "General does not expose stored configuration or retained internal declarations" do
    internal = ~w(ai_provider openai_api_key anthropic_api_key bowser_api_endpoint
                  dodorouter_endpoint dodorouter_api_key modsmith_model modsmith_timeout_ms action_budget)
    declared = Map.new(internal, &{&1, %{about: "Old configuration", secret: false}})
    stored = Map.new(internal ++ ["old_unused_key"], &{&1, "configured"})
    Enum.each(stored, fn {key, value} -> Settings.put(key, value) end)

    tree = JSON.encode!(Settings.view(declared, Settings.all()))
    for key <- internal, do: refute(tree =~ key)
    assert Settings.all() == stored
  end

  test "only declared mod preferences render and their credentials remain masked" do
    declared = %{
      "reading_voice" => %{about: "Voice for reading", secret: false},
      "reading_credential" => %{about: "Reading service login", secret: true},
      "ai_provider" => %{about: "Old built-in declaration", secret: false}
    }
    tree = Settings.view(declared, %{"reading_voice" => "warm", "reading_credential" => "sensitive-value", "old_key" => "hidden"})
    fields = for %{trailing: [field]} <- tree.children, do: field
    assert Enum.map(fields, & &1.event) == ["reading_credential", "reading_voice"]
    assert Enum.map(fields, & &1.placeholder) == ["••••••", "warm"]
    refute JSON.encode!(tree) =~ "sensitive-value"
    refute JSON.encode!(tree) =~ "old_key"
  end

  test "stale raw settings controls cannot alter hidden keys while mod settings remain editable" do
    Settings.put("bowser_api_endpoint", "https://configured.invalid")
    state = %{declared: %{"reading_voice" => %{secret: false}, "bowser_api_endpoint" => %{secret: false}}}
    edit = fn key, value ->
      Settings.handle_info({:browser_event, %{"event" => "surface", "surface" => "settings", "id" => key, "value" => value}}, state)
    end
    assert {:noreply, ^state} = edit.("bowser_api_endpoint", "https://other.invalid")
    assert {:noreply, ^state} = edit.("undeclared", "value")
    assert Settings.get("bowser_api_endpoint") == "https://configured.invalid"
    assert Settings.get("undeclared") == nil
    assert {:noreply, ^state} = edit.("reading_voice", " warm ")
    assert Settings.get("reading_voice") == "warm"
    assert {:noreply, ^state} = edit.("reading_voice", "")
    assert Settings.get("reading_voice") == nil
  end

end
