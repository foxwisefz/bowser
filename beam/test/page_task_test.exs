defmodule BowserBrain.PageTaskTest do
  use ExUnit.Case, async: false
  alias BowserBrain.PageTask

  setup do
    root = Path.join(System.tmp_dir!(), "task-exports-#{BowserBrain.ModRevision.id()}")
    old = Application.get_env(:bowser_brain, :task_downloads_dir)
    Application.put_env(:bowser_brain, :task_downloads_dir, root)
    on_exit(fn ->
      if old, do: Application.put_env(:bowser_brain, :task_downloads_dir, old),
        else: Application.delete_env(:bowser_brain, :task_downloads_dir)
      File.rm_rf!(root)
    end)
    {:ok, root: root}
  end

  test "exports preserve bytes, never overwrite and detect changed or missing files" do
    content = "{\"messages\":[{\"text\":\"你好\\nfull text\",\"timestamp\":null}]}"
    args = %{"name" => "conversation.json", "content" => content}
    assert {:ok, file} = PageTask.save(%{}, args)
    assert File.read!(file["path"]) == content
    assert {:ok, second} = PageTask.save(%{"artifacts" => [file]}, args)
    refute file["path"] == second["path"]
    p = %{"artifacts" => [file, second]}
    assert Enum.all?(PageTask.check(p), & &1["intact"])
    File.write!(file["path"], "changed")
    File.rm!(second["path"])
    assert Enum.all?(PageTask.check(p), &(not &1["intact"]))
  end

  test "rejects paths, invalid formats, invalid JSON and oversized exports", %{root: root} do
    for name <- ["../escape.txt", "/tmp/out.txt", "a/b.json", "x.js", "x.sh", "a.json\n"] do
      assert {:error, _} = PageTask.save(%{}, %{"name" => name, "content" => "{}"})
    end
    assert {:error, _} = PageTask.save(%{}, %{"name" => "x.json", "content" => "no"})
    assert {:error, _} = PageTask.save(%{}, %{"name" => "x.txt", "content" => <<255>>})
    assert {:error, _} = PageTask.save(%{}, %{"name" => "x.txt", "content" => String.duplicate("x", 1_048_577)})
    assert {:error, _} = PageTask.save(%{"artifacts" => List.duplicate(%{"bytes" => 1}, 32)}, %{"name" => "x.txt", "content" => "x"})
    assert {:error, _} = PageTask.save(%{"artifacts" => [%{"bytes" => 8_388_608}]}, %{"name" => "x.txt", "content" => "x"})
    refute File.exists?(root)
  end

  test "redirected output directories cannot write elsewhere", %{root: root} do
    File.mkdir_p!(root)
    File.ln_s!(System.tmp_dir!(), Path.join(root, "Bowser Tasks"))
    assert {:error, _} = PageTask.save(%{}, %{"name" => "x.txt", "content" => "secret"})
  end

  test "both catalogs agree on task contracts and the task runner excludes mod writes" do
    direct = File.read!("priv/ai-tools.json") |> JSON.decode!()
    [_, native, _] = File.read!("../shell/Sources/BowserRuntimeTool/ToolCatalog.swift") |> String.split(~r/#"""|"""#/)
    native = JSON.decode!(native)
    for name <- ["save_task_file", "task_files"] do
      assert Enum.find(direct, &(&1["name"] == name)) == Enum.find(native, &(&1["name"] == name))
    end
    Process.put(:modsmith_kind, "task")
    assert Enum.sort(Enum.map(BowserBrain.DirectAgent.tools(), & &1["name"])) == Enum.sort(PageTask.tools())
    Process.delete(:modsmith_kind)
    refute Enum.any?(BowserBrain.DirectAgent.tools(), &(&1["name"] == "save_task_file"))
  end
end
