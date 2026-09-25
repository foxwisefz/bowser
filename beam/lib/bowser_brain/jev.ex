defmodule BowserBrain.Jev do
  @moduledoc "Typed Jev judgments through the authenticated Bowser service; no provider key in mods."
  def evaluate(state, questions) do
    owner = BowserBrain.ModScope.owner()
    count = if is_map(questions), do: map_size(questions), else: 0
    if owner, do: BowserBrain.ModLog.stage(owner, :jev_started, count)
    result = evaluate_request(state, questions)
    if owner do
      case result do
        {:ok, _} -> BowserBrain.ModLog.stage(owner, :jev_ok, count)
        {:error, reason} -> BowserBrain.ModLog.stage(owner, :jev_error, count, error: reason)
      end
    end
    result
  end

  defp evaluate_request(state, questions) when is_map(questions) do
    body = %{"state" => state, "questions" => questions}

    if map_size(questions) in 1..16 and byte_size(JSON.encode!(body)) <= 32_768 do
      with {:ok, %{"answers" => answers} = reply} when is_map(answers) <-
             BowserBrain.AI.jev(state, questions) do
        {:ok, reply}
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_response}
      end
    else
      {:error, :request_too_large}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  defp evaluate_request(_, _), do: {:error, :invalid_request}
end
