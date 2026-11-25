defmodule BowserBrain.ResourceControllerTest do
  use ExUnit.Case, async: false
  alias BowserBrain.ResourceController, as: Controller
  defp window, do: %{"id" => "w", "profile" => "work", "tabs" => [1, 2, 3], "active" => 2, "panes" => []}

  test "a restarted controller requests a snapshot on the existing native connection" do
    alias BowserBrain.Bridge
    path = Path.join(System.tmp_dir!(), "resource-#{System.unique_integer([:positive])}.sock")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: 4, active: false, ifaddr: {:local, path}])
    {:ok, peer} = :gen_tcp.connect({:local, path}, 0, [:binary, packet: 4, active: false])
    {:ok, sock} = :gen_tcp.accept(listener, 1_000)
    previous = :sys.get_state(Bridge)
    :sys.replace_state(Bridge, &Map.merge(&1, %{sock: sock, engine_hello: %{"resource_protocol" => 1}}))
    on_exit(fn ->
      :sys.replace_state(Bridge, fn _ -> previous end)
      for socket <- [peer, sock, listener], do: :gen_tcp.close(socket)
      File.rm(path)
    end)

    {:ok, controller} = GenServer.start_link(Controller, nil)
    try do
      receive_frame = fn ->
        assert {:ok, data} = :gen_tcp.recv(peer, 0, 1_000)
        JSON.decode!(data)
      end
      assert %{"op" => "resource_snapshot"} = receive_frame.()
      send(controller, {:browser_event, %{"event" => "resources", "snapshot" => %{"version" => 1, "session" => "native"}}})
      assert %{"op" => "resource_policy", "session" => "native"} = receive_frame.()
      assert %{"op" => "resource_ready"} = receive_frame.()
    after
      GenServer.stop(controller)
    end
  end
  test "resource capability is explicit and retained in handoff identity" do
    alias BowserBrain.Bridge
    assert Bridge.resource_identity(%{})["resource_protocol"] == nil
    identity = Bridge.resource_identity(%{"engine_build_id" => "host", "resources" => %{"version" => 1, "windows" => [%{"profile" => "work"}]}})
    assert identity["resource_protocol"] == 1
    refute Map.has_key?(identity, "resources")
    assert Bridge.resource_identity(identity) == identity
    assert Bridge.resource_identity(%{"resources" => %{"version" => 2}})["resource_protocol"] == 2
  end
  test "download policy survives missing source tabs and sanitizes filenames" do
    event = %{"request" => "d", "intent" => %{"action" => "download_destination", "download" => "download-id"},
      "snapshot" => %{"windows" => [], "session" => "native", "next" => 2, "revision" => "rev", "downloads" => [
        %{"id" => "download-id", "profile" => "work", "suggested" => "../../file.bin", "awaiting_destination" => true}]}}
    assert %{command: %{filename: "file.bin", profile: "work", download: "download-id"}} = Controller.decision(event)
    assert Controller.download_filename("..") == "download"
    assert Controller.download_filename("a\u0000b") == "ab"
    assert length(Controller.navigation_rules()) == 2
  end
  test "opening follows current tab and restore append remains explicit" do
    intent = %{"action" => "opened", "tab" => 3, "anchor" => 1, "activate" => false}
    assert %{order: [1, 3, 2], active: 2} = Controller.tab_command(intent, window())
    assert %{order: [1, 2, 3], active: 3} = Controller.tab_command(Map.merge(intent, %{"append" => true, "activate" => true}), window())
  end
  test "closing selects next neighbor, preserves background focus and respects visible panes" do
    assert %{active: 3} = Controller.tab_command(%{"action" => "close", "tab" => 2}, window())
    assert %{active: 2} = Controller.tab_command(%{"action" => "close", "tab" => 3}, window())
    assert %{active: 1} = Controller.tab_command(%{"action" => "close", "tab" => 2}, Map.put(window(), "panes", [1, 2]))
  end
  test "cycles wrap, moves reject foreign tabs, and stale intents are discarded" do
    assert %{active: 1} = Controller.tab_command(%{"action" => "cycle", "tab" => 2, "offset" => 2}, window())
    assert nil == Controller.tab_command(%{"action" => "move", "tab" => 2, "target" => 99}, window())
    event = %{"request" => "r", "intent" => %{"action" => "close", "tab" => 99},
      "snapshot" => %{"windows" => [window()], "session" => "native", "next" => 4, "revision" => "rev"}}
    assert %{discard: true, request: "r", sequence: 4} = Controller.decision(event)
    assert %{command: %{profile: "work", window: "w", revision: "rev", active: 3}} = Controller.decision(put_in(event, ["intent", "tab"], 2))
  end
  test "download popup returns to its opener without stealing a changed selection" do
    close = %{"action" => "close", "tab" => 2, "selecting" => 1}
    assert %{active: 1} = Controller.tab_command(close, window())
    assert %{active: 3} = Controller.tab_command(close, Map.put(window(), "active", 3))
    assert %{active: 3} = Controller.tab_command(Map.put(close, "selecting", 99), window())
    assert %{active: 3} = Controller.tab_command(Map.put(close, "selecting", 2), window())
  end
  test "closing uses live focus history before strip neighbors" do
    focused = Map.put(window(), "focus_history", [2, 99, 1, 3])
    assert %{active: 1} = Controller.tab_command(%{"action" => "close", "tab" => 2}, focused)
    assert %{active: 2} = Controller.tab_command(%{"action" => "close", "tab" => 1}, focused)
    assert %{active: 3} = Controller.tab_command(%{"action" => "close", "tab" => 2, "selecting" => 3}, focused)
    assert %{active: 3} = Controller.tab_command(%{"action" => "close", "tab" => 2}, Map.put(focused, "panes", [2, 3]))
    assert %{active: 3} = Controller.tab_command(%{"action" => "close", "tab" => 2}, Map.put(focused, "focus_history", [2, 99]))
  end
end
