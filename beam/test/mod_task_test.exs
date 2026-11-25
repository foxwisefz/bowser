defmodule BowserBrain.ModTaskTest do
  use ExUnit.Case, async: false
  alias BowserBrain.{ModScope, ModTask, UserContent}

  defmodule Probe do
    use BowserBrain.Mod

    def supervisor, do: Task.Supervisor.start_link()
    def supervised_worker(supervisor, receiver) do
      Task.Supervisor.start_child(supervisor, fn ->
        receive do
          :inspect -> send(receiver, {:scope, {ModScope.current(), ModScope.owner()}})
        end
      end)
    end
    def supervised_api, do: Task.Supervisor
    def scope, do: {ModScope.current(), ModScope.owner()}
    def scope(item), do: {item, scope()}
    def report(receiver), do: send(receiver, {:scope, scope()})

    def worker(receiver) do
      Task.start(fn ->
        receive do
          :inspect ->
            nested = Task.async(fn -> {ModScope.current(), ModScope.owner()} end)
            send(receiver, {:scope, Task.await(nested)})
        end
      end)
    end
  end

  test "Task.Supervisor in mods works and retains the caller after it exits" do
    {:ok, supervisor} = Probe.supervisor()
    on_exit(fn -> if Process.alive?(supervisor), do: Supervisor.stop(supervisor) end)
    receiver = self()
    parent = spawn(fn ->
      Process.put(:bowser_profile, "work")
      Process.put(:bowser_mod_owner, Probe)
      {:ok, worker} = Probe.supervised_worker(supervisor, receiver)
      send(receiver, {:worker, worker})
    end)
    ref = Process.monitor(parent)
    assert_receive {:worker, worker}
    assert_receive {:DOWN, ^ref, :process, ^parent, _}
    assert worker in Probe.supervised_api().children(supervisor)
    send(worker, :inspect)
    assert_receive {:scope, {"work", Probe}}
  end

  test "supervised async, MFA and lazy streams carry the submitting mod scope" do
    api = Probe.supervised_api()
    supervisor = start_supervised!({api, []})
    Process.put(:bowser_profile, "work")
    Process.put(:bowser_mod_owner, Probe)

    for operation <- [:async, :async_nolink] do
      for args <- [[supervisor, &Probe.scope/0], [supervisor, Probe, :scope, []]] do
        assert {"work", Probe} = args |> then(&apply(api, operation, &1)) |> Task.await()
      end
    end
    assert {:ok, _} = api.start_child(supervisor, Probe, :report, [self()], restart: :temporary)
    assert_receive {:scope, {"work", Probe}}

    streams = for operation <- [:async_stream, :async_stream_nolink], args <- [
      [supervisor, [1, 2], &Probe.scope/1, [max_concurrency: 1]],
      [supervisor, [1, 2], Probe, :scope, [], [max_concurrency: 1]]
    ], do: apply(api, operation, args)
    # Enumeration can happen later in a different context.
    Process.put(:bowser_profile, "foreign")
    Process.put(:bowser_mod_owner, OtherMod)
    for stream <- streams do
      assert Enum.to_list(stream) == [{:ok, {1, {"work", Probe}}}, {:ok, {2, {"work", Probe}}}]
    end
    {:ok, worker} = api.start_child(supervisor, fn -> receive do :stop -> :ok end end)
    assert :ok = api.terminate_child(supervisor, worker)
    refute Process.alive?(worker)
  end

  test "ordinary Task calls in mods retain ownership after their parent exits" do
    receiver = self()

    parent =
      spawn(fn ->
        Process.put(:bowser_profile, "work")
        Process.put(:bowser_mod_owner, Probe)
        {:ok, worker} = Probe.worker(receiver)
        send(receiver, {:worker, worker})
      end)

    ref = Process.monitor(parent)
    assert_receive {:worker, worker}
    assert_receive {:DOWN, ^ref, :process, ^parent, _}
    send(worker, :inspect)
    assert_receive {:scope, {"work", Probe}}
  end

  test "streams carry scope and content cannot override its owning profile" do
    before = :sys.get_state(UserContent)
    on_exit(fn -> :sys.replace_state(UserContent, fn _ -> before end) end)
    Process.put(:bowser_profile, "work")
    Process.put(:bowser_mod_owner, Probe)

    assert [{:ok, {"work", Probe}}] =
             ModTask.async_stream([1], fn _ -> {ModScope.current(), ModScope.owner()} end)
             |> Enum.to_list()

    task =
      ModTask.async(fn ->
        BowserBrain.Page.set_scripts(["void 0"], profile: "foreign", reload: false)
      end)

    assert :ok = ModTask.await(task)
    state = :sys.get_state(UserContent)
    assert Map.has_key?(state.scripts, {Probe, "work"})
    refute Map.has_key?(state.scripts, {Probe, "foreign"})
  end
end
