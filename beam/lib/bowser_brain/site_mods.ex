defmodule BowserBrain.SiteMods do
  @moduledoc """
  Per-origin persistent payloads (bowser-browser-uwo): plain files under
  ~/.bowser/sites/<host>/*.css|*.js, injected on every page of that host,
  forever — the "from now on" half of ModSmith, and hand-editable like
  everything else. The watcher checks content digests once a second; changes apply with a reload.
  JS runs isolated unless its first declaration (after an optional profile
  tag) is `// bowser-world: page`. The engine enforces each payload's host.
  """
  use GenServer
  require Logger

  alias BowserBrain.UserContent

  @poll_ms 1_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def sites_dir, do: Path.join(BowserBrain.Paths.home(), "sites")

  @doc "Write a payload file (ModSmith calls this); applied within a second."
  def put(host, name, content) do
    dir = Path.join(sites_dir(), sanitize(host))
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, sanitize(name)), content)
  end

  def payloads_for(host, profile \\ "default") do
    dir = Path.join(sites_dir(), host)

    case File.ls(dir) do
      {:ok, names} ->
        for name <- Enum.sort(names), Path.extname(name) in [".css", ".js"],
            {:ok, source} <- [File.read(Path.join(dir, name))], BowserBrain.ModScope.source_profile(source) == profile do
          {name, source}
        end

      _ ->
        []
    end
  end

  @impl true
  def init(nil) do
    # Off in hermetic tests (bowser-browser-is4).
    if Application.get_env(:bowser_brain, :watch_sites, true) do
      File.mkdir_p!(sites_dir())
      send(self(), {:scan, false})
    end

    {:ok, %{mtimes: %{}}}
  end

  @impl true
  def handle_info({:scan, reload_on_change}, state) do
    files = Path.wildcard(Path.join(sites_dir(), "*/*.{css,js}"))

    mtimes =
      for path <- files, into: %{} do
        {path, :crypto.hash(:sha256, File.read!(path))}
      end

    next =
      if mtimes != state.mtimes or (files != [] and not Map.has_key?(state, :profiles)) do
        if pid = Process.whereis(BowserBrain.ModControls), do: send(pid, :catalog_changed)
        if map_size(state.mtimes) > 0 or not reload_on_change do
          Logger.info("sitemods: #{map_size(mtimes)} payload(s) across sites — applying")
        end

        groups =
          files
          |> Enum.sort()
          |> Enum.map(fn path ->
            source = File.read!(path)
            {BowserBrain.ModScope.source_profile(source), script(path, source)}
          end)
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

        profiles = Map.keys(groups)
        for profile <- Enum.uniq(profiles ++ Map.get(state, :profiles, [])) do
          UserContent.put_scripts(:site_mods, Map.get(groups, profile, []),
            reload: reload_on_change, profile: profile)
        end
        state |> Map.put(:mtimes, mtimes) |> Map.put(:profiles, profiles)
      else
        state
      end

    Process.send_after(self(), {:scan, true}, @poll_ms)
    {:noreply, next}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc false
  def build_scripts(files) do
    for path <- Enum.sort(files), do: script(path, File.read!(path))
  end

  defp script(path, content) do
    host = path |> Path.dirname() |> Path.basename()
    body =
      case Path.extname(path) do
        ".css" ->
          """
          var s = document.createElement("style");
          s.setAttribute("data-bowser-site", #{JSON.encode!(Path.basename(path))});
          s.textContent = #{JSON.encode!(content)};
          (document.head || document.documentElement).appendChild(s);
          """

        ".js" ->
          content
      end

    world = if Path.extname(path) == ".js", do: BowserBrain.ScriptPolicy.source_world(content), else: "isolated"
    %{source: body, world: world, host: host}
  end

  defp sanitize(name), do: String.replace(name, ~r/[^A-Za-z0-9._-]/, "_")
end
