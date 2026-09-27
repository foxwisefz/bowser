# Built-in mod controls: `:mods` (or View →
# Mods) shows everything running against the CURRENT page — this host's
# site payloads and the global OTP mods — each row a one-click toggle.
# Off is the `.off` rename convention: SiteMods stops injecting a renamed
# payload within a second, and a disabled mod's process is terminated (the
# Loader restarts it when the file gets its name back). State survives
# restarts because it IS the filesystem.
defmodule BowserBrain.ModControls do
  use BowserBrain.CoreFeature

  import BowserBrain.View

  alias BowserBrain.{Chrome, Surface}

  def initial_state() do
    # info: which rows have their (i) description expanded.
    %{active: 0, urls: %{}, info: MapSet.new()}
  end

  def handle_event(%{"event" => "hello"} = hello, state) do
    assert_chrome()
    publish_toolbar_catalog()
    render(%{state | active: Map.get(hello, "active", state.active)})
  end

  def handle_event(%{"event" => "favicon_changed"}, state), do: render(state)

  def handle_event(%{"event" => "settings_opened"}, state), do: render(state)

  def handle_event(%{"event" => "tab_activated", "webview" => wv}, state) do
    render(%{state | active: wv})
  end

  def handle_event(%{"event" => "url_changed", "webview" => wv, "url" => url}, state) do
    next = %{state | urls: Map.put(state.urls, wv, url)}
    if wv == state.active, do: render(next), else: next
  end

  def handle_event(%{"event" => "omnibar_command", "text" => "mods"}, state), do: render(state, true)
  def handle_event(%{"event" => "chrome_click", "id" => id} = event, state)
      when id in ["mods", "global_mods"] do
    state
    |> Map.put(:active, Map.get(event, "webview", state.active))
    |> Map.put(:show_global, id == "global_mods")
    |> render(true)
  end

  def handle_event(%{"event" => "surface", "surface" => "mods", "id" => "scope"}, state) do
    state |> Map.put(:show_global, not Map.get(state, :show_global, false)) |> render()
  end

  def handle_event(
        %{"event" => "surface", "surface" => "mods", "id" => "toggle", "value" => raw},
        state
      ) do
    case should_flip?(raw) && parse_toggle(toggle_payload(raw)) do
      false ->
        state

      {:site, host, name} ->
        dir = Path.join([BowserBrain.Paths.home(), "sites", host])
        File.rename(Path.join(dir, name), Path.join(dir, toggle_path(name)))

      {:mod, name} ->
        dir = Path.join(BowserBrain.Paths.home(), "mods")
        path = Path.join(dir, name)

        if enabled?(name) do
          # Terminate the running process too — the rename alone only
          # prevents future starts.
          for module <- BowserBrain.Loader.modules_in(path) do
            for {pid, _} <- Registry.lookup(BowserBrain.ModRegistry, module) do
              DynamicSupervisor.terminate_child(BowserBrain.ModSupervisor, pid)
            end
            BowserBrain.UserContent.release(module)
          end
        end

        File.rename(path, Path.join(dir, toggle_path(name)))

      :error ->
        :ok
    end

    publish_toolbar_catalog()
    # Show the file change immediately; Loader notifies after the process changes.
    render(state)
  end

  # ⓘ click: expand/collapse this row's description (bowser-browser-ft0
  # refinement — compact rows, info on demand).
  def handle_event(
        %{"event" => "surface", "surface" => "mods", "id" => "info", "value" => key},
        state
      ) do
    expanded = expanded(state)

    info =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    render(Map.put(state, :info, info))
  end

  # ✎ click: hand this file to ModSmith to modify (its panel comes up with
  # the file pre-targeted; you type the change).
  def handle_event(
        %{"event" => "surface", "surface" => "mods", "id" => "edit", "value" => value},
        state
      ) do
    case edit_path(value) do
      nil -> :ok
      path -> BowserBrain.ModSmith.modify(path)
    end

    state
  end

  def handle_event(_event, state), do: state

  def handle_info(:catalog_changed, state) do
    publish_toolbar_catalog()
    {:noreply, render(state)}
  end

  def handle_info(other, state), do: super(other, state)

  # -- pure helpers (public for tests) ---------------------------------------

  @doc "The defmodule name inside mod source, or nil."
  def modname(source) do
    case Regex.run(~r/defmodule\s+([A-Za-z0-9_.]+)/, source) do
      [_, name] -> name
      _ -> nil
    end
  end

  @doc "a.css <-> a.css.off"
  def toggle_path(name) do
    if String.ends_with?(name, ".off"),
      do: String.replace_suffix(name, ".off", ""),
      else: name <> ".off"
  end

  def enabled?(name), do: not String.ends_with?(name, ".off")

  @doc """
  One-line description from a file's leading comment — Elixir `#`, JS `//`,
  or CSS `/* */` — nil when the file starts with code (bowser-browser-ft0).
  """
  def describe_source(source) do
    source
    |> String.split("\n", parts: 6)
    |> Enum.reject(&String.contains?(&1, "bowser-profile:"))
    |> Enum.find_value(fn line ->
      case Regex.run(~r{^\s*(?:#|//|/\*)\s*(.+?)\s*(?:\*/)?\s*$}, line) do
        [_, text] when text != "" -> String.slice(text, 0, 60)
        _ -> nil
      end
    end)
  end

  @doc "The host: a mod declared in `use BowserBrain.CoreFeature, host: ...`, or nil."
  def host_of_source(source) do
    case Regex.run(~r/use\s+BowserBrain\.Mod\s*,\s*host:\s*"([^"]+)"/, source) do
      [_, host] -> host
      _ -> nil
    end
  end

  @doc "A switch sends %{\"on\" => bool, \"payload\" => p}; a plain button sends p. Public for tests."
  def toggle_payload(%{"payload" => p}), do: p
  def toggle_payload(p), do: p

  @doc """
  Only flip when the switch asks for a state the file is not already in —
  a repeated or spurious emission must be a no-op (a blind toggle turned
  every render into a mass on/off flip). A plain button payload always flips.
  """
  def should_flip?(%{"on" => on, "payload" => p}) when is_boolean(on) do
    name = p |> String.split("|") |> List.last()
    on != enabled?(name)
  end

  def should_flip?(_plain), do: true

  @doc "Button payload round-trip: site|host|file or mod|file."
  def parse_toggle("site|" <> rest) do
    case String.split(rest, "|", parts: 2) do
      [host, name] -> {:site, host, name}
      _ -> :error
    end
  end

  def parse_toggle("mod|" <> name) do
    if Path.basename(name) == name,
      do: {:mod, name}, else: :error
  end
  def parse_toggle(_), do: :error

  @doc "Catalog path ModSmith should modify for a row payload (.off stripped); nil if not a row."
  def edit_path(value) do
    case parse_toggle(value) do
      {:mod, name} -> "mods/" <> display(name)
      {:site, host, name} -> "sites/#{host}/" <> display(name)
      :error -> nil
    end
  end

  @doc false
  def visible_scope?(scope, host, global?) do
    if global? do
      is_nil(scope)
    else
      is_binary(scope) and is_binary(host) and
        (host == scope or String.ends_with?(host, "." <> scope))
    end
  end

  # Internal shell catalog. The shell selects synchronously on navigation and
  # tab changes, so another window's active tab cannot replace these controls.
  @doc false
  def toolbar_catalog(home) do
    sites = for path <- Path.wildcard(Path.join([home, "sites", "*", "*"])),
      name = Path.basename(path),
      Path.extname(display(name)) in [".css", ".js"],
      {:ok, source} <- [File.read(path)] do
        host = path |> Path.dirname() |> Path.basename()
        toolbar_entry("site|#{host}|#{name}", name, source, host, false)
      end

    mods = for path <- Path.wildcard(Path.join([home, "mods", "*"])),
      name = Path.basename(path),
      Path.extname(display(name)) == ".ex",
      not String.starts_with?(name, "zz_"),
      {:ok, source} <- [File.read(path)],
      host = host_of_source(source), is_binary(host) do
        toolbar_entry("mod|#{name}", name, source, host, true)
      end

    Enum.sort_by(sites ++ mods, &{&1.profile, &1.host, &1.title})
  end

  defp publish_toolbar_catalog do
    BowserBrain.Bridge.cast_msg(%{op: "chrome", chrome: "set_site_mods",
      mods: toolbar_catalog(BowserBrain.Paths.home())})
  end

  defp toolbar_entry(id, name, source, host, subdomains) do
    %{id: id, title: display(name), host: host, subdomains: subdomains,
      profile: BowserBrain.ModScope.source_profile(source), on: enabled?(name)}
  end

  # -- rendering --------------------------------------------------------------

  # No add_menu_item here: PanelMenu already gives every surface a
  # View-menu toggle ("panel:mods"), so a second "Mods" entry was a duplicate.
  defp assert_chrome do
    Chrome.register_command("mods", "What's modding this page — toggle on/off")
  end

  defp host_of(state) do
    # Prefer our own capture, but fall back to the brain's authoritative
    # tab→url mirror: a hot-reloaded mod_switch starts with an empty urls
    # map and would otherwise show NO site payloads for an already-loaded
    # page (the "no twitter mods for x.com" bug).
    url = state.urls[state.active] || BowserBrain.Session.url_of(state.active) || ""
    URI.parse(url).host
  end

  defp render(state, activate \\ false) do
    host = host_of(state)
    global? = Map.get(state, :show_global, false)

    sites_dir = not global? && host && Path.join([BowserBrain.Paths.home(), "sites", host])

    site_rows =
      case sites_dir && File.ls(sites_dir) do
        {:ok, names} ->
          for name <- Enum.sort(names),
              Path.extname(display(name)) in [".css", ".js"],
              BowserBrain.ModScope.file_profile(Path.join(sites_dir, name)) == BowserBrain.ModScope.profile_of(state.active) do
            info = describe_file(Path.join(sites_dir, name)) || "site payload"
            row(dot(enabled?(name)) <> " " <> display(name), "site|#{host}|#{name}", info, state, host)
          end

        _ ->
          []
      end

    mods_dir = Path.join(BowserBrain.Paths.home(), "mods")

    mod_rows =
      case File.ls(mods_dir) do
        {:ok, names} ->
          for name <- Enum.sort(names),
              String.ends_with?(name, ".ex") or String.ends_with?(name, ".ex.off"),
              not String.starts_with?(name, "zz_"),
              BowserBrain.ModScope.file_profile(Path.join(mods_dir, name)) == BowserBrain.ModScope.profile_of(state.active),
              {:ok, source} <- [File.read(Path.join(mods_dir, name))],
              scope = host_of_source(source),
              visible_scope?(scope, host, global?) do

            status =
              cond do
                not enabled?(name) -> nil
                running?(source) -> nil
                true -> "STOPPED"
              end

            info =
              [scope, status, describe_source(source) || "mod"]
              |> Enum.reject(&is_nil/1)
              |> Enum.join(" · ")

            row(dot(enabled?(name)) <> " " <> display(name), "mod|#{name}", info, state, scope)
          end

        _ ->
          []
      end

    Surface.show(
      :mods,
      vstack(
        [section(if(global?, do: "Global mods", else: "This tab#{if host, do: " · #{host}", else: ""}"))] ++
          (if site_rows ++ mod_rows == [],
             do: [text(if(global?, do: "No global mods in this profile.", else: "No mods for this tab."), style: :caption)],
             else: site_rows ++ mod_rows) ++
          [button(if(global?, do: "Show tab mods", else: "Show global mods"), event: "scope")]
      ),
      title: "Mods",
      kind: :settings,
      section: "Mods",
      order: 20,
      activate: activate
    )

    state
  end

  # A freshly hot-swapped process still carries the previous code's state
  # shape; reaching for state.info crashed and ATE the owner's click.
  # Tolerate any shape instead (the crash-restart heals state, but nothing
  # should be lost in the meantime).
  defp expanded(state), do: Map.get(state, :info) || MapSet.new()

  # icon · name / description · ✎ · switch — the extensions-list pattern.
  defp row(label, payload, info, state, host) do
    on = enabled?(payload |> String.split("|") |> List.last())

    row(String.replace_prefix(String.replace_prefix(label, "● ", ""), "○ ", ""),
      subtitle: String.slice(info, 0, 90),
      path: BowserBrain.ModIcon.cached(host, BowserBrain.ModScope.profile_of(state.active)),
      symbol: if(String.starts_with?(payload, "site|"), do: "doc.text", else: "puzzlepiece.extension"),
      trailing: [
        button("✎", event: "edit", payload: payload, compact: true),
        toggle("toggle", on: on, payload: payload)
      ]
    )
  end

  defp describe_file(path) do
    case File.read(path) do
      {:ok, source} -> describe_source(source)
      _ -> nil
    end
  end

  # Is the process for this mod source actually alive? An enabled file with
  # a dead process means it crashed past the restart budget.
  defp running?(source) do
    case modname(source) do
      nil -> false
      name -> Registry.lookup(BowserBrain.ModRegistry, Module.concat([name])) != []
    end
  end

  defp dot(true), do: "●"
  defp dot(false), do: "○"
  defp display(name), do: String.replace_suffix(name, ".off", "")
end
