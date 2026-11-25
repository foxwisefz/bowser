defmodule BowserBrain.ModTask do
  @moduledoc false
  # `use BowserBrain.Mod` binds Task to this adapter. Capture ownership before
  # spawning, so even a worker that outlives its parent keeps its boundary.
  @doc false
  def wrap(fun) do
    profile = BowserBrain.ModScope.current()
    owner = BowserBrain.ModScope.owner()

    fn ->
      if profile, do: Process.put(:bowser_profile, profile)
      if owner, do: Process.put(:bowser_mod_owner, owner)
      fun.()
    end
  end

  def start(fun), do: Task.start(wrap(fun))
  def start(module, function, args), do: start(fn -> apply(module, function, args) end)
  def start_link(fun), do: Task.start_link(wrap(fun))
  def start_link(module, function, args), do: start_link(fn -> apply(module, function, args) end)
  def async(fun), do: Task.async(wrap(fun))
  def async(module, function, args), do: async(fn -> apply(module, function, args) end)

  def async_stream(enumerable, fun, opts \\ []) do
    Task.async_stream(enumerable, wrap_stream(fun), opts)
  end

  @doc false
  def wrap_stream(fun) do
    profile = BowserBrain.ModScope.current()
    owner = BowserBrain.ModScope.owner()

    fn item ->
      if profile, do: Process.put(:bowser_profile, profile)
      if owner, do: Process.put(:bowser_mod_owner, owner)
      fun.(item)
    end
  end

  def async_stream(enumerable, module, function, args, opts \\ []),
    do: async_stream(enumerable, fn item -> apply(module, function, [item | args]) end, opts)

  defdelegate await(task), to: Task
  defdelegate await(task, timeout), to: Task
  defdelegate await_many(tasks), to: Task
  defdelegate await_many(tasks, timeout), to: Task
  defdelegate yield(task), to: Task
  defdelegate yield(task, timeout), to: Task
  defdelegate yield_many(tasks), to: Task
  defdelegate yield_many(tasks, timeout), to: Task
  defdelegate shutdown(task), to: Task
  defdelegate shutdown(task, timeout), to: Task
  defdelegate ignore(task), to: Task
end

defmodule BowserBrain.ModTask.Supervisor do
  @moduledoc false
  # The Task alias in a mod also qualifies Task.Supervisor. Keep that API
  # available and capture the caller's ownership, not the supervisor's.
  alias BowserBrain.ModTask

  defdelegate start_link(), to: Task.Supervisor
  defdelegate start_link(opts), to: Task.Supervisor
  defdelegate child_spec(opts), to: Task.Supervisor
  defdelegate children(supervisor), to: Task.Supervisor
  defdelegate terminate_child(supervisor, pid), to: Task.Supervisor

  for operation <- [:start_child, :async, :async_nolink] do
    def unquote(operation)(supervisor, fun, opts \\ []),
      do: Task.Supervisor.unquote(operation)(supervisor, ModTask.wrap(fun), opts)

    def unquote(operation)(supervisor, module, function, args, opts \\ []),
      do: unquote(operation)(supervisor, fn -> apply(module, function, args) end, opts)
  end

  for operation <- [:async_stream, :async_stream_nolink] do
    def unquote(operation)(supervisor, enumerable, fun, opts \\ []),
      do: Task.Supervisor.unquote(operation)(supervisor, enumerable, ModTask.wrap_stream(fun), opts)

    def unquote(operation)(supervisor, enumerable, module, function, args, opts \\ []),
      do: unquote(operation)(supervisor, enumerable, fn item -> apply(module, function, [item | args]) end, opts)
  end
end
