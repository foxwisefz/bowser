defmodule BowserBrain.ModWorkshopTest do
  use ExUnit.Case, async: false
  alias BowserBrain.{ModWorkshop, ModRevision}

  setup do
    root = Path.join(System.tmp_dir!(), "modsmith-#{ModRevision.id()}")
    File.mkdir_p!(root)
    old_home = System.get_env("BOWSER_HOME")
    old_path = Application.get_env(:bowser_brain, :modsmith_workspace_path)
    old_auditor = Application.get_env(:bowser_brain, :modsmith_auditor)
    Application.put_env(:bowser_brain, :modsmith_auditor, fn prompt ->
      data = JSON.decode!(prompt)
      {:ok, JSON.encode!(%{verdict: "allow", reason: "Test fixture approved", sha256: data["sha256"], nonce: data["nonce"]})}
    end)
    original = :sys.get_state(ModWorkshop)
    System.put_env("BOWSER_HOME", root)
    Application.put_env(:bowser_brain, :modsmith_workspace_path, Path.join(root, "history.json"))

    :sys.replace_state(ModWorkshop, fn _ ->
      %{
        original
        | data: ModRevision.empty(),
          run: nil,
          error: nil,
          urls: %{7 => "https://example.com"},
          active: 7
      }
    end)

    owner = self()

    Application.put_env(:bowser_brain, :modsmith_runner, fn prompt, resume, _, app ->
      send(owner, {:runner, self(), Process.get(:modsmith_run), prompt, resume, app})

      receive do
        {:result, result} -> result
      end
    end)

    on_exit(fn ->
      state = :sys.get_state(ModWorkshop)
      if state.run, do: Process.exit(state.run.pid, :kill)
      :sys.replace_state(ModWorkshop, fn _ -> original end)

      if old_home,
        do: System.put_env("BOWSER_HOME", old_home),
        else: System.delete_env("BOWSER_HOME")

      Application.put_env(:bowser_brain, :modsmith_workspace_path, old_path)
      Application.delete_env(:bowser_brain, :modsmith_runner)
      if old_auditor, do: Application.put_env(:bowser_brain, :modsmith_auditor, old_auditor),
        else: Application.delete_env(:bowser_brain, :modsmith_auditor)

      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "existing disabled mods reopen one conversation and reject foreign paths", %{root: root} do
    File.mkdir_p!(Path.join(root, "mods"))
    File.write!(Path.join(root, "mods/reader.ex.off"), "# Existing reader\n")
    File.write!(Path.join(root, "mods/other.ex"), "# bowser-profile: other\n")
    state = event("open", %{})
    available = ModWorkshop.snapshot(state, "main").available_mods
    assert Enum.any?(available, &(&1.path == "mods/reader.ex.off" and not &1.enabled))
    refute Enum.any?(available, &(&1.path == "mods/other.ex"))
    state = event("edit_existing", %{"path" => "mods/reader.ex.off"})
    [project] = state.data["projects"]
    assert project["existing_path"] == "mods/reader.ex"
    assert project["status"] == "ready"
    state = event("edit_existing", %{"path" => "mods/reader.ex"})
    assert length(state.data["projects"]) == 1
    assert ModWorkshop.snapshot(state, "main").selected == project["id"]
    state = event("edit_existing", %{"path" => "mods/other.ex"})
    assert state.error != nil
    state = event("edit_existing", %{"path" => "../private"})
    assert state.error != nil
    assert length(state.data["projects"]) == 1
  end

  test "saved-app picker includes disabled files only from its own app", %{root: root} do
    id = "com.foxwiseai.bowser.site.0123456789abcdef"
    app = %{"id" => id, "url" => "https://example.com", "name" => "Example"}
    dir = Path.join([root, "app-mods", id])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "reader.css.off"), "body { color: red }")
    state = event("open", %{"app" => app})
    assert [%{path: path, enabled: false}] = ModWorkshop.snapshot(state, id).available_mods
    state = event("edit_existing", %{"app" => app, "path" => path})
    [project] = state.data["projects"]
    assert project["scope"] == "app"
    assert project["app"] == app
    assert ModWorkshop.snapshot(state, "main").projects == []
  end

  test "cancel fences late results and retry starts a fresh run" do
    state = event("submit", %{"text" => "Make reading easier", "scope" => "site"})
    assert_receive {:runner, pid, token, _, _, _}, 2000
    id = state.run.project
    assert event("cancel", %{"project" => "unknown"}).run != nil
    state = event("cancel", %{"project" => id})
    assert state.run == nil
    refute Process.alive?(pid)
    assert hd(state.data["projects"])["status"] == "interrupted"
    send(ModWorkshop, {:finished, token, nil, {:output, "{}"}})
    assert :sys.get_state(ModWorkshop).run == nil
    state = event("retry", %{"project" => id})
    assert state.run.token != token
    assert_receive {:runner, _, _, _, _, _}, 2000
  end

  test "unfinished runs continue in the same project with failure context and ownership guards" do
    event("submit", %{"text" => "Stamp slop on new posts"})
    assert_receive {:runner, pid, _, _, _, _}, 2000
    state = complete(pid, [file("draft")], %{"status" => "partial", "notes" => "Observer never starts"})
    [project] = state.data["projects"]
    id = project["id"]
    assert event("continue", %{"project" => "unknown"}).run == nil
    assert event("continue", %{"project" => id, "app" => %{"id" => "foreign"}}).run == nil
    state = event("continue", %{"project" => id})
    assert state.run.project == id
    assert length(state.data["projects"]) == 1
    assert_receive {:runner, pid, token, prompt, _, _}, 2000
    assert prompt =~ "Stamp slop on new posts"
    assert prompt =~ "Observer never starts"
    assert event("continue", %{"project" => id}).run.token == token
    refute_receive {:runner, _, _, _, _, _}, 50
    state = complete(pid, [file("fixed")])
    assert hd(state.data["projects"])["status"] == "active"
    assert event("continue", %{"project" => id}).run == nil
  end

  test "enable and test enables once, resumes verification and keeps ownership and Undo" do
    ModRevision.write("sites/example.com/reading.css.off", "original")
    event("submit", %{"text" => "Reading mode"})
    assert_receive {:runner, pid, _, _, _, _}, 1000
    [project] = complete(pid, [file("draft")], %{"status" => "needs_help"}).data["projects"]
    id = project["id"]
    assert event("enable_and_test", %{"project" => "unknown"}).run == nil
    assert event("enable_and_test", %{"project" => id, "app" => %{"id" => "foreign"}}).run == nil
    assert ModRevision.read("sites/example.com/reading.css") == nil
    state = event("enable_and_test", %{"project" => id})
    assert state.run.project == id
    assert_receive {:runner, pid, token, prompt, _, _}, 1000
    assert prompt =~ "verify the requested behavior"
    assert prompt =~ "Respect the owner's existing authorization"
    [visible] = ModWorkshop.snapshot(state, "main").projects
    assert List.last(visible["turns"])["role"] == "activity"
    refute Map.has_key?(List.last(visible["turns"]), "instruction")
    assert List.last(hd(state.data["projects"])["turns"])["instruction"] =~ "structured next_step"
    assert ModRevision.read("sites/example.com/reading.css.off") == nil
    assert ModRevision.read("sites/example.com/reading.css") != nil
    assert event("enable_and_test", %{"project" => id}).run.token == token
    [project] = complete(pid, [], %{"status" => "needs_help"}).data["projects"]
    assert project["status"] == "needs_help"
    assert event("enable_and_test", %{"project" => id}).run == nil
    event("undo", %{"project" => id})
    event("undo", %{"project" => id})
    assert ModRevision.read("sites/example.com/reading.css") == nil
    assert ModRevision.read("sites/example.com/reading.css.off") != nil
  end

  test "enabling an unverified mod does not report success" do
    ModRevision.write("sites/example.com/reading.css.off", "original")
    event("submit", %{"text" => "Reading mode"})
    assert_receive {:runner, pid, _, _, _, _}, 1000
    [project] = complete(pid, [file("draft")], %{"status" => "needs_help"}).data["projects"]
    state = event("toggle", %{"project" => project["id"]})
    assert hd(state.data["projects"])["status"] == "needs_help"
  end

  test "next steps persist independently of blocked repairs and clear when work resumes" do
    Application.put_env(:bowser_brain, :modsmith_auditor, fn _ -> {:error, :unavailable} end)
    event("submit", %{"text" => "Organize my workspace", "scope" => "browser"})
    assert_receive {:runner, pid, token, _, _, _}, 1000
    assert %{ok: false} = ModWorkshop.tool(token, "put_mod", %{
      "name" => "workspace.ex", "content" => "defmodule WorkspaceFixture do use BowserBrain.Mod end"
    })
    step = %{"title" => "Choose a workspace", "detail" => "Which workspace should this apply to?", "action" => "reply"}
    state = complete(pid, [], %{"status" => "needs_help", "next_step" => step})
    [project] = ModWorkshop.snapshot(state, "main").projects
    assert project["next_step"] == step
    assert project["repair_notice"] =~ "not installed"
    assert ModRevision.read("mods/workspace.ex") == nil
    persisted = JSON.decode!(File.read!(Application.get_env(:bowser_brain, :modsmith_workspace_path)))
    assert hd(persisted["projects"])["next_step"] == step
    state = event("submit", %{"project" => project["id"], "text" => "The personal workspace"})
    assert hd(state.data["projects"])["next_step"] == nil
    assert hd(state.data["projects"])["repair_notice"] == nil
  end

  test "retry uses the owner request and automatic instructions stay out of snapshots" do
    event("submit", %{"text" => "Make text easier to read"})
    assert_receive {:runner, pid, _, _, _, _}, 1000
    [project] = complete(pid, [], %{"status" => "needs_help"}).data["projects"]
    event("clarify", %{"project" => project["id"]})
    assert_receive {:runner, pid, _, prompt, _, _}, 1000
    assert prompt =~ "without making changes"
    complete(pid, [file("draft")], %{"status" => "failed"})
    state = event("retry", %{"project" => project["id"]})
    assert_receive {:runner, _, _, prompt, _, _}, 1000
    assert hd(hd(state.data["projects"])["revisions"])["request"] == "Make text easier to read"
    assert prompt =~ "Make text easier to read"
    [visible] = ModWorkshop.snapshot(state, "main").projects
    assert List.last(visible["turns"])["role"] == "activity"
    refute JSON.encode!(visible) =~ "without making changes"
  end

  test "runtime observer pause prevents a successful ModSmith result" do
    event("submit", %{"text" => "Add a page control"})
    assert_receive {:runner, pid, _, _, _, _}, 1000
    send(ModWorkshop, {:browser_event, %{"event" => "mod_script_fault", "webview" => 7, "reason" => "observer_loop"}})
    [project] = complete(pid, [file("body {}")], %{"status" => "active"}).data["projects"]
    assert project["status"] == "failed"
    assert project["summary"] =~ "observer"
  end

  test "saving files preserves nonworking outcomes and allows continuation" do
    for status <- ["needs_help", "failed"] do
      event("submit", %{"text" => "Filter new posts"})
      assert_receive {:runner, pid, _, _, _, _}, 2000
      state = complete(pid, [file("broken")], %{"status" => status})
      [project | _] = state.data["projects"]
      assert project["status"] == status
      assert event("continue", %{"project" => project["id"]}).run != nil
      assert_receive {:runner, _, _, _, _, _}, 2000
      event("cancel", %{"project" => project["id"]})
    end
  end

  test "cancel stops an outstanding audit and ignores late approval" do
    state = event("submit", %{"text" => "Make reading easier", "scope" => "site"})
    assert_receive {:runner, _, token, _, _, _}, 2000
    audit = spawn(fn -> receive do :never -> :ok end end)
    ref = make_ref()
    timer = Process.send_after(ModWorkshop, {:audit_finished, ref, :ok}, 60_000)
    pending = %{pid: audit, ref: ref, timer: timer, token: token, keys: [],
      continuation: {:info, {:finished, token, nil, {:output, "{}"}}}}
    :sys.replace_state(ModWorkshop, &Map.put(&1, :pending_audit, pending))
    state = event("cancel", %{"project" => state.run.project})
    assert state.pending_audit == nil
    refute Process.alive?(audit)
    assert Process.read_timer(timer) == false
    send(ModWorkshop, {:audit_finished, ref, :ok})
    assert hd(:sys.get_state(ModWorkshop).data["projects"])["status"] == "interrupted"
  end

  test "stopping a runner also terminates its CLI process" do
    parent = self()
    pid = spawn(fn ->
      port = Port.open({:spawn_executable, "/bin/sleep"}, [{:args, ["60"]}, :exit_status])
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      send(parent, {:cli, os_pid})
      receive do :never -> :ok end
    end)
    assert_receive {:cli, os_pid}
    BowserBrain.ModSmith.stop_runner(pid)
    Process.sleep(30)
    {_, status} = System.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    assert status != 0
  end

  test "CLI errors with successful exit codes are failures and redact raw details" do
    events = [%{"type" => "result", "is_error" => true, "result" => "401 invalid API key secret-value"}]
    assert {"saved", {:error, message}} = BowserBrain.ModSmith.completion(0, events, [], "saved")
    assert message =~ "Authentication failed"
    refute message =~ "secret-value"
    assert {nil, {:error, message}} = BowserBrain.ModSmith.completion(1, [], ["429 rate limit"], nil)
    assert message =~ "rate limited"
  end

  defp event(action, values) do
    send(
      ModWorkshop,
      {:browser_event, Map.merge(%{"event" => "modsmith", "action" => action}, values)}
    )

    :sys.get_state(ModWorkshop)
  end

  defp complete(pid, files, extra \\ %{}) do
    envelope =
      Map.merge(
        %{
          "files" => files,
          "name" => "Reading mode",
          "summary" => "Made the text larger",
          "notes" => "",
          "checks" => ["Checked computed font size"]
        },
        extra
      )

    send(pid, {:result, {"session-1", {:output, JSON.encode!(envelope)}}})
    await(fn -> :sys.get_state(ModWorkshop).run == nil end)
    :sys.get_state(ModWorkshop)
  end

  defp await(fun, attempts \\ 200)
  defp await(_, 0), do: flunk("workflow did not settle")

  defp await(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          await(fun, attempts - 1)
        )
  end

  defp file(content), do: %{"path" => "sites/example.com/reading.css", "content" => content}

