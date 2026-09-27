defmodule BowserBrain.ModWorkshop do
  @moduledoc "Core ModSmith workflow: durable conversations, scoped runs and reversible file revisions."
  use GenServer
  alias BowserBrain.{ModRevision, ModSmith, ModSmithOutcome, Bridge, AppMods}
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def delete_existing(path, profile),
    do: GenServer.call(__MODULE__, {:delete_existing, path, profile}, 15_000)
  def modify(path), do: GenServer.cast(__MODULE__, {:modify, path})

  def tool(token, tool, args) do
    result = dispatch_tool(token, tool, args)
    GenServer.call(__MODULE__, {:tool_receipt, token, tool, args, result})
    result
  end

  defp dispatch_tool(token, tool, args) do
    case GenServer.call(__MODULE__, {:context, token, tool}) do
      {:ok, run} ->
        cond do
          Map.get(run, :documentation, false) and tool not in ["list_tabs", "page_html", "page_screenshot", "read_mod", "list_mods", "mod_diagnostics"] ->
            %{ok: false, error: "Writing instructions is read-only. Inspect existing source and page HTML; do not change or execute the mod."}

          tool == "put_asset" and run.app == nil ->
            GenServer.call(__MODULE__, {:draft_asset, token, args}, 15_000)

          tool == "put_payload" ->
            GenServer.call(__MODULE__, {:draft, token, args}, 15_000)

          tool == "put_mod" and run.app == nil ->
            case GenServer.call(__MODULE__, {:draft_mod, token, args}, 110_000) do
              %{ok: true, installed: path} = reply ->
                runtime =
                  if ModRevision.actual_path(path) == path,
                    do: BowserBrain.Loader.load_now(ModRevision.absolute(path)),
                    else: %{ok: true, status: "disabled"}
                Map.merge(reply, %{ok: runtime.ok, runtime: runtime,
                  applies: "File recorded for Undo. Runtime result reports compilation and startup/reload; verify appearance separately."})
              reply -> reply
            end

          tool == "page_screenshot" ->
            if run.app,
              do: AppMods.dispatch(tool, args, run.app["id"]),
              else: BowserBrain.AgentPort.dispatch(%{"tool" => tool, "args" => args |> Map.put("webview", run.webview) |> Map.put("expected_host", run.capture_host) |> Map.put("profile", run.profile)})

          tool in ["native_screenshot", "native_click", "website_layout"] and run.app == nil ->
            BowserBrain.AgentPort.dispatch(%{"tool" => tool, "args" => Map.put(args, "webview", run.webview)})

          tool == "jev" and run.app == nil ->
            BowserBrain.AgentPort.dispatch(%{"tool" => "jev", "args" => args})

          tool == "list_tabs" ->
            %{ok: true, active: if(run.target_available, do: run.webview),
              target_available: run.target_available, expected_url: run.url, tabs: run.tabs}

          tool in ["shell_theme", "toolbars"] and run.app == nil ->
            BowserBrain.AgentPort.dispatch(%{"tool" => tool})

          tool == "list_mods" and run.app == nil ->
            profile = Map.get(run, :profile, BowserBrain.ModScope.profile_of(run.webview))
            %{ok: true, mods: BowserBrain.ModCatalog.catalog() |> Enum.filter(&(&1.profile == profile)) |> Enum.map(&Map.delete(&1, :profile))}

          tool in ["read_mod", "store_get", "store_put", "mod_diagnostics"] and run.app == nil ->
            scoped_data_tool(run, tool, args)

          tool in ["page_eval", "page_html", "list_mods", "read_mod", "store_get", "store_put"] ->
            args = args |> Map.delete("site_app") |> Map.put("webview", run.webview)

            if run.app,
              do: AppMods.dispatch(tool, args, run.app["id"]),
              else: BowserBrain.AgentPort.dispatch(%{"tool" => tool, "args" => args})

          true ->
            %{ok: false, error: "Tool unavailable in ModSmith"}
        end

      {:error, reason} ->
        %{ok: false, error: reason}
    end
  end

  # Catalog visibility is not authorization: check the exact source/storage
  # target on every call, including disabled files and Elixir module aliases.
  defp scoped_data_tool(%{profile: profile}, "read_mod", %{"path" => path})
       when is_binary(profile) and profile != "" do
    with {:ok, actual, source} <- scoped_source(path),
         true <- BowserBrain.ModScope.source_profile(source) == profile do
      %{ok: true, path: actual, content: BowserBrain.ModScope.untag(source)}
    else
      _ -> scope_error()
    end
  end

  defp scoped_data_tool(%{profile: profile}, tool, %{"mod" => requested} = args)
       when tool in ["store_get", "store_put", "mod_diagnostics"] and is_binary(profile) and profile != "" and
              is_binary(requested) do
    mod = String.replace_prefix(requested, "Elixir.", "")

    if Regex.match?(~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/, mod) and
         module_owned_by?(mod, profile) do
      BowserBrain.AgentPort.dispatch(%{"tool" => tool, "args" => Map.put(args, "mod", mod)})
    else
      scope_error()
    end
  end

  defp scoped_data_tool(_, _, _), do: scope_error()
  defp scope_error, do: %{ok: false, error: "Mod is unavailable in this ModSmith profile"}

  defp scoped_source(path) when is_binary(path) do
    if (String.starts_with?(path, "mods/") or String.starts_with?(path, "sites/")) and
         ModRevision.allowed?(path) do
      actual = ModRevision.actual_path(path)
      case ModRevision.read(actual) do
        source when is_binary(source) -> {:ok, actual, source}
        _ -> :error
      end
    else
      :error
    end
  rescue
    _ -> :error
  end
  defp scoped_source(_), do: :error

  defp module_owned_by?(mod, profile) do
    # Inspect all declarations, not just the visible profile. Ambiguous names
    # must never authorize access to the shared Store namespace. Never compile
    # source or intern model-controlled module names while checking ownership.
    owners =
      Path.wildcard(Path.join(BowserBrain.ModCatalog.mods_dir(), "*.ex{,.off}"))
      |> Enum.flat_map(fn file ->
        case scoped_source("mods/" <> Path.basename(file)) do
          {:ok, _, source} ->
            if mod in declared_mods(source), do: [BowserBrain.ModScope.source_profile(source)], else: []
          _ -> []
        end
      end)

    owners != [] and Enum.all?(owners, &(&1 == profile)) and runtime_owner_matches?(mod, profile)
  end

  defp runtime_owner_matches?(mod, profile) do
    # A live module can still belong to its previous profile after a file edit.
    module =
      try do
        String.to_existing_atom("Elixir." <> mod)
      rescue
        ArgumentError -> nil
      end

    if module == nil do
      true
    else
      case Registry.lookup(BowserBrain.ModRegistry, module) do
        [] -> true
        entries -> Enum.all?(entries, fn {pid, _} -> BowserBrain.ModScope.current(pid) == profile end)
      end
    end
  rescue
    _ -> false
  end

  defp declared_mods(source) do
    case Code.string_to_quoted(source, static_atoms_encoder: fn name, _ -> {:ok, name} end) do
      {:ok, ast} ->
        for {"defmodule", _, [{:__aliases__, _, names}, body]} <- statements(ast),
            is_list(body),
            Enum.all?(names, &is_binary/1),
            Enum.any?(statements(Keyword.get(body, :do)), fn
              {"use", _, [{:__aliases__, _, ["BowserBrain", "Mod"]} | _]} -> true
              _ -> false
            end),
            do: names |> Enum.join(".") |> String.replace_prefix("Elixir.", "")
      _ -> []
    end
  end

  defp statements({:__block__, _, statements}), do: statements
  defp statements(statement), do: [statement]

  @impl true
  def init(_) do
    Registry.register(BowserBrain.Events, :browser_event, nil)
    data = ModRevision.load() |> BowserBrain.ModIdentity.normalize() |> recover()
    {:ok, %{data: data, run: nil, active: 0, urls: %{}, progress: [], error: nil, accepted: nil}}
  end

  def recover(data) do
    projects =
      Enum.map(data["projects"], fn p ->
        p =
          if undo = p["pending_undo"] do
            r = Enum.find(p["revisions"], &(&1["id"] == undo))

            case r && ModRevision.restore(r) do
              :ok ->
                p
                |> Map.put(
                  "revisions",
                  Enum.map(p["revisions"], fn r ->
                    if r["id"] == undo, do: Map.put(r, "status", "undone"), else: r
                  end)
                )
                |> Map.put("usage", r["usage_before"])
                |> Map.put("status", "restored")
                |> Map.put("session", nil)
                |> Map.delete("pending_undo")

              _ ->
                Map.put(
                  p,
                  "summary",
                  "Restoration was interrupted. Your files are preserved; retry Undo."
                )
            end
          else
            p
          end

        revisions =
          Enum.map(p["revisions"], fn r ->
            if r["status"] == "working", do: Map.put(r, "status", "interrupted"), else: r
          end)

        if p["status"] == "working" do
          p
          |> Map.put("revisions", revisions)
          |> Map.put("status", "interrupted")
          |> Map.put(
            "summary",
            "The previous run was interrupted. Draft changes may still be active; you can undo or continue."
          )
        else
          Map.put(p, "revisions", revisions)
        end
      end)

    ModRevision.save(%{data | "projects" => projects})
  end

  @impl true
  def handle_info({:browser_event, %{"event" => "hello"} = event}, state) do
    BowserBrain.Chrome.register_command("do", "ModSmith — create a mod")
    BowserBrain.Chrome.register_command("do+", "ModSmith — refine the latest mod")
    urls = Map.new(event["tabs"] || [], fn t -> {t["webview"] || t["id"], t["url"] || ""} end)
    state = %{state | urls: Map.merge(state.urls, urls), active: event["active"] || state.active}
    publish(state)
    {:noreply, state}
  end

  def handle_info({:browser_event, %{"event" => "tab_activated", "webview" => wv}}, state),
    do: {:noreply, tap(%{state | active: wv}, &publish/1)}

  def handle_info(
        {:browser_event, %{"event" => "url_changed", "webview" => wv, "url" => url}},
        state
      ),
      do: {:noreply, %{state | urls: Map.put(state.urls, wv, url)}}

  def handle_info({:browser_event, %{"event" => "favicon_changed"}}, state),
    do: {:noreply, tap(state, &publish/1)}

  def handle_info({:browser_event, %{"event" => "modsmith_scope", "request_id" => id} = event}, state)
      when is_binary(id) and byte_size(id) <= 64 do
    BowserBrain.ModScopeSuggestion.request(event)
    {:noreply, state}
  end

  def handle_info({:browser_event, %{"event" => "modsmith"} = event}, state) do
    state = action(state, event) |> Map.put(:error_client, client(event))
    publish(state, client(event), event["action"] == "open")
    {:noreply, state}
  rescue
    error ->
      state = %{state | error: Exception.message(error)}
      publish(state, client(event))
      {:noreply, state}
  end

  def handle_info({:browser_event, %{"event" => "site_mod_request"} = event}, state) do
    handle_info(
      {:browser_event,
       Map.merge(event, %{"event" => "modsmith", "action" => "submit", "text" => event["request"]})},
      state
    )
  end

  def handle_info(
        {:browser_event, %{"event" => "omnibar_command", "text" => "do+" <> rest}},
        state
      ) do
    {index, text} = ModSmith.parse_followup(rest)
    projects = Enum.filter(state.data["projects"], &is_nil(&1["app"]))
    project = Enum.at(projects, if(index == :latest, do: 0, else: index - 1))

    event = %{
      "action" => if(text == "", do: "select", else: "submit"),
      "project" => project && project["id"],
      "text" => text
    }

    state = if project, do: action(state, event), else: %{state | error: "Create a mod first."}
    publish(state, "main", true)
    {:noreply, state}
  end

  def handle_info(
        {:browser_event, %{"event" => "omnibar_command", "text" => "do" <> rest}},
        state
      ) do
    state =
      if String.trim(rest) == "",
        do: state,
        else: action(state, %{"action" => "submit", "text" => String.trim(rest)})

    publish(state, "main", true)
    {:noreply, state}
  end

  def handle_info({:browser_event, %{"event" => "mod_script_fault", "reason" => "observer_loop",
      "webview" => webview}}, %{run: %{webview: webview}} = state) do
    {:noreply, %{state | run: Map.put(state.run, :script_fault, true)}}
  end

  def handle_info({:progress, token, line}, %{run: %{token: token}} = state) do
    state = %{state | progress: Enum.take(state.progress ++ [line], -80)}
    publish(state)
    {:noreply, state}
  end

  def handle_info({:finished, token, session, result} = message, %{run: %{token: token}} = state) do
    Process.demonitor(state.run.ref, [:flush])
    files = case result do
      {:output, output} ->
        case ModSmith.extract_json(output) do
          {:ok, %{"files" => files}} when is_list(files) -> resolve_drafts(state, files)
          _ -> []
        end
      _ -> []
    end
    case audit_gate(state, files, {:info, message}) do
      {:pending, state} -> {:noreply, state}
      outcome ->
        result = case outcome do
          :ready -> result
          {:error, reason} -> {:error, reason}
        end
        state = finish(state, session, result)
        publish(state)
        {:noreply, state}
    end
  end

  def handle_info({:audit_finished, ref, result}, %{pending_audit: %{ref: ref} = pending} = state) do
    Process.cancel_timer(pending.timer)
    if Process.alive?(pending.pid), do: ModSmith.stop_runner(pending.pid)
    state = Map.put(state, :pending_audit, nil)
    same_run = state.run != nil and state.run.token == pending.token
    valid_run = same_run and
      (state.urls[state.run.webview] == nil or URI.parse(state.urls[state.run.webview]).host == URI.parse(state.run.url).host)
    result = if valid_run, do: result, else: {:error, "The ModSmith run ended during security audit"}
    state = if result == :ok,
      do: Map.update(state, :audit_approvals, pending.keys, &(Enum.uniq(&1 ++ pending.keys))), else: state
    state = if same_run do
      failures = Map.get(state.run, :audit_failures, %{})
      failures = Enum.reduce(pending.keys, failures, fn {_, path, _}, failures ->
        if result == :ok, do: Map.delete(failures, path), else: Map.put(failures, path, true)
      end)
      %{state | run: Map.put(state.run, :audit_failures, failures)}
    else
      state
    end
    case {pending.continuation, result} do
      {{:call, request, from}, :ok} ->
        case handle_call(request, from, state) do
          {:reply, reply, state} ->
            GenServer.reply(from, reply)
            {:noreply, state}
          {:noreply, state} -> {:noreply, state}
        end
      {{:call, _, from}, {:error, reason}} ->
        GenServer.reply(from, %{ok: false, error: reason})
        {:noreply, state}
      {{:info, message}, :ok} -> handle_info(message, state)
      {{:info, {:finished, _, session, _}}, {:error, reason}} ->
        if same_run do
          state = finish(state, session, {:error, reason})
          publish(state)
          {:noreply, state}
        else
          {:noreply, state}
        end
    end
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{run: %{ref: ref}} = state) do
    state = finish(state, nil, {:error, "Generation stopped: #{inspect(reason)}"})
    publish(state)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_cast({:modify, path}, state) do
    state = edit_existing(state, %{"path" => path})
    publish(state, "main", true)
    {:noreply, state}
  end

  @impl true
  def handle_call({:delete_existing, path, profile}, _, state) do
    try do
      if state.run, do: raise("Stop the current build before deleting a mod.")
      canonical = BowserBrain.ModCatalog.display(path)
      entry = Enum.find(BowserBrain.ModCatalog.catalog(), fn entry ->
        entry.profile == profile and BowserBrain.ModCatalog.display(entry.path) == canonical
      end)
      unless entry, do: raise("That mod is no longer available in this profile.")
      project = Enum.find(state.data["projects"], fn p ->
        p["app"] == nil and Map.get(p, "profile", "default") == profile and
          Enum.any?(paths(p), &(BowserBrain.ModCatalog.display(&1) == canonical))
      end) || (new_project(Path.basename(canonical), "site", "", nil)
        |> Map.put("existing_path", canonical) |> Map.put("profile", profile))
      next = delete_project(state, project)
      publish(next)
      {:reply, if(next.error, do: {:error, next.error}, else: :ok), next}
    rescue
      error -> {:reply, {:error, Exception.message(error)}, state}
    end
  end

  def handle_call({:tool_receipt, token, tool, args, result}, _, %{run: %{token: token}} = state) do
    run = state.run
    id = Map.get(run, :receipt_sequence, 0) + 1
    # Source is checked separately; keep bounded observations in memory, not full page transcripts on disk.
    args = Map.drop(args, ["content"])
    image = Map.get(result, :image) || Map.get(result, "image")
    result = Map.drop(result, [:image, "image"])
    run = if is_binary(image) and byte_size(image) <= 5_400_000,
      do: Map.put(run, :images, Enum.take(Map.get(run, :images, []) ++ [%{id: id, data: image}], -2)), else: run
    receipt = %{id: id, tool: tool, args: String.slice(JSON.encode!(args), 0, 2000),
      result: String.slice(JSON.encode!(result), 0, 3000)}
    run = run |> Map.put(:receipt_sequence, id)
      |> Map.put(:receipts, Enum.take(Map.get(run, :receipts, []) ++ [receipt], -32))
      |> Map.delete(:verification)
    run = if tool in ["put_mod", "put_payload", "put_asset"], do: Map.put(run, :last_write, id), else: run
    {:reply, :ok, %{state | run: run}}
  end
  def handle_call({:tool_receipt, _, _, _, _}, _, state), do: {:reply, :ok, state}

  def handle_call({:verification_context, token, output}, _, %{run: %{token: token}} = state) do
    p = project(state, state.run.project)
    {:ok, envelope} = ModSmith.extract_json(output)
    installed = verification_files_match?(state, envelope)
    context = %{documentation: Map.get(state.run, :documentation, false), installed: installed, scope: p["scope"],
      requests: Enum.filter(p["turns"], &(&1["role"] == "user")) |> Enum.map(& &1["text"]) |> then(fn requests -> Enum.uniq(Enum.take(requests, 1) ++ Enum.take(requests, -12)) end),
      candidate: Map.drop(envelope, ["files"]),
      receipts: Map.get(state.run, :receipts, []), last_write: Map.get(state.run, :last_write, 0),
      images: Map.get(state.run, :images, []), failed_attempts: Map.get(p, "failed_attempts", [])}
    {:reply, {:ok, context}, state}
  end
  def handle_call({:verification_context, _, _}, _, state), do: {:reply, {:error, :ended}, state}

  def handle_call({:verification_result, token, hash, verdict}, _, %{run: %{token: token}} = state) do
    state = put_in(state.run[:verification], %{hash: hash, verdict: verdict})
    state = case verdict do
      {:error, reason} ->
        p = project(state, state.run.project)
        attempt = %{"reason" => reason, "revision" => token}
        put_project(state, Map.put(p, "failed_attempts", Enum.take(Map.get(p, "failed_attempts", []) ++ [attempt], -8)))
      _ -> state
    end
    {:reply, :ok, state}
  end
  def handle_call({:verification_result, _, _, _}, _, state), do: {:reply, :ok, state}

  def handle_call({:context, token, tool}, _, state) do
    case state.run do
      %{token: ^token} = run ->
        p = project(state, run.project)
        tabs = if run.app, do: [%{webview: run.webview, url: run.url}], else:
          state.urls
          |> Enum.filter(fn {wv, url} ->
            BowserBrain.ModScope.profile_of(wv) == run.profile and
              (p["scope"] == "browser" or URI.parse(url).host == URI.parse(run.url).host)
          end)
          |> Enum.sort_by(fn {wv, _} -> {wv != run.webview, wv != state.active, wv} end)
          |> Enum.map(fn {wv, url} -> %{webview: wv, url: url} end)
        target = List.first(tabs)
        run = if target, do: %{run | webview: target.webview}, else: run
        state = %{state | run: run}
        safe = tool in ["list_tabs", "list_mods", "read_mod", "mod_diagnostics"]
        if target || safe do
          {:reply, {:ok, Map.merge(run, %{tabs: tabs, target_available: target != nil, capture_host: if(p["scope"] == "site", do: URI.parse(run.url).host)})}, state}
        else
          {:reply, {:error, "No matching tab is open in this profile. Source and diagnostics remain available; open #{run.url} to verify page behavior."}, state}
        end

      _ ->
        {:reply, {:error, "This run has ended. Start a new refinement before changing files."}, state}
    end
  end

  def handle_call({:draft, token, args}, _, %{run: %{token: token}} = state) do
    p = project(state, state.run.project)
    host = URI.parse(p["url"]).host

    path =
      if p["app"],
        do: "app-mods/#{p["app"]["id"]}/#{args["name"]}",
        else: "sites/#{args["host"] || host}/#{args["name"]}"

    if not is_binary(args["content"]) or not ModRevision.allowed?(path) do
      {:reply, %{ok: false, error: "Expected CSS/JS payload content and a scoped filename"}, state}
    else
    profile = Map.get(state.run, :profile, BowserBrain.ModScope.profile_of(state.run.webview))
    content = if p["app"], do: args["content"], else: BowserBrain.ModScope.tag(args["content"], profile, Path.extname(path))
    existing = ModRevision.absolute(ModRevision.actual_path(path))
    result = if is_nil(p["app"]) and File.exists?(existing) and BowserBrain.ModScope.file_profile(existing) != profile,
      do: {:error, "This payload belongs to another profile; choose a different name", state},
      else: write_files(state, [%{"path" => path, "content" => content}])
    case result do
      {:ok, state} ->
        {:reply, %{ok: true, installed: path, applies: "Live; revision recorded for Undo"}, state}

      {:error, reason, state} ->
        {:reply, %{ok: false, error: reason}, state}
    end
    end
  rescue
    _ -> {:reply, %{ok: false, error: "Invalid payload path or content"}, state}
  end

  def handle_call({:draft, _, _}, _, state), do: {:reply, %{ok: false, error: "Run ended"}, state}

  def handle_call({:draft_asset, token, args}, _, %{run: %{token: token, app: nil}} = state) do
    name = args["name"]
    if is_binary(name) and Regex.match?(~r/^[A-Za-z0-9_-][A-Za-z0-9._-]*\.svg$/, name) do
      path = "assets/#{state.run.project}/#{name}"
      case write_files(state, [%{"path" => path, "content" => args["content"]}]) do
        {:ok, state} ->
          {:reply, %{ok: true, installed: path, image_path: ModRevision.absolute(path)}, state}
        {:error, reason, state} -> {:reply, %{ok: false, error: reason}, state}
      end
    else
      {:reply, %{ok: false, error: "Expected an SVG filename without directories"}, state}
    end
  end
  def handle_call({:draft_asset, _, _}, _, state),
    do: {:reply, %{ok: false, error: "An active ModSmith run is required"}, state}

  def handle_call({:draft_mod, token, args} = request, from, %{run: %{token: token, app: nil}} = state) do
    name = args["name"]
    if is_binary(name) and Regex.match?(~r/^[A-Za-z0-9_-][A-Za-z0-9._-]*\.ex$/, name) do
      case audit_gate(state, [%{"path" => "mods/#{name}", "content" => args["content"]}], {:call, request, from}) do
        :ready -> draft_mod(args, state)
        {:pending, state} -> {:noreply, state}
        {:error, reason} -> {:reply, %{ok: false, error: reason}, state}
      end
    else
      {:reply, %{ok: false, error: "Expected a mod filename ending in .ex, without directories"}, state}
    end
  end

  def handle_call({:draft_mod, _, _}, _, state),
    do: {:reply, %{ok: false, error: "An active browser/site ModSmith run is required"}, state}

  defp draft_mod(args, state) do
    name = args["name"]

    if is_binary(name) and Regex.match?(~r/^[A-Za-z0-9_-][A-Za-z0-9._-]*\.ex$/, name) do
      path = "mods/#{name}"

      profile = Map.get(state.run, :profile, BowserBrain.ModScope.profile_of(state.run.webview))
      source = BowserBrain.ModScope.tag(args["content"], profile)
      existing = ModRevision.absolute(ModRevision.actual_path(path))
      result = if File.exists?(existing) and BowserBrain.ModScope.file_profile(existing) != profile,
        do: {:error, "This mod belongs to another profile; choose a different name", state},
        else: write_files(state, [%{"path" => path, "content" => source}])
      case result do
        {:ok, state} ->
          {:reply, %{ok: true, installed: path,
            applies: "Written with Undo history. Loader compiles asynchronously; verify runtime state before reporting success."}, state}
        {:error, reason, state} ->
          {:reply, %{ok: false, error: reason}, state}
      end
    else
      {:reply, %{ok: false, error: "Expected a mod filename ending in .ex, without directories"}, state}
    end
  end


  defp client(event), do: get_in(event, ["app", "id"]) || "main"
  defp project(state, id), do: Enum.find(state.data["projects"], &(&1["id"] == id))
  defp selection_key(state, "main") do
    case BowserBrain.ModScope.profile_of(state.active) do
      "default" -> "main"
      profile -> "main:" <> profile
    end
  end
  defp selection_key(_state, client), do: client
  defp selected(state, client), do: state.data["selected"][selection_key(state, client)]
  defp persist(state), do: %{state | data: ModRevision.save(state.data)}

  defp put_project(state, project) do
    project = BowserBrain.ModIdentity.attach(project)
    data =
      Map.put(state.data, "projects", [
        project | Enum.reject(state.data["projects"], &(&1["id"] == project["id"]))
      ])

    persist(%{state | data: data})
  end

  defp select(state, client, id),
    do: persist(%{state | data: put_in(state.data, ["selected", selection_key(state, client)], id), error: nil})

  defp available_mods(state, "main") do
    profile = BowserBrain.ModScope.profile_of(state.active)
    BowserBrain.ModCatalog.catalog()
    |> Enum.filter(&(&1.profile == profile))
    |> Enum.map(fn entry ->
      %{path: entry.path, name: Path.basename(BowserBrain.ModCatalog.display(entry.path)),
        scope: entry.host || "Across Bowser", enabled: entry.enabled,
        favicon: BowserBrain.ModIcon.cached(entry.host, profile)}
    end)
  end
  defp available_mods(_state, client) do
    if AppMods.valid_id?(client) do
      Path.wildcard(Path.join([AppMods.root(), client, "*.{css,js}{,.off}"]))
      |> Enum.map(fn path ->
        name = Path.basename(path)
        %{path: "app-mods/#{client}/#{name}", name: String.replace_suffix(name, ".off", ""),
          scope: "Only this app", enabled: not String.ends_with?(name, ".off")}
      end)
    else
      []
    end
  end
  defp edit_existing(state, event) do
    client = client(event)
    requested = event["path"]
    entry = Enum.find(available_mods(state, client), fn entry ->
      BowserBrain.ModCatalog.display(entry.path) == BowserBrain.ModCatalog.display(requested || "")
    end)
    if entry do
      path = BowserBrain.ModCatalog.display(entry.path)
      profile = BowserBrain.ModScope.profile_of(state.active)
      existing = Enum.find(state.data["projects"], fn p ->
        (get_in(p, ["app", "id"]) || "main") == client and
          (client != "main" or Map.get(p, "profile", "default") == profile) and
          Enum.any?(paths(p), &(BowserBrain.ModCatalog.display(&1) == path))
      end)
      project = existing ||
        (new_project(entry.name, if(client != "main", do: "app", else: if(entry.scope == "Across Bowser", do: "browser", else: "site")),
          if(client != "main", do: get_in(event, ["app", "url"]) || "", else: if(entry.scope == "Across Bowser", do: "", else: "https://#{entry.scope}")), event["app"])
          |> Map.put("existing_path", path) |> Map.put("profile", profile))
      state |> put_project(project) |> select(client, project["id"])
    else
      %{state | error: "That mod is no longer available in this window."}
    end
  end

  defp action(state, %{"action" => action} = event) do
    client = client(event)
    id = event["project"]
    project = project(state, id)
    valid = project && (get_in(project, ["app", "id"]) || "main") == client &&
      (client != "main" or Map.get(project, "profile", "default") == BowserBrain.ModScope.profile_of(state.active))

    cond do
      action == "open" ->
        %{state | error: nil}

      action == "edit_existing" ->
        edit_existing(state, event)

      action == "new" ->
        select(state, client, nil)

      action == "select" and valid ->
        select(state, client, id)

      action == "delete" and valid and state.run == nil ->
        delete_project(state, project)

      action == "delete" ->
        %{state | error: if(valid, do: "Stop the current build before deleting a mod.", else: "That mod is unavailable in this window.")}

      action in ["undo", "toggle"] and valid and state.run == nil ->
        revision_action(state, project, action)

      action == "cancel" and state.run != nil and
          (get_in(state.run.app || %{}, ["id"]) || "main") == client and
          ((is_binary(event["run"]) and event["run"] == state.run.token) or
            (event["run"] == nil and valid and state.run.project == id)) ->
        ModSmith.stop_runner(state.run.pid)
        if pending = Map.get(state, :pending_audit) do
          Process.cancel_timer(pending.timer)
          ModSmith.stop_runner(pending.pid)
          case pending.continuation do
            {:call, _, from} -> GenServer.reply(from, %{ok: false, error: "Build stopped"})
            _ -> :ok
          end
        end
        state |> Map.put(:pending_audit, nil) |> finish(nil, :cancelled)

      action == "enable_and_test" and valid and state.run == nil ->
        files = live_paths(project)
        if files != [] and Enum.all?(files, &String.ends_with?(&1, ".off")) do
          enabled = revision_action(state, project, "toggle")
          if enabled.error do
            enabled
          else
            request = "The owner chose Enable & test. The mod has been enabled. " <>
              "Inspect runtime diagnostics and verify the requested behavior on the original page. " <>
              "Repair failures before reporting success. Enabling or compiling alone is not verification. " <>
              "Use non-destructive checks where possible. Respect the owner's existing authorization; " <>
              "if testing needs an additional choice, permission, or consequential external action, " <>
              "return a structured next_step explaining exactly what is needed."
            start(enabled, Map.put(event, "text", request), project(enabled, id))
          end
        else
          state
        end

      action == "document" and valid and state.run == nil ->
        request = "Write a usage guide for this existing mod. This is read-only: inspect its current source and page HTML, without modifying files, executing actions or testing side effects. Return usage: {entry_point: exact place/control/command or automatic trigger, steps: [ordered owner-facing steps], tips: optional configuration or limitations}. Describe only implemented behavior. Return files: []. Do not claim runtime verification."
        start(state, Map.put(event, "text", request), project)

      action == "clarify" and valid and state.run == nil and project["status"] == "needs_help" ->
        request = "Review the previous result and current state without making changes or taking external actions. " <>
          "Explain the actual blocker and return a structured next_step stating exactly what the owner " <>
          "needs to answer or do. Keep rejected repairs separate from missing input. Do not invent a prerequisite."
        start(state, Map.put(event, "text", request), project)

      action == "continue" and valid and state.run == nil and
          project["status"] in ["partial", "needs_help", "failed", "interrupted"] ->
        request = "Continue this unfinished mod. Preserve the original goal and existing work. " <>
          "Inspect the current files and the previous result's limitations, fix what failed, " <>
          "and verify the requested behavior on the page before reporting success."
        request = if get_in(project, ["next_step", "action"]) == "resume",
          do: request <> " The owner confirmed completing this prerequisite: " <> project["next_step"]["detail"],
          else: request
        start(state, Map.put(event, "text", request), project)

      action == "retry" and valid and state.run == nil and project["status"] in ["failed", "interrupted"] ->
        request = Enum.find(Enum.reverse(project["turns"]), &(&1["role"] == "user" and ModSmithOutcome.legacy_activity(&1["text"]) == nil))
        if request, do: start(state, Map.put(event, "text", request["text"]), project), else: state

      action == "submit" and state.run != nil ->
        %{state | error: "Another change is still running. Your draft has been kept."}

      action == "submit" and id != nil and not valid ->
        %{state | error: "That mod is unavailable in this window."}

      action == "submit" ->
        start(state, event, if(valid, do: project))

      true ->
        state
    end
  end

  def new_project(name, scope, url, app) do
    %{
      "id" => ModRevision.id(),
      "name" => String.slice(name, 0, 70),
      "scope" => scope,
      "url" => url,
      "app" => app,
      "session" => nil,
      "turns" => [],
      "revisions" => [],
      "status" => "ready",
      "summary" => "",
      "notes" => "",
      "checks" => []
    }
  end

  defp start(state, event, existing) do
    text = String.trim(event["text"] || "")
    app = (existing && existing["app"]) || event["app"]

    url =
      (existing && existing["url"]) || (app && app["url"]) || event["url"] ||
        state.urls[state.active] || ""

    if text == "" or (app && not AppMods.valid_id?(app["id"])) do
      state
    else
      scope =
        (existing && existing["scope"]) || if(app, do: "app", else: event["scope"] || "site")

      if scope not in ["browser", "site", "app"] or
           (scope != "browser" and URI.parse(url).host == nil) do
        %{state | error: "Open a website before creating a site mod."}
      else
        p = existing || Map.put(new_project(text, scope, url, app), "profile", BowserBrain.ModScope.profile_of(event["webview"] || state.active))
        label = ModSmithOutcome.activity(event["action"])
        revision = ModRevision.new_revision(text) |> Map.put("label", label) |> Map.put("usage_before", p["usage"])
        turn = if label,
          do: %{"id" => revision["id"], "role" => "activity", "text" => label, "instruction" => text},
          else: %{"id" => revision["id"], "role" => "user", "text" => text}

        p =
          p
          |> Map.put("status", "working")
          |> Map.put("next_step", nil)
          |> Map.put("repair_notice", nil)
          |> Map.put("revisions", [revision | p["revisions"]])
          |> Map.put(
            "turns",
            p["turns"] ++ [turn]
          )

        state = state |> put_project(p) |> select(client(event), p["id"])
        wv = if app, do: 0, else: target_webview(state, url, event["webview"])
        run = %{previous_next_step: existing && existing["next_step"], previous_repair_notice: existing && existing["repair_notice"], documentation: event["action"] == "document", previous_status: existing && existing["status"], token: revision["id"], project: p["id"], webview: wv, profile: BowserBrain.ModScope.profile_of(wv), url: url, app: p["app"]}
        parent = self()

        {pid, ref} =
          spawn_monitor(fn ->
            Process.put(:modsmith_run, run.token)

            result =
              try do
                prompt = prompt(p, text, wv)

                runner =
                  Application.get_env(:bowser_brain, :modsmith_runner, &ModSmith.run_claude/4)

                runner.(
                  prompt,
                  p["session"],
                  fn line -> send(parent, {:progress, run.token, line}) end,
                  p["app"]
                )
              rescue
                error -> {nil, {:error, Exception.message(error)}}
              catch
                :exit, reason -> {nil, {:error, inspect(reason)}}
              end

            {session, output} = result
            send(parent, {:finished, run.token, session, output})
          end)

        %{
          state
          | run: Map.merge(run, %{pid: pid, ref: ref}),
            progress: [],
            error: nil,
            accepted: event["request_id"]
        }
      end
    end
  end

  defp target_webview(state, url, preferred) do
    host = URI.parse(url).host

    cond do
      preferred != nil and URI.parse(state.urls[preferred] || url).host == host ->
        preferred

      URI.parse(state.urls[state.active] || "").host == host ->
        state.active

      true ->
        Enum.find_value(state.urls, state.active, fn {wv, u} ->
          if URI.parse(u).host == host and BowserBrain.ModScope.profile_of(wv) == BowserBrain.ModScope.profile_of(state.active), do: wv
        end)
    end
  end

  defp prompt(p, request, wv) do
    host = URI.parse(p["url"]).host || "unknown"

    catalog =
      if p["app"],
        do: "Only this saved app's CSS/JS is available.",
        else: BowserBrain.ModCatalog.catalog() |> Enum.filter(&(&1.profile == BowserBrain.ModScope.profile_of(wv))) |> Enum.map_join("\n", &("#{&1.path}: #{&1.about}"))

    payloads =
      if p["app"],
        do: AppMods.payloads(p["app"]["id"]),
        else: BowserBrain.SiteMods.payloads_for(host, BowserBrain.ModScope.profile_of(wv))

    base =
      ModSmith.build_prompt(
        request,
        p["url"],
        host,
        ModSmith.page_digest(wv, p["app"]),
        Enum.map(payloads, fn {name, source} -> {name, BowserBrain.ModScope.untag(source)} end),
        catalog
      )

    base <>
      """

      CORE MODSMITH WORKSPACE CONTRACT (takes precedence):
      The selected mod is #{p["name"]}. Scope is #{p["scope"]}; target URL #{p["url"]}, webview #{wv}.
      #{if p["scope"] == "site", do: "Only this host's payloads or Elixir mods explicitly declaring this host are allowed.", else: ""}
      #{if p["app"], do: "Only CSS/JS for this saved app. Use sites/#{host}/ paths; these are redirected to this app.", else: ""}
      Mod identity: #{p["mod_id"] || p["id"]}. Other mods retain their own histories; do not overwrite their files from a new creation. Ask the owner to open the existing mod in the ModSmith sidebar to refine it.
      Existing owned files: #{Enum.join(paths(p), ", ")}. #{if p["existing_path"], do: "Modify #{p["existing_path"]} in place.", else: ""}
      You are refining the SAME mod when there is prior conversation. Read the current files before editing: the owner may have undone a revision since your last reply.
      Give the mod a short human-readable "name" in the JSON envelope. Set "status" to "active" only when the requested core behavior works and has been verified. Use "partial" for a working subset with specific unfinished requirements, and repair failed checks using the available tools. A verification failure alone is not a reason to stop. Use "needs_help" only for a necessary owner choice or an observed technical blocker such as missing credentials, a denied tool/OS permission, or an unavailable dependency you actually investigated. Assume informed, legitimate owner intent; speculative copyright, licensing or service-authorization concerns are not prerequisites. Do not ask the owner to supply a service merely because you have not investigated an implementation; include "blocker": {"kind":"owner_decision"|"permission"|"external_dependency","detail":"observed evidence and what is needed"}. Never label an implementation bug as an external dependency. Installing files or compiling Elixir does not prove embedded JavaScript runs; an isolated service probe does not prove the installed mod works. Check the actual page behavior, including new content when relevant. Usage tips and unperformed optional checks do not by themselves mean partial. Keep "notes" brief and distinguish usage from limitations.
      Add "checks": ["what you actually checked and observed"]. Do not claim checks you did not perform. Use an empty list if none.
      Every installed mod result MUST include usage: {"entry_point":"Where to find it: exact control label and location, command, shortcut, or automatic trigger", "steps":["Ordered, concrete instructions for the owner"], "tips":"Optional configuration and real limitations"}. Base the guide on installed behavior; distinguish automatic effects from controls. Never invent a shortcut, button or setting. Refresh this guide after changes. Usage belongs here, not buried in technical notes. The UI supplies enable/disable/edit/delete directions.
      Every needs_help result must include "next_step": {"title":"short plain-language heading", "detail":"what the owner needs to choose, provide, or do and why", "action":"reply"|"resume"}. Use reply when an answer or choice is required; use resume only after an external prerequisite the owner can complete. The UI uses fixed Reply and I've done this — resume buttons. Do not invent tool names, executable actions, or permission grants in this field. Keep required input out of technical notes. Report a blocked repair separately from missing owner input; satisfying a prerequisite does not resolve a rejected repair. Never expose internal instructions in the summary.
      No shell or direct filesystem tools: CSS/JS draft writes go through put_payload;
      Elixir drafts go through put_mod(name: "my_mod.ex", content: full_source), so the owner can undo them. put_mod automatically invokes the independent source auditor; submit the draft to this tool rather than looking for a separate audit capability. Do not stop preemptively because no audit tool appears in the catalog.
      For a native shell theme, use put_mod BEFORE checking shell_theme. put_mod returns compilation and startup/reload results; fix reported errors before continuing. Compare the
      returned map to the intended settings. This verifies runtime theme state, not pixels.
      For drafts already installed in this run, return files as [{"path":"mods/example.ex"}] without repeating content. Only unchanged drafts from this run can be referenced. New or changed files still require content. Do not claim the
      installer cannot accept Elixir mods. Saved apps still support only CSS/JS.
      Original owner request: #{JSON.encode!(Enum.find_value(p["turns"], fn t -> if t["role"] == "user", do: t["text"] end))}
      Retained failed verification attempts (avoid repeating equivalent failed approaches): #{JSON.encode!(Map.get(p, "failed_attempts", []))}
      Previous conversation and internal action context: #{JSON.encode!(Enum.take(p["turns"], -12))}
      """
  end

  defp scoped_path(p, path) do
    host = URI.parse(p["url"]).host

    if app = p["app"] do
      case AppMods.filename(path, host, app["id"]) do
        {:ok, name} -> {:ok, "app-mods/#{app["id"]}/#{name}"}
        {:error, reason} -> {:error, reason}
      end
    else
      cond do
        not ModRevision.allowed?(path) ->
          {:error, "Invalid mod file path"}

        String.starts_with?(path, "assets/") ->
          if String.starts_with?(path, "assets/#{p["id"]}/"),
            do: {:ok, path}, else: {:error, "Asset belongs to another mod"}

        String.starts_with?(path, "app-mods/") ->
          {:error, "Saved-app files are outside this mod's scope"}

        p["scope"] == "site" and not String.starts_with?(path, "sites/#{host}/") and
            not String.starts_with?(path, "mods/") ->
          {:error, "File is outside the selected site"}

        true ->
          {:ok, path}
      end
    end
  end

  defp prepare_file(p, %{"path" => path, "content" => content})
       when is_binary(path) and is_binary(content) and byte_size(content) <= 200_000 do
    with {:ok, path} <- scoped_path(p, path), :ok <- validate_code(p, path, content) do
      {:ok, {ModRevision.actual_path(path), content}}
    end
  end

  defp prepare_file(_, %{"path" => path, "content" => content})
       when is_binary(path) and is_binary(content),
       do: {:error, "Generated file #{path} is #{byte_size(content)} bytes; the limit is 200000 bytes"}

  defp prepare_file(_, %{"path" => path} = file) when is_binary(path) do
    cond do
      not ModRevision.allowed?(path) -> {:error, "Invalid mod file path: #{inspect(path)}"}
      Map.has_key?(file, "content") -> {:error, "Generated file #{path} requires text content"}
      true -> {:error, "Generated file #{path} has no content or unchanged draft from this run"}
    end
  end

  defp prepare_file(_, _), do: {:error, "Generated file must be an object with a text path and content"}

  defp validate_code(_, "assets/" <> _, content) do
    if String.contains?(content, "<svg") and not Regex.match?(~r/<!DOCTYPE|<!ENTITY|<script|<foreignObject|\b(?:href|src)\s*=\s*["'](?!#)|\burl\s*\(/i, content),
      do: :ok, else: {:error, "Use a self-contained SVG with no scripts, external resources, or entities"}
  end

  defp validate_code(p, path, content) do
    if String.ends_with?(String.replace_suffix(path, ".off", ""), ".ex") do
      with {:ok, ast} <- Code.string_to_quoted(content, static_atoms_encoder: fn name, _ -> {:ok, name} end) do
        host = URI.parse(p["url"]).host
        declarations =
          for {"defmodule", _, [{:__aliases__, _, names}, body]} <- statements(ast),
              is_list(body), Enum.all?(names, &is_binary/1),
              {"use", _, [{:__aliases__, _, target} | arguments]} <- statements(Keyword.get(body, :do)),
              target in [["BowserBrain", "Mod"], ["Elixir", "BowserBrain", "Mod"]],
              do: arguments

        # Only direct declarations describe a mod. Walking into quotes or
        # function bodies mistakes inert examples for executable metadata.
        # This is structural validation, not an Elixir capability boundary.
        cond do
          declarations == [] ->
            {:error, "Generated Elixir must define a top-level module using BowserBrain.Mod"}
          p["scope"] == "site" and not Enum.all?(declarations, fn
            [opts] when is_list(opts) -> List.keyfind(opts, "host", 0) == {"host", host}
            _ -> false
          end) ->
            {:error, "Every site mod must directly declare host: #{host}"}
          true -> :ok
        end
      else
        _ -> {:error, "Generated Elixir has a syntax error"}
      end
    else
      :ok
    end
  end

  defp prepared_files(state, files) do
    p = project(state, state.run.project)
    profile = Map.get(state.run, :profile, BowserBrain.ModScope.profile_of(state.run.webview))
    Enum.map(files, fn file ->
      case prepare_file(p, file) do
        {:ok, {path, content}} = result ->
          if other = BowserBrain.ModIdentity.conflict(state.data["projects"], p, path) do
            {:error, "This file belongs to #{other["name"]}. Open that mod in the ModSmith sidebar to edit it, or choose a new filename."}
          else
          if is_nil(p["app"]) and (String.starts_with?(path, "mods/") or String.starts_with?(path, "sites/")) do
            existing = ModRevision.absolute(ModRevision.actual_path(path))
            if File.exists?(existing) and BowserBrain.ModScope.file_profile(existing) != profile do
              {:error, "This file belongs to another profile; choose a different name"}
            else
              if is_binary(content) and String.ends_with?(String.replace_suffix(path, ".off", ""), ".ex") and module_collision?(path, content) do
                {:error, "Module name already in use; choose a different module name"}
              else
              {:ok, {path, if(is_binary(content), do: BowserBrain.ModScope.tag(content, profile, Path.extname(String.replace_suffix(path, ".off", ""))), else: content)}}
              end
            end
          else
            result
          end
          end
        error -> error
      end
    end)

  end

  defp module_collision?(path, source) do
    names = declared_mods(source)
    actual = ModRevision.actual_path(path)
    Path.wildcard(Path.join(BowserBrain.ModCatalog.mods_dir(), "*.ex{,.off}"))
    |> Enum.any?(fn file ->
      candidate = "mods/" <> Path.basename(file)
      candidate != actual and
        case scoped_source(candidate) do
          {:ok, _, other} -> Enum.any?(declared_mods(other), &(&1 in names))
          _ -> false
        end
    end)
  end

  defp audit_key(state, path, content),
    do: {state.run.token, path, BowserBrain.ModAuditor.digest(content)}

  defp audit_gate(state, files, continuation) do
    prepared = prepared_files(state, files)
    with nil <- Enum.find(prepared, &match?({:error, _}, &1)) do
      needed = for {:ok, {path, source}} <- prepared,
        String.ends_with?(String.replace_suffix(path, ".off", ""), ".ex"),
        audit_key(state, path, source) not in Map.get(state, :audit_approvals, []),
        do: {path, source}
      cond do
        needed == [] -> :ready
        Map.get(state, :pending_audit) != nil -> {:error, "A security audit is already running"}
        true ->
          parent = self()
          ref = make_ref()
          token = state.run.token
          p = project(state, state.run.project)
          [revision | _] = p["revisions"]
          context = %{request: revision["request"], scope: p["scope"], host: URI.parse(p["url"]).host,
            prior_requests: p["revisions"] |> tl() |> Enum.reverse() |> Enum.map(fn prior ->
              %{request: prior["request"], status: prior["status"]}
            end)}
          # Read baselines before the worker starts. Draft writes retain the original
          # revision snapshot, while previous_source reflects the latest on-disk draft.
          reviews = Enum.map(needed, fn {path, source} ->
            previous = ModRevision.read(path)
            original = case revision["files"][path] do
              nil -> previous
              file -> file["before"]
            end
            {path, source, Map.merge(context, %{previous_source: previous, revision_start_source: original})}
          end)
          pid = spawn(fn ->
            result = Enum.reduce_while(reviews, :ok, fn {path, source, context}, :ok ->
              case BowserBrain.ModAuditor.review(context, path, source) do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end
            end)
            send(parent, {:audit_finished, ref, result})
          end)
          timer = Process.send_after(self(), {:audit_finished, ref, {:error, "Security audit timed out; Elixir was not installed"}}, 95_000)
          pending = %{ref: ref, token: token, pid: pid, timer: timer, continuation: continuation,
            keys: Enum.map(needed, fn {path, source} -> audit_key(state, path, source) end)}
          state = state |> Map.put(:pending_audit, pending) |> Map.update!(:progress, &(&1 ++ ["Security audit reviewing generated Elixir"]))
          publish(state)
          {:pending, state}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, "Cannot prepare generated files for security audit"}
  end

  defp write_files(state, files) do
    prepared = prepared_files(state, files)
    prepared = Enum.map(prepared, fn
      {:ok, {path, source}} = item ->
        if String.ends_with?(String.replace_suffix(path, ".off", ""), ".ex") and
             audit_key(state, path, source) not in Map.get(state, :audit_approvals, []),
          do: {:error, "Security audit approval is required before installing Elixir"}, else: item
      item -> item
    end)

    case Enum.find(prepared, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:error, reason, state}

      nil ->
        Enum.reduce_while(prepared, {:ok, state}, fn {:ok, {path, content}}, {:ok, current} ->
          captured =
            try do
              p = project(current, current.run.project)
              [revision | rest] = p["revisions"]
              revision = ModRevision.capture(revision, path, content)
              {:ok, put_project(current, Map.put(p, "revisions", [revision | rest]))}
            rescue
              error -> {:error, Exception.message(error)}
            end

          case captured do
            {:error, reason} ->
              {:halt, {:error, reason, current}}

            {:ok, recorded} ->
              try do
                ModRevision.write(path, content)
                {:cont, {:ok, recorded}}
              rescue
                error -> {:halt, {:error, Exception.message(error), recorded}}
              end
          end
        end)
    end
  rescue
    error -> {:error, Exception.message(error), state}
  end

  # References may only name an unchanged draft captured by THIS run.
  defp resolve_drafts(state, files) when is_list(files) do
    p = project(state, state.run.project)
    [revision | _] = p["revisions"]
    Enum.map(files, fn
      %{"path" => path} = file when not is_map_key(file, "content") ->
        resolve_draft(p, revision, path, file)
      file -> file
    end)
  end
  defp resolve_drafts(_, files), do: files

  defp resolve_draft(p, revision, path, file) do
    with true <- is_binary(path),
         {:ok, scoped} <- scoped_path(p, path),
         actual <- ModRevision.actual_path(scoped),
         %{"after" => content} when is_binary(content) <- revision["files"][actual],
         ^content <- ModRevision.read(actual) do
      Map.merge(file, %{"path" => actual, "content" => content})
    else
      _ -> file
    end
  rescue
    _ -> file
  end

  defp verification_files_match?(state, envelope) do
    files = resolve_drafts(state, envelope["files"] || [])
    is_list(files) and files != [] and
      Enum.all?(prepared_files(state, files), fn
        {:ok, {path, content}} -> is_binary(content) and not String.ends_with?(ModRevision.actual_path(path), ".off") and
          ModRevision.read(ModRevision.actual_path(path)) == content
        _ -> false
      end)
  rescue
    _ -> false
  end

  defp finish(%{run: %{documentation: true}} = state, _session, result) do
    Process.demonitor(state.run.ref, [:flush])
    usage = case result do
      {:output, output} -> case ModSmith.extract_json(output) do
        {:ok, envelope} -> ModSmithOutcome.usage(envelope)
        _ -> nil
      end
      _ -> nil
    end
    p = project(state, state.run.project)
    p = p |> Map.put("status", state.run.previous_status || "ready")
      |> Map.put("next_step", state.run.previous_next_step)
      |> Map.put("repair_notice", state.run.previous_repair_notice)
      |> Map.put("revisions", tl(p["revisions"]))
      |> Map.put("usage", usage || p["usage"])
      |> Map.put("turns", p["turns"] ++ [%{"id" => ModRevision.id(), "role" => "activity",
        "text" => if(usage, do: "Usage instructions are ready.", else: "Could not write instructions. Try again.")}])
    next = put_project(state, p)
    %{next | run: nil, error: if(usage, do: nil, else: "Could not generate usage instructions. Try again.")}
  end

  defp finish(state, session, result) do
    Process.demonitor(state.run.ref, [:flush])
    envelope = case result do
      {:output, output} -> case ModSmith.extract_json(output) do
        {:ok, value} when is_map(value) -> value
        _ -> %{}
      end
      _ -> %{}
    end

    {state, status, summary, notes, checks, name} =
      case result do
        :cancelled ->
          {state, "interrupted", "Build stopped. Changes already applied are kept; use Undo to revert them.", "", [], nil}

        {:output, output} ->
          case ModSmith.extract_json(output) do
            {:ok, envelope} when is_map(envelope) ->
              files = envelope["files"] || []
              files = resolve_drafts(state, files)
              notes = string(envelope["notes"])
              summary = string(envelope["summary"])

              checks =
                if is_list(envelope["checks"]),
                  do: Enum.filter(envelope["checks"], &is_binary/1),
                  else: []

              cond do
                files == [] ->
                  {state, "needs_help", summary, notes, checks, envelope["name"]}

                not is_list(files) ->
                  {state, "failed", "Invalid generated file list", notes, checks, nil}

                true ->
                  case write_files(state, files) do
                    {:ok, state} ->
                      {state, if(envelope["status"] in ["partial", "needs_help", "failed"], do: envelope["status"], else: "active"), summary, notes,
                       checks, envelope["name"]}

                    {:error, reason, state} ->
                      {state, "failed", reason, notes, checks, nil}
                  end
              end

            _ ->
              {state, "failed", "The agent did not return a usable result.", "", [], nil}
          end

        {:error, reason} ->
          {state, "failed", string(reason), "", [], nil}
      end

    verified = case {result, Map.get(state.run, :verification)} do
      {{:output, output}, %{hash: hash, verdict: :ok}} -> BowserBrain.ModAuditor.digest(output) == hash and verification_files_match?(state, envelope)
      _ -> false
    end
    {status, summary, notes} = if status == "active" and not verified,
      do: {"partial", "The requested behavior is not verified yet.", "Live outcome verification is still required. " <> notes},
      else: {status, summary, notes}

    {status, summary} = if Map.get(state.run, :script_fault, false),
      do: {"failed", "A page hook was paused because its observer kept triggering itself. Repair the hook, then run verification again."},
      else: {status, summary}
    p = project(state, state.run.project)
    next_step = ModSmithOutcome.next_step(envelope, status)
    repair_notice = if map_size(Map.get(state.run, :audit_failures, %{})) > 0,
      do: "A proposed change could not pass security review and was not installed. Any earlier saved changes remain."
    [revision | rest] = p["revisions"]
    revision = revision |> Map.put("status", status) |> Map.put("summary", summary)

    turn = %{
      "id" => ModRevision.id(),
      "role" => "assistant",
      "text" => summary,
      "status" => status,
      "notes" => notes,
      "checks" => checks,
      "next_step" => next_step,
      "repair_notice" => repair_notice
    }

    p =
      p
      |> Map.put("session", session || p["session"])
      |> Map.put("status", status)
      |> Map.put("summary", summary)
      |> Map.put("notes", notes)
      |> Map.put("checks", checks)
      |> Map.put("next_step", next_step)
      |> Map.put("repair_notice", repair_notice)
      |> Map.put("usage", ModSmithOutcome.usage(envelope) || if(status in ["failed", "interrupted"], do: p["usage"]))
      |> Map.put("revisions", [revision | rest])
      |> Map.put("turns", p["turns"] ++ [turn])
      |> Map.put(
        "name",
        if(is_binary(name) and name != "", do: String.slice(name, 0, 70), else: p["name"])
      )

    state = put_project(state, p)
    %{state | run: nil} |> Map.put(:audit_approvals, [])
  end

  defp string(value) when is_binary(value), do: value
  defp string(nil), do: ""
  defp string(value), do: JSON.encode!(value)

  defp paths(p),
    do:
      (Map.get(p, "owned_files", []) ++ Enum.flat_map(p["revisions"], &Map.keys(&1["files"])) ++ List.wrap(p["existing_path"]))
      |> Enum.uniq()

  defp live_paths(p) do
    paths(p)
    |> Enum.flat_map(fn path ->
      plain = String.replace_suffix(path, ".off", "")
      [plain, plain <> ".off"]
    end)
    |> Enum.uniq()
    |> Enum.filter(&(ModRevision.read(&1) != nil))
  end

  defp delete_project(state, project) do
    canonical = &String.replace_suffix(&1, ".off", "")
    identity = fn p ->
      paths(p) |> Enum.reject(&String.starts_with?(&1, "assets/"))
      |> Enum.map(canonical) |> MapSet.new()
    end
    target = identity.(project)
    duplicates = Enum.filter(state.data["projects"], fn p ->
      p["id"] == project["id"] or
        (MapSet.size(target) > 0 and identity.(p) == target and p["app"] == project["app"] and
          Map.get(p, "profile", "default") == Map.get(project, "profile", "default"))
    end)
    deleting = Enum.uniq_by([project | duplicates], & &1["id"])
    ids = Enum.map(deleting, & &1["id"])
    asset_ids = Enum.flat_map(deleting, &Map.get(&1, "history_ids", [&1["id"]]))
    files = deleting |> Enum.flat_map(&live_paths/1) |> Enum.uniq()
    others = Enum.reject(state.data["projects"], &(&1["id"] in ids))
    shared = others |> Enum.flat_map(&paths/1) |> Enum.map(canonical) |> MapSet.new()

    if Enum.any?(files, &MapSet.member?(shared, canonical.(&1))),
      do: raise("This mod shares files with another ModSmith project. Resolve the shared files before deleting it.")

    originals = Map.new(files, &{&1, ModRevision.read(&1)})
    Enum.each(originals, fn {path, source} ->
      owned = cond do
        String.starts_with?(path, "assets/") -> Enum.any?(asset_ids, &String.starts_with?(path, "assets/#{&1}/"))
        app = project["app"] -> String.starts_with?(path, "app-mods/#{app["id"]}/")
        true -> not String.starts_with?(path, "app-mods/") and
          BowserBrain.ModScope.source_profile(source) == Map.get(project, "profile", "default")
      end
      unless owned, do: raise("A mod file now belongs to another profile or app. Nothing was deleted.")
    end)

    data = state.data
      |> Map.put("projects", others)
      |> Map.update!("selected", fn selections ->
        Map.reject(selections, fn {_, id} -> id in ids end)
      end)

    try do
      Enum.each(files, &ModRevision.write(&1, nil))
      %{state | data: ModRevision.save(data), error: nil}
    rescue
      error ->
        Enum.each(originals, fn {path, source} -> ModRevision.write(path, source) end)
        %{state | error: "Could not delete the mod: #{Exception.message(error)}. Its history has been kept."}
    end
  end

  defp revision_action(state, p, "undo") do
    revision = Enum.find(p["revisions"], &(&1["status"] != "undone" and ModRevision.changed?(&1)))

    if revision do
      state = put_project(state, Map.put(p, "pending_undo", revision["id"]))

      case ModRevision.restore(revision) do
        :ok ->
          revisions =
            Enum.map(p["revisions"], fn r ->
              if r["id"] == revision["id"], do: Map.put(r, "status", "undone"), else: r
            end)

          p =
            p
            |> Map.put("revisions", revisions)
            |> Map.put("usage", revision["usage_before"])
            |> Map.put("status", "restored")
            |> Map.put("summary", "Restored the files from before: #{ModSmithOutcome.revision_label(revision)}")
            |> Map.put("next_step", nil)
            |> Map.put("repair_notice", nil)
            |> Map.put("session", nil)
            |> Map.put(
              "turns",
              p["turns"] ++
                [
                  %{
                    "id" => ModRevision.id(),
                    "role" => "system",
                    "text" =>
                      "Undid: #{ModSmithOutcome.revision_label(revision)}. Website actions and stored mod data were not reversed."
                  }
                ]
            )

          put_project(%{state | error: nil}, p)

        {:error, reason} ->
          state = put_project(state, p)
          %{state | error: reason}
      end
    else
      state
    end
  end

  defp revision_action(state, p, "toggle") do
    files = live_paths(p)
    enabled = Enum.any?(files, &(not String.ends_with?(&1, ".off")))
    files = Enum.filter(files, &(String.ends_with?(&1, ".off") != enabled))
    revision = ModRevision.new_revision(if(enabled, do: "Disable mod", else: "Enable mod")) |> Map.put("usage_before", p["usage"])

    pairs =
      Enum.flat_map(files, fn path ->
        target = if enabled, do: path <> ".off", else: String.replace_suffix(path, ".off", "")

        if ModRevision.read(target) != nil,
          do: raise("Both active and disabled files exist; resolve them before toggling.")

        [{target, ModRevision.read(path)}, {path, nil}]
      end)

    revision =
      Enum.reduce(pairs, revision, fn {path, content}, r ->
        ModRevision.capture(r, path, content)
      end)

    p = Map.put(p, "revisions", [revision | p["revisions"]])
    state = put_project(state, p)

    result =
      try do
        Enum.each(pairs, fn {path, content} -> ModRevision.write(path, content) end)
        :ok
      rescue
        error -> {:error, Exception.message(error)}
      end

    restored_status = if p["status"] == "disabled", do: Map.get(p, "status_before_disable", "needs_help"), else: p["status"]
    status =
      if result == :ok,
        do: if(enabled, do: "disabled", else: restored_status),
        else: "interrupted"

    p = if enabled, do: Map.put(p, "status_before_disable", p["status"]), else: p

    p =
      p
      |> Map.put("status", status)
      |> Map.put("revisions", [Map.put(revision, "status", status) | tl(p["revisions"])])

    state = put_project(state, p)

    case result do
      :ok -> %{state | error: nil}
      {:error, reason} -> %{state | error: "#{reason}. Use Undo to restore the files."}
    end
  end

  def snapshot(state, client) do
    projects =
      Enum.filter(state.data["projects"], &((get_in(&1, ["app", "id"]) || "main") == client and
        (client != "main" or Map.get(&1, "profile", "default") == BowserBrain.ModScope.profile_of(state.active))))

    %{
      op: "modsmith_state",
      available_mods: available_mods(state, client),
      app: if(client == "main", do: nil, else: client),
      selected: selected(state, client),
      busy: state.run != nil,
      running_run: if(state.run && (get_in(state.run.app || %{}, ["id"]) || "main") == client, do: state.run.token),
      running_project: if(state.run && (get_in(state.run.app || %{}, ["id"]) || "main") == client, do: state.run.project),
      accepted: state.accepted,
      error: if(Map.get(state, :error_client, "main") == client, do: state.error),
      progress:
        if(state.run && (get_in(state.run.app || %{}, ["id"]) || "main") == client,
          do: state.progress,
          else: []
        ),
      stage: stage(state.progress),
      projects:
        Enum.map(projects, fn p ->
          files = live_paths(p)

          revision =
            Enum.find(p["revisions"], &(&1["status"] != "undone" and ModRevision.changed?(&1)))

          p
          |> Map.drop(["session", "revisions"])
          |> Map.put("turns", Enum.map(p["turns"], &ModSmithOutcome.visible_turn/1))
          |> Map.put("favicon", if(p["scope"] != "browser", do: BowserBrain.ModIcon.cached(p["url"], Map.get(p, "profile", "default"))))
          |> Map.put("files", files)
          |> Map.put("enabled", Enum.any?(files, &(not String.ends_with?(&1, ".off"))))
          |> Map.put("can_undo", revision != nil)
          |> Map.put("undo_label", revision && ModSmithOutcome.revision_label(revision))
        end)
    }
  end

  def stage(progress) do
    line = List.last(progress) || ""

    cond do
      String.contains?(line, ["put_payload", "store_put"]) -> "Making changes"
      String.contains?(line, "page_eval") -> "Checking the page"
      true -> "Inspecting and building"
    end
  end

  defp publish(state, client \\ nil, show \\ false) do
    clients =
      if client, do: [client], else: Enum.uniq(["main" | Map.keys(state.data["selected"])])

    Enum.each(clients, fn c -> Bridge.cast_msg(Map.put(snapshot(state, c), :show, show)) end)
  end
end
