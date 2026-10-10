defmodule BowserBrain.ModCopy do
  @moduledoc "Copies installed mod code and assets into an independent, disabled profile mod."
  alias BowserBrain.{ModIdentity, ModRevision, ModScope, ModWorkshop}

  def prepare(project, destination) do
    unless project["app"] == nil and destination != Map.get(project, "profile", "default") and
             Enum.any?(BowserBrain.Profiles.list(), &(&1["id"] == destination)),
      do: raise("Choose another existing browser profile.")

    copy = ModWorkshop.new_project(project["name"], project["scope"], project["url"], nil)
    suffix = "Copy" <> Base.encode16(:crypto.strong_rand_bytes(8))
    sources = ModIdentity.files(project)
      |> Enum.map(&ModRevision.actual_path/1)
      |> Enum.uniq()
      |> Enum.flat_map(fn path ->
        case ModRevision.read(path) do
          nil -> []
          source -> [{path, source}]
        end
      end)
    unless Enum.any?(sources, fn {p, _} -> not String.starts_with?(p, "assets/") end),
      do: raise("This mod has no installed files to copy.")
    Enum.each(sources, fn {path, source} ->
      if String.starts_with?(path, "assets/") do
        owners = Map.get(project, "history_ids", [project["id"]])
        unless Enum.any?(owners, &String.starts_with?(path, "assets/#{&1}/")),
          do: raise("This asset belongs to another mod.")
      else
        unless ModScope.source_profile(source) == Map.get(project, "profile", "default"),
          do: raise("A mod file now belongs to another profile.")
      end
    end)
    paths = Map.new(sources, fn {path, _} ->
      plain = ModIdentity.canonical(path)
      destination = if String.starts_with?(plain, "assets/"),
        do: "assets/#{copy["id"]}/#{Path.basename(Path.dirname(plain))}-#{Path.basename(plain)}",
        else: Path.rootname(plain) <> "_" <> suffix <> Path.extname(plain) <> ".off"
      {plain, destination}
    end)
    modules = sources |> Enum.filter(fn {p, _} -> String.ends_with?(ModIdentity.canonical(p), ".ex") end)
      |> Enum.flat_map(fn {_, source} ->
        ast = Code.string_to_quoted!(source)
        statements = case ast do {:__block__, _, list} -> list; other -> [other] end
        for {:defmodule, _, [{:__aliases__, _, names}, _]} <- statements, do: names
      end)
    files = Map.new(sources, fn {path, source} ->
      destination_path = Map.fetch!(paths, ModIdentity.canonical(path))
      source = if String.ends_with?(ModIdentity.canonical(path), ".ex"),
        do: rewrite(source, modules, suffix, paths), else: replace_paths(source, paths)
      source = if String.starts_with?(path, "assets/"), do: source,
        else: ModScope.tag(source, destination, Path.extname(ModIdentity.canonical(path)))
      {destination_path, source}
    end)
    copy = copy |> Map.put("profile", destination) |> Map.put("owned_files", Map.keys(files))
      |> Map.put("summary", "Copied with fresh data. Turn it on to use it in this profile.")
      |> ModIdentity.attach()
    {copy, files}
  end

  def install(files, save) do
    Enum.each(files, fn {path, _} ->
      if ModRevision.read(path) != nil, do: raise("A destination file already exists.")
    end)
    try do
      Enum.each(files, fn {path, content} -> ModRevision.write(path, content) end)
      save.()
    rescue
      error ->
        Enum.each(files, fn {path, _} -> ModRevision.write(path, nil) end)
        reraise error, __STACKTRACE__
    end
  end

  defp rewrite(source, modules, suffix, paths) do
    ast = Code.string_to_quoted!(source)
    {_, aliases} = Macro.prewalk(ast, [[:Store], [:BowserBrain, :Store]], fn
      {:alias, _, [{:__aliases__, _, [:BowserBrain, :Store]}, [as: {:__aliases__, _, name}]]} = node, acc -> {node, [name | acc]}
      node, acc -> {node, acc}
    end)
    {_, imported} = Macro.prewalk(ast, false, fn
      {:import, _, [{:__aliases__, _, names} | _]} = node, acc -> {node, acc or names in aliases}
      node, acc -> {node, acc}
    end)
    # All declarations and references get a fresh root, including module atoms.
    root = String.to_atom(suffix)
    ast = Macro.postwalk(ast, fn
      {:__aliases__, meta, names} = node ->
        if Enum.any?(modules, &(Enum.take(names, length(&1)) == &1)),
          do: {:__aliases__, meta, [root | names]}, else: node
      value when is_binary(value) -> replace_paths(value, paths)
      value when is_atom(value) ->
        name = Atom.to_string(value)
        if Enum.any?(modules, &(name == "Elixir." <> Enum.join(&1, "."))),
          do: String.to_atom("Elixir." <> suffix <> "." <> String.replace_prefix(name, "Elixir.", "")), else: value
      node -> node
    end)
    # Literal/custom Store namespaces need isolation too, not only __MODULE__.
    ast = Macro.postwalk(ast, fn
      {{:., dot, [{:__aliases__, _, names} = module, operation]}, meta, [scope | args]}
          when operation in [:all, :get, :put, :update, :delete, :clear] ->
        own_scope = case scope do
          {:__MODULE__, _, _} -> true
          {:__aliases__, _, [^root | _]} -> true
          _ -> false
        end
        if names in aliases and not own_scope do
          scoped = quote do: unquote(suffix) <> "." <> BowserBrain.Store.scope(unquote(scope))
          {{:., dot, [module, operation]}, meta, [scoped | args]}
        else
          {{:., dot, [module, operation]}, meta, [scope | args]}
        end
      {operation, meta, [scope | args]} = node when operation in [:all, :get, :put, :update, :delete, :clear] ->
        if imported do
          scoped = case scope do
            {:__MODULE__, _, _} -> scope
            {:__aliases__, _, [^root | _]} -> scope
            _ -> quote do: unquote(suffix) <> "." <> BowserBrain.Store.scope(unquote(scope))
          end
          {operation, meta, [scoped | args]}
        else
          node
        end
      node -> node
    end)
    Macro.to_string(ast) <> "\n"
  end

  defp replace_paths(source, paths) do
    Enum.reduce(paths, source, fn {old, new}, text ->
      String.replace(text, old, ModIdentity.canonical(new))
    end)
  end
end