test "Work drafts and project lists cannot take over Default mods" do
  session = :sys.get_state(BowserBrain.Session)
  :sys.replace_state(BowserBrain.Session, &Map.put(&1, :profiles, %{7 => "work"}))
  on_exit(fn -> :sys.replace_state(BowserBrain.Session, fn _ -> session end) end)
  ModRevision.write("mods/owned.ex", "defmodule DefaultOwned do use BowserBrain.Mod end")
  event("submit", %{"text" => "Work shell", "scope" => "browser"})
  assert_receive {:runner, _pid, token, _, nil, nil}, 1000
  assert %{ok: false} = ModWorkshop.tool(token, "put_mod", %{"name" => "owned.ex", "content" => "defmodule DefaultOwned do use BowserBrain.Mod end"})
  assert BowserBrain.ModScope.file_profile(ModRevision.absolute("mods/owned.ex")) == "default"
  state = :sys.get_state(ModWorkshop)
  [work] = state.data["projects"]
  assert work["profile"] == "work"
  default = ModWorkshop.new_project("Default only", "browser", "https://example.com", nil)
  state = put_in(state.data["projects"], [default, work])
  assert Enum.map(ModWorkshop.snapshot(state, "main").projects, & &1["id"]) == [work["id"]]
  assert ModWorkshop.snapshot(state, "main").selected == work["id"]
