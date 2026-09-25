defmodule BowserBrain.ModTask do
  @moduledoc false
  # `use BowserBrain.Mod` binds Task to this adapter. Capture ownership before
  # spawning, so even a worker that outlives its parent keeps its boundary.
  defp wrap(fun) do
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
    profile = BowserBrain.ModScope.current()
    owner = BowserBrain.ModScope.owner()

    Task.async_stream(
      enumerable,
      fn item ->
        if profile, do: Process.put(:bowser_profile, profile)
        if owner, do: Process.put(:bowser_mod_owner, owner)
        fun.(item)
      end,
      opts
    )
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
