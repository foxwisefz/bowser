defmodule BowserBrain.NativeTools do
  @moduledoc "Read-only executable discovery for GUI-launched native mods. Does not run or install tools."

  def directories do
    search_directories(System.user_home!(), System.get_env("PATH", ""), ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
  end

  @doc false
  def search_directories(home, path, standard) do
    (String.split(path, ":", trim: true) ++ standard ++ [Path.join(home, ".local/bin")])
    |> Enum.filter(&(Path.type(&1) == :absolute))
    |> Enum.uniq()
  end

  @doc "Resolve a bare executable name to an executable file, or nil. No process is started."
  def find_executable(name), do: find_executable(name, directories())
  @doc false
  def find_executable(name, directories) do
    if valid_name?(name) do
      Enum.find_value(directories, fn directory ->
        path = Path.join(directory, name)
        if File.regular?(path), do: System.find_executable(path)
      end)
    end
  end

  @doc "PATH override for System.cmd/3 env: so the selected tool can find its companion tools."
  def environment, do: [{"PATH", Enum.join(directories(), ":")}]

  def discover(%{"names" => names}) when is_list(names) and length(names) in 1..8 do
    if Enum.all?(names, &valid_name?/1) do
      %{ok: true, tools: Enum.map(Enum.uniq(names), fn name ->
        path = find_executable(name)
        %{name: name, available: path != nil, path: path}
      end), note: "Existence and executable permissions only; no tool was run and no version or feature behavior was verified. Native mods can resolve again with BowserBrain.NativeTools.find_executable/1 and pass NativeTools.environment/0 to System.cmd env:."}
    else
      invalid()
    end
  end
  def discover(_), do: invalid()

  defp valid_name?(name), do: is_binary(name) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._+-]{0,79}\z/, name)
  defp invalid, do: %{ok: false, error: "Provide 1–8 bare executable names, not paths, arguments or shell commands."}
end
