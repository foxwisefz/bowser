defmodule BowserBrain.ModTaskTest do
  use ExUnit.Case, async: false
  alias BowserBrain.{ModScope, ModTask, UserContent}

  defmodule Probe do
    use BowserBrain.Mod

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
