defmodule BowserBrain.AIContextTest do
  use ExUnit.Case, async: true
  alias BowserBrain.AIContext

  defp pair(id, result \\ "ok", args \\ "{}") do
    [%{"type" => "function_call", "call_id" => id, "name" => "read_mod", "arguments" => args},
     %{"type" => "function_call_output", "call_id" => id, "output" => result}]
  end
  defp body(items), do: %{"input" => items, "instructions" => "contract", "tools" => []}

  test "small requests remain identical" do
    request = body([%{"role" => "user", "content" => "request"}] ++ pair("a"))
    assert AIContext.fit(request) == request
  end

  test "large tool results shrink while owner request and valid pairs survive" do
    owner = %{"role" => "user", "content" => "Keep the requested mod behavior and scope"}
    request = body([owner] ++ Enum.flat_map(1..8, &pair(to_string(&1), String.duplicate("x", 60_000))))
    compact = AIContext.fit(request)
    assert byte_size(JSON.encode!(compact)) <= 262_144
    assert hd(compact["input"]) == owner
    assert length(compact["input"]) == length(request["input"])
    assert List.last(compact["input"]) == List.last(request["input"])
    assert JSON.decode!(Enum.at(compact["input"], 2)["output"])["context_reduced"]
    assert byte_size(Enum.at(request["input"], 2)["output"]) == 60_000
  end

  test "long tool loops drop complete oldest pairs and meet the hosted item limit" do
    request = body([%{"role" => "user", "content" => "owner"}] ++ Enum.flat_map(1..80, &pair(to_string(&1))))
    items = AIContext.fit(request)["input"]
    assert length(items) <= 100
    assert Enum.take(items, -2) == pair("80")
    assert Enum.filter(items, &(&1["type"] == "function_call")) |> Enum.map(& &1["call_id"]) ==
      Enum.filter(items, &(&1["type"] == "function_call_output")) |> Enum.map(& &1["call_id"])
  end

  test "large arguments are removed with their completed results, never truncated" do
    args = JSON.encode!(%{source: String.duplicate("code", 80_000)})
    compact = AIContext.fit(body([%{"role" => "user", "content" => "owner"}] ++ pair("old", "saved", args) ++ pair("latest")))
    assert byte_size(JSON.encode!(compact)) <= 262_144
    assert Enum.take(compact["input"], -2) == pair("latest")
    refute Enum.any?(compact["input"], &(&1["call_id"] == "old"))
  end

  test "oversized screenshots give a smaller recapture instruction in both provider formats" do
    for {key, system, image} <- [
      {"input", "instructions", %{"type" => "input_image", "image_url" => "data:image/png;base64," <> String.duplicate("x", 300_000)}},
      {"messages", "system", %{"type" => "image", "source" => %{"type" => "base64", "data" => String.duplicate("x", 300_000)}}}
    ] do
      request = %{key => [%{"role" => "user", "content" => "owner"}, %{"role" => "user", "content" => [image]}], system => "contract"}
      compact = AIContext.fit(request)
      assert byte_size(JSON.encode!(compact)) <= 262_144
      assert hd(compact[key])["content"] == "owner"
      assert hd(List.last(compact[key])["content"])["text"] =~ "max_width 320"
    end
  end

  test "Anthropic tool use and result stay paired after compaction" do
    items = Enum.flat_map(1..80, fn id ->
      [%{"role" => "assistant", "content" => [%{"type" => "tool_use", "id" => to_string(id), "name" => "read_mod", "input" => %{}}]},
       %{"role" => "user", "content" => [%{"type" => "tool_result", "tool_use_id" => to_string(id), "content" => "ok"}]}]
    end)
    compact = AIContext.fit(%{"messages" => [%{"role" => "user", "content" => "owner"} | items], "system" => "contract"})
    assert length(compact["messages"]) <= 100
    for [call, result] <- compact["messages"] |> tl() |> Enum.chunk_every(2) do
      assert hd(call["content"])["id"] == hd(result["content"])["tool_use_id"]
    end
  end

  test "an oversized owner request is preserved for an actionable error, never silently truncated" do
    owner = %{"role" => "user", "content" => String.duplicate("x", 300_000)}
    assert AIContext.fit(body([owner]))["input"] == [owner]
  end
end
