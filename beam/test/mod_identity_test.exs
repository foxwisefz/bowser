defmodule BowserBrain.ModIdentityTest do
  use ExUnit.Case, async: true
  alias BowserBrain.{ModIdentity, ModWorkshop}

  test "duplicate histories become one mod without losing turns, undo, assets or selections" do
    newer = ModWorkshop.new_project("Reader", "site", "https://example.com", nil)
      |> Map.put("existing_path", "mods/reader.ex.off")
      |> Map.put("turns", [%{"id" => "new", "text" => "refine"}])
      |> Map.put("revisions", [%{"id" => "new", "at" => 2, "files" => %{"mods/reader.ex.off" => %{}}}])
    older = ModWorkshop.new_project("Reader", "site", "https://example.com", nil)
      |> Map.put("existing_path", "mods/reader.ex")
      |> Map.put("turns", [%{"id" => "old", "text" => "create"}])
    asset = "assets/#{older["id"]}/icon.svg"
    older = Map.put(older, "revisions", [%{"id" => "old", "at" => 1, "files" => %{asset => %{}}}])
    data = %{"projects" => [newer, older], "selected" => %{"main" => older["id"]}}
    result = ModIdentity.normalize(data)
    [mod] = result["projects"]
    assert mod["mod_id"] == newer["id"]
    assert Enum.map(mod["turns"], & &1["id"]) == ["old", "new"]
    assert Enum.map(mod["revisions"], & &1["id"]) == ["new", "old"]
    assert asset in mod["owned_files"]
    assert older["id"] in mod["history_ids"]
    assert result["selected"]["main"] == mod["id"]
    assert ModIdentity.normalize(result) == result
    assert ModIdentity.files(Map.put(mod, "revisions", [])) == mod["owned_files"]
  end

  test "ownership stays separate across profiles, unrelated mods and empty drafts" do
    one = ModWorkshop.new_project("Reader", "site", "https://example.com", nil)
      |> Map.put("existing_path", "mods/reader.ex")
    other = one |> Map.put("id", "other") |> Map.put("profile", "work")
    draft = ModWorkshop.new_project("Draft", "site", "https://example.com", nil)
    result = ModIdentity.normalize(%{"projects" => [one, other, draft], "selected" => %{}})
    assert length(result["projects"]) == 3
    assert ModIdentity.conflict(result["projects"], draft, "mods/reader.ex.off")["id"] == one["id"]
    assert ModIdentity.conflict(result["projects"], one, "mods/reader.ex") == nil
  end
end
