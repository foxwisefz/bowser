defmodule BowserBrain.ModIdentity do
  @moduledoc "Stable mod ownership independent of conversation and undo records."

  def canonical(path), do: String.replace_suffix(path, ".off", "")

  def files(project) do
    (Map.get(project, "owned_files", []) ++ List.wrap(project["existing_path"]) ++
       Enum.flat_map(project["revisions"] || [], &Map.keys(&1["files"])))
    |> Enum.map(&canonical/1) |> Enum.uniq()
  end

  def attach(project) do
    project |> Map.put_new("mod_id", project["id"])
      |> Map.put("owned_files", files(project))
      |> Map.put_new("history_ids", [project["id"]])
  end

  def owner(project), do: {get_in(project, ["app", "id"]), Map.get(project, "profile", "default")}

  def normalize(data) do
    {projects, aliases} = Enum.reduce(data["projects"], {[], %{}}, fn raw, {projects, aliases} ->
      project = attach(raw)
      primary = primary(project)
      existing = Enum.find(projects, fn other ->
        owner(other) == owner(project) and
          (other["mod_id"] == project["mod_id"] or (primary != [] and primary(other) == primary))
      end)
      if existing do
        merged = existing
          |> Map.put("owned_files", Enum.uniq(existing["owned_files"] ++ project["owned_files"]))
          |> Map.put("history_ids", Enum.uniq(existing["history_ids"] ++ project["history_ids"]))
          |> Map.put("turns", Enum.uniq_by(project["turns"] ++ existing["turns"], & &1["id"]))
          |> Map.put("revisions", Enum.uniq_by(existing["revisions"] ++ project["revisions"], & &1["id"]) |> Enum.sort_by(&(&1["at"] || 0), :desc))
          |> Map.put("session", nil)
        {Enum.map(projects, fn p -> if p["id"] == existing["id"], do: merged, else: p end),
         Map.put(aliases, project["id"], existing["id"])}
      else
        {projects ++ [project], aliases}
      end
    end)
    data |> Map.put("projects", projects)
      |> Map.update!("selected", &Map.new(&1, fn {client, id} -> {client, Map.get(aliases, id, id)} end))
  end

  defp primary(project), do: files(project) |> Enum.reject(&String.starts_with?(&1, "assets/")) |> Enum.sort()

  def conflict(projects, current, path) do
    path = canonical(path)
    Enum.find(projects, fn other ->
      other["id"] != current["id"] and owner(other) == owner(current) and path in files(other)
    end)
  end
end
