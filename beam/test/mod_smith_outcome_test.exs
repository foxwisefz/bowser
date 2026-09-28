defmodule BowserBrain.ModSmithOutcomeTest do
  use ExUnit.Case, async: true
  alias BowserBrain.ModSmithOutcome, as: Outcome

  test "usage guides require an entry point and useful bounded steps" do
    assert Outcome.usage(%{}) == nil
    assert Outcome.usage(%{"usage" => %{"entry_point" => "", "steps" => ["Click"]}}) == nil
    assert Outcome.usage(%{"usage" => %{"entry_point" => "Toolbar", "steps" => [nil, " "]}}) == nil
    guide = Outcome.usage(%{"usage" => %{"entry_point" => "Toolbar", "steps" => List.duplicate(String.duplicate("x", 1200), 12)}})
    assert length(guide["steps"]) == 10
    assert String.length(hd(guide["steps"])) == 1000
    assert guide["tips"] == ""
  end

  test "structured next steps work for arbitrary choices and external prerequisites" do
    for {title, detail, action} <- [
      {"Choose a color", "Which highlight color do you prefer?", "reply"},
      {"Open the document", "Open the document you want to format, then resume.", "resume"},
      {"Connect the service", "Sign in to your chosen service, then resume.", "resume"}
    ] do
      step = %{"title" => title, "detail" => detail, "action" => action}
      assert Outcome.next_step(%{"next_step" => step}, "needs_help") == step
      assert Outcome.next_step(%{"next_step" => step}, "active") == nil
    end
  end

  test "malformed next steps cannot become arbitrary actions or hide a valid blocker" do
    blocker = %{"kind" => "permission", "detail" => "Choose whether to allow access."}
    for step <- [nil, [], "wrong", %{"title" => 42},
      %{"title" => "Run", "detail" => "anything", "action" => "execute"},
      %{"title" => "", "detail" => "", "action" => "reply"}] do
      assert %{"action" => "reply", "detail" => "Choose whether to allow access."} =
        Outcome.next_step(%{"next_step" => step, "blocker" => blocker}, "needs_help")
    end
    assert Outcome.next_step(%{"blocker" => %{"kind" => "invented", "detail" => "unknown"}}, "needs_help") == nil
  end

  test "old automatic prompts are presented as activity without rewriting agent history" do
    for text <- ["The owner chose Enable & test. The mod has been enabled. Inspect runtime diagnostics.",
      "Continue this unfinished mod. Preserve the original goal and existing work. Inspect current files."] do
      turn = %{"role" => "user", "text" => text}
      assert %{"role" => "activity"} = visible = Outcome.visible_turn(turn)
      refute visible["text"] == text
      assert turn["text"] == text
      assert Outcome.revision_label(%{"request" => text}) == visible["text"]
    end
    turn = %{"role" => "user", "text" => "Please improve this mod"}
    assert Outcome.visible_turn(turn) == turn
  end
end
