defmodule BowserBrain.TopicFilterTest do
  use ExUnit.Case, async: true
  alias BowserBrain.TopicFilter, as: Filter
  Code.compile_file(Path.expand("../example_mods/topic_filter.ex", __DIR__))

  test "disabled by default; enabling requires consent and site opt-in" do
    settings = Filter.defaults()
    refute Filter.active?(settings, "x")
    assert {:error, _} = Filter.validate(Map.put(settings, "enabled", true))

    assert {:ok, settings} =
             Filter.validate(Map.merge(settings, %{"enabled" => true, "consent" => true}))

    assert Filter.active?(settings, "x")
    refute Filter.active?(Map.put(settings, "site_x", false), "x")
    refute Filter.active?(Map.put(settings, "paused_until", 100), "x", 99)
    assert Filter.active?(Map.put(settings, "paused_until", 100), "x", 100)
  end

  test "custom topics are bounded, deduplicated and removable" do
    assert {:ok, settings} =
             Filter.validate(Map.put(Filter.defaults(), "custom", " Cats\n\n cats \nDogs"))

    assert settings["custom"] == "Cats\nDogs"
    assert length(Filter.criteria(settings)) == 5
    assert {:error, _} = Filter.validate(Map.put(settings, "custom", String.duplicate("x", 121)))
    assert {:error, _} = Filter.validate(Map.put(settings, "custom", Enum.join(1..21, "\n")))
    assert {:ok, settings} = Filter.validate(Map.put(settings, "custom", ""))
    assert length(Filter.criteria(settings)) == 3
  end

  test "sensitivity consumes probabilities; malformed replies fail open" do
    criteria = [{"a", "Topic", "topic"}]

    for {strictness, expected} <- [
          {"relaxed", []},
          {"balanced", ["Topic"]},
          {"strict", ["Topic"]}
        ] do
      assert {:ok, %{labels: ^expected}} =
               Filter.decide(%{"a" => %{"noul" => 0.7}}, criteria, strictness)
    end

    for answers <- [
          %{},
          %{"a" => nil},
          %{"a" => %{"noul" => 1.1}},
          %{"a" => %{"noul" => -0.1}},
          %{"a" => %{"noul" => "0.99"}}
        ] do
      assert {:error, :invalid_response} = Filter.decide(answers, criteria, "relaxed")
    end
  end

  test "one target per request, batching only questions to respect service limits" do
    criteria = for n <- 1..28, do: {"t#{n}", "Topic #{n}", "Description #{n}"}
    owner = self()

    evaluate = fn state, questions ->
      send(owner, {:request, state, map_size(questions)})
      {:ok, %{"answers" => Map.new(questions, fn {key, _} -> {key, %{"noul" => 0.9}} end)}}
    end

    assert {:ok, answers} = Filter.evaluate("Post", criteria, evaluate)
    assert map_size(answers) == 28
    assert_receive {:request, %{"text" => "Post"}, 16}
    assert_receive {:request, %{"text" => "Post"}, 12}

    assert {:error, :invalid_response} =
             Filter.evaluate("Post", criteria, fn _, _ -> {:ok, %{"answers" => %{}}} end)

    assert {:error, 429} = Filter.evaluate("Post", criteria, fn _, _ -> {:error, 429} end)
  end

  test "cache keys include text and criteria" do
    criteria = Filter.criteria(Filter.defaults())
    refute Filter.digest("A", criteria) == Filter.digest("B", criteria)
    refute Filter.digest("A", criteria) == Filter.digest("A", [])
    assert Filter.criteria(Map.put(Filter.defaults(), "mode", "dim")) == criteria
  end

  test "route allowlist excludes private messaging and spoofed hosts" do
    for url <- [
          "https://x.com/messages/1",
          "https://x.com/i/chat/1",
          "https://www.linkedin.com/messaging",
          "https://x.com.evil.test/",
          "http://x.com/"
        ] do
      assert Filter.site(url) == nil
    end

    for {url, site} <- [
          {"https://x.com/home", "x"},
          {"https://www.reddit.com/r/test", "reddit"},
          {"https://www.youtube.com/watch?v=test", "youtube"},
          {"https://news.ycombinator.com/", "hn"},
          {"https://www.linkedin.com/feed/", "linkedin"}
        ] do
      assert Filter.site(url) == site
    end
  end

  test "runtime state stays portable through the mod upgrader" do
    state = %{
      tabs: [1, 3],
      pending: %{{3, "document"} => 12},
      settings: Filter.defaults(),
      cache: %{}
    }

    assert BowserBrain.ModUpgrade.portable?(state)

    next =
      TopicFilterMod.handle_event(
        %{"event" => "page", "webview" => 5, "payload" => %{"kind" => "topic-filter-ready"}},
        state
      )

    assert Enum.sort(next.tabs) == [1, 3, 5]
    assert BowserBrain.ModUpgrade.portable?(next)
  end

  test "settings distinguish off, active and paused states" do
    defaults = Filter.defaults()
    assert TopicFilterMod.status_text(defaults) =~ "Off"
    enabled = Map.merge(defaults, %{"enabled" => true, "consent" => true})
    assert TopicFilterMod.status_text(enabled) =~ "On"

    assert TopicFilterMod.status_text(
             Map.put(enabled, "paused_until", System.system_time(:second) + 3600)
           ) =~ "Paused"
  end

  test "mod ignores stale results and unrelated timeouts" do
    token = make_ref()
    payload = %{"document" => "doc", "generation" => 1}

    state = %{
      pending: %{{5, "doc"} => token},
      generation: 2,
      settings: Filter.defaults(),
      cache: %{}
    }

    assert {:noreply, next} =
             TopicFilterMod.handle_info(
               {:topic_result, token, 5, payload, "key", [], {:ok, %{}}},
               state
             )

    assert next.pending == %{}
    assert next.cache == %{}

    assert {:noreply, ^state} =
             TopicFilterMod.handle_info({:topic_timeout, make_ref(), 5, payload}, state)
  end
end
