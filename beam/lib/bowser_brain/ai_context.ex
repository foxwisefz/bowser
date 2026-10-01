defmodule BowserBrain.AIContext do
  @moduledoc false
  @limit 262_144
  @notice "Earlier working context was reduced to fit the request. The saved mod conversation is unchanged. Re-read current mod files and diagnostics when needed; omitted results are not evidence of success."

  # Work only on the outgoing copy. Keep the owner prompt and tool-call pairs;
  # never truncate JSON arguments or erase the project's durable conversation.
  def fit(%{"input" => items} = body) when is_list(items), do: fit(body, "input")
  def fit(%{"messages" => items} = body) when is_list(items), do: fit(body, "messages")
  def fit(body), do: body

  defp fits?(body, key), do: byte_size(JSON.encode!(body)) <= @limit and length(body[key]) <= 100

  defp fit(body, key) do
    if fits?(body, key) do
      body
    else
      system = if key == "input", do: "instructions", else: "system"
      body = Map.update(body, system, @notice, &(&1 <> "\n\n" <> @notice))
      body = reduce_items(body, key, &omit_image/1)
      body = reduce_items(body, key, &shorten_result/1)
      body = reduce_pairs(body, key)
      reduce_items(body, key, fn item ->
        if item["role"] == "assistant" and not tool_call?(item), do: nil, else: item
      end)
    end
  end

  defp reduce_items(body, key, transform) do
    {items, _} = Enum.map_reduce(body[key], body, fn item, current ->
      if fits?(current, key) do
        {item, current}
      else
        replacement = transform.(item)
        # Replace only one occurrence, preserving ordering and duplicates.
        index = Enum.find_index(current[key], &(&1 == item))
        updated = if is_nil(replacement), do: List.delete_at(current[key], index),
          else: List.replace_at(current[key], index, replacement)
        {replacement, Map.put(current, key, updated)}
      end
    end)
    Map.put(body, key, Enum.reject(items, &is_nil/1))
  end

  defp omit_image(%{"content" => parts} = item) when is_list(parts) do
    Map.put(item, "content", Enum.map(parts, fn part ->
      if part["type"] in ["input_image", "image"] do
        type = if part["type"] == "input_image", do: "input_text", else: "text"
        %{"type" => type, "text" => "Screenshot omitted to fit the provider request. Capture again at max_width 320 if needed; this image has not been inspected."}
      else
        part
      end
    end))
  end
  defp omit_image(item), do: item

  defp shortened(value) when is_binary(value) and byte_size(value) > 4_096 do
    JSON.encode!(%{context_reduced: true, excerpt: String.slice(value, 0, 1_000),
      instruction: "Result abbreviated. Request a smaller excerpt or read the current file if needed."})
  end
  defp shortened(value), do: value

  defp shorten_result(%{"type" => "function_call_output", "output" => value} = item),
    do: Map.put(item, "output", shortened(value))
  defp shorten_result(%{"content" => parts} = item) when is_list(parts) do
    Map.put(item, "content", Enum.map(parts, fn
      %{"type" => "tool_result", "content" => value} = part -> Map.put(part, "content", shortened(value))
      part -> part
    end))
  end
  defp shorten_result(item), do: item

  defp call_id(%{"type" => "function_call", "call_id" => id}), do: id
  defp call_id(%{"content" => [%{"type" => "tool_use", "id" => id}]}), do: id
  defp call_id(_), do: nil
  defp result_id(%{"type" => "function_call_output", "call_id" => id}), do: id
  defp result_id(%{"content" => [%{"type" => "tool_result", "tool_use_id" => id}]}), do: id
  defp result_id(_), do: nil
  defp tool_call?(%{"content" => parts}) when is_list(parts),
    do: Enum.any?(parts, &(&1["type"] in ["tool_use", "tool_call", "function_call"]))
  defp tool_call?(item), do: not is_nil(call_id(item))

  defp reduce_pairs(body, key) do
    # Completed oldest calls are expendable; unmatched/pending calls stay intact.
    Enum.reduce(body[key], body, fn item, current ->
      id = call_id(item)
      if not fits?(current, key) and not is_nil(id) and Enum.any?(current[key], &(result_id(&1) == id)) do
        Map.put(current, key, Enum.reject(current[key], &(call_id(&1) == id or result_id(&1) == id)))
      else
        current
      end
    end)
  end
end
