defmodule BowserBrain.NativeToolsTest do
  use ExUnit.Case, async: true
  alias BowserBrain.NativeTools

  test "finds executable symlinks outside GUI PATH without running them" do
    root = Path.join(System.tmp_dir!(), "native-tools-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "bin"))
    on_exit(fn -> File.rm_rf!(root) end)
    executable = Path.join(root, "implementation")
    marker = Path.join(root, "executed")
    File.write!(executable, "#!/bin/sh\ntouch #{marker}\n")
    File.chmod!(executable, 0o755)
    File.ln_s!(executable, Path.join(root, "bin/converter"))
    directories = NativeTools.search_directories(root, "/usr/bin:.:relative", [Path.join(root, "bin")])
    refute "." in directories
    refute "relative" in directories
    assert NativeTools.find_executable("converter", directories) == Path.join(root, "bin/converter")
    refute File.exists?(marker)
    File.chmod!(executable, 0o644)
    assert NativeTools.find_executable("converter", directories) == nil
    assert NativeTools.find_executable("missing", directories) == nil
  end

  test "discovery rejects paths commands malformed names and oversized batches" do
    for names <- [[], ["../bin/tool"], ["/bin/sh"], ["tool --version"], ["$(touch x)"], ["tool\n"], [nil], List.duplicate("tool", 9)] do
      assert %{ok: false} = NativeTools.discover(%{"names" => names})
    end
    assert %{ok: true, tools: [%{name: "bowser-nonexistent-fixture", available: false, path: nil}]} =
      NativeTools.discover(%{"names" => ["bowser-nonexistent-fixture"]})
    assert [{"PATH", path}] = NativeTools.environment()
    assert "/opt/homebrew/bin" in String.split(path, ":")
  end
end