end

  test "source and Store tools enforce profile ownership on every operation", %{root: root} do
    session = :sys.get_state(BowserBrain.Session)
    :sys.replace_state(BowserBrain.Session, &Map.put(&1, :profiles, %{7 => "default"}))
    on_exit(fn -> :sys.replace_state(BowserBrain.Session, fn _ -> session end) end)
    suffix = Base.encode16(:crypto.strong_rand_bytes(8))
    mine = "DefaultStore" <> suffix
    foreign = "WorkStore" <> suffix
    fake = "QuotedStore" <> suffix
    for {file, profile, name} <- [{"mine.ex.off", "default", mine}, {"foreign.ex", "work", foreign}] do
      ModRevision.write("mods/" <> file,
        "# bowser-profile: #{profile}\ndefmodule #{name} do use BowserBrain.Mod end")
    end
    ModRevision.write("mods/quote.ex", "quote do defmodule #{fake} do use BowserBrain.Mod end end")
    ModRevision.write("sites/example.com/private.css.off", "/* bowser-profile: work */\nbody {}")
    BowserBrain.Store.put(foreign, "secret", "original")
    on_exit(fn ->
      BowserBrain.Store.clear(mine)
      BowserBrain.Store.clear(foreign)
    end)
    event("submit", %{"text" => "Fix my mod", "scope" => "browser"})
    assert_receive {:runner, _pid, token, _, nil, nil}, 1000
    assert %{ok: true, content: source} = ModWorkshop.tool(token, "read_mod", %{"path" => "mods/mine.ex"})
    assert source =~ mine
    refute source =~ "bowser-profile:"
    assert %{ok: false, error: collision} = ModWorkshop.tool(token, "put_mod", %{"name" => "takeover.ex", "content" => "defmodule #{foreign} do use BowserBrain.Mod end"})
    assert collision =~ "Module name already in use"
    for path <- ["mods/foreign.ex", "sites/example.com/private.css", "mods/missing.ex", "../settings.json", nil] do
      assert %{ok: false} = ModWorkshop.tool(token, "read_mod", %{"path" => path})
    end
    for name <- [foreign, "Elixir." <> foreign, fake, "Unknown", "../" <> mine, nil] do
      assert %{ok: false} = ModWorkshop.tool(token, "store_get", %{"mod" => name})
      assert %{ok: false} = ModWorkshop.tool(token, "mod_diagnostics", %{"mod" => name})
      assert %{ok: false} = ModWorkshop.tool(token, "store_put", %{"mod" => name, "key" => "secret", "value" => "changed"})
    end
    BowserBrain.ModLog.stage(mine, :applied, 0)
    assert %{ok: true, receipts: [%{stage: :applied, count: 0}]} = ModWorkshop.tool(token, "mod_diagnostics", %{"mod" => mine})
    assert BowserBrain.Store.get(foreign, "secret") == "original"
    assert %{ok: true} = ModWorkshop.tool(token, "store_put", %{"mod" => "Elixir." <> mine, "key" => "draft", "value" => "mine"})
    assert %{ok: true, value: "mine"} = ModWorkshop.tool(token, "store_get", %{"mod" => mine, "key" => "draft"})

    # Source ownership is rechecked rather than cached from list_mods or a
    # previous successful request. Conflicting profiles cannot share Store.
    ModRevision.write("mods/conflict.ex", "# bowser-profile: work\ndefmodule #{mine} do use BowserBrain.Mod end")
    assert %{ok: false} = ModWorkshop.tool(token, "store_get", %{"mod" => mine})
    File.rm!(Path.join(root, "mods/conflict.ex"))
    File.rename!(Path.join(root, "mods/mine.ex.off"), Path.join(root, "outside.ex"))
    File.ln_s!(Path.join(root, "outside.ex"), Path.join(root, "mods/mine.ex.off"))
    assert %{ok: false} = ModWorkshop.tool(token, "read_mod", %{"path" => "mods/mine.ex"})
    assert %{ok: false} = ModWorkshop.tool(token, "store_get", %{"mod" => mine})
  end

  test "site drafts reject inert host declarations before any file write or compilation", %{root: root} do
    event("submit", %{"text" => "Change this site", "scope" => "site"})
    assert_receive {:runner, _pid, token, _, nil, nil}, 1000
    marker = Path.join(root, "must-not-execute")
    side_effect = "File.write!(#{inspect(marker)}, \"executed\")\n"
    sources = [
      "quote do defmodule QuotedHost do use BowserBrain.Mod, host: \"example.com\" end end",
      "defmodule QuotedBody do quote do use BowserBrain.Mod, host: \"example.com\" end end",
      "defmodule FunctionBody do def unused do use BowserBrain.Mod, host: \"example.com\" end end",
      "defmodule WrongHost do use BowserBrain.Mod, host: \"other.example\" end\nquote do use BowserBrain.Mod, host: \"example.com\" end",
      "defmodule MissingHost do use BowserBrain.Mod end\nquote do use BowserBrain.Mod, host: \"example.com\" end",
      "defmodule HelperOnly do def hello, do: :ok end",
      "defmodule GoodHost do use BowserBrain.Mod, host: \"example.com\" end\ndefmodule ForeignHost do use BowserBrain.Mod, host: \"other.example\" end"
    ]
    for source <- sources do
      assert %{ok: false} = ModWorkshop.tool(token, "put_mod", %{"name" => "invalid_host.ex", "content" => side_effect <> source})
      refute File.exists?(marker)
      assert ModRevision.read("mods/invalid_host.ex") == nil
    end
    [project] = :sys.get_state(ModWorkshop).data["projects"]
    assert hd(project["revisions"])["files"] == %{}

    assert %{ok: true} = ModWorkshop.tool(token, "put_mod", %{
      "name" => "valid_host.ex",
      "content" => "defmodule GenuineScopedDraft do use BowserBrain.Mod, host: \"example.com\" end"
    })
    assert ModRevision.read("mods/valid_host.ex") =~ "GenuineScopedDraft"
  end

  test "direct agent continues after audited mod installation", %{root: root} do
    File.write!(Path.join(root, "registration.json"), JSON.encode!(%{"telemetryToken" => "fixture-token"}))
    previous = Application.get_env(:bowser_brain, :ai_transport)
    on_exit(fn ->
      if previous, do: Application.put_env(:bowser_brain, :ai_transport, previous),
        else: Application.delete_env(:bowser_brain, :ai_transport)
    end)
    event("submit", %{"text" => "Create fixture", "scope" => "site"})
    assert_receive {:runner, _pid, token, _, nil, nil}, 1000
    Process.put(:modsmith_run, token)
    Application.put_env(:bowser_brain, :ai_transport, fn _, _, body, _ ->
      if length(body["input"]) == 1 do
        args = %{"name" => "direct_fixture.ex", "content" => "defmodule DirectInstallFixture do use BowserBrain.Mod, host: \"example.com\" end"}
        {:ok, %{"output" => [%{"type" => "function_call", "name" => "put_mod", "call_id" => "one", "arguments" => JSON.encode!(args)}]}}
      else
        result = body["input"] |> List.last() |> Map.fetch!("output") |> JSON.decode!()
        assert result["ok"]
        {:ok, %{"output" => [%{"type" => "message", "content" => [%{"type" => "output_text", "text" => "finished"}]}]}}
      end
    end)
    assert {nil, {:output, "finished"}} = BowserBrain.DirectAgent.run("fixture", nil, fn _ -> :ok end, nil)
  end

  test "direct agent uses a final tool-free summary when its tool budget ends", %{root: root} do
    File.write!(Path.join(root, "registration.json"), JSON.encode!(%{"telemetryToken" => "fixture-token"}))
    previous = Application.get_env(:bowser_brain, :ai_transport)
    on_exit(fn ->
      if previous, do: Application.put_env(:bowser_brain, :ai_transport, previous),
        else: Application.delete_env(:bowser_brain, :ai_transport)
    end)
    Application.put_env(:bowser_brain, :ai_transport, fn _, _, body, _ ->
      if body["tools"] == [] do
        assert length(body["input"]) == 65
        {:ok, %{"output" => [%{"type" => "message", "content" => [%{"type" => "output_text", "text" => "bounded summary"}]}]}}
      else
        {:ok, %{"output" => [%{"type" => "function_call", "name" => "list_tabs", "call_id" => "call-#{length(body["input"])}", "arguments" => "{}"}]}}
      end
    end)
    assert {nil, {:output, "bounded summary"}} = BowserBrain.DirectAgent.run("fixture", nil, fn _ -> :ok end, nil)
  end

  test "direct agent continues past twelve rounds and resumes a partial result", %{root: root} do
    File.write!(Path.join(root, "registration.json"), JSON.encode!(%{"telemetryToken" => "fixture-token"}))
    previous = Application.get_env(:bowser_brain, :ai_transport)
    on_exit(fn ->
      if previous, do: Application.put_env(:bowser_brain, :ai_transport, previous),
        else: Application.delete_env(:bowser_brain, :ai_transport)
    end)
    Process.put(:continuation_test_calls, 0)
    Application.put_env(:bowser_brain, :ai_transport, fn _, _, body, _ ->
      n = Process.get(:continuation_test_calls)
      Process.put(:continuation_test_calls, n + 1)
      assert body["tools"] != []
      output = cond do
        n < 14 -> [%{"type" => "function_call", "name" => "list_tabs", "call_id" => "call-#{n}", "arguments" => "{}"}]
        n == 14 -> [%{"type" => "message", "content" => [%{"type" => "output_text", "text" => JSON.encode!(%{status: "partial", summary: "One check remains"})}]}]
        true ->
          assert List.last(body["input"])["role"] == "user"
          [%{"type" => "message", "content" => [%{"type" => "output_text", "text" => "finished"}]}]
      end
      {:ok, %{"output" => output}}
    end)
    assert {nil, {:output, "finished"}} = BowserBrain.DirectAgent.run("fixture", nil, fn _ -> :ok end, nil)
    assert Process.get(:continuation_test_calls) == 16
  end

  test "failed verification gets repair attempts but concrete external blockers stop", %{root: root} do
    File.write!(Path.join(root, "registration.json"), JSON.encode!(%{"telemetryToken" => "fixture-token"}))
    previous = Application.get_env(:bowser_brain, :ai_transport)
    on_exit(fn ->
      if previous, do: Application.put_env(:bowser_brain, :ai_transport, previous), else: Application.delete_env(:bowser_brain, :ai_transport)
    end)
    for status <- ["needs_help", "failed", "partial"] do
      Process.put(:repair_calls, 0)
      Application.put_env(:bowser_brain, :ai_transport, fn _, _, body, _ ->
        n = Process.get(:repair_calls)
        Process.put(:repair_calls, n + 1)
        envelope = if n == 0, do: %{status: status, notes: "No decisions recorded"}, else: %{status: "active", checks: ["All items evaluated and kept"]}
        assert body["tools"] != []
        {:ok, %{"output" => [%{"type" => "message", "content" => [%{"type" => "output_text", "text" => JSON.encode!(envelope)}]}]}}
      end)
      assert {nil, {:output, result}} = BowserBrain.DirectAgent.run("fixture", nil, fn _ -> :ok end, nil)
      assert JSON.decode!(result)["status"] == "active"
      assert Process.get(:repair_calls) == 2
    end
    Process.put(:repair_calls, 0)
    Application.put_env(:bowser_brain, :ai_transport, fn _, _, _, _ ->
      Process.put(:repair_calls, Process.get(:repair_calls) + 1)
      envelope = %{status: "needs_help", blocker: %{kind: "permission", detail: "The website requires the owner to sign in"}}
      {:ok, %{"output" => [%{"type" => "message", "content" => [%{"type" => "output_text", "text" => JSON.encode!(envelope)}]}]}}
    end)
    assert {nil, {:output, _}} = BowserBrain.DirectAgent.run("fixture", nil, fn _ -> :ok end, nil)
    assert Process.get(:repair_calls) == 1
  end

  test "repeated needs_help without tool progress is bounded", %{root: root} do
    File.write!(Path.join(root, "registration.json"), JSON.encode!(%{"telemetryToken" => "fixture-token"}))
    previous = Application.get_env(:bowser_brain, :ai_transport)
    on_exit(fn ->
      if previous, do: Application.put_env(:bowser_brain, :ai_transport, previous), else: Application.delete_env(:bowser_brain, :ai_transport)
    end)
    Process.put(:repair_calls, 0)
    Application.put_env(:bowser_brain, :ai_transport, fn _, _, body, _ ->
      Process.put(:repair_calls, Process.get(:repair_calls) + 1)
      status = if body["tools"] == [], do: "failed", else: "needs_help"
      {:ok, %{"output" => [%{"type" => "message", "content" => [%{"type" => "output_text", "text" => JSON.encode!(%{status: status})}]}]}}
    end)
    assert {nil, {:output, result}} = BowserBrain.DirectAgent.run("fixture", nil, fn _ -> :ok end, nil)
    assert JSON.decode!(result)["status"] == "failed"
    assert Process.get(:repair_calls) == 4
  end

  test "expired working budget goes directly to summary without executing tools", %{root: root} do
    File.write!(Path.join(root, "registration.json"), JSON.encode!(%{"telemetryToken" => "fixture-token"}))
    previous = Application.get_env(:bowser_brain, :ai_transport)
    previous_budget = Application.get_env(:bowser_brain, :modsmith_work_ms)
    Application.put_env(:bowser_brain, :modsmith_work_ms, 0)
    on_exit(fn ->
      if previous, do: Application.put_env(:bowser_brain, :ai_transport, previous), else: Application.delete_env(:bowser_brain, :ai_transport)
      if previous_budget, do: Application.put_env(:bowser_brain, :modsmith_work_ms, previous_budget), else: Application.delete_env(:bowser_brain, :modsmith_work_ms)
    end)
    Application.put_env(:bowser_brain, :ai_transport, fn _, _, body, _ ->
      assert body["tools"] == []
      assert length(body["input"]) == 1
      {:ok, %{"output" => [%{"type" => "message", "content" => [%{"type" => "output_text", "text" => "budget summary"}]}]}}
    end)
    assert {nil, {:output, "budget summary"}} = BowserBrain.DirectAgent.run("fixture", nil, fn _ -> :ok end, nil)
  end

  test "advertised Jev tool reaches authenticated server transport", %{root: root} do
    previous = Application.get_env(:bowser_brain, :ai_transport)
    on_exit(fn ->
      if previous, do: Application.put_env(:bowser_brain, :ai_transport, previous),
        else: Application.delete_env(:bowser_brain, :ai_transport)
    end)
    File.write!(Path.join(root, "registration.json"), JSON.encode!(%{"telemetryToken" => "fixture-token"}))
    owner = self()
    Application.put_env(:bowser_brain, :ai_transport, fn url, token, body, _ ->
      send(owner, {:jev_request, url, token, body})
      {:ok, %{"answers" => %{"filler" => %{"type" => "noul", "noul" => 0.99}}}}
    end)
    event("submit", %{"text" => "Filter suspicious listings", "scope" => "site"})
    assert_receive {:runner, _pid, token, _, nil, nil}, 1000
    args = %{"state" => "Quantum miracle headphones", "questions" => %{"filler" => %{"type" => "noul", "instructions" => "Is this an implausible claim?"}}}
    assert %{ok: true, result: %{"answers" => _}} = ModWorkshop.tool(token, "jev", args)
    assert_receive {:jev_request, url, "fixture-token", ^args}
    assert URI.parse(url).path == "/v1/ai/jev"
    assert %{ok: false} = ModWorkshop.tool("invalid-run", "jev", args)
  end

  @tag :live_audit
  @tag timeout: 120_000
  test "live hosted audit installs a runtime Jev draft through put_mod", %{root: root} do
    if System.get_env("BOWSER_LIVE_AUDIT_TEST") != "1", do: flunk("Live audit test must be explicitly enabled")
    receipt = System.fetch_env!("BOWSER_AUDIT_RECEIPT")
    File.cp!(receipt, Path.join(root, "registration.json"))
    File.chmod!(Path.join(root, "registration.json"), 0o600)
    settings = Application.get_env(:bowser_brain, :settings_path)
    endpoint = System.get_env("BOWSER_API_ENDPOINT")
    Application.put_env(:bowser_brain, :settings_path, Path.join(root, "settings.json"))
    System.put_env("BOWSER_API_ENDPOINT", "http://127.0.0.1:8080")
    Application.delete_env(:bowser_brain, :modsmith_auditor)
    on_exit(fn ->
      Application.put_env(:bowser_brain, :settings_path, settings)
      if endpoint, do: System.put_env("BOWSER_API_ENDPOINT", endpoint), else: System.delete_env("BOWSER_API_ENDPOINT")
    end)
    event("submit", %{"text" => "Build a mod helper that uses Bowser Jev to classify supplied listing text for implausible claims", "scope" => "site"})
    assert_receive {:runner, _pid, token, _, nil, nil}, 1000
    source = ~S"""
    defmodule LiveAuditedJevFixture do
      use BowserBrain.Mod, host: "example.com"
      def classify(listing) do
        BowserBrain.Jev.evaluate(%{"listing" => listing}, %{
          "implausible" => %{"type" => "noul", "instructions" => "Does the listing make implausible product claims?"}
        })
      end
    end
    """
    result = ModWorkshop.tool(token, "put_mod", %{"name" => "live_jev_fixture.ex", "content" => source})
    assert %{ok: true, runtime: %{ok: true}} = result
    assert File.regular?(Path.join(root, "mods/live_jev_fixture.ex"))
    assert {:ok, %{"answers" => %{"implausible" => %{"noul" => score}}}} =
      apply(LiveAuditedJevFixture, :classify, ["Quantum headphones raise IQ by 900 percent and eliminate the need for sleep"])
    assert score > 0.8
  end

  test "independent audit precedes writes and compilation and reviews exact tagged source", %{root: root} do
    owner = self()
    Application.put_env(:bowser_brain, :modsmith_auditor, fn prompt ->
      send(owner, {:audit, self(), JSON.decode!(prompt)})
      receive do
        :approve ->
          data = JSON.decode!(prompt)
          {:ok, JSON.encode!(%{verdict: "allow", reason: "Approved fixture", sha256: data["sha256"], nonce: data["nonce"]})}
      end
    end)
    event("submit", %{"text" => "A native control", "scope" => "browser"})
    assert_receive {:runner, _pid, token, _, nil, nil}, 1000
    marker = Path.join(root, "compiled")
    source = "File.write!(#{inspect(marker)}, \"compiled\")\ndefmodule AuditedFixture do use BowserBrain.Mod end"
    task = Task.async(fn -> ModWorkshop.tool(token, "put_mod", %{"name" => "audited.ex", "content" => source}) end)
    assert_receive {:audit, auditor, data}, 1000
    assert data["source"] == BowserBrain.ModScope.tag(source, "default")
    assert data["request"] == "A native control"
    refute File.exists?(marker)
    assert ModRevision.read("mods/audited.ex") == nil
    # The native workspace remains responsive while the audit is pending.
    assert :sys.get_state(ModWorkshop).pending_audit != nil
    send(auditor, :approve)
    assert %{ok: true} = Task.await(task, 3000)
    assert File.read!(marker) == "compiled"
    assert ModRevision.read("mods/audited.ex") == data["source"]
  end

  test "refinement audits include owner history and stable original plus latest draft sources" do
    owner = self()
    Application.put_env(:bowser_brain, :modsmith_auditor, fn prompt ->
      data = JSON.decode!(prompt)
      send(owner, {:review_context, data})
      decision = if String.contains?(data["source"], "reject_change"), do: "reject", else: "allow"
      {:ok, JSON.encode!(%{verdict: decision, reason: "Fixture", sha256: data["sha256"], nonce: data["nonce"]})}
    end)
    path = "mods/context.ex"
    source = "defmodule AuditContextFixture do use BowserBrain.Mod end"
    tagged = BowserBrain.ModScope.tag(source, "default")
    event("submit", %{"text" => "Create private notes", "scope" => "browser"})
    assert_receive {:runner, pid, _, _, _, _}, 1000
    state = complete(pid, [%{"path" => path, "content" => source}])
    assert_receive {:review_context, creation}
    assert creation["prior_requests"] == []
    assert creation["previous_source"] == nil
    assert creation["revision_start_source"] == nil
    [project] = state.data["projects"]
    id = project["id"]
    initial_status = hd(project["revisions"])["status"]

    event("submit", %{"project" => id, "text" => "Make the editor darker"})
    assert_receive {:runner, pid, token, _, _, _}, 1000
    draft = source <> "\n# dark palette"
    assert %{ok: true} = ModWorkshop.tool(token, "put_mod", %{"name" => "context.ex", "content" => draft})
    assert_receive {:review_context, refinement}
    assert refinement["request"] == "Make the editor darker"
    assert refinement["prior_requests"] == [%{"request" => "Create private notes", "status" => initial_status}]
    assert refinement["previous_source"] == tagged
    assert refinement["revision_start_source"] == tagged

    assert %{ok: false} = ModWorkshop.tool(token, "put_mod", %{"name" => "context.ex", "content" => draft <> "\n# reject_change"})
    assert_receive {:review_context, rejected}
    assert rejected["previous_source"] == refinement["source"]
    assert rejected["revision_start_source"] == tagged
    assert ModRevision.read(path) == refinement["source"]
    complete(pid, [%{"path" => path, "content" => draft}])
    event("undo", %{"project" => id})
    assert ModRevision.read(path) == tagged

    event("submit", %{"project" => id, "text" => "Use a lighter editor"})
    assert_receive {:runner, pid, _, _, _, _}, 1000
    complete(pid, [%{"path" => path, "content" => source <> "\n# light palette"}])
    assert_receive {:review_context, after_undo}
    assert after_undo["prior_requests"] == [
      %{"request" => "Create private notes", "status" => initial_status},
      %{"request" => "Make the editor darker", "status" => "undone"}
    ]
    assert after_undo["previous_source"] == tagged
    assert after_undo["revision_start_source"] == tagged
  end

  test "editing an existing disabled mod supplies its actual source without invented history" do
    source = "defmodule ExistingAuditFixture do use BowserBrain.Mod end"
    ModRevision.write("mods/existing_audit.ex.off", source)
    owner = self()
    Application.put_env(:bowser_brain, :modsmith_auditor, fn prompt ->
      send(owner, {:existing_context, JSON.decode!(prompt)})
      {:error, :unavailable}
    end)
    state = event("edit_existing", %{"path" => "mods/existing_audit.ex"})
    [project] = state.data["projects"]
    event("submit", %{"project" => project["id"], "text" => "Adjust spacing"})
    assert_receive {:runner, pid, _, _, _, _}, 1000
    complete(pid, [%{"path" => "mods/existing_audit.ex", "content" => source <> "\n# spacing"}])
    assert_receive {:existing_context, context}
    assert context["path"] == "mods/existing_audit.ex.off"
    assert context["prior_requests"] == []
    assert context["previous_source"] == source
    assert context["revision_start_source"] == source
    assert ModRevision.read("mods/existing_audit.ex.off") == source
  end

  test "rejected and unavailable audits leave draft and final batches inert", %{root: root} do
    Application.put_env(:bowser_brain, :modsmith_auditor, fn _ -> {:error, :unavailable} end)
    event("submit", %{"text" => "A native control", "scope" => "browser"})
    assert_receive {:runner, pid, token, _, nil, nil}, 1000
    marker = Path.join(root, "forbidden")
    source = "File.write!(#{inspect(marker)}, \"bad\")\ndefmodule RejectedFixture do use BowserBrain.Mod end"
    assert %{ok: false} = ModWorkshop.tool(token, "put_mod", %{"name" => "rejected.ex", "content" => source})
    refute File.exists?(marker)
    assert ModRevision.read("mods/rejected.ex") == nil
    complete(pid, [%{"path" => "sites/example.com/first.css", "content" => "body {}"}, %{"path" => "mods/rejected.ex", "content" => source}])
    refute File.exists?(marker)
    assert ModRevision.read("mods/rejected.ex") == nil
    assert ModRevision.read("sites/example.com/first.css") == nil
    [project] = :sys.get_state(ModWorkshop).data["projects"]
    assert project["status"] == "failed"
    assert hd(project["revisions"])["files"] == %{}
  end

  test "audit timeout and stale-run approval cannot install a draft" do
    owner = self()
    Application.put_env(:bowser_brain, :modsmith_auditor, fn prompt ->
      send(owner, {:waiting_audit, self(), JSON.decode!(prompt)})
      receive do
        :approve ->
          data = JSON.decode!(prompt)
          {:ok, JSON.encode!(%{verdict: "allow", reason: "Fixture", sha256: data["sha256"], nonce: data["nonce"]})}
      end
    end)
    event("submit", %{"text" => "A native control", "scope" => "browser"})
    assert_receive {:runner, _pid, token, _, nil, nil}, 1000
    args = %{"name" => "waiting.ex", "content" => "defmodule WaitingAuditFixture do use BowserBrain.Mod end"}
    task = Task.async(fn -> ModWorkshop.tool(token, "put_mod", args) end)
    assert_receive {:waiting_audit, auditor, _}, 1000
    pending = :sys.get_state(ModWorkshop).pending_audit
    send(ModWorkshop, {:audit_finished, pending.ref, {:error, "Security audit timed out"}})
    assert %{ok: false} = Task.await(task, 3000)
    refute Process.alive?(auditor)
    assert ModRevision.read("mods/waiting.ex") == nil

    task = Task.async(fn -> ModWorkshop.tool(token, "put_mod", args) end)
    assert_receive {:waiting_audit, auditor, _}, 1000
    :sys.replace_state(ModWorkshop, fn state -> %{state | urls: %{7 => "https://other.example"}} end)
    send(auditor, :approve)
    assert %{ok: false} = Task.await(task, 3000)
    assert ModRevision.read("mods/waiting.ex") == nil
  end

  test "changing audited source requires a fresh review and preserves the approved file" do
    owner = self()
    Application.put_env(:bowser_brain, :modsmith_auditor, fn prompt ->
      data = JSON.decode!(prompt)
      send(owner, {:reviewed_source, data["source"]})
      decision = if String.contains?(data["source"], "reject_this_change"), do: "reject", else: "allow"
      {:ok, JSON.encode!(%{verdict: decision, reason: "Fixture", sha256: data["sha256"], nonce: data["nonce"]})}
    end)
    event("submit", %{"text" => "A native control", "scope" => "browser"})
    assert_receive {:runner, _pid, token, _, nil, nil}, 1000
    source = "defmodule FreshAuditFixture do use BowserBrain.Mod end"
    assert %{ok: true} = ModWorkshop.tool(token, "put_mod", %{"name" => "fresh.ex", "content" => source})
    assert_receive {:reviewed_source, first}
    assert %{ok: false} = ModWorkshop.tool(token, "put_mod", %{"name" => "fresh.ex", "content" => source <> "\n# reject_this_change"})
    assert_receive {:reviewed_source, second}
    refute first == second
    assert ModRevision.read("mods/fresh.ex") == first
    assert :sys.get_state(ModWorkshop).run.audit_failures != %{}
    assert %{ok: true} = ModWorkshop.tool(token, "put_mod", %{"name" => "fresh.ex", "content" => source <> "\n# repaired"})
    assert :sys.get_state(ModWorkshop).run.audit_failures == %{}
  end

  test "nil content and payload tool names cannot bypass the Elixir gate" do
    owner = self()
    Application.put_env(:bowser_brain, :modsmith_auditor, fn _ -> send(owner, :unexpected_audit); {:error, :unavailable} end)
    event("submit", %{"text" => "A native control", "scope" => "browser"})
    assert_receive {:runner, pid, token, _, nil, nil}, 1000
    assert %{ok: false} = ModWorkshop.tool(token, "put_mod", %{"name" => "nil.ex", "content" => nil})
    for args <- [%{"name" => "payload.ex", "content" => "defmodule PayloadBypass do use BowserBrain.Mod end"},
                 %{"name" => "../../mods/bypass.ex", "content" => "defmodule PayloadBypass do use BowserBrain.Mod end"},
                 %{"name" => "valid.css", "content" => nil}] do
      assert %{ok: false} = ModWorkshop.tool(token, "put_payload", args)
    end
    assert Process.alive?(Process.whereis(ModWorkshop))
    refute_received :unexpected_audit
    complete(pid, [%{"path" => "mods/nil.ex", "content" => nil}])
    assert ModRevision.read("mods/nil.ex") == nil
    assert ModRevision.read("mods/bypass.ex") == nil
    [project] = :sys.get_state(ModWorkshop).data["projects"]
    assert project["status"] == "failed"
  end

  test "Elixir drafts share final revision history and Undo removes the installed file" do
    event("submit", %{"text" => "AOL shell", "scope" => "browser"})
    assert_receive {:runner, pid, token, prompt, nil, nil}, 1000
    assert prompt =~ "put_mod"
    content = "defmodule DraftSkin do\n use BowserBrain.Mod\nend"
    assert %{ok: true, installed: "mods/draft_skin.ex"} =
      ModWorkshop.tool(token, "put_mod", %{"name" => "draft_skin.ex", "content" => content})
    assert ModRevision.read("mods/draft_skin.ex") == BowserBrain.ModScope.tag(content, "default")
    state = complete(pid, [%{"path" => "mods/draft_skin.ex"}], %{"notes" => "Use the toolbar."})
    assert hd(state.data["projects"])["status"] == "active"
    [project] = state.data["projects"]
    assert hd(project["revisions"])["files"]["mods/draft_skin.ex"]["before"] == nil
    assert %{ok: false} = ModWorkshop.tool(token, "put_mod", %{"name" => "late.ex", "content" => content})
    event("undo", %{"project" => project["id"]})
    assert ModRevision.read("mods/draft_skin.ex") == nil
    for {mod_pid, _} <- Registry.lookup(BowserBrain.ModRegistry, DraftSkin),
      do: DynamicSupervisor.terminate_child(BowserBrain.ModSupervisor, mod_pid)
  end

  for reference <- ["mods/disabled_draft.ex", "mods/disabled_draft.ex.off"] do
    test "final reference #{reference} resolves the disabled draft and preserves Undo" do
      path = "mods/disabled_draft.ex.off"
      original = "defmodule DisabledDraft do use BowserBrain.Mod end"
      ModRevision.write(path, original)
      event("submit", %{"text" => "Refine it", "scope" => "browser"})
      assert_receive {:runner, pid, token, _, _, _}, 1000
      source = original <> "\n# refined"
      assert %{ok: true, runtime: %{status: "disabled"}} =
        ModWorkshop.tool(token, "put_mod", %{"name" => "disabled_draft.ex", "content" => source})
      state = complete(pid, [%{"path" => unquote(reference)}], %{"status" => "needs_help"})
      [project] = state.data["projects"]
      assert project["status"] == "needs_help"
      assert Map.keys(hd(project["revisions"])["files"]) == [path]
      assert ModRevision.read(path) == BowserBrain.ModScope.tag(source, "default")
      assert ModRevision.read("mods/disabled_draft.ex") == nil
      event("undo", %{"project" => project["id"]})
      assert ModRevision.read(path) == original
      assert ModRevision.read("mods/disabled_draft.ex") == nil
    end
  end

  test "disabled draft references cannot adopt an external edit or an older run" do
    path = "sites/example.com/reading.css.off"
    ModRevision.write(path, "original")
    event("submit", %{"text" => "Reading mode"})
    assert_receive {:runner, pid, token, _, _, _}, 1000
    assert %{ok: true} = ModWorkshop.tool(token, "put_payload", %{
      "host" => "example.com", "name" => "reading.css", "content" => "draft"
    })
    ModRevision.write(path, "owner edit")
    [project] = complete(pid, [%{"path" => "sites/example.com/reading.css"}]).data["projects"]
    assert project["status"] == "failed"
    assert ModRevision.read(path) == "owner edit"
    ModRevision.write(path, BowserBrain.ModScope.tag("draft", "default", ".css"))
    event("submit", %{"project" => project["id"], "text" => "Try again"})
    assert_receive {:runner, pid, _, _, _, _}, 1000
    [project] = complete(pid, [%{"path" => "sites/example.com/reading.css"}]).data["projects"]
    assert project["status"] == "failed"
    assert hd(project["revisions"])["files"] == %{}
  end

  test "file validation identifies missing content, malformed paths and actual size limits" do
    for {entry, detail} <- [
      {%{"path" => "mods/missing.ex"}, "unchanged draft from this run"},
      {%{"path" => "mods/nil.ex", "content" => nil}, "requires text content"},
      {%{"path" => "../outside.ex"}, "Invalid mod file path"},
      {%{"path" => nil}, "text path"},
      {"not a file", "object"},
      {%{"path" => "sites/example.com/huge.css", "content" => String.duplicate("x", 200_001)},
       "200001 bytes; the limit is 200000 bytes"}
    ] do
      event("submit", %{"text" => "Reading mode"})
      assert_receive {:runner, pid, _, _, _, _}, 1000
      state = complete(pid, [entry])
      project = Enum.find(state.data["projects"], &(&1["id"] == state.data["selected"]["main"]))
      assert project["status"] == "failed"
      assert project["summary"] =~ detail
      assert hd(project["revisions"])["files"] == %{}
      assert Process.alive?(Process.whereis(ModWorkshop))
    end
  end

  test "draft reports init failures without losing Undo history" do
    event("submit", %{"text" => "AOL shell", "scope" => "browser"})
    assert_receive {:runner, pid, token, _, nil, nil}, 1000
    source = "defmodule BrokenDraftInit do use BowserBrain.Mod; def init_mod(_), do: raise(\"broken init\") end"
    assert %{ok: false, runtime: %{modules: [%{status: "failed", error: error}]}} =
      ModWorkshop.tool(token, "put_mod", %{"name" => "broken_init.ex", "content" => source})
    assert error =~ "broken init"
    complete(pid, [])
  end

  test "SVG assets belong to the current mod and are removed by Undo" do
    event("submit", %{"text" => "AOL logo", "scope" => "browser"})
    assert_receive {:runner, pid, token, _, nil, nil}, 1000
    svg = ~s(<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" fill="red"/></svg>)
    assert %{ok: true, installed: path, image_path: absolute} =
      ModWorkshop.tool(token, "put_asset", %{"name" => "logo.svg", "content" => svg})
    assert File.read!(absolute) == svg
    assert %{ok: false} = ModWorkshop.tool(token, "put_asset", %{"name" => "../logo.svg", "content" => svg})
    assert %{ok: false} = ModWorkshop.tool(token, "put_asset", %{"name" => "bad.svg", "content" => "<svg><script/></svg>"})
    state = complete(pid, [%{"path" => path}])
    [p] = state.data["projects"]
    assert p["status"] == "active"
    event("undo", %{"project" => p["id"]})
    refute File.exists?(absolute)
  end

  test "Elixir draft rejects paths, syntax errors, and unscoped code for site requests" do
    event("submit", %{"text" => "Style this site", "scope" => "site"})
    assert_receive {:runner, pid, token, _, nil, nil}, 1000
    for args <- [
      %{"name" => "../escape.ex", "content" => "defmodule Escape do end"},
      %{"name" => "invalid.ex", "content" => "defmodule Broken do"},
      %{"name" => "unscoped.ex", "content" => "defmodule Unscoped do use BowserBrain.Mod end"}
    ] do
      assert %{ok: false} = ModWorkshop.tool(token, "put_mod", args)
    end
    assert ModRevision.read("mods/unscoped.ex") == nil
    complete(pid, [])
  end

  test "draft and final share an original snapshot; repeated refinements and undo retain identity" do
    ModRevision.write("sites/example.com/reading.css", "original")
    event("submit", %{"text" => "Bigger text", "request_id" => "request-1"})
    assert_receive {:runner, pid, token, _, nil, nil}, 1000

    assert %{ok: true} =
             ModWorkshop.tool(token, "put_payload", %{
               "host" => "example.com",
               "name" => "reading.css",
               "content" => "draft"
             })

    state = complete(pid, [file("first")])
    [p] = state.data["projects"]
    id = p["id"]
    assert state.data["selected"]["main"] == id
    assert hd(p["revisions"])["files"]["sites/example.com/reading.css"]["before"] == "original"
    assert state.accepted == "request-1"

    for content <- ["second", "third"] do
      event("submit", %{"project" => id, "text" => "Even bigger"})
      assert_receive {:runner, pid, _, prompt, "session-1", nil}, 1000
      assert prompt =~ "Reading mode"
      complete(pid, [file(content)])
    end

    state = event("undo", %{"project" => id})
    assert ModRevision.read("sites/example.com/reading.css") == BowserBrain.ModScope.tag("second", "default", ".css")
    assert hd(state.data["projects"])["session"] == nil
    event("undo", %{"project" => id})
    assert ModRevision.read("sites/example.com/reading.css") == BowserBrain.ModScope.tag("first", "default", ".css")
    event("undo", %{"project" => id})
    assert ModRevision.read("sites/example.com/reading.css") == "original"
    assert ModRevision.load()["selected"]["main"] == id
  end

  test "failure retains draft with undo, rejects late tool calls, and surfaces caveats" do
    event("submit", %{"text" => "Reading mode"})
    assert_receive {:runner, pid, token, _, _, _}, 1000

    assert %{ok: true} =
             ModWorkshop.tool(token, "put_payload", %{
               "host" => "example.com",
               "name" => "reading.css",
               "content" => "draft"
             })

    send(pid, {:result, {"failed-session", {:error, "Timed out"}}})
    await(fn -> :sys.get_state(ModWorkshop).run == nil end)
    [p] = :sys.get_state(ModWorkshop).data["projects"]
    assert p["status"] == "failed"
    assert ModRevision.read("sites/example.com/reading.css") == BowserBrain.ModScope.tag("draft", "default", ".css")
    assert %{ok: false} = ModWorkshop.tool(token, "put_payload", %{})
    event("undo", %{"project" => p["id"]})
    assert ModRevision.read("sites/example.com/reading.css") == nil
    event("submit", %{"project" => p["id"], "text" => "Try again"})
    assert_receive {:runner, pid, _, _, _, _}, 1000

    state =
      complete(pid, [file("working")], %{"status" => "partial", "notes" => "Mobile layout is unfinished", "checks" => []})

    [p] = state.data["projects"]
    assert p["status"] == "partial"
    assert List.last(p["turns"])["notes"] == "Mobile layout is unfinished"
    assert List.last(p["turns"])["checks"] == []
  end

  test "tab changes do not retarget a refinement; off-site writes are refused" do
    event("submit", %{"text" => "Reading mode"})
    assert_receive {:runner, pid, token, _, _, _}, 1000

    assert %{ok: false} =
             ModWorkshop.tool(token, "put_payload", %{
               "host" => "other.com",
               "name" => "reading.css",
               "content" => "bad"
             })

    state = complete(pid, [file("one")])
    [p] = state.data["projects"]

    send(
      ModWorkshop,
      {:browser_event, %{"event" => "url_changed", "webview" => 8, "url" => "https://other.com"}}
    )

    send(ModWorkshop, {:browser_event, %{"event" => "tab_activated", "webview" => 8}})
    event("submit", %{"project" => p["id"], "text" => "Refine"})
    assert_receive {:runner, pid, token, prompt, _, _}, 1000
    assert prompt =~ "webview 7"
    assert %{active: 7} = ModWorkshop.tool(token, "list_tabs", %{})
    complete(pid, [file("two")])
  end

  test "undo preflights every file and preserves an external edit" do
    r =
      ModRevision.new_revision("two files")
      |> ModRevision.capture("sites/example.com/a.css", "a")
      |> ModRevision.capture("sites/example.com/b.css", "b")

    ModRevision.write("sites/example.com/a.css", "a")
    ModRevision.write("sites/example.com/b.css", "external")
    assert {:error, _} = ModRevision.restore(r)
    assert ModRevision.read("sites/example.com/a.css") == "a"
    assert ModRevision.read("sites/example.com/b.css") == "external"
  end

  test "toggle is reversible and editing disabled files leaves them disabled" do
    event("submit", %{"text" => "Reading mode"})
    assert_receive {:runner, pid, _, _, _, _}, 1000
    state = complete(pid, [file("one")])
    [p] = state.data["projects"]
    event("toggle", %{"project" => p["id"]})
    assert ModRevision.read("sites/example.com/reading.css") == nil
    assert ModRevision.read("sites/example.com/reading.css.off") == BowserBrain.ModScope.tag("one", "default", ".css")
    event("submit", %{"project" => p["id"], "text" => "Change while disabled"})
    assert_receive {:runner, pid, _, _, _, _}, 1000
    complete(pid, [file("two")])
    assert ModRevision.read("sites/example.com/reading.css") == nil
    assert ModRevision.read("sites/example.com/reading.css.off") == BowserBrain.ModScope.tag("two", "default", ".css")
    event("undo", %{"project" => p["id"]})
    event("undo", %{"project" => p["id"]})
    assert ModRevision.read("sites/example.com/reading.css") == BowserBrain.ModScope.tag("one", "default", ".css")
    assert ModRevision.read("sites/example.com/reading.css.off") == nil
  end

  test "saved app has its own history, revisions and CSS/JS scope" do
    app = %{"id" => "com.foxwiseai.bowser.site.0123456789abcdef", "url" => "https://example.com"}
    event("submit", %{"app" => app, "text" => "App reading mode"})
    assert_receive {:runner, pid, token, _, nil, ^app}, 1000

    assert %{ok: false} = ModWorkshop.tool(token, "put_mod", %{
      "name" => "app.ex", "content" => "defmodule AppDraft do use BowserBrain.Mod end"
    })
    assert ModRevision.read("mods/app.ex") == nil
    for tool <- ["store_get", "store_put", "mod_diagnostics"] do
      assert %{ok: false} = ModWorkshop.tool(token, tool, %{"mod" => "AnyMod", "key" => "secret", "value" => "changed"})
    end
    assert %{ok: false} = ModWorkshop.tool(token, "read_mod", %{"path" => "mods/app.ex", "site_app" => "main"})

    assert %{ok: true} =
             ModWorkshop.tool(token, "put_payload", %{
               "name" => "reading.css",
               "content" => "app draft"
             })

    state = complete(pid, [file("app final")])
    assert ModRevision.read("sites/example.com/reading.css") == nil
    assert ModRevision.read("app-mods/#{app["id"]}/reading.css") == "app final"
    assert ModWorkshop.snapshot(state, "main").projects == []
    [p] = ModWorkshop.snapshot(state, app["id"]).projects
    event("undo", %{"app" => app, "project" => p["id"]})
    assert ModRevision.read("app-mods/#{app["id"]}/reading.css") == nil
  end

  test "interrupted run reopens as recoverable and keeps selected conversation" do
    p = ModWorkshop.new_project("Reading", "site", "https://example.com", nil)

    r =
      ModRevision.new_revision("draft")
      |> ModRevision.capture("sites/example.com/reading.css", "draft")

    p = Map.merge(p, %{"status" => "working", "revisions" => [r]})
    ModRevision.write("sites/example.com/reading.css", "draft")
    data = ModWorkshop.recover(%{"projects" => [p], "selected" => %{"main" => p["id"]}})
    assert hd(data["projects"])["status"] == "interrupted"
    assert data["selected"]["main"] == p["id"]
    assert :ok = ModRevision.restore(hd(hd(data["projects"])["revisions"]))
  end

  test "symlinked mod directories cannot escape the revision root", %{root: root} do
    File.mkdir_p!(Path.join(root, "sites"))
    File.ln_s!(System.tmp_dir!(), Path.join(root, "sites/example.com"))
    assert_raise ArgumentError, fn -> ModRevision.write("sites/example.com/a.css", "bad") end
    refute ModRevision.allowed?("sites/example.com/../../a.css")
  end

  test "pending undo finishes after restart" do
    p = ModWorkshop.new_project("Reading", "site", "https://example.com", nil)

    r =
      ModRevision.new_revision("new file")
      |> ModRevision.capture("sites/example.com/reading.css", "draft")
      |> Map.put("status", "active")

    ModRevision.write("sites/example.com/reading.css", "draft")
    p = Map.merge(p, %{"status" => "active", "revisions" => [r], "pending_undo" => r["id"]})
    data = ModWorkshop.recover(%{"projects" => [p], "selected" => %{"main" => p["id"]}})
    assert ModRevision.read("sites/example.com/reading.css") == nil
    assert hd(hd(data["projects"])["revisions"])["status"] == "undone"
    assert hd(data["projects"])["pending_undo"] == nil

  end

  test "final output cannot overwrite an external edit made after a draft" do
    event("submit", %{"text" => "Reading mode"})
    assert_receive {:runner, pid, token, _, _, _}, 1000

    assert %{ok: true} =
             ModWorkshop.tool(token, "put_payload", %{
               "host" => "example.com",
               "name" => "reading.css",
               "content" => "draft"
             })

    ModRevision.write("sites/example.com/reading.css", "owner edit")
    state = complete(pid, [file("final")])
    assert hd(state.data["projects"])["status"] == "failed"
    assert ModRevision.read("sites/example.com/reading.css") == "owner edit"

    assert hd(hd(state.data["projects"])["revisions"])["files"]["sites/example.com/reading.css"][
             "after"
           ] == BowserBrain.ModScope.tag("draft", "default", ".css")
  end

  test "invalid later file prevents final envelope writes, and saved apps reject modules" do
    event("submit", %{"text" => "Reading mode"})
    assert_receive {:runner, pid, _, _, _, _}, 1000

    state =
      complete(pid, [file("good"), %{"path" => "sites/other.com/bad.css", "content" => "bad"}])

    assert hd(state.data["projects"])["status"] == "failed"
    assert ModRevision.read("sites/example.com/reading.css") == nil
    app = %{"id" => "com.foxwiseai.bowser.site.0123456789abcdef", "url" => "https://example.com"}
    event("submit", %{"app" => app, "text" => "App mod"})
    assert_receive {:runner, pid, _, _, _, _}, 1000
    state = complete(pid, [%{"path" => "mods/global.ex", "content" => "defmodule Demo do end"}])
    assert hd(state.data["projects"])["status"] == "failed"
    assert ModRevision.read("mods/global.ex") == nil
  end
end
