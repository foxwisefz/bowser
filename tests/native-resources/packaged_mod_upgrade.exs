Application.load(:bowser_brain)
for key <- [:connect_bridge, :spawn_engine, :load_user_mods, :watch_lib, :watch_sites], do: Application.put_env(:bowser_brain, key, false)
{:ok, _} = Application.ensure_all_started(:bowser_brain)
path = Path.join(System.fetch_env!("BOWSER_HOME"), "probe.ex")
File.write!(path, "defmodule ReleaseMigrationProbe do use BowserBrain.Mod; def init_mod(_), do: %{value: 42} end")
%{ok: true} = BowserBrain.Loader.load_now(path)
[{pid, _}] = Registry.lookup(BowserBrain.ModRegistry, ReleaseMigrationProbe)
File.write!(path, "defmodule ReleaseMigrationProbe do use BowserBrain.Mod; def state_version, do: 1; def migrate_state(0, s), do: {:ok, Map.put(s, :ready, true)} end")
%{ok: true} = BowserBrain.Loader.load_now(path)
%{value: 42, ready: true} = :sys.get_state(pid)
IO.puts("PACKAGED_MOD_MIGRATION_PASSED")

File.write!(path, """
defmodule ReleaseTaskProbe do
  use BowserBrain.Mod
  def export(path, receiver) do
    {:ok, supervisor} = Task.Supervisor.start_link()
    Task.Supervisor.start_child(supervisor, fn ->
      File.write!(path, JSON.encode!(%{profile: BowserBrain.ModScope.current(), owner: inspect(BowserBrain.ModScope.owner())}))
      send(receiver, :exported)
    end)
    supervisor
  end
end
""")
%{ok: true, warnings: []} = BowserBrain.Loader.load_now(path)
Process.put(:bowser_profile, "work")
Process.put(:bowser_mod_owner, ReleaseTaskProbe)
output = Path.join(System.fetch_env!("BOWSER_HOME"), "export.json")
supervisor = ReleaseTaskProbe.export(output, self())
receive do :exported -> :ok after 2_000 -> raise "export worker did not finish" end
%{"profile" => "work", "owner" => "ReleaseTaskProbe"} = output |> File.read!() |> JSON.decode!()
Supervisor.stop(supervisor)
IO.puts("PACKAGED_MOD_TASK_EXPORT_PASSED")
