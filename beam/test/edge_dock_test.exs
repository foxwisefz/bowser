defmodule EdgeDockTabsTest do
  use ExUnit.Case, async: false

  defp base, do: %{tabs: %{}, order: [], active: nil}

  defp ev(state, map), do: BowserBrain.TabDeck.handle_event(map, state)

  test "profile cycle follows profile order, wraps, and reuses existing tabs" do
    profiles = Enum.map(["default", "work", "reading"], &%{"id" => &1})
    state = %{tabs: %{1 => %{profile: "default"}, 2 => %{profile: "work"}}, order: [1, 2], active: 1}
    assert BowserBrain.TabDeck.cycle_target(state, profiles) == {:tab, 2}
    assert BowserBrain.TabDeck.cycle_target(%{state | active: 2}, profiles) == {:window, "reading"}
    state = %{state | tabs: Map.put(state.tabs, 3, %{profile: "reading"}), order: [1, 2, 3], active: 3}
    assert BowserBrain.TabDeck.cycle_target(state, profiles) == {:tab, 1}
    assert BowserBrain.TabDeck.cycle_target(state, [%{"id" => "default"}]) == nil
    assert BowserBrain.TabDeck.cycle_target(state, []) == nil
  end

  test "native insertion order overrides event arrival order" do
    state = base()
      |> ev(%{"event" => "hello", "tabs" => [%{"id" => 1}, %{"id" => 2}], "active" => 1})
      |> ev(%{"event" => "tab_opened", "webview" => 3, "order" => [1, 3, 2]})
    assert state.order == [1, 3, 2]
    state = ev(state, %{"event" => "tabs_reordered", "order" => [2, 1, 3]})
    assert state.order == [2, 1, 3]
    assert state.active == 1
  end

  test "closed tabs leave the dock — no phantom icons (bowser-browser-55l)" do
    state =
      base()
      |> ev(%{"event" => "tab_opened", "webview" => 1})
      |> ev(%{"event" => "tab_opened", "webview" => 2})
      |> ev(%{"event" => "tab_activated", "webview" => 2})
      |> ev(%{"event" => "webview_closed", "webview" => 2})

    assert state.order == [1]
    refute Map.has_key?(state.tabs, 2)
    # The closed tab was active: don't keep pointing at a ghost.
    assert state.active == nil
  end

  test "closing a background tab keeps the active one" do
    state =
      base()
      |> ev(%{"event" => "tab_opened", "webview" => 1})
      |> ev(%{"event" => "tab_opened", "webview" => 2})
      |> ev(%{"event" => "tab_activated", "webview" => 1})
      |> ev(%{"event" => "webview_closed", "webview" => 2})

    assert state.order == [1]
    assert state.active == 1
  end

  test "closing an unknown webview is a no-op" do
    state = base() |> ev(%{"event" => "tab_opened", "webview" => 1})
    assert ^state = BowserBrain.TabDeck.handle_event(%{"event" => "webview_closed", "webview" => 9}, state)
  end

  test "same-domain tabs get stable per-URL tint dots; lone domains get none" do
    state =
      base()
      |> ev(%{"event" => "tab_opened", "webview" => 1})
      |> ev(%{"event" => "tab_opened", "webview" => 2})
      |> ev(%{"event" => "tab_opened", "webview" => 3})
      |> ev(%{"event" => "url_changed", "webview" => 1, "url" => "https://x.y.com/a"})
      |> ev(%{"event" => "url_changed", "webview" => 2, "url" => "https://x.y.com/b"})
      |> ev(%{"event" => "url_changed", "webview" => 3, "url" => "https://elsewhere.org/"})

    [one, two, three] = state.last_items

    assert one.tint =~ ~r/^#[0-9a-f]{6}$/
    assert two.tint =~ ~r/^#[0-9a-f]{6}$/
    assert one.tint != two.tint

    # Path-hash stability: the color is a pure function of the URL.
    assert one.tint == BowserBrain.TabDeck.domain_tint("https://x.y.com/a")

    # A lone-domain tab needs no disambiguation dot.
    refute Map.has_key?(three, :tint)
  end

  test "host_of downcases and rejects bad URLs" do
    assert BowserBrain.TabDeck.host_of("https://X.y.COM/a") == "x.y.com"
    assert BowserBrain.TabDeck.host_of(nil) == nil
    assert BowserBrain.TabDeck.host_of("not a url") == nil
  end
  test "visible_order shows only the active tab's profile; unknown profile = default; no active = all" do
    state =
      base()
      |> ev(%{"event" => "tab_opened", "webview" => 1, "profile" => "default"})
      |> ev(%{"event" => "tab_opened", "webview" => 2, "profile" => "work"})
      |> ev(%{"event" => "tab_opened", "webview" => 3})
      |> ev(%{"event" => "tab_opened", "webview" => 4, "profile" => "work"})

    assert BowserBrain.TabDeck.active_profile(state) == nil
    assert BowserBrain.TabDeck.active_profile(%{state | active: 2}) == "work"
    assert BowserBrain.TabDeck.active_profile(%{state | active: 3}) == "default"
    assert BowserBrain.TabDeck.visible_order(state) == [1, 2, 3, 4]
    assert BowserBrain.TabDeck.visible_order(%{state | active: 2}) == [2, 4]
    assert BowserBrain.TabDeck.visible_order(%{state | active: 3}) == [1, 3]
  end

  describe "rot and recency" do
    defp look(tab, active \\ false, now \\ 1_000_000),
      do: BowserBrain.TabDeck.appearance(tab, active, now)

    test "fresh tabs are full opacity with no glow" do
      assert look(%{opened_at: 1_000_000 - 9 * 60_000}) == %{dim: 1.0, glow: 0.0}
      assert look(%{}) == %{dim: 1.0, glow: 0.0}
    end

    test "idle tabs rot: fade after ten minutes, floor at eight hours" do
      # 4h idle: 1 - (240-10)/(470 min) * 0.55 ≈ 0.73, quantized to 0.75
      assert look(%{opened_at: 1_000_000 - 4 * 3_600_000}).dim == 0.75
      assert look(%{opened_at: 1_000_000 - 8 * 3_600_000}).dim == 0.45
      assert look(%{opened_at: 1_000_000 - 30 * 24 * 3_600_000}).dim == 0.45
    end

    test "the active tab never dims and glows only after a 5s dwell" do
      assert look(%{focused_since: 1_000_000 - 4_999}, true) == %{dim: 1.0, glow: 0.0}
      assert look(%{focused_since: 1_000_000 - 5_000}, true) == %{dim: 1.0, glow: 1.0}
      assert look(%{}, true) == %{dim: 1.0, glow: 0.0}
    end

    test "a used tab keeps a decaying glow for ten minutes after focus leaves" do
      assert look(%{last_used: 1_000_000 - 60_000}).glow == 0.9
      assert look(%{last_used: 1_000_000 - 3 * 60_000}).glow == 0.7
      assert look(%{last_used: 1_000_000 - 11 * 60_000}).glow == 0.0
      # A fresh use also clears accumulated rot.
      assert look(%{last_used: 1_000_000 - 60_000, opened_at: 1_000_000 - 9 * 3_600_000}).dim == 1.0
    end

    test "settle_dwell: peeks under 5s count as no use, real dwell stamps last_used" do
      now = 1_000_000
      state = %{tabs: %{1 => %{focused_since: now - 4_999, opened_at: now - 60_000}, 2 => %{}}, order: [1, 2], active: 1}

      peek = BowserBrain.TabDeck.settle_dwell(state, now)
      refute Map.has_key?(peek.tabs[1], :last_used)
      refute Map.has_key?(peek.tabs[1], :focused_since)
      assert peek.tabs[2] == %{}

      used = BowserBrain.TabDeck.settle_dwell(%{state | tabs: Map.put(state.tabs, 1, %{focused_since: now - 5_000})}, now)
      assert used.tabs[1].last_used == now
      refute Map.has_key?(used.tabs[1], :focused_since)

      assert BowserBrain.TabDeck.settle_dwell(%{state | active: nil}, now) == %{state | active: nil}
    end

    test "switching tabs settles the outgoing dwell and starts the incoming one" do
      state =
        base()
        |> ev(%{"event" => "tab_opened", "webview" => 1})
        |> ev(%{"event" => "tab_opened", "webview" => 2})
        |> ev(%{"event" => "tab_activated", "webview" => 1})

      assert is_integer(state.tabs[1].focused_since)
      assert state.tabs[1].opened_at <= state.tabs[1].focused_since

      switched = ev(state, %{"event" => "tab_activated", "webview" => 2})
      assert switched.active == 2
      assert is_integer(switched.tabs[2].focused_since)
      # The 5s dwell hadn't elapsed in test time: a peek stamps nothing.
      refute Map.has_key?(switched.tabs[1], :focused_since)
      refute Map.has_key?(switched.tabs[1], :last_used)
    end

    test "decay ticks ship nothing while appearance is unchanged" do
      state = base() |> ev(%{"event" => "tab_opened", "webview" => 1})
      items = state.last_items
      assert List.first(items).dim == 1.0
      assert List.first(items).glow == 0.0

      assert {:noreply, %{last_items: ^items}} = BowserBrain.TabDeck.handle_info(:decay_tick, state)
    end
  end
end
