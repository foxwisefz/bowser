defmodule BowserBrain.ModIconTest do
  use ExUnit.Case, async: false
  alias BowserBrain.{IconJobs, ModIcon}

  test "uses the page origin cache, falls back to the domain, and isolates profiles" do
    original = System.get_env("BOWSER_HOME")
    root = Path.join(System.tmp_dir!(), "mod-icons-#{System.unique_integer([:positive])}")
    System.put_env("BOWSER_HOME", root)
    on_exit(fn ->
      if original, do: System.put_env("BOWSER_HOME", original), else: System.delete_env("BOWSER_HOME")
      File.rm_rf!(root)
    end)
    dir = Path.join(root, "app-icons-v2")
    File.mkdir_p!(dir)
    path = Path.join(dir, IconJobs.icon_key("https://example.com", "personal") <> ".png")
    File.write!(path, "icon fixture")
    assert ModIcon.cached("https://example.com/article", "personal") == path
    assert ModIcon.cached("example.com", "personal") == path
    assert ModIcon.cached("http://example.com/article", "personal") == path
    refute ModIcon.cached("example.com", "work")
    refute ModIcon.cached("unvisited.example", "personal")
    refute ModIcon.cached(nil, "personal")
    refute ModIcon.cached("file:///tmp/icon.png", "personal")
  end
end
