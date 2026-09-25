defmodule BowserBrain.ModDiagnosticsTest do
  use ExUnit.Case, async: false
  alias BowserBrain.{ModLog, Jev}

  defmodule Fixture do
    use BowserBrain.Mod
    def handle_event(%{"event" => "page", "payload" => "error"}, _), do: raise("fixture")
    def handle_event(_, state), do: state
  end

  test "scoped callbacks record delivery and return, without copying payloads" do
    event = %{"event" => "page", "payload" => "private fixture content"}
    assert {:noreply, %{}} = Fixture.handle_info({:browser_event, event}, %{})
    assert [%{stage: :page_received}, %{stage: :page_handled}] = ModLog.diagnostics(Fixture) |> Enum.take(-2)
    refute inspect(ModLog.diagnostics(Fixture)) =~ "private fixture"
    assert_raise RuntimeError, fn -> Fixture.handle_info({:browser_event, %{event | "payload" => "error"}}, %{}) end
    assert %{stage: :page_error} = List.last(ModLog.diagnostics(Fixture))
  end

  test "zero applied is recorded and unknown errors cannot leak bodies" do
    assert :ok = ModLog.stage("ZeroFixture", :applied, 0, webview: 9)
    assert :ok = ModLog.stage("ZeroFixture", :jev_error, 1, error: {:private, "secret"})
    assert [%{stage: :applied, count: 0, webview: 9}, %{error: :other}] = ModLog.diagnostics("ZeroFixture")
    assert {:error, :invalid_stage} = ModLog.stage("ZeroFixture", :arbitrary, 1)
    assert {:error, :invalid_stage} = ModLog.stage("ZeroFixture", :applied, -1)
  end

  test "receipts are bounded and ordered" do
    for n <- 1..1100, do: ModLog.stage("RingFixture", :applied, n)
    entries = ModLog.diagnostics("RingFixture")
    assert length(entries) == 100
    assert hd(entries).count == 1001
    assert List.last(entries).count == 1100
    assert length(:sys.get_state(ModLog).diagnostics) == 1000
  end

  test "all-keep Jev replies are successful evaluations and timeouts retain their cause" do
    root = Path.join(System.tmp_dir!(), "jev-diag-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "registration.json"), JSON.encode!(%{"telemetryToken" => "fixture"}))
    old_home = System.get_env("BOWSER_HOME")
    old_transport = Application.get_env(:bowser_brain, :ai_transport)
    System.put_env("BOWSER_HOME", root)
    on_exit(fn ->
      if old_home, do: System.put_env("BOWSER_HOME", old_home), else: System.delete_env("BOWSER_HOME")
      if old_transport, do: Application.put_env(:bowser_brain, :ai_transport, old_transport), else: Application.delete_env(:bowser_brain, :ai_transport)
      File.rm_rf!(root)
    end)
    Registry.register(BowserBrain.ModRegistry, KeepFixture, nil)
    Application.put_env(:bowser_brain, :ai_transport, fn _, _, _, _ ->
      {:ok, %{"answers" => %{"item" => %{"choice" => "keep", "confidence" => 0.99}}}}
    end)
    assert {:ok, %{"answers" => %{"item" => %{"choice" => "keep"}}}} = Jev.evaluate("fixture", %{"item" => %{}})
    assert %{stage: :jev_ok, count: 1} = List.last(ModLog.diagnostics(KeepFixture))
    Application.put_env(:bowser_brain, :ai_transport, fn _, _, _, _ -> {:error, :timeout} end)
    assert {:error, :timeout} = Jev.evaluate("fixture", %{"item" => %{}})
    assert %{stage: :jev_error, error: :timeout} = List.last(ModLog.diagnostics(KeepFixture))
    Registry.unregister(BowserBrain.ModRegistry, KeepFixture)
  end

  test "registered mod Jev failures are recorded even if callers discard the result" do
    Registry.register(BowserBrain.ModRegistry, JevFixture, nil)
    assert {:error, :request_too_large} = Jev.evaluate("fixture", %{})
    assert [%{stage: :jev_started, count: 0}, %{stage: :jev_error, error: :request_too_large}] = ModLog.diagnostics(JevFixture)
    Registry.unregister(BowserBrain.ModRegistry, JevFixture)
  end
end
