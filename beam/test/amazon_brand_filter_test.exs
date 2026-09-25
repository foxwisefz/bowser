defmodule BowserBrain.AmazonBrandFilterTest do
  use ExUnit.Case, async: false
  @compile {:no_warn_undefined, AmazonBrandFilter}
  setup_all do
    Code.compile_file(Path.expand("../example_mods/amazon_brand_filter.ex", __DIR__))
    :ok
  end
  setup do
    root = Path.join(System.tmp_dir!(), "single-jev-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "registration.json"), JSON.encode!(%{"telemetryToken" => "fixture"}))
    old_home = System.get_env("BOWSER_HOME")
    old_transport = Application.get_env(:bowser_brain, :ai_transport)
    System.put_env("BOWSER_HOME", root)
    BowserBrain.Store.clear(AmazonBrandFilter)
    on_exit(fn ->
      if old_home, do: System.put_env("BOWSER_HOME", old_home), else: System.delete_env("BOWSER_HOME")
      if old_transport, do: Application.put_env(:bowser_brain, :ai_transport, old_transport), else: Application.delete_env(:bowser_brain, :ai_transport)
      BowserBrain.Store.clear(AmazonBrandFilter)
      File.rm_rf!(root)
    end)
    :ok
  end
  defp item(id, text), do: %{"asin" => id, "title" => text, "text" => text}
  defp event(items), do: %{"event" => "page", "webview" => 42, "payload" => %{"kind" => "amazon_brand_candidates", "items" => items}}
  defp initial do
    {:ok, state} = AmazonBrandFilter.migrate_state(1, %{enabled: true})
    state
  end
  defp answer(choice), do: {:ok, %{"answers" => %{"brand" => %{"choice" => choice, "confidence" => 0.99}}}}

  test "one request per listing, unchanged cache hit, edited content reevaluated" do
    owner = self()
    Application.put_env(:bowser_brain, :ai_transport, fn _, _, body, _ ->
      send(owner, {:request, body})
      answer("keep")
    end)
    items = [item("a", "Brand A"), item("b", "Brand B")]
    state = AmazonBrandFilter.handle_event(event(items), initial())
    assert_receive {:request, %{"state" => first, "questions" => %{"brand" => _} = questions}}
    assert first == hd(items)
    assert map_size(questions) == 1
    assert_receive {:brand_result, _, {:ok, false}} = result
    {:noreply, state} = AmazonBrandFilter.handle_info(result, state)
    assert_receive {:request, %{"state" => second}}
    assert second == List.last(items)
    assert_receive {:brand_result, _, {:ok, false}} = result
    {:noreply, state} = AmazonBrandFilter.handle_info(result, state)
    state = AmazonBrandFilter.handle_event(event(items), state)
    assert state.pending == nil
    refute_receive {:request, _}
    edited = item("a", "Changed brand")
    state = AmazonBrandFilter.handle_event(event([edited]), state)
    assert_receive {:request, %{"state" => ^edited}}
    assert_receive {:brand_result, _, _} = result
    AmazonBrandFilter.handle_info(result, state)
  end

  test "missing answers, uncertain scores, and errors are never cached as keep" do
    for reply <- [{:ok, %{"answers" => %{}}}, {:ok, %{"answers" => %{"brand" => %{"choice" => "hide", "confidence" => 0.1}}}}, {:error, :timeout}] do
      BowserBrain.Store.clear(AmazonBrandFilter)
      Application.put_env(:bowser_brain, :ai_transport, fn _, _, _, _ -> reply end)
      state = AmazonBrandFilter.handle_event(event([item("a", "Unknown")]), initial())
      assert_receive {:brand_result, _, {:error, _}} = result
      {:noreply, state} = AmazonBrandFilter.handle_info(result, state)
      assert BowserBrain.Store.all(AmazonBrandFilter) == %{}
      state = AmazonBrandFilter.handle_event(event([item("a", "Unknown")]), state)
      assert state.pending == nil
    end
  end
end
