defmodule BowserBrain.ModLog do
  @moduledoc """
  The debugging window into mod-land (bowser-browser-h9i): any mod calls
  `ModLog.log("dubber", "chunk 3 translated in 1.8s")` and the line lands in
  a ring buffer (last #{100}). `:log` in the omnibar toggles a live panel
  showing the tail — the owner's answer to "it silently doesn't work".
  Logging is safe when the registry is down (old brains): it no-ops.
  """
  use GenServer

  import BowserBrain.View

  alias BowserBrain.Surface

  @keep 100
  @shown 28

  def start_link(opts), do: GenServer.start_link(__MODULE__, nil, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Append a line; cheap cast, no-op if the log isn't running."
  def log(tag, msg, server \\ __MODULE__) do
    GenServer.cast(server, {:log, to_string(tag), to_string(msg), System.system_time(:millisecond)})
  end

  @doc "Most recent entries, newest last."
  def recent(server \\ __MODULE__) do
    GenServer.call(server, :recent)
  catch
    :exit, _ -> []
  end

  @doc "Record bounded pipeline metadata, never page text. Counts may be zero."
  def stage(mod, stage, count \\ 1, opts \\ []) do
    if stage in [:page_received, :page_handled, :page_error, :jev_started, :jev_ok,
                 :jev_error, :applied, :apply_error] and is_integer(count) and count >= 0 do
      error = Keyword.get(opts, :error)
      error = if error in [:timeout, :unavailable, :rate_limited, :unauthorized,
                           :request_too_large, :invalid_request, :invalid_response], do: error,
                else: if(is_nil(error), do: nil, else: :other)
      webview = Keyword.get(opts, :webview)
      entry = %{mod: normalize_mod(mod), stage: stage, count: count,
                at: System.system_time(:millisecond), error: error,
                webview: if(is_integer(webview), do: webview, else: nil)}
      GenServer.cast(__MODULE__, {:stage, entry})
      :ok
    else
      {:error, :invalid_stage}
    end
  end

  @doc "Last 100 pipeline receipts for this module, within a global 1000-receipt ring."
  def diagnostics(mod) do
    GenServer.call(__MODULE__, {:diagnostics, normalize_mod(mod)})
  catch
    :exit, _ -> []
  end

  defp normalize_mod(mod), do: mod |> to_string() |> String.replace_prefix("Elixir.", "")

  @doc "Show/hide the live panel."
  def toggle(server \\ __MODULE__) do
    GenServer.call(server, :toggle)
  catch
    :exit, _ -> :error
  end

  @impl true
  def init(nil) do
    {:ok, _} = Registry.register(BowserBrain.Events, :browser_event, nil)
    {:ok, %{entries: :queue.new(), count: 0, shown: false}}
  end

  @impl true
  def handle_cast({:log, tag, msg, at}, state) do
    entries = :queue.in({tag, msg, at}, state.entries)

    {entries, count} =
      if state.count >= @keep,
        do: {elem(:queue.out(entries), 1), state.count},
        else: {entries, state.count + 1}

    state = %{state | entries: entries, count: count}
    if state.shown, do: render(state)
    {:noreply, state}
  end

  def handle_cast({:stage, entry}, state) do
    entries = [entry | Map.get(state, :diagnostics, [])] |> Enum.take(1000)
    {:noreply, Map.put(state, :diagnostics, entries)}
  end

  def handle_call({:diagnostics, mod}, _from, state) do
    entries = Map.get(state, :diagnostics, []) |> Enum.filter(&(&1.mod == mod)) |> Enum.take(100) |> Enum.reverse()
    {:reply, entries, state}
  end

  @impl true
  def handle_call(:recent, _from, state) do
    {:reply, :queue.to_list(state.entries), state}
  end

  def handle_call(:toggle, _from, state) do
    state = %{state | shown: not state.shown}

    if state.shown do
      render(state)
    else
      Surface.close(:log)
    end

    {:reply, {:ok, state.shown}, state}
  end

  @impl true
  def handle_info({:browser_event, %{"event" => "omnibar_command", "text" => "log"}}, state) do
    {:reply, _, state} = handle_call(:toggle, nil, state)
    {:noreply, state}
  end

  def handle_info({:browser_event, %{"event" => "hello"}}, state) do
    BowserBrain.Chrome.register_command("log", "Mod log — live debugging tail")
    if state.shown, do: render(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp render(state) do
    lines =
      state.entries
      |> :queue.to_list()
      |> Enum.take(-@shown)
      |> Enum.map(fn {tag, msg, at} ->
        time = at |> div(1000) |> rem(86_400) |> format_time()
        text("#{time} [#{tag}] #{String.slice(msg, 0, 100)}", style: :caption)
      end)

    Surface.show(
      :log,
      vstack([text("Mod Log", style: :title)] ++
        (lines == [] && [text("nothing logged yet", style: :caption)] || lines)),
      title: "Mod Log",
      anchor: :right_of_main,
      width: 480
    )
  end

  defp format_time(day_seconds) do
    h = div(day_seconds, 3600)
    m = day_seconds |> div(60) |> rem(60)
    s = rem(day_seconds, 60)
    :io_lib.format(~c"~2..0B:~2..0B:~2..0B", [h, m, s]) |> List.to_string()
  end
end
