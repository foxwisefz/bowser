defmodule BowserBrain.SiteModsSecurityTest do
  use ExUnit.Case, async: false

  test "scans transfer edited site scripts between profiles and remove deleted files" do
    alias BowserBrain.{SiteMods, UserContent}
    root = Path.join(System.tmp_dir!(), "site-scan-#{BowserBrain.ModRevision.id()}")
    previous_home = System.get_env("BOWSER_HOME")
    System.put_env("BOWSER_HOME", root)
    previous_content = :sys.get_state(UserContent)
    on_exit(fn ->
      :sys.replace_state(UserContent, fn _ -> previous_content end)
      if previous_home, do: System.put_env("BOWSER_HOME", previous_home), else: System.delete_env("BOWSER_HOME")
      File.rm_rf!(root)
    end)

    site = "fixture.example"
    path = Path.join([root, "sites", site, "tagged.js"])
    source = "// bowser-profile: work\n// bowser-world: page\nwindow.siteAPI()"
    SiteMods.put(site, "tagged.js", source)
    timestamp = File.stat!(path).mtime
    {:noreply, state} = SiteMods.handle_info({:scan, false}, %{mtimes: %{}})
    assert SiteMods.payloads_for(site, "work") == [{"tagged.js", source}]
    assert [%{world: "page", host: ^site, source: ^source}] = :sys.get_state(UserContent).scripts[{:site_mods, "work"}]
    assert {:noreply, ^state} = SiteMods.handle_info({:scan, true}, state)

    edited = String.replace(source, "work", "home")
    File.write!(path <> ".new", edited)
    File.touch!(path <> ".new", timestamp)
    File.rename!(path <> ".new", path)
    {:noreply, state} = SiteMods.handle_info({:scan, true}, state)
    scripts = :sys.get_state(UserContent).scripts
    assert [%{world: "page", host: ^site, source: ^edited}] = scripts[{:site_mods, "home"}]
    refute Map.has_key?(scripts, {:site_mods, "work"})
    assert SiteMods.payloads_for(site, "work") == []

    File.rm!(path)
    assert {:noreply, %{profiles: []}} = SiteMods.handle_info({:scan, true}, state)
    refute Map.has_key?(:sys.get_state(UserContent).scripts, {:site_mods, "home"})
  end

  test "site CSS and JS carry native host restrictions and explicit worlds" do
    root = Path.join(System.tmp_dir!(), "site-guard-#{BowserBrain.ModRevision.id()}")
    dir = Path.join(root, "bank.example")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(root) end)
    js = Path.join(dir, "private.js")
    css = Path.join(dir, "private.css")
    page = Path.join(dir, "page.js")
    File.write!(js, "globalThis.ran += 1;")
    File.write!(css, "body { color: red; }")
    File.write!(page, "// bowser-profile: work\n// bowser-world: page\nwindow.siteAPI()")
    [page_script, css_script, js_script] = BowserBrain.SiteMods.build_scripts([js, css, page])
    assert Enum.all?([page_script, css_script, js_script], &(&1.host == "bank.example"))
    assert page_script.world == "page"
    assert css_script.world == "isolated"
    assert js_script == %{host: "bank.example", world: "isolated", source: "globalThis.ran += 1;"}
    assert css_script.source =~ "body { color: red; }"
  end
end
