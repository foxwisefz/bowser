defmodule BowserBrain.BridgeFrameTest do
  use ExUnit.Case, async: true
  alias BowserBrain.Bridge

  setup do
    path = Path.join(System.tmp_dir!(), "frame-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: 4, active: false, ifaddr: {:local, path}])

    {:ok, peer} = :gen_tcp.connect({:local, path}, 0, [:binary, packet: :raw, active: false])
    {:ok, sock} = :gen_tcp.accept(listener, 1_000)

    on_exit(fn ->
      for s <- [peer, sock, listener], do: :gen_tcp.close(s)
      File.rm(path)
    end)
    %{sock: sock, peer: peer}
  end

  test "packet4 requests and fragmented replies preserve JSON and correlation", %{sock: sock, peer: peer} do
    tag = make_ref()
    state = %{sock: sock, pending: %{}, next_id: 1}
    {:noreply, state} = Bridge.handle_call({:eval_js, 7, "'hello'", :isolated}, {self(), tag}, state)
    assert {:ok, <<size::32>>} = :gen_tcp.recv(peer, 4, 1_000)
    assert {:ok, bytes} = :gen_tcp.recv(peer, size, 1_000)
    assert %{"op" => "eval_js", "id" => 1, "webview" => 7, "world" => "isolated"} = JSON.decode!(bytes)
    reply = JSON.encode!(%{op: "js_result", id: 1, ok: true, value: "héllo"})
    frame = <<byte_size(reply)::32, reply::binary>>
    for <<byte <- frame>>, do: :gen_tcp.send(peer, <<byte>>)
    assert {:ok, payload} = :gen_tcp.recv(sock, 0, 1_000)
    {:noreply, state} = Bridge.handle_info({:tcp, sock, payload}, state)
    assert_receive {^tag, {:ok, "héllo"}}
    assert state.pending == %{}
    assert {:noreply, ^state} = Bridge.handle_info({:tcp, sock, "invalid JSON"}, state)
  end

  for kind <- [:tcp_closed, :tcp_error] do
    test "#{kind} completes outstanding RPCs and immediately rejects new requests", %{sock: sock} do
      calls = [
        {:eval_js, 1, "0", :isolated}, {:get_cookies, "https://fixture.invalid", "default"},
        {:native_verify, "page_screenshot", %{}}, {:eval_site_js, "fixture", "0"}
      ]
      ready = %{sock: sock, pending: %{}, next_id: 1}
      state = Enum.reduce(calls, ready, fn call, acc ->
        {:noreply, next} = Bridge.handle_call(call, {self(), call}, acc)
        next
      end)

      old = make_ref()
      late = JSON.encode!(%{op: "js_result", id: 1, ok: true, value: "stale"})
      for event <- [{:tcp, old, late}, {:tcp_error, old, :econnreset}, {:tcp_closed, old}, :connect] do
        assert {:noreply, ^state} = Bridge.handle_info(event, state)
      end

      event = if unquote(kind) == :tcp_closed, do: {:tcp_closed, sock}, else: {:tcp_error, sock, :econnreset}
      assert {:noreply, %{pending: pending, sock: nil} = offline} = Bridge.handle_info(event, state)
      assert pending == %{}
      for call <- calls do
        assert_receive {^call, {:error, :not_connected}}
        assert {:reply, {:error, :not_connected}, ^offline} = Bridge.handle_call(call, {self(), call}, offline)
      end
      assert {:noreply, ^offline} = Bridge.handle_info({:tcp_closed, sock}, offline)
    end
  end
end

defmodule BowserBrain.BridgeBackpressureTest do
  use ExUnit.Case, async: false
  alias BowserBrain.Bridge

  test "a connected peer that never reads releases blocked and outstanding callers" do
    previous = System.get_env("BOWSER_RELAY_DIR")
    dir = Path.join(System.tmp_dir!(), "br-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    System.put_env("BOWSER_RELAY_DIR", dir)
    on_exit(fn ->
      if previous, do: System.put_env("BOWSER_RELAY_DIR", previous), else: System.delete_env("BOWSER_RELAY_DIR")
      File.rm_rf!(dir)
    end)

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, Bridge.socket_path()}])
    {:noreply, ready} = Bridge.handle_info(:connect, %{sock: nil, pending: %{}, next_id: 1})
    {:ok, peer} = :gen_tcp.accept(listener, 1_000)
    :ok = :inet.setopts(peer, recbuf: 4_096)
    :ok = :inet.setopts(ready.sock, sndbuf: 4_096)
    {:noreply, pending} = Bridge.handle_call({:eval_site_js, "fixture", "0"}, {self(), :first}, ready)

    large = {:eval_js, 1, String.duplicate("x", 2_000_000), :isolated}
    began = System.monotonic_time(:millisecond)
    offline = Enum.reduce_while(1..4, pending, fn id, state ->
      case Bridge.handle_call(large, {self(), id}, state) do
        {:noreply, next} -> {:cont, next}
        {:reply, {:error, :not_connected}, next} -> {:halt, next}
      end
    end)
    assert System.monotonic_time(:millisecond) - began < 4_000
    assert offline.sock == nil
    assert offline.pending == %{}
    assert_receive {:first, {:error, :not_connected}}
  end
end
