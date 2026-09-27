defmodule BowserBrain.ModSmithOutcome do
  @moduledoc "User-facing ModSmith activity and next steps, independent of mod behavior."

  def activity("enable_and_test"), do: "Mod enabled. Testing it now…"
  def activity("continue"), do: "Resuming testing and fixes…"
  def activity("retry"), do: "Trying your request again…"
  def activity("clarify"), do: "Checking what’s needed next…"
  def activity(_), do: nil

  # Existing saved conversations retain the original instructions for agent context.
  def legacy_activity("The owner chose Enable & test. The mod has been enabled." <> _), do: activity("enable_and_test")
  def legacy_activity("Continue this unfinished mod. Preserve the original goal and existing work." <> _), do: activity("continue")
  def legacy_activity(_), do: nil

  def visible_turn(turn) do
    label = if turn["role"] == "user", do: legacy_activity(turn["text"]), else: nil
    turn = if label, do: Map.merge(turn, %{"role" => "activity", "text" => label}), else: turn
    Map.drop(turn, ["instruction"])
  end

  def revision_label(revision), do: revision["label"] || legacy_activity(revision["request"]) || revision["request"]

  def next_step(envelope, status) when status in ["needs_help", "partial", "failed"] do
    case envelope["next_step"] do
      %{"title" => title, "detail" => detail, "action" => action}
      when is_binary(title) and is_binary(detail) and action in ["reply", "resume"] ->
        if String.trim(title) != "" and String.trim(detail) != "",
          do: %{"title" => String.slice(title, 0, 100), "detail" => String.slice(detail, 0, 1500), "action" => action},
          else: blocker_step(envelope["blocker"])
      _ -> blocker_step(envelope["blocker"])
    end
  end
  def next_step(_, _), do: nil

  defp blocker_step(%{"kind" => kind, "detail" => detail})
       when kind in ["owner_decision", "permission", "external_dependency"] and is_binary(detail) do
    if String.trim(detail) != "" do
      %{"title" => if(kind == "external_dependency", do: "Before testing can continue", else: "Your input is needed"),
        "detail" => String.slice(detail, 0, 1500), "action" => if(kind == "external_dependency", do: "resume", else: "reply")}
    end
  end
  defp blocker_step(_), do: nil
end
