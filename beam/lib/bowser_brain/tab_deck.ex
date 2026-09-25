defmodule BowserBrain.TabDeck do
  use BowserBrain.CoreFeature

  import BowserBrain.View

  # Left-edge, mostly-hidden dock of tab favicons with proximity magnification.
  # Replaces the native tab strip (Chrome.hide_tab_bar). Click an icon to focus
  # that tab.
  #
  # Rot & recency: tabs age visually. Focus counts as "use" only after
  # DWELL milliseconds — quick peeks refresh nothing. A used tab keeps a warm
  # glow for RECENT_MS after focus leaves it; idle icons fade toward the rot
  # floor over ROT_MS. A slow tick re-renders, but ships nothing while the
  # quantized appearance (1/20 steps) is unchanged.

  @dwell_ms 5_000
  @recent_ms 10 * 60_000
  @fresh_ms 10 * 60_000
  @rot_ms 8 * 3_600_000
  @rot_floor 0.45
  @tick_ms 5_000

  def initial_state() do
    %{tabs: %{}, order: [], active: nil}
  end

  # Full tab snapshot on connect — rebuild from scratch (also prunes closed tabs).
  def handle_event(%{"event" => "hello"} = ev, state) do
    BowserBrain.Chrome.hide_tab_bar()
    base = %{state | tabs: %{}, order: []} |> Map.put(:last_items, nil)

    state =
      ev
      |> Map.get("tabs", [])
      |> Enum.reduce(base, fn t, acc ->
        case Map.get(t, "id") do
          nil ->
            acc

          wv ->
            acc = put_tab(acc, wv, favicon: Map.get(t, "favicon"), title: Map.get(t, "title"), profile: Map.get(t, "profile"), url: Map.get(t, "url"))
            acc
        end
      end)

    state = %{state | active: Map.get(ev, "active", state.active)}
    # Fresh engine = fresh surfaces; hello also restarts the decay tick chain.
    Process.send_after(self(), :decay_tick, @tick_ms)
    state |> stamp_focus() |> render()
  end

  def handle_event(%{"event" => "tab_opened", "webview" => wv} = ev, state) do
    state |> put_tab(wv, profile: ev["profile"]) |> apply_order(ev["order"]) |> render()
  end

  def handle_event(%{"event" => "tabs_reordered", "order" => order}, state),
    do: state |> apply_order(order) |> render()

  def handle_event(%{"event" => "tab_activated", "webview" => wv}, state),
    do: state |> focus(wv) |> render()

  # Closed tabs leave the dock immediately — without this every ⌘W left a
  # phantom icon until the next engine roll (bowser-browser-55l).
  def handle_event(%{"event" => "webview_closed", "webview" => wv}, state) do
    if Map.has_key?(state.tabs, wv) or wv in state.order do
      %{
        state
        | tabs: Map.delete(state.tabs, wv),
          order: List.delete(state.order, wv),
          active: if(state.active == wv, do: nil, else: state.active)
      }
      |> render()
    else
      state
    end
  end

  def handle_event(%{"event" => "favicon_changed", "webview" => wv, "path" => path}, state) do
    state |> put_tab(wv, favicon: path) |> render()
  end

  def handle_event(%{"event" => "url_changed", "webview" => wv, "url" => url}, state) do
    state |> put_tab(wv, url: url) |> render()
  end

  def handle_event(%{"event" => "title_changed"} = ev, state) do
    case Map.get(ev, "webview", state.active) do
      nil -> state
      wv -> state |> put_tab(wv, title: Map.get(ev, "title")) |> render()
    end
  end

  # Dock click -> focus that tab. value is the item id we set (webview id).
  def handle_event(
        %{"event" => "surface", "surface" => "edge_dock", "id" => "select", "value" => v},
        state
      ) do
    case Enum.find(state.order, fn wv -> to_string(wv) == to_string(v) end) do
      nil ->
        state

      wv ->
        focus_tab(wv)
        render(focus(state, wv))
    end
  end

  def handle_event(%{"event" => "surface", "surface" => "edge_dock", "id" => "cycle_profile"}, state) do
    case cycle_target(state, BowserBrain.Profiles.list()) do
      {:tab, wv} ->
        focus_tab(wv)
        render(focus(state, wv))
      {:window, profile} ->
        BowserBrain.Chrome.open_window(profile)
        state
      nil -> state
    end
  end

  @doc false
  def cycle_target(state, profiles) do
    ids = profiles |> Enum.map(& &1["id"]) |> Enum.uniq()
    if length(ids) > 1 do
      index = Enum.find_index(ids, &(&1 == active_profile(state)))
      next = Enum.at(ids, if(index == nil, do: 0, else: rem(index + 1, length(ids))))
      case Enum.find(state.order, &(profile_of(state, &1) == next)) do
        nil -> {:window, next}
        wv -> {:tab, wv}
      end
    end
  end

  def handle_event(%{"event" => "mod_reloaded"}, state) do
    BowserBrain.Chrome.hide_tab_bar()
    render(state)
  end

  def handle_event(_ev, state), do: state

  # -- decay ticking ---------------------------------------------------------
  # One chain per engine connection: hello starts it, each tick reschedules.
  # Handoff freeze tolerates a queued tick (Handoff.poll_message?); ticks are
  # no-ops while the rendered items are unchanged.

  def handle_info(:decay_tick, state) do
    Process.send_after(self(), :decay_tick, @tick_ms)
    {:noreply, render(state)}
  end

  def handle_info(other, state), do: super(other, state)

  # -- helpers ---------------------------------------------------------------

  @doc """
  The dock-item aging for one tab: `dim` is icon opacity (1.0 → #{@rot_floor},
  over #{@rot_ms / 3_600_000} hours of idleness) and `glow` the 0–1 warm halo
  for tabs focused at least #{@dwell_ms / 1000} seconds, decaying over the
  following #{@recent_ms / 60_000} minutes. The active tab never dims; a focus
  shorter than the dwell threshold counts as no use at all. Values quantize to
  1/20 steps so timed re-renders ship only real changes. Public for tests.
  """
  def appearance(tab, active, now) when is_map(tab) and is_boolean(active) and is_integer(now) do
    anchor = Map.get(tab, :last_used) || Map.get(tab, :opened_at) || now
    age = if active, do: 0, else: max(0, now - anchor)
    dim = 1.0 - clamp01((age - @fresh_ms) / (@rot_ms - @fresh_ms)) * (1.0 - @rot_floor)

    glow =
      cond do
        active and now - Map.get(tab, :focused_since, now) >= @dwell_ms -> 1.0
        active -> 0.0
        true ->
          case Map.get(tab, :last_used) do
            nil -> 0.0
            used -> clamp01(1.0 - max(0, now - used) / @recent_ms)
          end
      end

    %{dim: quantize(dim), glow: quantize(glow)}
  end

  @doc """
  Ends the outgoing active tab's dwell at `now`: a dwell of at least
  #{@dwell_ms / 1000} seconds stamps `last_used` (the tab was really used);
  shorter peeks stamp nothing. Always clears `focused_since`. Public for tests.
  """
  def settle_dwell(%{active: nil} = state, _now), do: state

  def settle_dwell(state, now) do
    case Map.get(state.tabs, state.active) do
      nil -> state
      tab ->
        dwell = now - Map.get(tab, :focused_since, now)
        tab = tab |> Map.delete(:focused_since) |> then(fn t -> if dwell >= @dwell_ms, do: Map.put(t, :last_used, now), else: t end)
        put_in(state, [:tabs, state.active], tab)
    end
  end

  @doc """
  The dock shows only the ACTIVE window's profile: tabs whose profile is the
  active tab's (a tab with no recorded profile counts as default). With no
  active tab yet, everything shows. Public for tests.
  """
  def visible_order(state) do
    case active_profile(state) do
      nil -> state.order
      active_profile -> Enum.filter(state.order, &(profile_of(state, &1) == active_profile))
    end
  end

  def active_profile(state), do: state.active && profile_of(state, state.active)

  defp profile_of(state, wv), do: Map.get(Map.get(state.tabs, wv, %{}), :profile) || "default"

  defp put_tab(state, wv, attrs) do
    tab =
      case Map.get(state.tabs, wv) do
        nil -> %{favicon: nil, title: nil, opened_at: now_ms()}
        tab -> tab
      end

    tab =
      Enum.reduce(attrs, tab, fn
        {_k, nil}, acc -> acc
        {k, val}, acc -> Map.put(acc, k, val)
      end)

    order = if wv in state.order, do: state.order, else: state.order ++ [wv]
    %{state | tabs: Map.put(state.tabs, wv, tab), order: order}
  end

  # Switch focus locally: settle the outgoing tab's dwell (stamps its recency
  # when it was really used), then start the incoming tab's dwell. Both the
  # engine's tab_activated and our own dock clicks pass through here.
  defp focus(state, wv) do
    now = now_ms()

    state
    |> settle_dwell(now)
    |> Map.put(:active, wv)
    |> put_tab(wv, [])
    |> update_tab(wv, &Map.put(&1, :focused_since, now))
  end

  defp update_tab(state, wv, fun) do
    case Map.get(state.tabs, wv) do
      nil -> state
      tab -> %{state | tabs: Map.put(state.tabs, wv, fun.(tab))}
    end
  end

  defp stamp_focus(%{active: nil} = state), do: state
  defp stamp_focus(state), do: update_tab(state, state.active, &Map.put(&1, :focused_since, now_ms()))

  defp now_ms, do: System.system_time(:millisecond)
  defp clamp01(x), do: min(1.0, max(0.0, x))
  defp quantize(x) when is_number(x), do: round(x * 20) / 20

  defp apply_order(state, order) when is_list(order) do
    known = Enum.filter(Enum.uniq(order), &Map.has_key?(state.tabs, &1))
    %{state | order: known ++ (state.order -- known)}
  end
  defp apply_order(state, _), do: state

  defp render(state) do
    # The header identifies the active profile; tab artwork needs no repeated badge.
    profiles = BowserBrain.Profiles.list()
    rank = profiles |> Enum.map(& &1["id"]) |> Enum.with_index() |> Map.new()
    now = now_ms()

    grouped =
      Enum.sort_by(visible_order(state), fn wv ->
        Map.get(rank, Map.get(Map.get(state.tabs, wv, %{}), :profile) || "default", 99)
      end)

    host_counts =
      grouped
      |> Enum.map(&host_of(state.tabs[&1][:url]))
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()

    items =
      Enum.map(grouped, fn wv ->
        tab = Map.get(state.tabs, wv, %{favicon: nil, title: nil})
        active = wv == state.active
        look = appearance(tab, active, now)

        base = %{
          id: to_string(wv),
          active: active,
          title: tab.title || "Tab #{wv}",
          dim: look.dim,
          glow: look.glow
        }

        # Same-domain tabs get a per-URL tint dot so identical favicons stay
        # distinguishable. The hue is a pure hash of the full URL: stable
        # across close/reopen and independent of which other tabs exist.
        base =
          with host when not is_nil(host) <- host_of(tab[:url]),
               true <- Map.get(host_counts, host, 0) > 1 do
            Map.put(base, :tint, domain_tint(tab[:url]))
          else
            _ -> base
          end

        case tab.favicon do
          nil -> Map.put(base, :symbol, "globe")
          path -> Map.put(base, :path, path)
        end
      end)

    # Decay ticks land here between events; only ship real changes.
    if items == Map.get(state, :last_items) do
      state
    else
      BowserBrain.Surface.show(
        :edge_dock,
        magnify_strip(items, size: 32, spacing: 8, magnify: 1.4, event: "select",
          header: profile_header(active_profile(state)), header_height: 82, header_outside: true, chrome: "notch")
        |> Map.put(:profile_id, active_profile(state)),
        title: "Tabs",
        kind: :edge,
        edge: :left,
        peek: 3,
        attach: :screen,
        width: 48
      )

      Map.put(state, :last_items, items)
    end
  end

  @doc "Lowercased host for domain grouping; nil when the tab has no usable URL."
  def host_of(nil), do: nil
  def host_of(url) when is_binary(url) do
    case URI.parse(url).host do
      nil -> nil
      host -> String.downcase(host)
    end
  end

  @doc "Stable per-URL marker color (#rrggbb): hue from the URL hash, fixed saturation/lightness."
  def domain_tint(url) when is_binary(url) do
    <<a, b, _::binary>> = :crypto.hash(:blake2s, url)
    hsl_hex((a * 256 + b) / 65535 * 360, 0.62, 0.62)
  end

  defp hsl_hex(h, s, l) do
    c = (1 - abs(2 * l - 1)) * s
    hp = h / 60
    x = c * (1 - abs(:math.fmod(hp, 2) - 1))

    {r, g, b} =
      cond do
        hp < 1 -> {c, x, 0}
        hp < 2 -> {x, c, 0}
        hp < 3 -> {0, c, x}
        hp < 4 -> {0, x, c}
        hp < 5 -> {x, 0, c}
        true -> {c, 0, x}
      end

    m = l - c / 2

    [r, g, b]
    |> Enum.map_join(fn v -> round((v + m) * 255) |> Integer.to_string(16) |> String.pad_leading(2, "0") end)
    |> then(&("#" <> String.downcase(&1)))
  end

  def profile_header(nil), do: nil
  def profile_header(id) do
    profile = Enum.find(BowserBrain.Profiles.list(), &(&1["id"] == id)) || %{}
    name = if id == "default", do: "Default", else: profile["name"] || id
    profile_avatar(id, size: 18, badge: true, help: "Profile: " <> name)
  end

  defp focus_tab(wv) do
    BowserBrain.Surface.activate_tab(wv)
  end
end
