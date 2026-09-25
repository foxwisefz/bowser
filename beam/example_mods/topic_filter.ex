defmodule TopicFilterMod do
  use BowserBrain.Mod
  import BowserBrain.View
  alias BowserBrain.{TopicFilter, Store, Chrome, Surface, Page, Session}

  def init_mod(_) do
    settings = Map.merge(TopicFilter.defaults(), Store.get(__MODULE__, "settings", %{}))

    state = %{
      settings: settings,
      generation: System.unique_integer([:positive]),
      cache: %{},
      pending: %{},
      response: nil,
      tabs: []
    }

    install(state)
    state
  end

  defp install(state) do
    Chrome.register_command("topic-filter", "Topic Filter settings")
    script = TopicFilter.script(state.settings, state.generation)
    Page.set_scripts([script], reload: false)
    for wv <- Enum.uniq([0 | state.tabs]), do: Page.eval(script, webview: wv)
  end

  def handle_event(%{"event" => "hello"} = event, state) do
    tabs =
      Enum.reduce(event["webviews"] || [], state.tabs, fn item, acc ->
        id = if is_map(item), do: item["id"], else: item
        if is_integer(id), do: Enum.uniq([id | acc]), else: acc
      end)

    next = %{state | tabs: tabs}
    install(next)
    next
  end

  def handle_event(%{"event" => "mod_reloaded"}, state) do
    install(state)
    state
  end

  def handle_event(%{"event" => event, "webview" => wv}, state)
      when event in ["tab_activated", "url_changed"] do
    script = TopicFilter.script(state.settings, state.generation)

    Page.eval(
      "if(window.__bowserTopicFilter?.generation !== " <>
        to_string(state.generation) <> ") {" <> script <> "}",
      webview: wv
    )

    %{state | tabs: Enum.uniq([wv | state.tabs])}
  end

  def handle_event(%{"event" => "webview_closed", "webview" => wv}, state),
    do: %{state | tabs: List.delete(state.tabs, wv)}

  def handle_event(
        %{"event" => "page", "webview" => wv, "payload" => %{"kind" => "topic-filter-ready"}},
        state
      ),
      do: %{state | tabs: Enum.uniq([wv | state.tabs])}

  def handle_event(%{"event" => "omnibar_command", "text" => "topic-filter"}, state),
    do: render(state, true)

  def handle_event(
        %{
          "event" => "surface",
          "surface" => "topic-filter",
          "id" => "save",
          "value" => %{"request_id" => id, "values" => values}
        },
        state
      ) do
    case TopicFilter.validate(values) do
      {:ok, settings} ->
        case Store.put(__MODULE__, "settings", settings) do
          :ok ->
            next = %{
              state
              | settings: settings,
                generation: state.generation + 1,
                response: form_response(id, {:ok, settings})
            }

            install(next)
            render(next)

          _ ->
            render(%{state | response: form_response(id, {:error, "Could not save settings."})})
        end

      {:error, reason} ->
        render(%{state | response: form_response(id, {:error, reason})})
    end
  end

  def handle_event(%{"event" => "surface", "surface" => "topic-filter", "id" => action}, state)
      when action in ["pause", "resume"] do
    settings =
      Map.put(
        state.settings,
        "paused_until",
        if(action == "pause", do: System.system_time(:second) + 3600, else: 0)
      )

    case Store.put(__MODULE__, "settings", settings) do
      :ok ->
        next = %{state | settings: settings, generation: state.generation + 1}
        install(next)
        render(next)

      _ ->
        state
    end
  end

  def handle_event(
        %{"event" => "page", "payload" => %{"kind" => "topic-filter-settings"}},
        state
      ),
      do: render(state, true)

  def handle_event(
        %{
          "event" => "page",
          "webview" => wv,
          "payload" =>
            %{
              "kind" => "topic-filter",
              "generation" => generation,
              "document" => document,
              "id" => id,
              "text" => text,
              "url" => url
            } = payload
        },
        state
      )
      when is_binary(text) and byte_size(text) in 1..12000 and is_binary(id) and
             byte_size(id) <= 200 and
             is_binary(document) and byte_size(document) <= 200 and is_binary(url) do
    site = TopicFilter.site(Session.url_of(wv))
    criteria = TopicFilter.criteria(state.settings)
    key = TopicFilter.digest(text, criteria)

    cond do
      generation != state.generation or is_nil(site) or site != TopicFilter.site(url) or
        not TopicFilter.active?(state.settings, site) or criteria == [] ->
        state

      Map.has_key?(state.cache, key) ->
        reply(wv, payload, state.cache[key], criteria, state.settings, true)
        state

      map_size(state.pending) >= 3 or Map.has_key?(state.pending, {wv, document}) ->
        Page.eval(
          "window.__bowserTopicFilter?.apply(" <> JSON.encode!(payload) <> ", {retry: true})",
          webview: wv
        )

        state

      true ->
        parent = self()
        token = System.unique_integer([:positive])

        Task.start(fn ->
          result =
            try do
              TopicFilter.evaluate(text, criteria)
            rescue
              _ -> {:error, :evaluation_failed}
            catch
              _, _ -> {:error, :evaluation_failed}
            end

          send(parent, {:topic_result, token, wv, payload, key, criteria, result})
        end)

        Process.send_after(self(), {:topic_timeout, token, wv, payload}, 90_000)
        %{state | pending: Map.put(state.pending, {wv, document}, token)}
    end
  end

  def handle_event(_, state), do: state

  def handle_info({:topic_result, token, wv, payload, key, criteria, result}, state) do
    pending_key = {wv, payload["document"]}

    next =
      if state.pending[pending_key] == token do
        next = %{state | pending: Map.delete(state.pending, pending_key)}

        if payload["generation"] == state.generation do
          reply(wv, payload, result, criteria, state.settings, false)

          case result do
            {:ok, _} ->
              %{
                next
                | cache:
                    Map.put(
                      if(map_size(state.cache) >= 1000, do: %{}, else: state.cache),
                      key,
                      result
                    )
              }

            _ ->
              next
          end
        else
          next
        end
      else
        state
      end

    {:noreply, next}
  end

  def handle_info({:topic_timeout, token, wv, payload}, state) do
    key = {wv, payload["document"]}

    if state.pending[key] == token do
      reply(wv, payload, {:error, :timeout}, [], state.settings, false)
      {:noreply, %{state | pending: Map.delete(state.pending, key)}}
    else
      {:noreply, state}
    end
  end

  def handle_info(message, state), do: super(message, state)

  defp reply(wv, payload, result, criteria, settings, cached) do
    decision =
      case result do
        {:ok, answers} -> TopicFilter.decide(answers, criteria, settings["strictness"])
        error -> error
      end

    value =
      case decision do
        {:ok, decision} -> Map.merge(decision, %{cached: cached})
        {:error, reason} -> %{error: TopicFilter.service_message(reason)}
      end

    Page.eval(
      "window.__bowserTopicFilter?.apply(" <>
        JSON.encode!(Map.take(payload, ~w(generation document id text url))) <>
        "," <> JSON.encode!(value) <> ")",
      webview: wv
    )
  end

  defp render(state, activate \\ false) do
    controls =
      [
        field("Enable", input("enabled", kind: :toggle, label: "Filter supported feeds")),
        field(
          "Post text",
          input("consent",
            kind: :toggle,
            label: "Allow selected post text to be sent to Bowser and TypeSafe"
          )
        ),
        field(
          "Hiding style",
          input("mode",
            kind: :choice,
            options: choices([{"cover", "Cover"}, {"dim", "Dim"}, {"remove", "Remove"}])
          )
        ),
        field(
          "Sensitivity",
          input("strictness",
            kind: :choice,
            options:
              choices([
                {"relaxed", "Relaxed · 80%"},
                {"balanced", "Balanced · 65%"},
                {"strict", "Strict · 50%"}
              ])
          )
        )
      ] ++
        Enum.map(TopicFilter.topics(), fn {id, label, _} ->
          field(label, input(id, kind: :toggle, label: "Hide " <> label))
        end) ++
        [
          field(
            "Custom topics",
            input("custom",
              kind: :multiline,
              label: "One topic per line, up to 20",
              min_height: 120
            )
          )
        ] ++
        Enum.map(TopicFilter.sites(), fn {id, label} ->
          field(label, input("site_" <> id, kind: :toggle, label: "Filter " <> label))
        end)

    view =
      vstack(
        [
          text("Topic Filter", style: :heading),
          text(
            "Choose what you want to see less of. Only eligible post text is sent through your Bowser account to TypeSafe. No message inboxes or input fields are read. Text can contain personal information; enable only for feeds you want evaluated.",
            style: :caption
          ),
          text(
            "Cover keeps feed geometry intact. Remove uses a cover on X to preserve scrolling. YouTube filters comments only. Show restores any hidden item.",
            style: :caption
          ),
          text(status_text(state.settings)),
          text(
            "To turn on: check Enable and Post text below, then choose Save and apply at the bottom.",
            style: :caption
          ),
          hstack([
            action("Pause for 1 hour", event: "pause", disabled: not state.settings["enabled"]),
            action("Resume", event: "resume", disabled: not state.settings["enabled"])
          ]),
          form("topic-filter-preferences", state.settings, fields(controls),
            event: "save",
            submit_label: "Save and apply",
            response: state.response
          )
        ],
        spacing: 16,
        fill_width: true
      )

    Surface.show("topic-filter", view, title: "Topic Filter", kind: :settings, activate: activate)
    state
  end

  def status_text(settings) do
    cond do
      not settings["enabled"] -> "Off — settings are not filtering feeds"
      not settings["consent"] -> "Off — post-text permission is required"
      settings["paused_until"] > System.system_time(:second) -> "Paused for one hour"
      true -> "On — filtering your selected sites"
    end
  end

  defp choices(pairs), do: Enum.map(pairs, fn {value, label} -> %{value: value, label: label} end)
end
