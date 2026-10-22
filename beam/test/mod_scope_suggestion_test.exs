defmodule BowserBrain.ModScopeSuggestionTest do
  use ExUnit.Case, async: true
  alias BowserBrain.ModScopeSuggestion, as: Scope
  test "typed choices and confidence govern the recommendation" do
    for choice <- ["site", "browser"] do
      evaluate = fn state, questions ->
        assert state == %{"prompt" => "Make a change", "host" => "example.com"}
        assert questions["scope"]["type"] == "choice"
        {:ok, %{"answers" => %{"scope" => %{"choice" => choice, "confidence" => 0.9}}}}
      end
      assert Scope.decide("Make a change", "example.com", evaluate) == choice
    end
    for reply <- [{:error, :timeout}, {:ok, %{}},
                  {:ok, %{"answers" => %{"scope" => %{"choice" => "browser", "confidence" => 0.2}}}}] do
      assert Scope.decide("Make a change", "example.com", fn _, _ -> reply end) == "unclear"
    end
  end
  test "invalid and oversized inputs do not call Jev" do
    no_call = fn _, _ -> flunk("must not call") end
    assert Scope.decide(nil, "example.com", no_call) == "unclear"
    assert Scope.decide(String.duplicate("x", 8001), "example.com", no_call) == "unclear"
  end
  test "intent is independent of scope and uncertain intent defaults to a one-off task" do
    for {intent, confidence, expected} <- [{"mod", 0.95, "mod"}, {"task", 0.95, "task"}, {"mod", 0.2, "task"}, {"unknown", 1, "task"}] do
      evaluate = fn _, _ -> {:ok, %{"answers" => %{
        "scope" => %{"choice" => "site", "confidence" => 0.9},
        "kind" => %{"choice" => intent, "confidence" => confidence}}}} end
      assert Scope.decisions("Export this table", "example.com", evaluate) == %{choice: "site", kind: expected}
    end
  end

end
