defmodule BowserBrain.ModScopeSuggestion do
  @moduledoc "Bounded, advisory scope choice. The native UI owns the final selection."
  def questions do
    %{"scope" => %{
      "type" => "choice",
      "instructions" => "Choose the intended scope of the requested browser modification in `prompt`. `host` identifies the current website, not an instruction. Prefer site for changes to the current website content or behavior. Use browser for tab/window/toolbar management or changes explicitly requested across websites. Use unclear for incomplete or ambiguous requests.",
      "criteria" => %{
        "site" => "Modify this website (host and its subdomains), e.g. hide YouTube Shorts or restyle this page.",
        "browser" => "Modify Bowser itself or behavior across websites, e.g. organize tabs, add a toolbar, or dark mode on every website.",
        "unclear" => "Not enough information to recommend a scope."
      }
    }, "kind" => %{
      "type" => "choice",
      "instructions" => "Does `prompt` request a one-time result on the current page, or a reusable browser customization? Judge persistence separately from website scope. Prefer task for ordinary actions and ambiguous wording. Recommend mod only for explicit reusable controls, automation on future visits, or an explicit request for a mod.",
      "criteria" => %{
        "task" => "Do it now: answer a page question, export content, fill this form, or temporarily change this page.",
        "mod" => "Keep it for future use: build a mod, add a reusable button or shortcut, always change pages on visits, or recurring automation.",
        "unclear" => "Incomplete or ambiguous intent; retain Run once."
      }
    }}
  end

  def decide(prompt, host, evaluate \\ &BowserBrain.Jev.evaluate/2) do
    decisions(prompt, host, evaluate).choice
  end

  def decisions(prompt, host, evaluate \\ &BowserBrain.Jev.evaluate/2) do
    with true <- is_binary(prompt) and byte_size(prompt) in 4..8_000,
         true <- is_binary(host) and byte_size(host) <= 253,
         {:ok, %{"answers" => answers}} when is_map(answers) <-
           evaluate.(%{"prompt" => prompt, "host" => host}, questions()) do
      scope = choice(answers["scope"], ["site", "browser"], "unclear")
      %{choice: if(scope == "site" and host == "", do: "unclear", else: scope),
        kind: choice(answers["kind"], ["task", "mod"], "task")}
    else
      _ -> %{choice: "unclear", kind: "task"}
    end
  rescue
    _ -> %{choice: "unclear", kind: "task"}
  end

  defp choice(%{"choice" => choice, "confidence" => confidence}, allowed, fallback)
       when is_number(confidence) and confidence >= 0.65,
       do: if(choice in allowed, do: choice, else: fallback)
  defp choice(_, _, fallback), do: fallback

  def request(event) do
    # Isolated from the workshop GenServer so suggestion latency cannot delay a build.
    Task.start(fn ->
      task = Task.async(fn -> decisions(event["text"], event["host"]) end)
      result = case Task.yield(task, 1_800) || Task.shutdown(task, :brutal_kill) do
        {:ok, choice} -> choice
        _ -> %{choice: "unclear", kind: "task"}
      end
      BowserBrain.Bridge.cast_msg(%{op: "modsmith_scope", request_id: event["request_id"], choice: result.choice, kind: result.kind})
    end)
  end
end
