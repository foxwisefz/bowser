defmodule BowserBrain.Settings do
  @moduledoc """
  Flat key/value settings at ~/.bowser/settings.json — hand-editable, or:

      :set action_budget 30
      :set some_key                  # no value = delete
      :settings                      # browser preferences and declared mod settings

  MODS DECLARE THEIR SETTINGS (bowser-browser-3hs): a mod needing an API key
  calls, in init_mod/hello:

      Settings.declare("elevenlabs_api_key",
        secret: true, about: "ElevenLabs TTS — used by :read")

  Declared mod keys appear in the Settings window (set or not) with their
  description and an inline textfield — type a value and press Enter to
  save. Read with Settings.get("elevenlabs_api_key").
  """
  use GenServer
  require Logger

  import BowserBrain.View
  alias BowserBrain.Surface

  # Bowser manages service configuration; developer overrides do not belong in
  # General. Filter retained declarations too, so live handoffs cannot revive
  # the old raw configuration form.
  @internal_settings ~w(ai_provider openai_api_key anthropic_api_key bowser_api_endpoint
                        dodorouter_endpoint dodorouter_api_key modsmith_model
                        modsmith_timeout_ms action_budget)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def path, do: Application.get_env(:bowser_brain, :settings_path, Path.join(BowserBrain.Paths.home(), "settings.json"))

  def all do
    case BowserBrain.PrivateFiles.read(path()) do
      {:ok, raw} ->
        case JSON.decode(raw) do
          {:ok, %{} = map} -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  def get(key, default \\ nil), do: Map.get(all(), key, default)

  def put(key, value) do
    map = Map.put(all(), key, value)
    File.mkdir_p!(Path.dirname(path()))
    BowserBrain.PrivateFiles.write!(path(), JSON.encode!(map))
    :ok
  end

  def delete(key) do
    File.mkdir_p!(Path.dirname(path()))
    BowserBrain.PrivateFiles.write!(path(), JSON.encode!(Map.delete(all(), key)))
    :ok
  end

  @doc "Declare a mod setting so it shows (with purpose) in the Settings window."
  def declare(key, opts \\ []) do
    GenServer.cast(__MODULE__, {:declare, to_string(key),
      %{secret: Keyword.get(opts, :secret, false), about: Keyword.get(opts, :about)}})
  end

  def declarations, do: GenServer.call(__MODULE__, :declarations)

  @doc """
  Text summary of all settings for LLM context: key names, descriptions,
  set/unset — secret VALUES are masked and never leave the machine.
  """
  def summary do
    declared = declarations()
    stored = all()
    keys = (Map.keys(declared) ++ Map.keys(stored)) |> Enum.uniq() |> Enum.sort()

    if keys == [] do
      "none configured"
    else
      Enum.map_join(keys, "\n", fn key ->
        meta = Map.get(declared, key, %{})
        about = if meta[:about], do: " — #{meta[:about]}", else: ""

        status =
          case Map.fetch(stored, key) do
            {:ok, value} -> "set: #{mask(key, value, declared)}"
            :error -> "declared, NOT set"
          end

        "- #{key} (#{status})#{about}"
      end)
    end
  end

  @impl true
  def init(nil) do
    {:ok, _} = Registry.register(BowserBrain.Events, :browser_event, nil)
    {:ok, %{declared: %{}}}
  end

  @impl true
  def handle_cast({:declare, key, meta}, state) do
    {:noreply, %{state | declared: Map.put(state.declared, key, meta)}}
  end

  @impl true
  def handle_call(:declarations, _from, state), do: {:reply, state.declared, state}

  @impl true
  # The Settings window opened (⌘,): render our section fresh.
  def handle_info({:browser_event, %{"event" => "settings_opened"}}, state) do
    show_all(state.declared)
    {:noreply, state}
  end

  def handle_info({:browser_event, %{"event" => "hello"}}, state) do
    BowserBrain.Chrome.register_command("settings", "Settings window (⌘,)")
    show_all(state.declared)
    {:noreply, state}
  end

  def handle_info({:browser_event, %{"event" => "omnibar_command", "text" => "set " <> rest}}, state) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [key, value] ->
        put(key, value)
        Logger.info("settings: #{key} = #{mask(key, value, state.declared)}")
        show_all(state.declared)

      [key] when key != "" ->
        delete(key)
        Logger.info("settings: #{key} deleted")
        show_all(state.declared)

      _ ->
        show_all(state.declared)
    end

    {:noreply, state}
  end

  def handle_info({:browser_event, %{"event" => "omnibar_command", "text" => "settings"}}, state) do
    show_all(state.declared, true)
    {:noreply, state}
  end

  # Inline edits from declared mod settings.
  def handle_info(
        {:browser_event, %{"event" => "surface", "surface" => "settings", "id" => key, "value" => value}},
        state
      ) do
    if key in visible_keys(state.declared) do
      value = String.trim(to_string(value))

      if value == "" do
        delete(key)
        Logger.info("settings: #{key} cleared from panel")
      else
        put(key, value)
        Logger.info("settings: #{key} updated from panel")
      end
    end

    show_all(state.declared)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp visible_keys(declared) do
    declared |> Map.keys() |> Enum.reject(&(&1 in @internal_settings)) |> Enum.sort()
  end

  @doc false
  def view(declared, stored) do
    rows =
      Enum.map(visible_keys(declared), fn key ->
        meta = Map.fetch!(declared, key)
        current =
          case Map.fetch(stored, key) do
            {:ok, value} -> mask(key, value, declared)
            :error -> "not set"
          end

        row(key,
          subtitle: meta[:about],
          symbol: if(meta[:secret] == true, do: "key.fill", else: "slider.horizontal.3"),
          trailing: [textfield(key, placeholder: current)]
        )
      end)

    vstack(if(rows == [], do: [], else: [section("Mod settings") | rows]), spacing: 5)
  end

  defp show_all(declared, activate \\ false) do
    Surface.show(:settings, view(declared, all()),
      title: "General",
      kind: :settings,
      section: "General",
      order: 0,
      activate: activate
    )
  end

  defp mask(key, value, declared) do
    secret? =
      get_in(declared, [key, :secret]) == true or
        String.match?(key, ~r/key|token|secret|password/i)

    if secret? do
      "••••••"
    else
      to_string(value)
    end
  end
end
