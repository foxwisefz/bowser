defmodule BowserBrain.ModQuestion do
  @moduledoc "Bounded owner choices stored in the mod conversation, never executable actions."

  def validate(%{"question" => title, "detail" => detail, "options" => options})
      when is_binary(title) and is_binary(detail) and is_list(options) do
    valid = text?(title, 100) and text?(detail, 1500) and length(options) in 2..5 and
      Enum.all?(options, fn
        %{"label" => label, "description" => description} -> text?(label, 80) and text?(description, 300)
        _ -> false
      end)
    if valid and length(Enum.uniq_by(options, &String.downcase(String.trim(&1["label"])))) == length(options) do
      id = BowserBrain.ModRevision.id()
      choices = options |> Enum.with_index() |> Enum.map(fn {option, index} ->
        Map.take(option, ["label", "description"]) |> Map.put("id", "#{id}|#{index}")
      end)
      {:ok, %{"title" => title, "detail" => detail, "action" => "reply", "options" => choices}}
    else
      invalid()
    end
  end
  def validate(_), do: invalid()

  def answer(%{"title" => title, "options" => options}, id) when is_binary(id) do
    case Enum.find(options, &(&1["id"] == id)) do
      nil -> {:error, :stale}
      option -> {:ok, title <> "\n" <> option["label"] <> " — " <> option["description"]}
    end
  end
  def answer(_, _), do: {:error, :stale}

  defp text?(value, limit), do: is_binary(value) and String.trim(value) != "" and String.length(value) <= limit
  defp invalid, do: {:error, "Provide a question (1–100 characters), detail (1–1500), and 2–5 distinct options with label (1–80) and description (1–300)."}
end
